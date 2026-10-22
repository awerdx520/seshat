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
	"sync"
	"time"

	"seshat/internal/logging"
)

// timestampLayout 是进度/批注时间列的存储格式。
const timestampLayout = time.RFC3339

// annotationCreateMu 串行化 CreateAnnotation 的「find → insert」临界区。
//
// 竞态背景：CreateAnnotation 先按幂等键 findAnnotationByContent 查询、再裸 INSERT，
// 两步各向连接池取一次连接；db.go 的 SetMaxOpenConns(1) 只把「单条语句」串行化，
// 并不保证 find 与 insert 之间的窗口原子——两个 goroutine 交错时会都查不到，然后
// 各插一行，服务端因而出现重复批注，违反 (uid, kind, location, text) 唯一、命中
// 返回既有记录的幂等契约。
//
// 为什么进程内互斥足够：本服务是单进程 SQLite 服务（见 db.go 的 SetMaxOpenConns(1)
// 与单写者模型注释），同一时刻只有一个进程写这份库，故进程内互斥即可保证临界区
// 原子。跨进程 / 多实例部署（多个进程或容器共享同一个 db 文件）才需要
// UNIQUE(uid, kind, location, text) 索引兜底，属后续加固——本版有意不加迁移、不改
// schema（加唯一索引还需同时处理重复行的清理与 409/500 的错误映射）。
//
// 锁的作用域：包级而非 DB 实例级。DB 实例通常只有进程内一个，包级锁实现最简单，
// 代价是不同库实例的创建也被串行化——该操作是毫秒级的单行读写，可接受。
var annotationCreateMu sync.Mutex

// Progress 是单个文档的最新阅读进度；文档以 uid 标识（M7 起为服务端权威身份）。
type Progress struct {
	UID       string
	Position  string
	UpdatedAt string
}

// annotationKindNote 是批注的缺省形态：带备注正文的文本批注。
//
// 服务端不对 kind 做枚举校验（约定取值 note / highlight / ink，见 docs/api.md
// §4），该常量只用于「kind 缺省兜底」与「text 是否必填」两处判定。
const annotationKindNote = "note"

// annotationColumns 是批注查询统一使用的列清单，顺序与 scanAnnotation 的扫描
// 顺序严格一致；新增批注列时必须同时改这两处，避免各条 SQL 的列顺序漂移。
const annotationColumns = `id, uid, kind, location, text, selected_text, created_at, updated_at`

// Annotation 是单条批注；uid 指向所属文档。
//
// Kind 区分批注形态（约定 note / highlight / ink，服务端不做枚举校验）；
// SelectedText 保存高亮等形态的选中原文；Text 仍是备注正文/显示摘要
// （kind 为 highlight / ink 时为空串）。
type Annotation struct {
	ID           int64
	UID          string
	Kind         string
	Location     string
	Text         string
	SelectedText string
	CreatedAt    string
	UpdatedAt    string
}

// SetProgress 写入或覆盖文档的阅读进度（同 uid 后写覆盖）。
//
// 乐观冲突检测：当客户端显式提供 updatedAt（非空）且服务端已存记录的
// updated_at 晚于该值（即客户端基于旧版本写入）时，返回 ErrConflict 且不覆盖；
// 相等或更新则正常覆盖。updatedAt 为空时回填当前 UTC 时间并视为无条件写入，
// 以保持向后兼容。非 RFC3339 格式、或 uid/position 为空时返回
// ErrInvalidArgument 包装的错误。
func (d *DB) SetProgress(uid, position, updatedAt string) error {
	if strings.TrimSpace(uid) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "uid 不能为空")
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
			`SELECT updated_at FROM reading_progress WHERE uid = ?`, uid, ts); err != nil {
			return err
		}
	}

	// UPSERT：uid 为主键，冲突时覆盖 position 与 updated_at（后写覆盖语义）。
	_, err = d.db.Exec(
		`INSERT INTO reading_progress(uid, position, updated_at) VALUES(?, ?, ?)
		 ON CONFLICT(uid) DO UPDATE SET position = excluded.position, updated_at = excluded.updated_at`,
		uid, position, ts)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "写入阅读进度失败")
	}
	return nil
}

// GetProgress 读取文档的阅读进度；不存在时返回 ErrNotFound 包装的错误。
func (d *DB) GetProgress(uid string) (*Progress, error) {
	if strings.TrimSpace(uid) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "uid 不能为空")
	}

	var p Progress
	err := d.db.QueryRow(
		`SELECT uid, position, updated_at FROM reading_progress WHERE uid = ?`,
		uid).Scan(&p.UID, &p.Position, &p.UpdatedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, logging.Wrap(err, logging.ErrNotFound, "阅读进度不存在")
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "读取阅读进度失败")
	}
	return &p, nil
}

// CreateAnnotation 新建一条批注，created_at/updated_at 由服务端以当前 UTC 时间填充，
// 返回包含自增 id 与时间戳的完整记录；第二个返回值表示本次是否真的新建了记录。
//
// kind 缺省（空串或全空白）由本层兜底为 note——API 层缺省只作文档说明，反序列化后
// 的空 kind 会进显式 INSERT 语句，SQL 的 DEFAULT 'note' 不会生效。兜底必须发生在
// 校验之前，否则缺省 kind 的请求会被误判为「未知 kind 允许空 text」。
//
// 校验口径：uid、location 非空；仅 kind == note 时要求 text 非空，
// highlight / ink 以及任何未知 kind 一律允许空 text（服务端不做 kind 枚举校验）。
//
// 幂等去重：先按 (uid, kind, location, text) 查询既有记录（selected_text 不参与
// 键），命中则原样返回既有记录且 isNew = false——不插新行、不刷新 updated_at。
// 该语义使「本地已有批注/笔迹的一次性补登」可安全重放；同 location 不同 kind
// 视为两条独立批注。查询与插入在同一临界区内完成（annotationCreateMu），使并发
// 重放同一幂等键也不会各插一行。
//
// kind 归一化：本方法对 kind 统一做 strings.TrimSpace，使 " note " 与 "note" 等价
// （否则带空白的 note 不会命中「text 必填」分支，可绕过校验），"  " 兜底为 note。归一
// 化后的值参与落库与去重键，故返回值的 Kind 也是归一化形态。
func (d *DB) CreateAnnotation(uid, location, kind, text, selectedText string) (*Annotation, bool, error) {
	// kind 归一化与缺省兜底先于校验，见方法注释。
	kind = strings.TrimSpace(kind)
	if kind == "" {
		kind = annotationKindNote
	}
	if strings.TrimSpace(uid) == "" {
		return nil, false, logging.NewAppError(logging.ErrInvalidArgument, "uid 不能为空")
	}
	if location == "" {
		return nil, false, logging.NewAppError(logging.ErrInvalidArgument, "location 不能为空")
	}
	if kind == annotationKindNote && text == "" {
		return nil, false, logging.NewAppError(logging.ErrInvalidArgument, "text 不能为空")
	}

	// 临界区只含 find → insert（校验已在锁外完成，无共享状态参与），
	// 使「查不到就插」成为原子判定，见 annotationCreateMu 的注释。
	annotationCreateMu.Lock()
	defer annotationCreateMu.Unlock()

	existing, err := d.findAnnotationByContent(uid, kind, location, text)
	if err != nil {
		return nil, false, err
	}
	if existing != nil {
		return existing, false, nil
	}

	now := time.Now().UTC().Format(timestampLayout)
	res, err := d.db.Exec(
		`INSERT INTO annotations(uid, kind, location, text, selected_text, created_at, updated_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?)`,
		uid, kind, location, text, selectedText, now, now)
	if err != nil {
		return nil, false, logging.Wrap(err, logging.ErrInternal, "创建批注失败")
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, false, logging.Wrap(err, logging.ErrInternal, "读取新批注 id 失败")
	}

	return &Annotation{
		ID:           id,
		UID:          uid,
		Kind:         kind,
		Location:     location,
		Text:         text,
		SelectedText: selectedText,
		CreatedAt:    now,
		UpdatedAt:    now,
	}, true, nil
}

// findAnnotationByContent 按幂等键 (uid, kind, location, text) 查找既有批注；
// 未命中返回 (nil, nil)。selected_text 有意不参与匹配（同一处选中原文的多次补登
// 应命同一条记录）。
func (d *DB) findAnnotationByContent(uid, kind, location, text string) (*Annotation, error) {
	row := d.db.QueryRow(
		`SELECT `+annotationColumns+`
		 FROM annotations
		 WHERE uid = ? AND kind = ? AND location = ? AND text = ?
		 ORDER BY id LIMIT 1`,
		uid, kind, location, text)

	a, err := scanAnnotation(row)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "查询既有批注失败")
	}
	return a, nil
}

// ListAnnotations 按 id 升序返回指定文档的全部批注；无结果时返回空切片（非 nil）。
func (d *DB) ListAnnotations(uid string) ([]Annotation, error) {
	if strings.TrimSpace(uid) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "uid 不能为空")
	}

	rows, err := d.db.Query(
		`SELECT `+annotationColumns+`
		 FROM annotations WHERE uid = ? ORDER BY id`, uid)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "列举批注失败")
	}
	defer func() { _ = rows.Close() }()

	// 返回空切片而非 nil，避免调用方序列化出 JSON null。
	items := make([]Annotation, 0)
	for rows.Next() {
		a, err := scanAnnotation(rows)
		if err != nil {
			return nil, logging.Wrap(err, logging.ErrInternal, "解析批注记录失败")
		}
		items = append(items, *a)
	}
	if err := rows.Err(); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "遍历批注记录失败")
	}
	return items, nil
}

// UpdateAnnotation 整体替换批注的 location、kind、text 与 selected_text，保留
// created_at 并刷新 updated_at。目标 id 不存在时返回 ErrNotFound，字段校验口径与
// CreateAnnotation 一致（kind 缺省兜底为 note，仅 note 要求 text 非空）。
//
// 该方法是 UpdateAnnotationAt(id, location, kind, text, selectedText, "") 的便捷
// 形式：不携带客户端时间戳，即无条件覆盖（保持向后兼容）。
func (d *DB) UpdateAnnotation(
	id int64, location, kind, text, selectedText string) (*Annotation, error) {
	return d.UpdateAnnotationAt(id, location, kind, text, selectedText, "")
}

// UpdateAnnotationAt 整体替换批注的 location、kind、text 与 selected_text，保留
// created_at。
//
// 校验口径与 CreateAnnotation 相同：kind 先 TrimSpace 归一化再兜底（"  " → note，
// " note " 等价 note），仅 note 要求 text 非空，
// 因此 note → highlight 的改造（text 置空）与 highlight → note 的改造（补 text）
// 都由调用方显式给出 kind 与 text 决定。
//
// 乐观冲突检测：updatedAt 非空时既作为新的 updated_at，又用于比较——若服务端
// 已存记录的 updated_at 晚于该值（客户端基于旧版本写入），返回 ErrConflict 且
// 不覆盖。updatedAt 为空时由服务端回填当前 UTC 时间并视为无条件覆盖（等价于
// UpdateAnnotation）。目标 id 不存在时返回 ErrNotFound，必填字段为空或时间戳
// 格式非法时返回 ErrInvalidArgument。
func (d *DB) UpdateAnnotationAt(
	id int64, location, kind, text, selectedText, updatedAt string) (*Annotation, error) {
	// kind 归一化与缺省兜底先于校验，与 CreateAnnotation 同口径：TrimSpace 使
	// " note " 等价 note（因而要求 text 非空），"  " 兜底为 note。
	kind = strings.TrimSpace(kind)
	if kind == "" {
		kind = annotationKindNote
	}
	if id <= 0 {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "批注 id 非法")
	}
	if location == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "location 不能为空")
	}
	if kind == annotationKindNote && text == "" {
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
		`UPDATE annotations
		 SET location = ?, kind = ?, text = ?, selected_text = ?, updated_at = ?
		 WHERE id = ?`,
		location, kind, text, selectedText, ts, id)
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

// scanAnnotation 按 annotationColumns 的声明顺序扫描一行批注。
//
// rowScanner 复用 resource.go 的既有定义（*sql.Row 与 *sql.Rows 的共同扫描能力），
// 避免同一包里出现两份同义接口。
func scanAnnotation(row rowScanner) (*Annotation, error) {
	var a Annotation
	if err := row.Scan(&a.ID, &a.UID, &a.Kind, &a.Location, &a.Text, &a.SelectedText,
		&a.CreatedAt, &a.UpdatedAt); err != nil {
		return nil, err
	}
	return &a, nil
}

// getAnnotation 按 id 读取单条批注，供更新后回读使用。
func (d *DB) getAnnotation(id int64) (*Annotation, error) {
	row := d.db.QueryRow(
		`SELECT `+annotationColumns+` FROM annotations WHERE id = ?`, id)

	a, err := scanAnnotation(row)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, logging.Wrap(err, logging.ErrNotFound, "批注不存在")
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "读取批注失败")
	}
	return a, nil
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
