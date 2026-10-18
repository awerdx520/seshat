// 本文件实现变更日志表的表级读写（M7 服务端地基：增量同步）。
//
// 设计取舍：changes 是「全局单调游标日志」——seq 由 SQLite AUTOINCREMENT 提供，
// 严格递增且不复用，客户端持有最后消费的 seq 作游标即可拉取增量。日志只追加、
// 不修改、不设 TTL（历史由调用方按需裁剪，本层不提供删除接口）。
//
// 本层只做表级读写；「什么操作产生哪种事件」由 internal/registry（A2）决定。
package storage

import (
	"database/sql"
	"strings"

	"seshat/internal/logging"
)

// 变更事件的操作类型常量。
const (
	// OpCreate 表示资源新建（PUT 新建 / COPY 目标 / 扫描发现）。
	OpCreate = "create"
	// OpUpdate 表示资源内容更新（同路径覆盖写）。
	OpUpdate = "update"
	// OpRename 表示资源移动/改名（uid 不变，OldPath 记旧路径）。
	OpRename = "rename"
	// OpDelete 表示资源删除（resources 写墓碑，本表的 path 保留删除前路径）。
	OpDelete = "delete"
)

// ListChanges 的 limit 默认值与上限。
//
// 默认 500 与 REST 端点 /api/changes 的 limit 默认值一致；上限 2000 防止单次响应
// 过大（客户端可循环分页）。
const (
	changeDefaultLimit = 500
	changeMaxLimit     = 2000
)

// Change 是 changes 表中的一条变更事件。
//
// OldPath 仅 rename 事件使用，其余为空串；Blob/Rev 为该事件对应的内容标识与版本，
// 尽力而为（空串表示未知）。
type Change struct {
	Seq       int64
	UID       string
	Op        string
	Root      string
	Path      string
	OldPath   string
	Blob      string
	Rev       string
	ChangedAt string
}

// AppendChange 追加一条变更事件并返回其 seq（由 SQLite 自增分配）。
//
// ChangedAt 为空时回填当前 UTC，非空则规范化为 UTC；Op 必须是 create/update/
// rename/delete 之一；uid/root/path 为空或时间戳非法返回 ErrInvalidArgument。
func (d *DB) AppendChange(c Change) (int64, error) {
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

	res, err := d.db.Exec(
		`INSERT INTO changes(uid, op, root, path, old_path, blob, rev, changed_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
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

// ListChanges 返回 seq > since 的一批变更事件（按 seq 升序），以及下一页游标与是否还有更多。
//
// 分页语义：实际按 limit+1 条查询以判断 hasMore；nextCursor 为本批最后一条的 seq
// （无记录时回传 since，使游标不倒退、客户端可安全重试）。limit <= 0 取默认 500，
// 超过 2000 夹紧为 2000，保证 [1, 2000] 区间内生效。
func (d *DB) ListChanges(since int64, limit int) ([]Change, int64, bool, error) {
	if limit <= 0 {
		limit = changeDefaultLimit
	}
	if limit > changeMaxLimit {
		limit = changeMaxLimit
	}
	if since < 0 {
		since = 0
	}

	rows, err := d.db.Query(
		`SELECT seq, uid, op, root, path, old_path, blob, rev, changed_at
		 FROM changes WHERE seq > ? ORDER BY seq ASC LIMIT ?`, since, limit+1)
	if err != nil {
		return nil, since, false, logging.Wrap(err, logging.ErrInternal, "列举变更事件失败")
	}
	defer func() { _ = rows.Close() }()

	// 返回空切片而非 nil，避免调用方序列化出 JSON null。
	items := make([]Change, 0, limit)
	for rows.Next() {
		var c Change
		if err := rows.Scan(&c.Seq, &c.UID, &c.Op, &c.Root, &c.Path,
			&c.OldPath, &c.Blob, &c.Rev, &c.ChangedAt); err != nil {
			return nil, since, false, logging.Wrap(err, logging.ErrInternal, "解析变更事件失败")
		}
		items = append(items, c)
	}
	if err := rows.Err(); err != nil {
		return nil, since, false, logging.Wrap(err, logging.ErrInternal, "遍历变更事件失败")
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}
	nextCursor := since
	if n := len(items); n > 0 {
		nextCursor = items[n-1].Seq
	}
	return items, nextCursor, hasMore, nil
}

// LatestChangeSeq 返回日志中最大的 seq；无任何事件时返回 0。
func (d *DB) LatestChangeSeq() (int64, error) {
	var seq sql.NullInt64
	if err := d.db.QueryRow(`SELECT MAX(seq) FROM changes`).Scan(&seq); err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "读取最新变更 seq 失败")
	}
	if !seq.Valid {
		return 0, nil
	}
	return seq.Int64, nil
}
