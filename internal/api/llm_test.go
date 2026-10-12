// 本文件通过 httptest 覆盖 M6.2 的 LLM 任务队列端点：任务创建、节点轮询、结果回传
// 与节点注册。测试复用 server_test.go 中的 do / decodeJSON / assertErrorCode 辅助函数。
package api_test

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/storage"
)

// newLLMTestHandler 构造挂载临时数据库与测试令牌的处理器，并返回底层 DB 以便断言
// 任务表状态（响应体之外的可观察事实）。
func newLLMTestHandler(t *testing.T) (http.Handler, *storage.DB) {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return api.NewHandler(db, auth.New(testToken)), db
}

// taskStatusAndResult 读取任务的状态与结果列（result 为 NULL 时返回空串）。
func taskStatusAndResult(t *testing.T, db *storage.DB, id int64) (string, string) {
	t.Helper()
	var status string
	var result *string
	if err := db.SQL().QueryRow(
		`SELECT status, result FROM llm_tasks WHERE id = ?`, id).Scan(&status, &result); err != nil {
		t.Fatalf("读取任务 %d 失败: %v", id, err)
	}
	if result == nil {
		return status, ""
	}
	return status, *result
}

// TestLLMTaskLifecycle 覆盖本地任务全流程：创建 → 轮询领取 → 回传结果。
func TestLLMTaskLifecycle(t *testing.T) {
	h, db := newLLMTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/llm/tasks", testToken, map[string]string{
		"kind":    "summarize",
		"payload": `{"messages":[{"role":"user","content":"hello"}]}`,
		"route":   "local",
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("创建任务状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}
	createdBody := decodeJSON(t, created)
	id := createdID(t, created)
	if createdBody["status"] != storage.LLMTaskPending {
		t.Fatalf("创建响应 status = %v, 期望 %q", createdBody["status"], storage.LLMTaskPending)
	}

	polled := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testToken, nil, nil)
	if polled.Code != http.StatusOK {
		t.Fatalf("轮询状态码 = %d, 期望 200 (body=%q)", polled.Code, polled.Body.String())
	}
	task := decodeJSON(t, polled)
	if taskID, _ := task["id"].(float64); int64(taskID) != id {
		t.Fatalf("轮询返回 id = %v, 期望 %d", task["id"], id)
	}
	if task["kind"] != "summarize" || task["route"] != "local" {
		t.Fatalf("轮询返回字段不符: %q", polled.Body.String())
	}
	if task["status"] != storage.LLMTaskRunning {
		t.Fatalf("轮询返回 status = %v, 期望 %q", task["status"], storage.LLMTaskRunning)
	}
	if task["payload"] != `{"messages":[{"role":"user","content":"hello"}]}` {
		t.Fatalf("轮询返回 payload 未原样透传: %v", task["payload"])
	}

	// 已领取的任务不再可领取：队列为空返回 204。
	empty := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testToken, nil, nil)
	if empty.Code != http.StatusNoContent {
		t.Fatalf("二次轮询状态码 = %d, 期望 204 (body=%q)", empty.Code, empty.Body.String())
	}
	if empty.Body.Len() != 0 {
		t.Fatalf("204 响应体应为空, 实际 %q", empty.Body.String())
	}

	reported := do(t, h, http.MethodPost,
		"/api/llm/tasks/"+itoa(id)+"/result", testToken,
		map[string]string{"result": "本地推理结果"}, nil)
	if reported.Code != http.StatusNoContent {
		t.Fatalf("回传结果状态码 = %d, 期望 204 (body=%q)", reported.Code, reported.Body.String())
	}

	status, result := taskStatusAndResult(t, db, id)
	if status != storage.LLMTaskDone {
		t.Fatalf("任务状态 = %q, 期望 %q", status, storage.LLMTaskDone)
	}
	if result != "本地推理结果" {
		t.Fatalf("任务 result = %q, 期望 %q", result, "本地推理结果")
	}
}

// TestLLMTaskCreateDefaultsToCloud 验证 route 缺省为 cloud，且云端任务不进入本地轮询。
func TestLLMTaskCreateDefaultsToCloud(t *testing.T) {
	h, db := newLLMTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/llm/tasks", testToken, map[string]string{
		"kind":    "translate",
		"payload": `{"messages":[]}`,
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("创建任务状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}
	id := createdID(t, created)

	var route string
	if err := db.SQL().QueryRow(`SELECT route FROM llm_tasks WHERE id = ?`, id).Scan(&route); err != nil {
		t.Fatalf("读取任务 route 失败: %v", err)
	}
	if route != "cloud" {
		t.Fatalf("缺省 route = %q, 期望 cloud", route)
	}

	polled := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testToken, nil, nil)
	if polled.Code != http.StatusNoContent {
		t.Fatalf("云端任务不应被轮询领取, 状态码 = %d (body=%q)", polled.Code, polled.Body.String())
	}
}

// TestLLMTaskPollEmpty 验证无待办任务时轮询返回 204。
func TestLLMTaskPollEmpty(t *testing.T) {
	h, _ := newLLMTestHandler(t)

	rec := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testToken, nil, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("空队列轮询状态码 = %d, 期望 204 (body=%q)", rec.Code, rec.Body.String())
	}
}

// TestLLMTaskCreateValidation 验证创建任务的必填校验与非法 JSON。
func TestLLMTaskCreateValidation(t *testing.T) {
	h, _ := newLLMTestHandler(t)

	cases := []struct {
		name string
		body map[string]string
	}{
		{"kind 为空", map[string]string{"payload": `{"a":1}`, "route": "local"}},
		{"payload 为空", map[string]string{"kind": "k", "route": "local"}},
		{"route 非法", map[string]string{"kind": "k", "payload": `{"a":1}`, "route": "edge"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodPost, "/api/llm/tasks", testToken, tc.body, nil)
			assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
		})
	}

	malformed := do(t, h, http.MethodPost, "/api/llm/tasks", testToken, "not-an-object", nil)
	assertErrorCode(t, malformed, http.StatusBadRequest, "invalid_argument")
}

// TestLLMTaskReportFailure 验证回传 error 字段时任务被标记为 failed。
func TestLLMTaskReportFailure(t *testing.T) {
	h, db := newLLMTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/llm/tasks", testToken, map[string]string{
		"kind":    "summarize",
		"payload": `{"messages":[]}`,
		"route":   "local",
	}, nil)
	id := createdID(t, created)

	if polled := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testToken, nil, nil); polled.Code != http.StatusOK {
		t.Fatalf("轮询状态码 = %d, 期望 200", polled.Code)
	}

	rec := do(t, h, http.MethodPost,
		"/api/llm/tasks/"+itoa(id)+"/result", testToken,
		map[string]string{"error": "Ollama 不可达"}, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("回传失败状态码 = %d, 期望 204 (body=%q)", rec.Code, rec.Body.String())
	}

	status, result := taskStatusAndResult(t, db, id)
	if status != storage.LLMTaskFailed {
		t.Fatalf("任务状态 = %q, 期望 %q", status, storage.LLMTaskFailed)
	}
	if result != "Ollama 不可达" {
		t.Fatalf("任务 result = %q, 期望失败原因", result)
	}
}

// TestLLMTaskResultErrors 验证结果回传的非法 id 与任务不存在。
func TestLLMTaskResultErrors(t *testing.T) {
	h, _ := newLLMTestHandler(t)

	invalid := do(t, h, http.MethodPost, "/api/llm/tasks/abc/result", testToken,
		map[string]string{"result": "r"}, nil)
	assertErrorCode(t, invalid, http.StatusBadRequest, "invalid_argument")

	missing := do(t, h, http.MethodPost, "/api/llm/tasks/42/result", testToken,
		map[string]string{"result": "r"}, nil)
	assertErrorCode(t, missing, http.StatusNotFound, "not_found")
}

// TestNodeRegister 验证节点注册返回注册信息并落入 meta 表。
func TestNodeRegister(t *testing.T) {
	h, db := newLLMTestHandler(t)

	rec := do(t, h, http.MethodPost, "/api/llm/nodes/register", testToken,
		map[string]string{"node_name": "home-nas"}, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("注册状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["node_name"] != "home-nas" || body["status"] != "registered" {
		t.Fatalf("注册响应字段不符: %q", rec.Body.String())
	}
	if at, _ := body["registered_at"].(string); at == "" {
		t.Fatalf("注册响应缺少 registered_at: %q", rec.Body.String())
	}

	var value string
	if err := db.SQL().QueryRow(
		`SELECT value FROM meta WHERE key = ?`, "llm_node:home-nas").Scan(&value); err != nil {
		t.Fatalf("meta 表未记录节点注册: %v", err)
	}
	if value == "" {
		t.Fatal("meta 表中注册时间不应为空")
	}
}

// TestNodeRegisterRejectsEmptyName 验证 node_name 为空返回 400。
func TestNodeRegisterRejectsEmptyName(t *testing.T) {
	h, _ := newLLMTestHandler(t)

	rec := do(t, h, http.MethodPost, "/api/llm/nodes/register", testToken,
		map[string]string{"node_name": "  "}, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestLLMEndpointsRequireAuth 验证 LLM 端点同样要求 Bearer 认证。
func TestLLMEndpointsRequireAuth(t *testing.T) {
	h, _ := newLLMTestHandler(t)

	cases := []struct {
		method string
		target string
		body   any
	}{
		{http.MethodPost, "/api/llm/tasks", map[string]string{"kind": "k", "payload": "{}"}},
		{http.MethodGet, "/api/llm/tasks/poll", nil},
		{http.MethodPost, "/api/llm/tasks/1/result", map[string]string{"result": "r"}},
		{http.MethodPost, "/api/llm/nodes/register", map[string]string{"node_name": "n"}},
	}
	for _, tc := range cases {
		t.Run(tc.method+" "+tc.target, func(t *testing.T) {
			rec := do(t, h, tc.method, tc.target, "", tc.body, nil)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("未认证状态码 = %d, 期望 401", rec.Code)
			}
		})
	}
}

// itoa 将任务 id 转为十进制字符串，用于拼装结果回传端点路径。
func itoa(id int64) string {
	return strconv.FormatInt(id, 10)
}

// createdID 从创建任务响应中取出 id（字段缺失或非法时终止用例）。
func createdID(t *testing.T, rec *httptest.ResponseRecorder) int64 {
	t.Helper()
	v, ok := decodeJSON(t, rec)["id"].(float64)
	if !ok || v <= 0 {
		t.Fatalf("创建响应缺少有效 id: %q", rec.Body.String())
	}
	return int64(v)
}
