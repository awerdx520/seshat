//go:build !sqlcipher

package storage

import (
	"log/slog"
	"strings"

	// 注册纯 Go SQLite 驱动，驱动名为 "sqlite"（无需 CGO）。
	_ "modernc.org/sqlite"
)

// driverName 返回 modernc.org/sqlite 注册到 database/sql 的驱动名。
//
// 本文件在默认构建（未指定 -tags sqlcipher）下生效，提供无加密的纯 Go 驱动。
func driverName() string { return "sqlite" }

// buildDSN 为 SQLite 文件路径附加连接级 PRAGMA 参数。
//
// 内存库或已带查询串的路径原样返回，避免破坏调用方的自定义设置。
// modernc.org/sqlite 以 `_pragma=name(value)` 形式的查询参数设置 PRAGMA，
// 此处启用 5s busy_timeout、WAL 日志模式与外键约束。
//
// key 在本驱动下不被使用：默认构建不具备 DB 层加密能力，密钥处理见 warnKeyMode。
func buildDSN(path, key string) string {
	if path == ":memory:" || strings.Contains(path, "?") {
		return path
	}
	return path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)"
}

// warnKeyMode 记录默认构建（无加密）下的密钥处理情况。
//
// 未提供密钥时提示数据库以明文存储；提供了密钥但本构建无法加密时，明确提示
// 密钥被忽略，并引导使用 -tags sqlcipher 构建以启用加密。
func warnKeyMode(path, key string) {
	if key == "" {
		slog.Warn("storage: 未提供数据库加密密钥，数据库以明文存储", "path", path)
		return
	}
	slog.Warn("storage: 本构建未启用 SQLCipher（缺 -tags sqlcipher），加密密钥被忽略", "path", path)
}
