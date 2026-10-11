// Package index 提供笔记正文的全文检索索引（M1.6）。
//
// 实现基于 SQLite FTS5 虚表 notes_fts（见 storage 迁移 v4），FTS5 扩展由纯 Go
// 驱动 modernc.org/sqlite 提供（无需 CGO）。索引以文件相对路径 path（标为
// UNINDEXED，仅随结果回填、用于定位文件）为键，content 为被索引正文。
//
// 增量更新策略：写入前先按 path 删除旧行、再插入新行，使同一文件的索引始终
// 反映最新内容（覆盖语义）；文件被删除时直接删除其索引行。检索用 MATCH 并把
// 用户输入作为整体参数绑定，不做 SQL 字符串拼接，避免注入。
//
// 本包只依赖 storage.DB 的 SQL() 访问器，不感知 WebDAV/git，索引的触发由
// 调用方（internal/webdav）在写操作完成后负责。
package index

import (
	"strings"

	"notes/internal/logging"
	"notes/internal/storage"
)

// defaultLimit 是 Search 未显式指定上限（limit<=0）时返回的最大结果数。
const defaultLimit = 20

// Indexer 维护笔记正文的全文索引，底层复用 storage.DB 的 SQLite 连接。
//
// 并发说明：storage 的连接池已被限制为单连接，且本包写操作在事务内完成，
// 调用方无需额外串行化。
type Indexer struct {
	db *storage.DB
}

// New 构造索引器；db 须为已打开并完成迁移（含 notes_fts 虚表）的存储层。
func New(db *storage.DB) *Indexer {
	return &Indexer{db: db}
}

// Index 以 path 为键更新全文索引：先删除该 path 的旧行，再插入新内容，保证
// 同一文件的索引始终是最新的（覆盖语义）。两步在同一事务内完成，避免出现
// 「旧行已删、新行未插」的中间态被并发查询看到。
//
// path 为空（或仅空白）时返回 ErrInvalidArgument 包装的错误；索引器未初始化
// （nil 接收者或 db 为 nil）时同样返回错误。
func (ix *Indexer) Index(path, content string) error {
	if ix == nil || ix.db == nil {
		return logging.NewAppError(logging.ErrInvalidArgument, "索引器未初始化")
	}
	if strings.TrimSpace(path) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "索引路径不能为空")
	}

	tx, err := ix.db.SQL().Begin()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "开始索引事务失败")
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`DELETE FROM notes_fts WHERE path = ?`, path); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "删除旧索引失败")
	}
	if _, err := tx.Exec(`INSERT INTO notes_fts(path, content) VALUES(?, ?)`, path, content); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "写入索引失败")
	}
	if err := tx.Commit(); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "提交索引事务失败")
	}
	return nil
}

// Delete 删除 path 对应的全文索引行（文件被删除时调用）。path 不存在时为无操作
// （DELETE 影响 0 行即成功）；path 为空时直接返回 nil。索引器未初始化时返回错误。
func (ix *Indexer) Delete(path string) error {
	if ix == nil || ix.db == nil {
		return logging.NewAppError(logging.ErrInvalidArgument, "索引器未初始化")
	}
	if strings.TrimSpace(path) == "" {
		return nil
	}

	if _, err := ix.db.SQL().Exec(`DELETE FROM notes_fts WHERE path = ?`, path); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "删除索引失败")
	}
	return nil
}

// Search 以 query 对已索引正文做 FTS5 MATCH 查询，按相关性（内置 rank 列）排序
// 后返回命中的 path 列表，最多 limit 条（limit<=0 时取默认值 defaultLimit）。
//
// query 作为整体参数绑定到 MATCH，不做字符串拼接，因而注入不可能；但 FTS5 的
// MATCH 表达式本身对语法敏感，非法表达式（如未闭合引号）会由 SQLite 报错——该
// 情形属客户端输入错误，映射为 ErrInvalidArgument（API 层返回 400）而非内部错误。
// 空 query（仅空白）直接返回 nil，避免 FTS5 对空 MATCH 表达式报语法错误。
func (ix *Indexer) Search(query string, limit int) ([]string, error) {
	if ix == nil || ix.db == nil {
		return nil, logging.NewAppError(logging.ErrInvalidArgument, "索引器未初始化")
	}
	if strings.TrimSpace(query) == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = defaultLimit
	}

	rows, err := ix.db.SQL().Query(
		`SELECT path FROM notes_fts WHERE notes_fts MATCH ? ORDER BY rank LIMIT ?`,
		query, limit)
	if err != nil {
		// 用户输入直接作为 FTS5 MATCH 表达式（整体绑定，无注入）；非法语法
		// （未闭合引号、悬空操作符等）是客户端错误，映射为 ErrInvalidArgument，
		// 让 API 层返回 400，而非把输入问题当作服务端内部错误（500）。
		if isInvalidMatchError(err) {
			return nil, logging.Wrap(err, logging.ErrInvalidArgument, "全文检索查询语法非法")
		}
		return nil, logging.Wrap(err, logging.ErrInternal, "全文检索失败")
	}
	defer func() { _ = rows.Close() }()

	var paths []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, logging.Wrap(err, logging.ErrInternal, "解析检索结果失败")
		}
		paths = append(paths, p)
	}
	if err := rows.Err(); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "遍历检索结果失败")
	}
	return paths, nil
}

// isInvalidMatchError 判断错误是否来自 FTS5 的 MATCH 表达式语法错误。
// modernc.org/sqlite 把 FTS5 语法错误包装为形如
// "SQL logic error: fts5: syntax error near ..." 的消息，据此按关键字识别。
// 仅在错误确实来自 MATCH 语法时返回 true，避免把其它内部错误误判为客户端错误。
func isInvalidMatchError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "fts5") ||
		strings.Contains(msg, "syntax error") ||
		strings.Contains(msg, "unterminated") ||
		strings.Contains(msg, "malformed match")
}
