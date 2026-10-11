package index

import (
	"errors"
	"path/filepath"
	"testing"

	"notes/internal/logging"
	"notes/internal/storage"
)

// newTestIndexer 在临时目录打开全新存储库并返回索引器，注册清理。
func newTestIndexer(t *testing.T) *Indexer {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "notes.db"), "")
	if err != nil {
		t.Fatalf("storage.Open 失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return New(db)
}

// contains 报告切片是否包含 want。
func contains(paths []string, want string) bool {
	for _, p := range paths {
		if p == want {
			return true
		}
	}
	return false
}

// TestIndexThenSearchHits 验证索引后按正文关键词可检索到对应 path。
func TestIndexThenSearchHits(t *testing.T) {
	ix := newTestIndexer(t)

	if err := ix.Index("note.org", "hello world from notes"); err != nil {
		t.Fatalf("Index 失败: %v", err)
	}

	paths, err := ix.Search("hello", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !contains(paths, "note.org") {
		t.Fatalf("Search 结果 = %v, 期望包含 note.org", paths)
	}
}

// TestIndexOverwriteReflectsLatest 验证对同一 path 重复索引为覆盖语义：
// 旧内容不再命中，新内容命中，且 path 只出现一次。
func TestIndexOverwriteReflectsLatest(t *testing.T) {
	ix := newTestIndexer(t)

	if err := ix.Index("note.org", "alpha beta gamma"); err != nil {
		t.Fatalf("首次 Index 失败: %v", err)
	}
	if err := ix.Index("note.org", "delta epsilon zeta"); err != nil {
		t.Fatalf("覆盖 Index 失败: %v", err)
	}

	old, err := ix.Search("alpha", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if contains(old, "note.org") {
		t.Errorf("覆盖后旧关键词 alpha 仍命中: %v", old)
	}

	latest, err := ix.Search("delta", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !contains(latest, "note.org") {
		t.Fatalf("覆盖后新关键词 delta 未命中: %v", latest)
	}

	// 覆盖不应留下重复行：结果中 note.org 只出现一次。
	count := 0
	for _, p := range latest {
		if p == "note.org" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("覆盖后 note.org 出现 %d 次, 期望 1 次", count)
	}
}

// TestDeleteRemovesFromSearch 验证删除后不再命中。
func TestDeleteRemovesFromSearch(t *testing.T) {
	ix := newTestIndexer(t)

	if err := ix.Index("note.org", "findme content"); err != nil {
		t.Fatalf("Index 失败: %v", err)
	}
	if err := ix.Delete("note.org"); err != nil {
		t.Fatalf("Delete 失败: %v", err)
	}

	paths, err := ix.Search("findme", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if contains(paths, "note.org") {
		t.Fatalf("Delete 后仍命中: %v", paths)
	}

	// 再次删除不存在的 path 为无操作，不报错。
	if err := ix.Delete("absent.org"); err != nil {
		t.Fatalf("删除不存在的 path 失败: %v", err)
	}
}

// TestSearchOrderingAndLimit 验证多文件检索按相关性排序且 limit 生效。
func TestSearchOrderingAndLimit(t *testing.T) {
	ix := newTestIndexer(t)

	// docA 中 apple 只出现一次且文档较长；docB 只有 apple 一词，词频密度更高，
	// bm25 相关性应排在 docA 之前。
	docs := map[string]string{
		"a.org": "apple banana cherry date elderberry fig grape",
		"b.org": "apple",
		"c.org": "unrelated text only",
	}
	for p, c := range docs {
		if err := ix.Index(p, c); err != nil {
			t.Fatalf("Index(%s) 失败: %v", p, err)
		}
	}

	all, err := ix.Search("apple", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("apple 命中数 = %d, 期望 2 (%v)", len(all), all)
	}
	if all[0] != "b.org" {
		t.Errorf("相关性最高者 = %q, 期望 b.org (完整结果 %v)", all[0], all)
	}

	// 不相关文档不命中。
	if contains(all, "c.org") {
		t.Errorf("不相关文档 c.org 被命中: %v", all)
	}

	// limit=1 只返回最相关的一条。
	limited, err := ix.Search("apple", 1)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if len(limited) != 1 || limited[0] != "b.org" {
		t.Errorf("limit=1 结果 = %v, 期望 [b.org]", limited)
	}
}

// TestSearchEmptyQuery 验证空/空白 query 返回空结果且不报错。
func TestSearchEmptyQuery(t *testing.T) {
	ix := newTestIndexer(t)

	if err := ix.Index("note.org", "some content"); err != nil {
		t.Fatalf("Index 失败: %v", err)
	}

	for _, q := range []string{"", "   ", "\t\n"} {
		paths, err := ix.Search(q, 10)
		if err != nil {
			t.Fatalf("Search(%q) 返回错误: %v", q, err)
		}
		if len(paths) != 0 {
			t.Errorf("Search(%q) = %v, 期望空结果", q, paths)
		}
	}
}

// TestSearchDefaultLimit 验证 limit<=0 时使用默认上限：写入超过 defaultLimit 条
// 命中记录后，Search(q, 0) 返回不超过 defaultLimit 条。
func TestSearchDefaultLimit(t *testing.T) {
	ix := newTestIndexer(t)

	for i := range defaultLimit + 5 {
		p := filepath.Join("dir", string(rune('a'+i))+".org")
		if err := ix.Index(p, "sharedtoken body"); err != nil {
			t.Fatalf("Index(%s) 失败: %v", p, err)
		}
	}

	paths, err := ix.Search("sharedtoken", 0)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if len(paths) > defaultLimit {
		t.Fatalf("默认上限生效失败: 返回 %d 条, 期望 <= %d", len(paths), defaultLimit)
	}
}

// TestIndexRejectsEmptyPath 验证空路径被拒绝。
func TestIndexRejectsEmptyPath(t *testing.T) {
	ix := newTestIndexer(t)

	if err := ix.Index("", "content"); err == nil {
		t.Fatal("Index 空 path 应返回错误，实际返回 nil")
	}
}

// TestSearchInvalidMATCHReturnsInvalidArgument 验证非法 FTS5 MATCH 表达式
// （如未闭合引号）被映射为 ErrInvalidArgument（而非 ErrInternal），使 API 层
// 能据此返回 400 而非 500。用户输入直接作为 MATCH 表达式时语法错误属客户端错误。
func TestSearchInvalidMATCHReturnsInvalidArgument(t *testing.T) {
	ix := newTestIndexer(t)
	if err := ix.Index("note.org", "hello world"); err != nil {
		t.Fatalf("Index 失败: %v", err)
	}

	// 未闭合的双引号是 FTS5 非法语法。
	_, err := ix.Search(`"unclosed`, 10)
	if err == nil {
		t.Fatal("非法 MATCH 表达式应返回错误，实际返回 nil")
	}
	var appErr *logging.AppError
	if !errors.As(err, &appErr) {
		t.Fatalf("错误类型 = %T, 期望 *logging.AppError (%v)", err, err)
	}
	if appErr.Code != logging.ErrInvalidArgument {
		t.Errorf("错误码 = %q, 期望 %q", appErr.Code, logging.ErrInvalidArgument)
	}
}
