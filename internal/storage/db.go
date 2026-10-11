// Package storage 提供笔记系统的 SQLite 持久化层：打开数据库、执行 schema
// 迁移与关闭连接。
//
// 驱动选择：本包使用纯 Go 驱动 modernc.org/sqlite（无需 CGO）。原计划使用
// SQLCipher（github.com/mutecomm/go-sqlcipher）实现 DB 层静态加密，但当前构建
// 环境缺少系统 libsqlcipher（pkg-config 与 ldconfig 均未发现），而 SQLCipher 的
// Go 绑定必须依赖 CGO + 系统库，故本实现将「DB 层加密」降级为待办：加密交由
// M0.6（密钥管理）与磁盘 LUKS 加密兜底。届时若环境具备 libsqlcipher，可在此
// 包内替换驱动并启用 Open 的 key 参数，调用方接口无需变更。
package storage

import (
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	// 注册纯 Go SQLite 驱动，驱动名为 "sqlite"。
	_ "modernc.org/sqlite"

	"notes/internal/logging"
)

// driverName 是 modernc.org/sqlite 注册到 database/sql 的驱动名。
const driverName = "sqlite"

// schemaVersion 是当前程序期望的 schema 版本号。
//
// 语义：migrations 中第 i 条脚本将 user_version 从 i 迁移到 i+1，因此
// schemaVersion 必须恒等于 len(migrations)（由 TestMigrationsLengthMatchesVersion 守卫）。
// 新增迁移时：追加脚本到 migrations 末尾，并把 schemaVersion 加一。
const schemaVersion = 1

// migrations 按版本顺序保存 schema 迁移脚本。
//
// 约束：新增迁移只能追加到末尾、不得修改已发布的脚本；脚本本身建议写成可重复
// 执行的形式（如 CREATE TABLE IF NOT EXISTS），以便在版本号写入失败重试时保持幂等。
var migrations = []string{
	// v1：元数据表，用于存放系统级键值对；后续里程碑在此基础上扩展其它表。
	`CREATE TABLE IF NOT EXISTS meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`,
}

// errEmptyPath 表示调用方传入了空的数据库路径。
var errEmptyPath = errors.New("数据库路径为空")

// DB 封装底层 SQLite 连接，并暴露存储层的打开/关闭能力。
type DB struct {
	db   *sql.DB
	path string
}

// Open 打开（或创建）位于 path 的 SQLite 数据库，并自动执行尚未应用的 schema 迁移。
//
// key 为数据库加密密钥，原设计用于 SQLCipher 的 DB 层加密。当前构建环境缺少系统
// libsqlcipher，本实现基于纯 Go 驱动、不启用 DB 层加密：key 为空时按明文库打开，
// key 非空时仅记录降级告警、密钥被忽略。该参数保留以维持调用方接口稳定，待 M0.6
// 补全密钥管理与加密后启用。
func Open(path, key string) (*DB, error) {
	if strings.TrimSpace(path) == "" {
		return nil, logging.Wrap(errEmptyPath, logging.ErrInvalidArgument, "打开数据库失败")
	}

	if key == "" {
		slog.Warn("storage: 未提供数据库加密密钥，数据库以明文存储", "path", path)
	} else {
		slog.Warn("storage: SQLCipher 不可用，加密密钥被忽略，DB 层加密降级为待办", "path", path)
	}

	db, err := sql.Open(driverName, buildDSN(path))
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "打开数据库失败")
	}

	// SQLite 为单写者模型：限制为单连接可避免并发写导致的 SQLITE_BUSY 竞争，
	// 代价是读并发受限；后续如需更高读并发可改用读写分离的连接池。
	db.SetMaxOpenConns(1)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, logging.Wrap(err, logging.ErrInternal, "连接数据库失败")
	}

	if err := applyMigrations(db); err != nil {
		_ = db.Close()
		return nil, err
	}

	return &DB{db: db, path: path}, nil
}

// Close 关闭底层数据库连接并释放资源；对 nil 接收者安全。
func (d *DB) Close() error {
	if d == nil || d.db == nil {
		return nil
	}
	return d.db.Close()
}

// buildDSN 为 SQLite 文件路径附加连接级 PRAGMA 参数。
//
// 内存库或已带查询串的路径原样返回，避免破坏调用方的自定义设置。
func buildDSN(path string) string {
	if path == ":memory:" || strings.Contains(path, "?") {
		return path
	}
	return path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)"
}

// applyMigrations 读取当前 user_version，并按序执行所有未应用的迁移。
func applyMigrations(db *sql.DB) error {
	var current int
	if err := db.QueryRow("PRAGMA user_version").Scan(&current); err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取 schema 版本失败")
	}

	if current > schemaVersion {
		return logging.Wrap(
			fmt.Errorf("数据库 schema 版本 %d 高于程序支持的 %d", current, schemaVersion),
			logging.ErrInternal, "数据库版本不兼容")
	}

	for v := current; v < schemaVersion; v++ {
		if err := applyMigration(db, v+1); err != nil {
			return err
		}
	}
	return nil
}

// applyMigration 在单个事务内执行一条迁移脚本并推进 user_version，保证二者原子生效。
func applyMigration(db *sql.DB, version int) error {
	tx, err := db.Begin()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("开始迁移 v%d 事务失败", version))
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(migrations[version-1]); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("应用迁移 v%d 失败", version))
	}

	// PRAGMA 不支持参数占位符；version 为包内递增常量，直接拼接安全。
	if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", version)); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("更新 schema 版本至 v%d 失败", version))
	}

	if err := tx.Commit(); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("提交迁移 v%d 失败", version))
	}
	return nil
}
