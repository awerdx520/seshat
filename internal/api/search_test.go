package api_test

import (
	"net/http"
	"path/filepath"
	"strings"
	"testing"

	"notes/internal/api"
	"notes/internal/auth"
	"notes/internal/index"
	"notes/internal/storage"
)

// newSearchHandler 构造挂载全文索引器的处理器：在临时目录打开存储库、建索引器
// 并用 seed 预置索引（path → 正文），最后经 NewHandlerFull 组装。
func newSearchHandler(t *testing.T, seed map[string]string) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "notes.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	ix := index.New(db)
	for path, content := range seed {
		if err := ix.Index(path, content); err != nil {
			t.Fatalf("索引 %s 失败: %v", path, err)
		}
	}
	return api.NewHandlerFull(db, nil, ix, auth.New(testToken))
}

// TestSearchEndpointHits 验证索引后经 /api/search 可检索到对应文件路径。
func TestSearchEndpointHits(t *testing.T) {
	h := newSearchHandler(t, map[string]string{
		"note.org":     "hello world from notes",
		"sub/book.org": "another hello note",
	})

	rec := do(t, h, http.MethodGet, "/api/search?q=hello", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	results, ok := decodeJSON(t, rec)["results"].([]any)
	if !ok {
		t.Fatalf("响应缺少 results 数组: %q", rec.Body.String())
	}
	got := map[string]bool{}
	for _, r := range results {
		got[r.(string)] = true
	}
	if !got["note.org"] || !got["sub/book.org"] {
		t.Fatalf("results = %v, 期望包含 note.org 与 sub/book.org", results)
	}
}

// TestSearchEndpointLimit 验证 limit 参数限制返回条数。
func TestSearchEndpointLimit(t *testing.T) {
	h := newSearchHandler(t, map[string]string{
		"a.org": "common token",
		"b.org": "common token",
		"c.org": "common token",
	})

	rec := do(t, h, http.MethodGet, "/api/search?q=common&limit=2", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	results, ok := decodeJSON(t, rec)["results"].([]any)
	if !ok {
		t.Fatalf("响应缺少 results 数组: %q", rec.Body.String())
	}
	if len(results) != 2 {
		t.Fatalf("results 长度 = %d, 期望 2 (results=%v)", len(results), results)
	}
}

// TestSearchEndpointEmptyQuery 验证空 q 返回 400。
func TestSearchEndpointEmptyQuery(t *testing.T) {
	h := newSearchHandler(t, nil)
	rec := do(t, h, http.MethodGet, "/api/search?q=", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestSearchEndpointInvalidLimit 验证非法 limit（非正整数）返回 400。
func TestSearchEndpointInvalidLimit(t *testing.T) {
	h := newSearchHandler(t, nil)
	rec := do(t, h, http.MethodGet, "/api/search?q=hello&limit=0", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestSearchEndpointWithoutIndexer 验证未启用索引器时搜索端点返回 503。
func TestSearchEndpointWithoutIndexer(t *testing.T) {
	db, err := storage.Open(filepath.Join(t.TempDir(), "notes.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h := api.NewHandlerFull(db, nil, nil, auth.New(testToken))

	rec := do(t, h, http.MethodGet, "/api/search?q=hello", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusServiceUnavailable, "unavailable")
}

// TestStaticIndexServed 验证 GET / 返回内嵌的 HTML 首页（公开资源，无需令牌）。
func TestStaticIndexServed(t *testing.T) {
	h := newSearchHandler(t, nil)

	rec := do(t, h, http.MethodGet, "/", "", nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Fatalf("Content-Type = %q, 期望含 text/html", ct)
	}
	if !strings.Contains(rec.Body.String(), "<html") {
		t.Fatalf("响应体不含 <html: %q", rec.Body.String())
	}
}

// TestStaticAssetServed 验证 GET /static/<asset> 返回内嵌静态资源（公开资源）。
func TestStaticAssetServed(t *testing.T) {
	h := newSearchHandler(t, nil)

	rec := do(t, h, http.MethodGet, "/static/app.js", "", nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "/api/search") {
		t.Fatalf("app.js 内容异常: %q", rec.Body.String())
	}
}

// TestSearchEndpointRequiresAuth 验证 /api/search 仍受 Bearer 认证保护。
func TestSearchEndpointRequiresAuth(t *testing.T) {
	h := newSearchHandler(t, nil)
	rec := do(t, h, http.MethodGet, "/api/search?q=hello", "", nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("状态码 = %d, 期望 401 (body=%q)", rec.Code, rec.Body.String())
	}
}
