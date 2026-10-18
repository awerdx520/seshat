// 本文件实现引用图的表级读写（M7 服务端地基：seshat: 引用解析）。
//
// 设计取舍：refs 是「源文档在某位置引用了目标文档」的多对多关系表，复合主键
// (source_uid, source_location, target_uid, target_location) 天然去重。写入口只提供
// 「整份替换」（ReplaceRefs）——.org 文件写入成功后重解析全文，用当前解析结果覆盖该
// source 的全部引用，避免增量 diff 的复杂度；替换在单事务内完成，读者看不到中间态。
package storage

import (
	"strings"
	"time"

	"seshat/internal/logging"
)

// 引用查询方向常量。
const (
	// RefDirectionIn 表示「谁引用了我」：按 target_uid 查询。
	RefDirectionIn = "in"
	// RefDirectionOut 表示「我引用了谁」：按 source_uid 查询。
	RefDirectionOut = "out"
)

// Ref 是引用图中的一条边。
type Ref struct {
	SourceUID      string
	SourceLocation string
	TargetUID      string
	TargetLocation string
	CreatedAt      string
}

// ReplaceRefs 用 refs 整份替换 sourceUID 的全部引用（单事务内先删后插）。
//
// 语义要点：
//   - refs 为空（nil 或空切片）表示清空该 source 的全部引用；
//   - 重复调用结果一致（幂等）；
//   - refs 元素的 SourceUID 字段被忽略，统一使用参数 sourceUID（避免调用方传参不一致）；
//   - CreatedAt 为空时回填当前 UTC，非空则规范化为 UTC。
//
// sourceUID 为空、任一元素 TargetUID 为空或时间戳非法时返回 ErrInvalidArgument，
// 且不写入任何数据（校验先于事务）。
func (d *DB) ReplaceRefs(sourceUID string, refs []Ref) error {
	if strings.TrimSpace(sourceUID) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "引用 source uid 不能为空")
	}

	now := time.Now().UTC().Format(timestampLayout)
	rows := make([]Ref, 0, len(refs))
	for _, r := range refs {
		if strings.TrimSpace(r.TargetUID) == "" {
			return logging.NewAppError(logging.ErrInvalidArgument, "引用 target uid 不能为空")
		}
		created, err := normalizeOptionalTimestamp(r.CreatedAt)
		if err != nil {
			return err
		}
		if created == "" {
			created = now
		}
		rows = append(rows, Ref{
			SourceUID:      sourceUID,
			SourceLocation: r.SourceLocation,
			TargetUID:      r.TargetUID,
			TargetLocation: r.TargetLocation,
			CreatedAt:      created,
		})
	}

	tx, err := d.db.Begin()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "开始替换引用事务失败")
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM refs WHERE source_uid = ?`, sourceUID); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "清除旧引用失败")
	}
	for _, r := range rows {
		// OR REPLACE 兜住「同一批次内重复边」的情形（复合主键冲突）。
		if _, err := tx.Exec(
			`INSERT OR REPLACE INTO refs(source_uid, source_location, target_uid, target_location, created_at)
			 VALUES(?, ?, ?, ?, ?)`,
			r.SourceUID, r.SourceLocation, r.TargetUID, r.TargetLocation, r.CreatedAt); err != nil {
			return logging.Wrap(err, logging.ErrInternal, "写入引用失败")
		}
	}

	if err := tx.Commit(); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "提交替换引用事务失败")
	}
	return nil
}

// ListRefs 按方向列举与 uid 相关的引用，按 (source_uid, source_location, target_uid,
// target_location) 升序返回；无结果时返回空切片（非 nil）。
//
// direction 取 in 时按 target_uid 查询（谁引用了我），取 out 时按 source_uid 查询
// （我引用了谁）；空串按 out 处理，其它取值返回 ErrInvalidArgument。
func (d *DB) ListRefs(uid, direction string) ([]Ref, error) {
	if strings.TrimSpace(uid) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "引用查询 uid 不能为空")
	}

	var column string
	switch direction {
	case "", RefDirectionOut:
		column = "source_uid"
	case RefDirectionIn:
		column = "target_uid"
	default:
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "direction 必须是 in 或 out")
	}

	// column 取自上面的固定白名单，不含外部输入，拼接安全。
	rows, err := d.db.Query(
		`SELECT source_uid, source_location, target_uid, target_location, created_at
		 FROM refs WHERE `+column+` = ?
		 ORDER BY source_uid, source_location, target_uid, target_location`, uid)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "列举引用失败")
	}
	defer func() { _ = rows.Close() }()

	// 返回空切片而非 nil，避免调用方序列化出 JSON null。
	items := make([]Ref, 0)
	for rows.Next() {
		var r Ref
		if err := rows.Scan(&r.SourceUID, &r.SourceLocation, &r.TargetUID,
			&r.TargetLocation, &r.CreatedAt); err != nil {
			return nil, logging.Wrap(err, logging.ErrInternal, "解析引用记录失败")
		}
		items = append(items, r)
	}
	if err := rows.Err(); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "遍历引用记录失败")
	}
	return items, nil
}
