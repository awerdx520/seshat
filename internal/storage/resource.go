// 本文件实现资源登记表的表级 CRUD（M7 服务端地基：uid 身份）。
//
// 设计取舍：resources 是服务端权威的文件身份登记，uid 由服务端生成、跨改名稳定，
// 路径只是 uid 的当前属性；删除写墓碑（deleted_at 非空）而非物理删除，使「按 uid
// 追溯已删资源」与「变更日志指向同一实体」成立。本层只做表级读写，不做 uid 生成、
// 不做事件记录——那些属 internal/registry（A2）。
//
// 时间戳与包内既有约定一致：RFC3339 UTC 文本存储，入库前统一规范化（见
// normalizeOptionalTimestamp）；两者均为定长且以 Z 结尾，故字典序比较等价于时间序比较。
package storage

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"seshat/internal/logging"
)

// ResourceKindFile 是 resources.kind 的默认取值（普通文件）。
const ResourceKindFile = "file"

// defaultResourceListLimit 是 ListResources 在 Limit 非正数时采用的默认上限。
//
// 取 500 与 REST 端点 /api/changes 的默认 limit 保持一致：既避免「不限」在资源数
// 增长后一次拉全表，也避免调用方忘记传 limit 时意外拿到空列表。
const defaultResourceListLimit = 500

// Entry 是 resources 表中的一条资源登记。
//
// DeletedAt 为空串表示存活，非空（RFC3339 UTC）表示墓碑；墓碑记录仍保留 Path
// （删除前路径）以供追溯。
type Entry struct {
	UID       string
	Root      string
	Path      string
	Kind      string // "file"（默认）
	Blob      string
	Rev       string
	Size      int64
	Mtime     int64
	CreatedAt string
	UpdatedAt string
	DeletedAt string // 空串表示存活
}

// ResourceFilter 是 ListResources 的过滤条件；零值表示「全部存活资源」。
type ResourceFilter struct {
	Root           string
	Prefix         string // path 前缀（按「path = prefix」或「path 以 prefix + '/' 开头」精确匹配，大小写敏感、无通配）
	Since          int64  // 0 表示不限
	IncludeDeleted bool
	Limit          int
}

// rowScanner 抽象 *sql.Row 与 *sql.Rows 的公共扫描能力。
type rowScanner interface {
	Scan(dest ...any) error
}

// resourceColumns 是 resources 表的读取列清单。
//
// deleted_at 用 COALESCE 兜成空串：列本身允许 NULL（历史脚本未写 NOT NULL），
// 而 Go 侧统一用 string 表达存活，避免每处调用都处理 sql.NullString。
const resourceColumns = `uid, root, path, kind, blob, size, mtime, rev,
	created_at, updated_at, COALESCE(deleted_at, '')`

// scanResource 按 resourceColumns 的顺序扫描一行资源记录。
func scanResource(row rowScanner) (*Entry, error) {
	var e Entry
	if err := row.Scan(&e.UID, &e.Root, &e.Path, &e.Kind, &e.Blob,
		&e.Size, &e.Mtime, &e.Rev, &e.CreatedAt, &e.UpdatedAt, &e.DeletedAt); err != nil {
		return nil, err
	}
	return &e, nil
}

// normalizeOptionalTimestamp 规范化可选时间戳：空串原样返回空串（表示「未设置」），
// 非空则解析为 RFC3339 并转为 UTC 文本；格式非法返回 ErrInvalidArgument。
//
// 与 state.go 的 normalizeTimestamp 的区别在于空值语义：后者把空串解释为「当前时间」，
// 这里必须保留空串（如 DeletedAt 空串表示存活），故单独实现而非复用。
func normalizeOptionalTimestamp(ts string) (string, error) {
	if strings.TrimSpace(ts) == "" {
		return "", nil
	}
	parsed, err := time.Parse(timestampLayout, ts)
	if err != nil {
		return "", logging.Wrap(err, logging.ErrInvalidArgument, "时间戳必须是 RFC3339 格式")
	}
	return parsed.UTC().Format(timestampLayout), nil
}

// prepareResource 校验身份字段并规范化时间戳/Kind，返回可直接入库的副本。
//
// 时间语义：CreatedAt 为空时回填当前 UTC；UpdatedAt 为空时沿用 CreatedAt；
// DeletedAt 为空表示存活（存空串）。
func prepareResource(e Entry) (Entry, error) {
	if strings.TrimSpace(e.UID) == "" {
		return Entry{}, logging.NewAppError(logging.ErrInvalidArgument, "资源 uid 不能为空")
	}
	if strings.TrimSpace(e.Root) == "" {
		return Entry{}, logging.NewAppError(logging.ErrInvalidArgument, "资源 root 不能为空")
	}
	if strings.TrimSpace(e.Path) == "" {
		return Entry{}, logging.NewAppError(logging.ErrInvalidArgument, "资源 path 不能为空")
	}
	if strings.TrimSpace(e.Kind) == "" {
		e.Kind = ResourceKindFile
	}

	created, err := normalizeOptionalTimestamp(e.CreatedAt)
	if err != nil {
		return Entry{}, err
	}
	if created == "" {
		created = time.Now().UTC().Format(timestampLayout)
	}

	updated, err := normalizeOptionalTimestamp(e.UpdatedAt)
	if err != nil {
		return Entry{}, err
	}
	if updated == "" {
		updated = created
	}

	deleted, err := normalizeOptionalTimestamp(e.DeletedAt)
	if err != nil {
		return Entry{}, err
	}

	e.CreatedAt, e.UpdatedAt, e.DeletedAt = created, updated, deleted
	return e, nil
}

// isUniqueViolation 判断底层错误是否为 SQLite 唯一约束冲突。
//
// 说明：database/sql 层不暴露驱动无关的约束冲突错误，包内既有代码也无先例；两个
// 驱动的错误文本都包含 "UNIQUE constraint failed"，故按文本判定，命中则映射为
// ErrConflict。未命中时仍返回 ErrInternal，不会掩盖真实故障。
func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

// CreateResource 插入一条资源登记；同一 (root, path) 已登记时返回 ErrConflict，
// uid 重复同样返回 ErrConflict。身份字段为空或时间戳非法时返回 ErrInvalidArgument。
func (d *DB) CreateResource(e Entry) error {
	prepared, err := prepareResource(e)
	if err != nil {
		return err
	}

	_, err = d.db.Exec(
		`INSERT INTO resources(uid, root, path, kind, blob, size, mtime, rev, created_at, updated_at, deleted_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		prepared.UID, prepared.Root, prepared.Path, prepared.Kind, prepared.Blob,
		prepared.Size, prepared.Mtime, prepared.Rev, prepared.CreatedAt, prepared.UpdatedAt,
		nullIfEmpty(prepared.DeletedAt))
	if err != nil {
		if isUniqueViolation(err) {
			return logging.Wrap(err, logging.ErrConflict, "资源 uid 或路径已登记")
		}
		return logging.Wrap(err, logging.ErrInternal, "创建资源登记失败")
	}
	return nil
}

// UpsertResource 按 uid 写入或覆盖资源登记（存在则更新，不存在则插入）。
//
// 语义：以 uid 为冲突目标，更新时刷新 root/path/kind/blob/rev/size/mtime/updated_at
// 与墓碑位，但保留 created_at（首次登记时间不可被改写）。若 uid 未登记而 (root, path)
// 已被其它 uid 占用，则判定为身份冲突并返回 ErrConflict——同一路径不允许对应两个 uid。
func (d *DB) UpsertResource(e Entry) error {
	prepared, err := prepareResource(e)
	if err != nil {
		return err
	}

	_, err = d.db.Exec(
		`INSERT INTO resources(uid, root, path, kind, blob, size, mtime, rev, created_at, updated_at, deleted_at)
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
		   deleted_at = excluded.deleted_at`,
		prepared.UID, prepared.Root, prepared.Path, prepared.Kind, prepared.Blob,
		prepared.Size, prepared.Mtime, prepared.Rev, prepared.CreatedAt, prepared.UpdatedAt,
		nullIfEmpty(prepared.DeletedAt))
	if err != nil {
		if isUniqueViolation(err) {
			return logging.Wrap(err, logging.ErrConflict, "资源路径已被其它 uid 占用")
		}
		return logging.Wrap(err, logging.ErrInternal, "写入资源登记失败")
	}
	return nil
}

// GetResourceByUID 按 uid 读取单条资源登记（含墓碑记录）；不存在时返回 ErrNotFound。
func (d *DB) GetResourceByUID(uid string) (*Entry, error) {
	if strings.TrimSpace(uid) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "资源 uid 不能为空")
	}

	e, err := scanResource(d.db.QueryRow(
		`SELECT `+resourceColumns+` FROM resources WHERE uid = ?`, uid))
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, logging.Wrap(err, logging.ErrNotFound, "资源不存在")
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "读取资源失败")
	}
	return e, nil
}

// GetResourceByPath 按 (root, path) 读取当前路径上的资源登记；不存在时返回 ErrNotFound。
//
// 墓碑记录占用的路径仍可查到（其 DeletedAt 非空），是否会遇到由调用方判断；
// 本方法不隐藏墓碑，以保持「路径 → 登记行」的一一对应。
func (d *DB) GetResourceByPath(root, path string) (*Entry, error) {
	if strings.TrimSpace(root) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "资源 root 不能为空")
	}
	if strings.TrimSpace(path) == "" {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "资源 path 不能为空")
	}

	e, err := scanResource(d.db.QueryRow(
		`SELECT `+resourceColumns+` FROM resources WHERE root = ? AND path = ?`, root, path))
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, logging.Wrap(err, logging.ErrNotFound, "资源不存在")
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "读取资源失败")
	}
	return e, nil
}

// ListResources 按过滤条件列举资源，按 (root, path) 升序返回；无结果时返回空切片（非 nil）。
//
// 过滤口径：
//   - Root 非空：仅该根；
//   - Prefix 非空：按路径段前缀匹配（path = prefix，或 path 以 prefix + '/' 开头），
//     故 prefix="a" 命中 "a" 与 "a/b"，不命中 "ab"；比较按字节精确进行——大小写敏感
//     且 '%'、'_' 无通配含义（早先用 path LIKE prefix || '/%'，其 LIKE 对 ASCII 大小写
//     不敏感且未转义通配符，prefix="a_b" 会误命中 "aXb"，目录删除因此误伤无关资源）；
//   - Since > 0：按 mtime（Unix 秒）过滤 mtime >= Since；
//   - IncludeDeleted=false：只返回存活资源（deleted_at 为 NULL 或空串）；
//   - Limit <= 0：取默认上限 defaultResourceListLimit（500），不表示「不限」。
func (d *DB) ListResources(f ResourceFilter) ([]Entry, error) {
	where := make([]string, 0, 4)
	args := make([]any, 0, 5)

	if strings.TrimSpace(f.Root) != "" {
		where = append(where, "root = ?")
		args = append(args, f.Root)
	}
	// 去掉尾斜杠后统一按「路径段边界」比较，避免 Prefix="a/" 退化成 "a//%"。用 substr
	// 做定长比较而非 LIKE：语义是「精确字节前缀 + '/'」，既大小写敏感也不会被 % / _ 影响。
	if prefix := strings.TrimSuffix(strings.TrimSpace(f.Prefix), "/"); prefix != "" {
		where = append(where, "(path = ? OR substr(path, 1, length(?) + 1) = ? || '/')")
		args = append(args, prefix, prefix, prefix)
	}
	if f.Since > 0 {
		where = append(where, "mtime >= ?")
		args = append(args, f.Since)
	}
	if !f.IncludeDeleted {
		where = append(where, "(deleted_at IS NULL OR deleted_at = '')")
	}

	limit := f.Limit
	if limit <= 0 {
		limit = defaultResourceListLimit
	}

	query := `SELECT ` + resourceColumns + ` FROM resources`
	if len(where) > 0 {
		query += " WHERE " + strings.Join(where, " AND ")
	}
	query += " ORDER BY root, path LIMIT ?"
	args = append(args, limit)

	rows, err := d.db.Query(query, args...)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "列举资源失败")
	}
	defer func() { _ = rows.Close() }()

	// 返回空切片而非 nil，避免调用方序列化出 JSON null。
	items := make([]Entry, 0)
	for rows.Next() {
		e, err := scanResource(rows)
		if err != nil {
			return nil, logging.Wrap(err, logging.ErrInternal, "解析资源记录失败")
		}
		items = append(items, *e)
	}
	if err := rows.Err(); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "遍历资源记录失败")
	}
	return items, nil
}

// TombstoneResource 给资源写墓碑（deleted_at 与 updated_at 置 at），不做物理删除。
//
// at 为空时回填当前 UTC；格式非法返回 ErrInvalidArgument；uid 不存在返回 ErrNotFound。
// 重复写墓碑视为成功（幂等），仅刷新时间戳。
func (d *DB) TombstoneResource(uid, at string) error {
	if strings.TrimSpace(uid) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "资源 uid 不能为空")
	}
	ts, err := normalizeTimestamp(at)
	if err != nil {
		return err
	}

	res, err := d.db.Exec(
		`UPDATE resources SET deleted_at = ?, updated_at = ? WHERE uid = ?`, ts, ts, uid)
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

// RenameResource 移动资源：改 root 与 path，uid 保持不变，并把 updated_at 置 at。
//
// at 为空时回填当前 UTC。目标路径已被其它 uid 占用时返回 ErrConflict（UNIQUE 约束），
// uid 不存在返回 ErrNotFound，必填字段为空返回 ErrInvalidArgument。
func (d *DB) RenameResource(uid, root, path, at string) error {
	if strings.TrimSpace(uid) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "资源 uid 不能为空")
	}
	if strings.TrimSpace(root) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "资源 root 不能为空")
	}
	if strings.TrimSpace(path) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "资源 path 不能为空")
	}
	ts, err := normalizeTimestamp(at)
	if err != nil {
		return err
	}

	res, err := d.db.Exec(
		`UPDATE resources SET root = ?, path = ?, updated_at = ? WHERE uid = ?`,
		root, path, ts, uid)
	if err != nil {
		if isUniqueViolation(err) {
			return logging.Wrap(err, logging.ErrConflict, "目标路径已被其它 uid 占用")
		}
		return logging.Wrap(err, logging.ErrInternal, "移动资源失败")
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

// CountResources 返回存活资源数（不含墓碑）。
//
// 口径与 ListResources 的默认过滤一致：墓碑资源不算「登记中的资源」，
// 需要含墓碑的总行数时用 ListResources(IncludeDeleted: true) 的长度。
func (d *DB) CountResources() (int, error) {
	var n int
	err := d.db.QueryRow(
		`SELECT COUNT(*) FROM resources WHERE deleted_at IS NULL OR deleted_at = ''`).Scan(&n)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "统计资源数量失败")
	}
	return n, nil
}

// nullIfEmpty 把空串转为 NULL 写入（仅用于 deleted_at 这类可空列）。
func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
