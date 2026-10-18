// 本文件实现「资源登记 + 变更事件」的单事务写入（M7 服务端地基）。
//
// 设计取舍：登记表与变更日志必须始终一致——客户端以 changes 的游标拉增量，
// 若出现「资源已登记但没有对应事件」或「事件指向未登记的资源」，同步端就会
// 永久漏掉某个文件。因此这两次写入放进同一个 SQLite 事务，任一步失败即整体回滚。
//
// 事务边界刻意保持短：本层只做 SQL，不做文件 IO、不做内容哈希（那些由
// internal/registry 在事务外完成），避免长时间占用单写者连接（见 db.go 的
// SetMaxOpenConns(1)）。
package storage

import (
	"database/sql"
	"strings"

	"seshat/internal/logging"
)

// upsertResourceSQL 是资源登记写入语句（与 UpsertResource 的语义一致）。
//
// 冲突目标为 uid：更新时保留 created_at（首次登记时间不可被改写），刷新
// 其余可变字段与墓碑位；若 uid 未登记而 (root, path) 已被其它 uid 占用，
// 则触发 UNIQUE 冲突，由调用方映射为 ErrConflict。
const upsertResourceSQL = `INSERT INTO resources(uid, root, path, kind, blob, size, mtime, rev, created_at, updated_at, deleted_at)
	 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	 ON CONFLICT(uid) DO UPDATE SET
	   root = excluded.root,
	   path = excluded.path,
	   kind = excluded.kind,
	   blob = excluded.blob,
	   size = excluded.size,
	   mtime = excluded.mtime,
	   rev = excluded.rev,
	   updated_at = excluded.updated_at,
	   deleted_at = excluded.deleted_at`

// tombstoneResourceSQL 是墓碑写入语句：只改墓碑位与 updated_at，保留 path。
const tombstoneResourceSQL = `UPDATE resources SET deleted_at = ?, updated_at = ? WHERE uid = ?`

// insertChangeSQL 是变更事件追加语句（seq 由 AUTOINCREMENT 分配）。
const insertChangeSQL = `INSERT INTO changes(uid, op, root, path, old_path, blob, rev, changed_at)
	 VALUES(?, ?, ?, ?, ?, ?, ?, ?)`

// ApplyResourceChange 在单事务内 upsert 一条 resources 记录并追加一条 changes 记录，
// 返回新 change 的 seq（由 SQLite AUTOINCREMENT 分配）。
//
// 资源写入有两种形态，由 e.DeletedAt 区分：
//   - 空串：按 uid upsert（含改名——path 变化即改名，uid 与 created_at 保持不变）；
//   - 非空：写墓碑（等同 TombstoneResource 语义），uid 未登记时返回 ErrNotFound。
//
// 事件校验（uid/op/root/path 必填、op 取值受限、时间戳格式）在事务内执行：
// 校验失败或插入失败都会连同上一步的资源写入一起回滚，这正是回归测试
// 「change 插入失败时 resource 不落库」所验证的行为。
func (d *DB) ApplyResourceChange(e Entry, c Change) (int64, error) {
	prepared, err := prepareResource(e)
	if err != nil {
		return 0, err
	}

	tx, err := d.db.Begin()
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "开始资源变更事务失败")
	}
	defer func() { _ = tx.Rollback() }()

	if err := writeResourceTx(tx, prepared); err != nil {
		return 0, err
	}

	seq, err := appendChangeTx(tx, c)
	if err != nil {
		return 0, err
	}

	if err := tx.Commit(); err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "提交资源变更事务失败")
	}
	return seq, nil
}

// writeResourceTx 在事务内写入资源登记（墓碑或 upsert）。
func writeResourceTx(tx *sql.Tx, e Entry) error {
	if e.DeletedAt != "" {
		res, err := tx.Exec(tombstoneResourceSQL, e.DeletedAt, e.UpdatedAt, e.UID)
		if err != nil {
			return logging.Wrap(err, logging.ErrInternal, "写入资源墓碑失败")
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return logging.Wrap(err, logging.ErrInternal, "读取更新影响行数失败")
		}
		if affected == 0 {
			return logging.Wrap(sql.ErrNoRows, logging.ErrNotFound, "资源不存在")
		}
		return nil
	}

	_, err := tx.Exec(upsertResourceSQL,
		e.UID, e.Root, e.Path, e.Kind, e.Blob, e.Size, e.Mtime, e.Rev,
		e.CreatedAt, e.UpdatedAt, nullIfEmpty(e.DeletedAt))
	if err != nil {
		if isUniqueViolation(err) {
			return logging.Wrap(err, logging.ErrConflict, "资源路径已被其它 uid 占用")
		}
		return logging.Wrap(err, logging.ErrInternal, "写入资源登记失败")
	}
	return nil
}

// appendChangeTx 在事务内追加一条变更事件，返回其 seq。
//
// 校验口径与 AppendChange 完全一致（uid/root/path 必填、op 四值、时间戳 RFC3339），
// 区别只在于执行发生在调用方事务内。
func appendChangeTx(tx *sql.Tx, c Change) (int64, error) {
	if strings.TrimSpace(c.UID) == "" {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "变更 uid 不能为空")
	}
	switch c.Op {
	case OpCreate, OpUpdate, OpRename, OpDelete:
	default:
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "变更 op 必须是 create/update/rename/delete")
	}
	if strings.TrimSpace(c.Root) == "" {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "变更 root 不能为空")
	}
	if strings.TrimSpace(c.Path) == "" {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "变更 path 不能为空")
	}
	ts, err := normalizeTimestamp(c.ChangedAt)
	if err != nil {
		return 0, err
	}

	res, err := tx.Exec(insertChangeSQL,
		c.UID, c.Op, c.Root, c.Path, c.OldPath, c.Blob, c.Rev, ts)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "追加变更事件失败")
	}
	seq, err := res.LastInsertId()
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "读取变更事件 seq 失败")
	}
	return seq, nil
}
