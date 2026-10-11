//go:build sqlcipher

package storage

import (
	"log/slog"
	"net/url"
	"strings"

	// 注册 SQLCipher 驱动（CGO + 包内自带的 SQLCipher amalgamation），驱动名为 "sqlite3"。
	// 该驱动自带 sqlite3.c/tomcrypt 源码，无需系统 libsqlcipher-dev。
	_ "github.com/mutecomm/go-sqlcipher/v4"
)

// driverName 返回 go-sqlcipher 注册到 database/sql 的驱动名。
//
// 本文件在 -tags sqlcipher 构建下生效，替代默认的纯 Go 驱动以启用 DB 层加密。
//
// 构建 tag 提醒：go-sqlcipher 默认未编入 FTS5，而 schema 迁移 v4 依赖 FTS5 虚表，
// 故完整构建命令为 `-tags "sqlcipher sqlite_fts5"`；仅用 `-tags sqlcipher` 会在
// 运行期报 `no such module: fts5`（迁移 v4 失败）。
func driverName() string { return "sqlite3" }

// buildDSN 为 SQLite 文件路径附加连接级 PRAGMA 参数与加密密钥。
//
// 内存库或已带查询串的路径原样返回，避免破坏调用方的自定义设置。
// go-sqlcipher（mattn/go-sqlite3 分支）以 `_name=value` 形式的查询参数设置 PRAGMA：
// `_busy_timeout`、`_journal_mode`、`_foreign_keys` 分别对应同名 PRAGMA；
// `_pragma_key` 由驱动转换为 `PRAGMA key = "<key>";`，并在打开连接后立即执行，
// 早于其余 PRAGMA（见驱动源码），故 key 派生先于 WAL 等操作，对加密库安全。
//
// key 语义：go-sqlcipher 将 key 包裹为双引号字符串交给 SQLCipher。普通文本按
// passphrase 处理（经 KDF 派生密钥）；形如 `x'<64位十六进制>'` 的值则按 SQLCipher
// 原始密钥字面量处理（要求恰好 32 字节）。key 为空时不附加 `_pragma_key`，库以
// 明文打开（SQLCipher 未设 key 时等同普通 SQLite），并在 warnKeyMode 中告警。
func buildDSN(path, key string) string {
	if path == ":memory:" || strings.Contains(path, "?") {
		return path
	}
	dsn := path + "?_busy_timeout=5000&_journal_mode=WAL&_foreign_keys=1"
	if key != "" {
		// QueryEscape 保证 key 中的 & = + 等字符不被 DSN 解析破坏；驱动侧
		// url.ParseQuery 会解码还原。
		dsn += "&_pragma_key=" + url.QueryEscape(key)
	}
	return dsn
}

// warnKeyMode 在启用加密的构建下，提示未提供密钥的明文回退情况。
func warnKeyMode(path, key string) {
	if key == "" {
		slog.Warn("storage: 未提供数据库加密密钥，SQLCipher 库以明文存储", "path", path)
	}
}
