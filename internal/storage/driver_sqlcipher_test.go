//go:build sqlcipher

package storage

import (
	"os"
	"path/filepath"
	"testing"
)

// sqlcipherTestKey 为加密路径测试使用的口令。
const sqlcipherTestKey = "correct horse battery staple"

// isSQLiteHeader 判断文件内容是否以明文 SQLite 魔数开头（"SQLite format 3\x00"）。
func isSQLiteHeader(b []byte) bool {
	const magic = "SQLite format 3\x00"
	return len(b) >= len(magic) && string(b[:len(magic)]) == magic
}

// TestSQLCipherEncryptedRoundTrip 验证 -tags sqlcipher 构建下 DB 层加密生效：
// 正确 key 可读写，且磁盘文件为密文（不含明文 SQLite 头）。
func TestSQLCipherEncryptedRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.db")

	db, err := Open(path, sqlcipherTestKey)
	if err != nil {
		t.Fatalf("以密钥 Open() 失败: %v", err)
	}
	if _, err := db.SQL().Exec("INSERT INTO meta(key, value) VALUES(?, ?)", "k", "v"); err != nil {
		t.Fatalf("写入 meta 失败: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("关闭失败: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取数据库文件失败: %v", err)
	}
	if isSQLiteHeader(content) {
		t.Fatal("数据库文件带明文 SQLite 头，加密未生效")
	}

	// 正确 key 重新打开，数据可读。
	db2, err := Open(path, sqlcipherTestKey)
	if err != nil {
		t.Fatalf("以正确密钥重新打开失败: %v", err)
	}
	defer func() { _ = db2.Close() }()

	var got string
	if err := db2.SQL().QueryRow("SELECT value FROM meta WHERE key = ?", "k").Scan(&got); err != nil {
		t.Fatalf("读取 meta 失败: %v", err)
	}
	if got != "v" {
		t.Fatalf("读取值 = %q, 期望 %q", got, "v")
	}
}

// TestSQLCipherWrongKeyFails 验证以错误 key 打开加密库会失败。
func TestSQLCipherWrongKeyFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.db")

	db, err := Open(path, sqlcipherTestKey)
	if err != nil {
		t.Fatalf("以密钥 Open() 失败: %v", err)
	}
	if _, err := db.SQL().Exec("INSERT INTO meta(key, value) VALUES(?, ?)", "k", "v"); err != nil {
		t.Fatalf("写入 meta 失败: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("关闭失败: %v", err)
	}

	db2, err := Open(path, "wrong-key")
	if err == nil {
		_ = db2.Close()
		t.Fatal("以错误密钥 Open() 应失败，实际成功")
	}
}

// TestSQLCipherEmptyKeyFailsOnEncryptedDB 验证未提供 key 时无法读取已加密库。
func TestSQLCipherEmptyKeyFailsOnEncryptedDB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.db")

	db, err := Open(path, sqlcipherTestKey)
	if err != nil {
		t.Fatalf("以密钥 Open() 失败: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("关闭失败: %v", err)
	}

	db2, err := Open(path, "")
	if err == nil {
		_ = db2.Close()
		t.Fatal("空 key 打开加密库应失败，实际成功")
	}
}
