package storage

import (
	"os"
	"path/filepath"
	"testing"
)

// openTestDB 在临时目录中打开一个全新的测试库，并注册测试结束后的清理。
func openTestDB(t *testing.T) *DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "notes.db")
	db, err := Open(path, "")
	if err != nil {
		t.Fatalf("Open() 返回错误: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// TestOpenCreatesDatabaseFile 验证 Open 会创建数据库文件。
func TestOpenCreatesDatabaseFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.db")

	db, err := Open(path, "")
	if err != nil {
		t.Fatalf("Open() 返回错误: %v", err)
	}
	defer func() { _ = db.Close() }()

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("数据库文件未创建: %v", err)
	}
}

// TestOpenRejectsEmptyPath 验证空路径被拒绝。
func TestOpenRejectsEmptyPath(t *testing.T) {
	if _, err := Open("", ""); err == nil {
		t.Fatal("空路径应返回错误，实际返回 nil")
	}
}

// TestSchemaVersionAfterOpen 验证迁移后 user_version 等于 schemaVersion。
func TestSchemaVersionAfterOpen(t *testing.T) {
	db := openTestDB(t)

	var v int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("读取 user_version 失败: %v", err)
	}
	if v != schemaVersion {
		t.Fatalf("user_version = %d, 期望 %d", v, schemaVersion)
	}
}

// TestMigrationsLengthMatchesVersion 守卫 migrations 与 schemaVersion 的一致性。
func TestMigrationsLengthMatchesVersion(t *testing.T) {
	if len(migrations) != schemaVersion {
		t.Fatalf("len(migrations) = %d, schemaVersion = %d，二者必须相等", len(migrations), schemaVersion)
	}
}

// TestMigrationIdempotent 验证重复 Open 不会重复执行迁移（数据与版本号均保持）。
func TestMigrationIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.db")

	db1, err := Open(path, "")
	if err != nil {
		t.Fatalf("首次 Open() 失败: %v", err)
	}
	if _, err := db1.db.Exec("INSERT INTO meta(key, value) VALUES(?, ?)", "k", "v"); err != nil {
		t.Fatalf("写入 meta 失败: %v", err)
	}
	if err := db1.Close(); err != nil {
		t.Fatalf("关闭首个连接失败: %v", err)
	}

	// 第二次 Open 应识别 user_version 已是最新，不重建表、不丢数据。
	db2, err := Open(path, "")
	if err != nil {
		t.Fatalf("二次 Open() 失败: %v", err)
	}
	defer func() { _ = db2.Close() }()

	var v int
	if err := db2.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("二次读取 user_version 失败: %v", err)
	}
	if v != schemaVersion {
		t.Fatalf("二次 user_version = %d, 期望 %d", v, schemaVersion)
	}

	var value string
	if err := db2.db.QueryRow("SELECT value FROM meta WHERE key = ?", "k").Scan(&value); err != nil {
		t.Fatalf("重新打开后读取 meta 失败: %v", err)
	}
	if value != "v" {
		t.Fatalf("meta 值 = %q, 期望 %q（迁移不应重建表）", value, "v")
	}
}

// TestMetaReadWrite 验证 meta 表支持插入、读取与更新。
func TestMetaReadWrite(t *testing.T) {
	db := openTestDB(t)

	if _, err := db.db.Exec("INSERT INTO meta(key, value) VALUES(?, ?)", "schema_owner", "notes"); err != nil {
		t.Fatalf("写入 meta 失败: %v", err)
	}

	var got string
	if err := db.db.QueryRow("SELECT value FROM meta WHERE key = ?", "schema_owner").Scan(&got); err != nil {
		t.Fatalf("读取 meta 失败: %v", err)
	}
	if got != "notes" {
		t.Fatalf("读取值 = %q, 期望 %q", got, "notes")
	}

	if _, err := db.db.Exec("UPDATE meta SET value = ? WHERE key = ?", "notes-v2", "schema_owner"); err != nil {
		t.Fatalf("更新 meta 失败: %v", err)
	}
	if err := db.db.QueryRow("SELECT value FROM meta WHERE key = ?", "schema_owner").Scan(&got); err != nil {
		t.Fatalf("更新后读取 meta 失败: %v", err)
	}
	if got != "notes-v2" {
		t.Fatalf("更新后读取值 = %q, 期望 %q", got, "notes-v2")
	}
}

// TestCloseIsNilSafe 验证对 nil 接收者调用 Close 不 panic。
func TestCloseIsNilSafe(t *testing.T) {
	var db *DB
	if err := db.Close(); err != nil {
		t.Fatalf("nil 接收者 Close() 返回错误: %v", err)
	}
}
