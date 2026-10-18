// 本文件覆盖 M7 B4 的 v7 迁移：状态表按 uid 重建、重建前的非空防御、v6 → v7 的
// 空表升级路径。
//
// 安全约束：所有用例都在 t.TempDir() 的一次性库上运行——v7 会 DROP 状态表且不可逆，
// 绝不能对真实数据库执行。
package storage

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// v6MigrationCount 是 v7 之前的迁移脚本条数，同时是 v6 库的 user_version。
const v6MigrationCount = 6

// buildV6DB 在 path 上构造一个 user_version = 6 的库：逐条执行 v1–v6 脚本后写入
// 版本号，从而复现「已装 A1 身份三表、尚未升 v7」的存量库（旧状态表结构为
// document_id 主键）。返回的 *sql.DB 由调用方写入旧数据后自行关闭。
func buildV6DB(t *testing.T, path string) *sql.DB {
	t.Helper()

	raw, err := sql.Open(driverName(), buildDSN(path, ""))
	if err != nil {
		t.Fatalf("打开 v6 测试库失败: %v", err)
	}
	// 用例提前失败时兜底释放；Close 可重复调用。
	t.Cleanup(func() { _ = raw.Close() })

	for i := 0; i < v6MigrationCount; i++ {
		if _, err := raw.Exec(migrations[i]); err != nil {
			t.Fatalf("执行 v%d 迁移脚本失败: %v", i+1, err)
		}
	}
	// PRAGMA 不支持占位符；v6MigrationCount 为包内常量，拼接安全。
	if _, err := raw.Exec(fmt.Sprintf("PRAGMA user_version = %d", v6MigrationCount)); err != nil {
		t.Fatalf("写入 user_version=%d 失败: %v", v6MigrationCount, err)
	}
	return raw
}

// insertLegacyProgress 在 v6 旧结构（document_id 主键）的 reading_progress 上写一行。
func insertLegacyProgress(t *testing.T, raw *sql.DB, docID string) {
	t.Helper()

	if _, err := raw.Exec(
		`INSERT INTO reading_progress(document_id, position, updated_at) VALUES(?, ?, ?)`,
		docID, "p1", "2026-10-18T10:00:00Z"); err != nil {
		t.Fatalf("写入旧结构进度失败: %v", err)
	}
}

// insertLegacyAnnotation 在 v6 旧结构（document_id 列）的 annotations 上写一行。
func insertLegacyAnnotation(t *testing.T, raw *sql.DB, docID string) {
	t.Helper()

	if _, err := raw.Exec(
		`INSERT INTO annotations(document_id, location, text, created_at, updated_at)
		 VALUES(?, ?, ?, ?, ?)`,
		docID, "loc-1", "旧批注", "2026-10-18T10:00:00Z", "2026-10-18T10:00:00Z"); err != nil {
		t.Fatalf("写入旧结构批注失败: %v", err)
	}
}

// rawUserVersion 直接读取库文件的 user_version（不触发迁移），用于断言「迁移失败
// 时版本号保持原值」。
func rawUserVersion(t *testing.T, path string) int {
	t.Helper()

	raw, err := sql.Open(driverName(), buildDSN(path, ""))
	if err != nil {
		t.Fatalf("打开库文件失败: %v", err)
	}
	defer func() { _ = raw.Close() }()

	var v int
	if err := raw.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("读取 user_version 失败: %v", err)
	}
	return v
}

// tableColumns 返回表的「列名 → 是否主键」映射，用于断言重建后的列集合。
func tableColumns(t *testing.T, db *DB, table string) map[string]bool {
	t.Helper()

	rows, err := db.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		t.Fatalf("读取 %s 表结构失败: %v", table, err)
	}
	defer func() { _ = rows.Close() }()

	cols := make(map[string]bool)
	for rows.Next() {
		var (
			cid       int
			name      string
			colType   string
			notNull   int
			dfltValue sql.NullString
			pk        int
		)
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dfltValue, &pk); err != nil {
			t.Fatalf("解析 %s 表结构失败: %v", table, err)
		}
		cols[name] = pk > 0
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("遍历 %s 表结构失败: %v", table, err)
	}
	return cols
}

// TestSchemaV7RebuildsStateTables 验证 v7 后 user_version = 7，且状态表以 uid 为键：
// document_id 列与旧索引随重建消失，新索引 idx_annotations_uid 建立。
func TestSchemaV7RebuildsStateTables(t *testing.T) {
	db := openTestDB(t)

	var v int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("读取 user_version 失败: %v", err)
	}
	if want := 7; v != want || schemaVersion != want {
		t.Fatalf("user_version = %d, 期望 7（schemaVersion = %d）", v, schemaVersion)
	}

	progress := tableColumns(t, db, "reading_progress")
	if len(progress) == 0 {
		t.Fatalf("reading_progress 表不存在")
	}
	if _, ok := progress["document_id"]; ok {
		t.Fatalf("reading_progress 不应再有 document_id 列: %v", progress)
	}
	if pk, ok := progress["uid"]; !ok || !pk {
		t.Fatalf("reading_progress.uid 应为非空主键: %v", progress)
	}
	for _, col := range []string{"position", "updated_at"} {
		if _, ok := progress[col]; !ok {
			t.Fatalf("reading_progress 缺少列 %s: %v", col, progress)
		}
	}

	annotations := tableColumns(t, db, "annotations")
	if len(annotations) == 0 {
		t.Fatalf("annotations 表不存在")
	}
	if _, ok := annotations["document_id"]; ok {
		t.Fatalf("annotations 不应再有 document_id 列: %v", annotations)
	}
	if pk, ok := annotations["id"]; !ok || !pk {
		t.Fatalf("annotations.id 应为自增主键: %v", annotations)
	}
	if pk, ok := annotations["uid"]; !ok || pk {
		t.Fatalf("annotations.uid 应为非主键列: %v", annotations)
	}
	for _, col := range []string{"location", "text", "created_at", "updated_at"} {
		if _, ok := annotations[col]; !ok {
			t.Fatalf("annotations 缺少列 %s: %v", col, annotations)
		}
	}

	// 旧表随 DROP 移除，其索引 idx_annotations_document 应一并消失；新索引应存在。
	var name string
	err := db.db.QueryRow(
		`SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_annotations_document'`).Scan(&name)
	if err == nil {
		t.Fatalf("旧索引 %s 未随状态表重建移除", name)
	}
	if err := db.db.QueryRow(
		`SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_annotations_uid'`).Scan(&name); err != nil {
		t.Fatalf("新索引 idx_annotations_uid 不存在: %v", err)
	}
}

// TestSchemaV7RejectsNonEmptyProgress 验证非空防御：v6 库的 reading_progress 有数据
// 时拒绝执行 v7 重建，错误信息含两表计数，且 user_version 保持 6（迁移整体回滚）。
func TestSchemaV7RejectsNonEmptyProgress(t *testing.T) {
	path := filepath.Join(t.TempDir(), "seshat.db")

	raw := buildV6DB(t, path)
	insertLegacyProgress(t, raw, "doc-1")
	if err := raw.Close(); err != nil {
		t.Fatalf("关闭 v6 测试库失败: %v", err)
	}

	_, err := Open(path, "")
	if err == nil {
		t.Fatalf("状态表非空时 Open() 应失败")
	}
	if !strings.Contains(err.Error(), "状态表非空，拒绝执行 v7 重建") {
		t.Fatalf("错误信息未包含明确原因: %v", err)
	}
	if !strings.Contains(err.Error(), "reading_progress=1") || !strings.Contains(err.Error(), "annotations=0") {
		t.Fatalf("错误信息应含两表行数: %v", err)
	}
	if v := rawUserVersion(t, path); v != v6MigrationCount {
		t.Fatalf("user_version = %d, 期望仍为 %d（失败的迁移不得推进版本）", v, v6MigrationCount)
	}
}

// TestSchemaV7RejectsNonEmptyAnnotations 验证 annotations 非空同样触发防御。
func TestSchemaV7RejectsNonEmptyAnnotations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "seshat.db")

	raw := buildV6DB(t, path)
	insertLegacyAnnotation(t, raw, "doc-1")
	if err := raw.Close(); err != nil {
		t.Fatalf("关闭 v6 测试库失败: %v", err)
	}

	_, err := Open(path, "")
	if err == nil {
		t.Fatalf("annotations 非空时 Open() 应失败")
	}
	if !strings.Contains(err.Error(), "reading_progress=0") || !strings.Contains(err.Error(), "annotations=1") {
		t.Fatalf("错误信息应含两表行数: %v", err)
	}
	if v := rawUserVersion(t, path); v != v6MigrationCount {
		t.Fatalf("user_version = %d, 期望仍为 %d", v, v6MigrationCount)
	}
}

// TestSchemaV7UpgradesEmptyV6DB 验证两表为空的 v6 库可正常升到 v7，且升级后新表
// 可直接以 uid 读写（数据面可用，不只是建表成功）。
func TestSchemaV7UpgradesEmptyV6DB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "seshat.db")

	raw := buildV6DB(t, path)
	var count int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM reading_progress`).Scan(&count); err != nil {
		t.Fatalf("读取旧表行数失败: %v", err)
	}
	if count != 0 {
		t.Fatalf("新建 v6 库的 reading_progress 应为空, 实际 %d 行", count)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("关闭 v6 测试库失败: %v", err)
	}

	db, err := Open(path, "")
	if err != nil {
		t.Fatalf("空表 v6 库升级到 v7 失败: %v", err)
	}
	defer func() { _ = db.Close() }()

	var v int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("读取 user_version 失败: %v", err)
	}
	if v != 7 {
		t.Fatalf("user_version = %d, 期望 7", v)
	}

	if err := db.SetProgress(testUID1, "p1", "2026-10-18T12:00:00Z"); err != nil {
		t.Fatalf("v7 库写入进度失败: %v", err)
	}
	got, err := db.GetProgress(testUID1)
	if err != nil {
		t.Fatalf("v7 库读取进度失败: %v", err)
	}
	if got.UID != testUID1 || got.Position != "p1" {
		t.Fatalf("v7 库读回进度不符: %+v", got)
	}
}
