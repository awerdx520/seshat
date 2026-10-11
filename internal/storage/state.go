// 本文件实现阅读进度与批注的持久化（M1.4 REST 状态同步的数据层）。
//
// 设计取舍：这两个实体是「结构化小状态」，与文件同步（WebDAV）分离，存 SQLite 表；
// 时间戳一律以 RFC3339（UTC）文本存储，允许由客户端提供，以便与客户端就增量同步
// （If-Modified-Since）达成一致。
package storage

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"notes/internal/logging"
)

// timestampLayout 是进度/批注时间列的存储格式。
const timestampLayout = time.RFC3339

// Progress 是单个文档的最新阅读进度。
type Progress struct {
	DocumentID string
	Position   string
	UpdatedAt  string
}

// Annotation 是单条批注。
type Annotation struct {
	ID         int64
	DocumentID string
	Location   string
	Text       string
	CreatedAt  string
	UpdatedAt  string
}

// SetProgress 写入或覆盖文档的阅读进度（同 document_id 后写覆盖）。
//
// 乐观冲突检测：当客户端显式提供 updatedAt（非空）且服务端已存记录的
// updated_at 晚于该值（即客户端基于旧版本写入）时，返回 ErrConflict 且不覆盖；
// 相等或更新则正常覆盖。updatedAt 为空时回填当前 UTC 时间并视为无条件写入，
// 以保持向后兼容。非 RFC3339 格式、或 documentID/position 为空时返回
// ErrInvalidArgument 包装的错误。
func (d *DB) SetProgress(documentID, position, updatedAt string) error {
	if strings.TrimSpace(documentID) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "document_id 不能为空")
	}
	if position == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "position 不能为空")
	}
	ts, err := normalizeTimestamp(updatedAt)
	if err != nil {
		return err
	}

	// 仅在客户端带了时间戳时做冲突检测；空时间戳表示无条件写入。
	if strings.TrimSpace(updatedAt) != "" {
		if err := d.assertNotStale(
			`SELECT updated_at FROM reading_progress WHERE document_id = ?`, documentID, ts); err != nil {
			return err
		}
	}

	// UPSERT：document_id 为主键，冲突时覆盖 position 与 updated_at（后写覆盖语义）。
	_, err = d.db.Exec(
		`INSERT INTO reading_progress(document_id, position, updated_at) VALUES(?, ?, ?)
		 ON CONFLICT(document_id) DO UPDATE SET position = excluded.position, updated_at = excluded.updated_at`,
		documentID, position, ts)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "写入阅读进度失败")
	}
	return nil
}

// GetProgress 读取文档的阅读进度；不存在时返回 ErrNotFound 包装的错误。
func (d *DB) GetProgress(documentID string) (*Progress, error) {
	if strings.TrimSpace(documentID) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "document_id 不能为空")
	}

	var p Progress
	err := d.db.QueryRow(
		`SELECT document_id, position, updated_at FROM reading_progress WHERE document_id = ?`,
		documentID).Scan(&p.DocumentID, &p.Position, &p.UpdatedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, logging.Wrap(err, logging.ErrNotFound, "阅读进度不存在")
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "读取阅读进度失败")
	}
	return &p, nil
}

// CreateAnnotation 新建一条批注，created_at/updated_at 由服务端以当前 UTC 时间填充，
// 返回包含自增 id 与时间戳的完整记录。必填字段为空时返回 ErrInvalidArgument。
func (d *DB) CreateAnnotation(documentID, location, text string) (*Annotation, error) {
	if strings.TrimSpace(documentID) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "document_id 不能为空")
	}
	if location == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "location 不能为空")
	}
	if text == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "text 不能为空")
	}

	now := time.Now().UTC().Format(timestampLayout)
	res, err := d.db.Exec(
		`INSERT INTO annotations(document_id, location, text, created_at, updated_at) VALUES(?, ?, ?, ?, ?)`,
		documentID, location, text, now, now)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "创建批注失败")
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "读取新批注 id 失败")
	}

	return &Annotation{
		ID:         id,
		DocumentID: documentID,
		Location:   location,
		Text:       text,
		CreatedAt:  now,
		UpdatedAt:  now,
	}, nil
}

// ListAnnotations 按 id 升序返回指定文档的全部批注；无结果时返回空切片（非 nil）。
func (d *DB) ListAnnotations(documentID string) ([]Annotation, error) {
	if strings.TrimSpace(documentID) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "document_id 不能为空")
	}

	rows, err := d.db.Query(
		`SELECT id, document_id, location, text, created_at, updated_at
		 FROM annotations WHERE document_id = ? ORDER BY id`, documentID)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "列举批注失败")
	}
	defer func() { _ = rows.Close() }()

	// 返回空切片而非 nil，避免调用方序列化出 JSON null。
	items := make([]Annotation, 0)
	for rows.Next() {
		var a Annotation
		if err := rows.Scan(&a.ID, &a.DocumentID, &a.Location, &a.Text, &a.CreatedAt, &a.UpdatedAt); err != nil {
			return nil, logging.Wrap(err, logging.ErrInternal, "解析批注记录失败")
		}
		items = append(items, a)
	}
	if err := rows.Err(); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "遍历批注记录失败")
	}
	return items, nil
}

// UpdateAnnotation 整体替换批注的 location 与 text，保留 created_at 并刷新 updated_at。
// 目标 id 不存在时返回 ErrNotFound，必填字段为空时返回 ErrInvalidArgument。
//
// 该方法是 UpdateAnnotationAt(id, location, text, "") 的便捷形式：不携带客户端
// 时间戳，即无条件覆盖（保持向后兼容）。
func (d *DB) UpdateAnnotation(id int64, location, text string) (*Annotation, error) {
	return d.UpdateAnnotationAt(id, location, text, "")
}

// UpdateAnnotationAt 整体替换批注的 location 与 text，保留 created_at。
//
// 乐观冲突检测：updatedAt 非空时既作为新的 updated_at，又用于比较——若服务端
// 已存记录的 updated_at 晚于该值（客户端基于旧版本写入），返回 ErrConflict 且
// 不覆盖。updatedAt 为空时由服务端回填当前 UTC 时间并视为无条件覆盖（等价于
// UpdateAnnotation）。目标 id 不存在时返回 ErrNotFound，必填字段为空或时间戳
// 格式非法时返回 ErrInvalidArgument。
func (d *DB) UpdateAnnotationAt(id int64, location, text, updatedAt string) (*Annotation, error) {
	if id <= 0 {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "批注 id 非法")
	}
	if location == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "location 不能为空")
	}
	if text == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "text 不能为空")
	}
	ts, err := normalizeTimestamp(updatedAt)
	if err != nil {
		return nil, err
	}

	// 仅在客户端带了时间戳时做冲突检测；空时间戳表示无条件覆盖。
	// 目标 id 不存在时 assertNotStale 视作可写，随后 UPDATE 影响 0 行会返回 ErrNotFound。
	if strings.TrimSpace(updatedAt) != "" {
		if err := d.assertNotStale(
			`SELECT updated_at FROM annotations WHERE id = ?`, id, ts); err != nil {
			return nil, err
		}
	}

	res, err := d.db.Exec(
		`UPDATE annotations SET location = ?, text = ?, updated_at = ? WHERE id = ?`,
		location, text, ts, id)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "更新批注失败")
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "读取更新影响行数失败")
	}
	if affected == 0 {
		return nil, logging.Wrap(sql.ErrNoRows, logging.ErrNotFound, "批注不存在")
	}

	return d.getAnnotation(id)
}

// DeleteAnnotation 删除指定批注；目标不存在时返回 ErrNotFound 包装的错误。
func (d *DB) DeleteAnnotation(id int64) error {
	if id <= 0 {
		return logging.NewAppError(logging.ErrInvalidArgument, "批注 id 非法")
	}

	res, err := d.db.Exec(`DELETE FROM annotations WHERE id = ?`, id)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "删除批注失败")
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取删除影响行数失败")
	}
	if affected == 0 {
		return logging.Wrap(sql.ErrNoRows, logging.ErrNotFound, "批注不存在")
	}
	return nil
}

// getAnnotation 按 id 读取单条批注，供更新后回读使用。
func (d *DB) getAnnotation(id int64) (*Annotation, error) {
	var a Annotation
	err := d.db.QueryRow(
		`SELECT id, document_id, location, text, created_at, updated_at FROM annotations WHERE id = ?`,
		id).Scan(&a.ID, &a.DocumentID, &a.Location, &a.Text, &a.CreatedAt, &a.UpdatedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, logging.Wrap(err, logging.ErrNotFound, "批注不存在")
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "读取批注失败")
	}
	return &a, nil
}

// normalizeTimestamp 将可选的 RFC3339 时间戳规范化为 UTC 文本；
// 传入空字符串时返回当前 UTC 时间，格式非法时返回 ErrInvalidArgument。
func normalizeTimestamp(ts string) (string, error) {
	if strings.TrimSpace(ts) == "" {
		return time.Now().UTC().Format(timestampLayout), nil
	}
	parsed, err := time.Parse(timestampLayout, ts)
	if err != nil {
		return "", logging.Wrap(err, logging.ErrInvalidArgument, "updated_at 必须是 RFC3339 时间戳")
	}
	return parsed.UTC().Format(timestampLayout), nil
}

// assertNotStale 读取 query 命中的现有 updated_at，若其晚于 incoming 则返回
// ErrConflict（乐观冲突检测）；无现有记录时视为可写（返回 nil）。
//
// query 必须按单个参数查询并只返回 updated_at 一列；incoming 需是经
// normalizeTimestamp 规范化的 RFC3339 UTC 文本，与库中存储格式一致——两者均
// 以 Z 结尾且定长，故字典序比较等价于时间序比较。
func (d *DB) assertNotStale(query string, key any, incoming string) error {
	var existing string
	err := d.db.QueryRow(query, key).Scan(&existing)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil
	case err != nil:
		return logging.Wrap(err, logging.ErrInternal, "读取现有 updated_at 失败")
	}
	if existing > incoming {
		return logging.NewAppError(logging.ErrConflict, "客户端 updated_at 早于服务端记录，拒绝覆盖")
	}
	return nil
}
