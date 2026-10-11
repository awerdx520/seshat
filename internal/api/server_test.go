// Package api_test 通过 httptest 驱动 REST 处理器，覆盖阅读进度与批注的全部端点。
//
// 测试在临时目录中打开独立 SQLite 库（每个用例一份），经 NewHandler 组装
// ServeMux + Bearer 认证中间件，从外部包视角验证公开接口行为。
package api_test

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"notes/internal/api"
	"notes/internal/auth"
	"notes/internal/storage"
)

// testToken 是测试用访问令牌，与 New 构造的 Authenticator 保持一致。
const testToken = "test-token"

// newTestHandler 构造挂载了临时数据库与测试令牌的 REST 处理器。
func newTestHandler(t *testing.T) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "notes.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return api.NewHandler(db, auth.New(testToken))
}

// do 发送一次请求：body 非 nil 时序列化为 JSON，token 非空时附加 Bearer 头，
// headers 用于附加额外请求头（如 If-Modified-Since）。
func do(t *testing.T, h http.Handler, method, target, token string, body any, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()

	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("序列化请求体失败: %v", err)
		}
		reader = bytes.NewReader(raw)
	}

	req := httptest.NewRequest(method, target, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// decodeJSON 将响应体解码为 map，失败即终止用例。
func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("响应体不是合法 JSON: %v (body=%q)", err, rec.Body.String())
	}
	return got
}

// decodeList 将响应体解码为对象数组。
func decodeList(t *testing.T, rec *httptest.ResponseRecorder) []map[string]any {
	t.Helper()
	var got []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("响应体不是合法 JSON 数组: %v (body=%q)", err, rec.Body.String())
	}
	return got
}

// assertErrorCode 断言响应为指定状态码且响应体错误码匹配。
func assertErrorCode(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("状态码 = %d, 期望 %d (body=%q)", rec.Code, status, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	errObj, ok := body["error"].(map[string]any)
	if !ok {
		t.Fatalf("响应体缺少 error 对象: %q", rec.Body.String())
	}
	if got, _ := errObj["code"].(string); got != code {
		t.Fatalf("错误码 = %q, 期望 %q", got, code)
	}
	if msg, _ := errObj["message"].(string); msg == "" {
		t.Fatalf("错误信息不应为空: %q", rec.Body.String())
	}
}

// TestProgressPutThenGet 验证进度设置后可原样读回。
func TestProgressPutThenGet(t *testing.T) {
	h := newTestHandler(t)

	put := do(t, h, http.MethodPut, "/api/progress/book-1", testToken, map[string]string{
		"position":   "chapter-3:42",
		"updated_at": "2026-10-11T10:00:00Z",
	}, nil)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", put.Code, put.Body.String())
	}

	get := do(t, h, http.MethodGet, "/api/progress/book-1", testToken, nil, nil)
	if get.Code != http.StatusOK {
		t.Fatalf("GET 状态码 = %d, 期望 200 (body=%q)", get.Code, get.Body.String())
	}
	body := decodeJSON(t, get)
	if body["document_id"] != "book-1" {
		t.Fatalf("document_id = %v, 期望 book-1", body["document_id"])
	}
	if body["position"] != "chapter-3:42" {
		t.Fatalf("position = %v, 期望 chapter-3:42", body["position"])
	}
	if body["updated_at"] != "2026-10-11T10:00:00Z" {
		t.Fatalf("updated_at = %v, 期望 2026-10-11T10:00:00Z", body["updated_at"])
	}
}

// TestProgressPutOverwrites 验证重复 PUT 为后写覆盖（UPSERT）。
func TestProgressPutOverwrites(t *testing.T) {
	h := newTestHandler(t)

	for _, pos := range []string{"p1", "p2"} {
		rec := do(t, h, http.MethodPut, "/api/progress/doc", testToken, map[string]string{
			"position":   pos,
			"updated_at": "2026-10-11T10:00:00Z",
		}, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("PUT %s 状态码 = %d, 期望 200", pos, rec.Code)
		}
	}

	get := do(t, h, http.MethodGet, "/api/progress/doc", testToken, nil, nil)
	if got := decodeJSON(t, get)["position"]; got != "p2" {
		t.Fatalf("position = %v, 期望后写覆盖为 p2", got)
	}
}

// TestProgressGetNotFound 验证读取不存在的进度返回 404。
func TestProgressGetNotFound(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodGet, "/api/progress/missing", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")
}

// TestProgressPutMissingPosition 验证 position 为空时返回 400。
func TestProgressPutMissingPosition(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodPut, "/api/progress/doc", testToken, map[string]string{
		"position":   "",
		"updated_at": "2026-10-11T10:00:00Z",
	}, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestProgressNotModified 验证 If-Modified-Since 未变时返回 304 且无响应体。
func TestProgressNotModified(t *testing.T) {
	h := newTestHandler(t)

	const stamp = "2026-10-11T10:00:00Z"
	put := do(t, h, http.MethodPut, "/api/progress/doc", testToken, map[string]string{
		"position":   "p1",
		"updated_at": stamp,
	}, nil)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200", put.Code)
	}

	ts, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		t.Fatalf("解析时间戳失败: %v", err)
	}

	rec := do(t, h, http.MethodGet, "/api/progress/doc", testToken, nil, map[string]string{
		"If-Modified-Since": ts.Format(http.TimeFormat),
	})
	if rec.Code != http.StatusNotModified {
		t.Fatalf("状态码 = %d, 期望 304 (body=%q)", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 0 {
		t.Fatalf("304 响应体应为空, 实际 %q", rec.Body.String())
	}

	// 早于更新时间的 If-Modified-Since 应返回完整内容。
	older := do(t, h, http.MethodGet, "/api/progress/doc", testToken, nil, map[string]string{
		"If-Modified-Since": ts.Add(-time.Hour).Format(http.TimeFormat),
	})
	if older.Code != http.StatusOK {
		t.Fatalf("旧时间戳状态码 = %d, 期望 200", older.Code)
	}
}

// TestAnnotationsCRUD 覆盖批注的创建、列举、更新、删除全流程。
func TestAnnotationsCRUD(t *testing.T) {
	h := newTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"document_id": "book-1",
		"location":    "chapter-1:10",
		"text":        "第一条批注",
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}
	createdBody := decodeJSON(t, created)
	id, ok := createdBody["id"].(float64)
	if !ok || id <= 0 {
		t.Fatalf("创建响应缺少有效 id: %q", created.Body.String())
	}
	if createdBody["document_id"] != "book-1" || createdBody["location"] != "chapter-1:10" {
		t.Fatalf("创建响应字段不符: %q", created.Body.String())
	}
	for _, field := range []string{"created_at", "updated_at"} {
		if s, _ := createdBody[field].(string); s == "" {
			t.Fatalf("创建响应缺少 %s: %q", field, created.Body.String())
		}
	}

	list := do(t, h, http.MethodGet, "/api/annotations?document_id=book-1", testToken, nil, nil)
	if list.Code != http.StatusOK {
		t.Fatalf("GET 列表状态码 = %d, 期望 200", list.Code)
	}
	items := decodeList(t, list)
	if len(items) != 1 {
		t.Fatalf("批注条数 = %d, 期望 1", len(items))
	}

	update := do(t, h, http.MethodPut, "/api/annotations/1", testToken, map[string]string{
		"location": "chapter-1:12",
		"text":     "修改后的批注",
	}, nil)
	if update.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", update.Code, update.Body.String())
	}
	updatedBody := decodeJSON(t, update)
	if updatedBody["text"] != "修改后的批注" || updatedBody["location"] != "chapter-1:12" {
		t.Fatalf("更新响应字段不符: %q", update.Body.String())
	}
	if updatedBody["created_at"] != createdBody["created_at"] {
		t.Fatalf("created_at 不应变化: %v → %v", createdBody["created_at"], updatedBody["created_at"])
	}

	deleteRec := do(t, h, http.MethodDelete, "/api/annotations/1", testToken, nil, nil)
	if deleteRec.Code != http.StatusNoContent {
		t.Fatalf("DELETE 状态码 = %d, 期望 204 (body=%q)", deleteRec.Code, deleteRec.Body.String())
	}

	after := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?document_id=book-1", testToken, nil, nil))
	if len(after) != 0 {
		t.Fatalf("删除后批注条数 = %d, 期望 0", len(after))
	}
}

// TestAnnotationsListSeparatesDocuments 验证列表按 document_id 过滤。
func TestAnnotationsListSeparatesDocuments(t *testing.T) {
	h := newTestHandler(t)

	for _, doc := range []string{"a", "a", "b"} {
		rec := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
			"document_id": doc,
			"location":    "loc",
			"text":        "text",
		}, nil)
		if rec.Code != http.StatusCreated {
			t.Fatalf("POST 状态码 = %d, 期望 201", rec.Code)
		}
	}

	items := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?document_id=a", testToken, nil, nil))
	if len(items) != 2 {
		t.Fatalf("文档 a 的批注条数 = %d, 期望 2", len(items))
	}
	items = decodeList(t, do(t, h, http.MethodGet, "/api/annotations?document_id=b", testToken, nil, nil))
	if len(items) != 1 {
		t.Fatalf("文档 b 的批注条数 = %d, 期望 1", len(items))
	}
}

// TestAnnotationsListRequiresDocumentID 验证缺少 document_id 查询参数返回 400。
func TestAnnotationsListRequiresDocumentID(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodGet, "/api/annotations", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestAnnotationCreateRejectsEmptyFields 验证创建时必填字段为空返回 400。
func TestAnnotationCreateRejectsEmptyFields(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"document_id": "book-1",
		"location":    "",
		"text":        "text",
	}, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestAnnotationUpdateNotFound 验证更新不存在的批注返回 404。
func TestAnnotationUpdateNotFound(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodPut, "/api/annotations/42", testToken, map[string]string{
		"location": "loc",
		"text":     "text",
	}, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")
}

// TestAnnotationDeleteNotFound 验证删除不存在的批注返回 404。
func TestAnnotationDeleteNotFound(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodDelete, "/api/annotations/42", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")
}

// TestAnnotationInvalidID 验证非数字 id 返回 400。
func TestAnnotationInvalidID(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodPut, "/api/annotations/abc", testToken, map[string]string{
		"location": "loc",
		"text":     "text",
	}, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestAnnotationMalformedJSON 验证请求体非法 JSON 返回 400。
func TestAnnotationMalformedJSON(t *testing.T) {
	h := newTestHandler(t)

	req := httptest.NewRequest(http.MethodPost, "/api/annotations", bytes.NewReader([]byte("{not json")))
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestUnauthorized 验证缺失或错误令牌一律返回 401，且不触碰存储。
func TestUnauthorized(t *testing.T) {
	h := newTestHandler(t)

	cases := []struct {
		name  string
		token string
	}{
		{"缺失令牌", ""},
		{"错误令牌", "wrong-token"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodGet, "/api/progress/doc", tc.token, nil, nil)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("GET 状态码 = %d, 期望 401", rec.Code)
			}
			if got := rec.Header().Get("WWW-Authenticate"); got == "" {
				t.Fatalf("401 响应应带 WWW-Authenticate 头")
			}

			rec = do(t, h, http.MethodPost, "/api/annotations", tc.token, map[string]string{
				"document_id": "book-1",
				"location":    "loc",
				"text":        "text",
			}, nil)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("POST 状态码 = %d, 期望 401", rec.Code)
			}
		})
	}
}

// TestServerEndToEndOverRealHTTP 用真实 HTTP 栈（httptest.NewServer + net/http 客户端）
// 冒烟验证关键路径，覆盖 ResponseRecorder 无法反映的传输层语义（304/204 的空响应体、
// 响应头与状态码组合）。
func TestServerEndToEndOverRealHTTP(t *testing.T) {
	db, err := storage.Open(filepath.Join(t.TempDir(), "notes.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	srv := httptest.NewServer(api.NewHandler(db, auth.New(testToken)))
	defer srv.Close()

	client := srv.Client()
	send := func(method, path, token string, body any, headers map[string]string) *http.Response {
		var reader io.Reader
		if body != nil {
			raw, err := json.Marshal(body)
			if err != nil {
				t.Fatalf("序列化请求体失败: %v", err)
			}
			reader = bytes.NewReader(raw)
		}
		req, err := http.NewRequest(method, srv.URL+path, reader)
		if err != nil {
			t.Fatalf("构造请求失败: %v", err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("请求 %s %s 失败: %v", method, path, err)
		}
		return resp
	}

	// 未认证请求在真实栈下同样拒绝。
	unauth := send(http.MethodGet, "/api/progress/doc", "", nil, nil)
	_ = unauth.Body.Close()
	if unauth.StatusCode != http.StatusUnauthorized {
		t.Fatalf("未认证状态码 = %d, 期望 401", unauth.StatusCode)
	}

	const stamp = "2026-10-11T10:00:00Z"
	put := send(http.MethodPut, "/api/progress/doc", testToken, map[string]string{
		"position":   "p1",
		"updated_at": stamp,
	}, nil)
	if put.StatusCode != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200", put.StatusCode)
	}
	if ct := put.Header.Get("Content-Type"); ct != "application/json; charset=utf-8" {
		t.Fatalf("PUT Content-Type = %q", ct)
	}
	_ = put.Body.Close()

	// 未变更时 304 且响应体为空。
	ts, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		t.Fatalf("解析时间戳失败: %v", err)
	}
	notModified := send(http.MethodGet, "/api/progress/doc", testToken, nil, map[string]string{
		"If-Modified-Since": ts.Format(http.TimeFormat),
	})
	buf, _ := io.ReadAll(notModified.Body)
	_ = notModified.Body.Close()
	if notModified.StatusCode != http.StatusNotModified {
		t.Fatalf("状态码 = %d, 期望 304", notModified.StatusCode)
	}
	if len(buf) != 0 {
		t.Fatalf("304 响应体应为空, 实际 %q", buf)
	}

	created := send(http.MethodPost, "/api/annotations", testToken, map[string]string{
		"document_id": "book-1",
		"location":    "loc",
		"text":        "text",
	}, nil)
	if created.StatusCode != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201", created.StatusCode)
	}
	_ = created.Body.Close()

	deleted := send(http.MethodDelete, "/api/annotations/1", testToken, nil, nil)
	buf, _ = io.ReadAll(deleted.Body)
	_ = deleted.Body.Close()
	if deleted.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE 状态码 = %d, 期望 204", deleted.StatusCode)
	}
	if len(buf) != 0 {
		t.Fatalf("204 响应体应为空, 实际 %q", buf)
	}
}

// TestUnauthorizedDoesNotWrite 验证未认证请求不会写入数据。
func TestUnauthorizedDoesNotWrite(t *testing.T) {
	h := newTestHandler(t)

	rec := do(t, h, http.MethodPut, "/api/progress/doc", "wrong-token", map[string]string{
		"position":   "p1",
		"updated_at": "2026-10-11T10:00:00Z",
	}, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("状态码 = %d, 期望 401", rec.Code)
	}

	// 认证通过后读取应仍为 404（未被未认证写入污染）。
	got := do(t, h, http.MethodGet, "/api/progress/doc", testToken, nil, nil)
	if got.Code != http.StatusNotFound {
		t.Fatalf("读取状态码 = %d, 期望 404（未认证请求不应写入）", got.Code)
	}
}
