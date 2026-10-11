package storage

import (
	"errors"
	"testing"
	"time"

	"notes/internal/logging"
)

// assertCode 断言 err 是被 AppError 包装的指定错误码。
func assertCode(t *testing.T, err error, want logging.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("期望错误码 %s，实际 err = nil", want)
	}
	var appErr *logging.AppError
	if !errors.As(err, &appErr) {
		t.Fatalf("err 不是 *logging.AppError: %v", err)
	}
	if appErr.Code != want {
		t.Fatalf("错误码 = %s, 期望 %s", appErr.Code, want)
	}
}

// TestProgressRoundTrip 验证进度写入后可按原样读回，且重复写入为后写覆盖。
func TestProgressRoundTrip(t *testing.T) {
	db := openTestDB(t)

	if err := db.SetProgress("doc-1", "p1", "2026-10-11T10:00:00Z"); err != nil {
		t.Fatalf("SetProgress() 返回错误: %v", err)
	}
	got, err := db.GetProgress("doc-1")
	if err != nil {
		t.Fatalf("GetProgress() 返回错误: %v", err)
	}
	if got.DocumentID != "doc-1" || got.Position != "p1" || got.UpdatedAt != "2026-10-11T10:00:00Z" {
		t.Fatalf("读回记录不符: %+v", got)
	}

	if err := db.SetProgress("doc-1", "p2", "2026-10-11T11:00:00Z"); err != nil {
		t.Fatalf("二次 SetProgress() 返回错误: %v", err)
	}
	got, err = db.GetProgress("doc-1")
	if err != nil {
		t.Fatalf("二次 GetProgress() 返回错误: %v", err)
	}
	if got.Position != "p2" || got.UpdatedAt != "2026-10-11T11:00:00Z" {
		t.Fatalf("后写覆盖失败: %+v", got)
	}
}

// TestProgressTimestampBackfill 验证空时间戳回填为当前 UTC 时间。
func TestProgressTimestampBackfill(t *testing.T) {
	db := openTestDB(t)

	if err := db.SetProgress("doc-1", "p1", ""); err != nil {
		t.Fatalf("SetProgress() 返回错误: %v", err)
	}
	got, err := db.GetProgress("doc-1")
	if err != nil {
		t.Fatalf("GetProgress() 返回错误: %v", err)
	}
	ts, err := time.Parse(time.RFC3339, got.UpdatedAt)
	if err != nil {
		t.Fatalf("回填时间戳不是 RFC3339: %q", got.UpdatedAt)
	}
	if delta := time.Since(ts); delta < 0 || delta > time.Minute {
		t.Fatalf("回填时间戳偏差过大: %v", delta)
	}
}

// TestProgressErrors 验证进度读写的参数与缺失错误码。
func TestProgressErrors(t *testing.T) {
	db := openTestDB(t)

	_, err := db.GetProgress("missing")
	assertCode(t, err, logging.ErrNotFound)

	err = db.SetProgress("doc-1", "", "2026-10-11T10:00:00Z")
	assertCode(t, err, logging.ErrInvalidArgument)

	err = db.SetProgress("doc-1", "p1", "not-a-timestamp")
	assertCode(t, err, logging.ErrInvalidArgument)

	err = db.SetProgress("   ", "p1", "")
	assertCode(t, err, logging.ErrInvalidArgument)
}

// TestAnnotationCRUD 覆盖批注的创建、列举（含过滤）、更新与删除。
func TestAnnotationCRUD(t *testing.T) {
	db := openTestDB(t)

	if _, err := db.CreateAnnotation("doc-2", "loc-1", "文本"); err != nil {
		t.Fatalf("CreateAnnotation() 返回错误: %v", err)
	}
	created, err := db.CreateAnnotation("doc-1", "loc-2", "文本2")
	if err != nil {
		t.Fatalf("二次 CreateAnnotation() 返回错误: %v", err)
	}
	if created.ID <= 0 {
		t.Fatalf("自增 id 非法: %d", created.ID)
	}
	if _, err := time.Parse(time.RFC3339, created.CreatedAt); err != nil {
		t.Fatalf("created_at 不是 RFC3339: %q", created.CreatedAt)
	}

	// 只返回目标文档的批注。
	items, err := db.ListAnnotations("doc-2")
	if err != nil {
		t.Fatalf("ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 || items[0].Location != "loc-1" {
		t.Fatalf("列举结果不符: %+v", items)
	}

	// 无批注的文档返回空切片（非 nil），保证上层序列化为 JSON []。
	empty, err := db.ListAnnotations("doc-none")
	if err != nil {
		t.Fatalf("ListAnnotations() 空结果返回错误: %v", err)
	}
	if empty == nil || len(empty) != 0 {
		t.Fatalf("空结果应为非 nil 空切片, 实际 %#v", empty)
	}

	updated, err := db.UpdateAnnotation(created.ID, "loc-3", "文本3")
	if err != nil {
		t.Fatalf("UpdateAnnotation() 返回错误: %v", err)
	}
	if updated.Location != "loc-3" || updated.Text != "文本3" {
		t.Fatalf("更新结果不符: %+v", updated)
	}
	if updated.CreatedAt != created.CreatedAt {
		t.Fatalf("created_at 不应变化: %q → %q", created.CreatedAt, updated.CreatedAt)
	}
	if updated.DocumentID != "doc-1" {
		t.Fatalf("document_id 不应变化: %q", updated.DocumentID)
	}

	if err := db.DeleteAnnotation(created.ID); err != nil {
		t.Fatalf("DeleteAnnotation() 返回错误: %v", err)
	}
	items, err = db.ListAnnotations("doc-1")
	if err != nil {
		t.Fatalf("删除后 ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("删除后仍有 %d 条批注", len(items))
	}
}

// TestAnnotationErrors 验证批注操作的缺失与参数错误码。
func TestAnnotationErrors(t *testing.T) {
	db := openTestDB(t)

	_, err := db.UpdateAnnotation(404, "loc", "文本")
	assertCode(t, err, logging.ErrNotFound)

	err = db.DeleteAnnotation(404)
	assertCode(t, err, logging.ErrNotFound)

	_, err = db.CreateAnnotation("doc", "", "文本")
	assertCode(t, err, logging.ErrInvalidArgument)

	_, err = db.CreateAnnotation("doc", "loc", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	_, err = db.ListAnnotations("")
	assertCode(t, err, logging.ErrInvalidArgument)

	_, err = db.GetProgress("")
	assertCode(t, err, logging.ErrInvalidArgument)
}

// TestAnnotationsSurviveReopen 验证批注与进度经一次关闭/重开（迁移幂等）后仍存在。
func TestAnnotationsSurviveReopen(t *testing.T) {
	path := t.TempDir() + "/notes.db"

	db, err := Open(path, "")
	if err != nil {
		t.Fatalf("首次 Open() 失败: %v", err)
	}
	if err := db.SetProgress("doc", "p1", "2026-10-11T10:00:00Z"); err != nil {
		t.Fatalf("SetProgress() 返回错误: %v", err)
	}
	if _, err := db.CreateAnnotation("doc", "loc", "文本"); err != nil {
		t.Fatalf("CreateAnnotation() 返回错误: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("关闭首个连接失败: %v", err)
	}

	reopened, err := Open(path, "")
	if err != nil {
		t.Fatalf("二次 Open() 失败: %v", err)
	}
	defer func() { _ = reopened.Close() }()

	if _, err := reopened.GetProgress("doc"); err != nil {
		t.Fatalf("重开后读取进度失败: %v", err)
	}
	items, err := reopened.ListAnnotations("doc")
	if err != nil || len(items) != 1 {
		t.Fatalf("重开后批注 = %+v, err = %v", items, err)
	}
}
