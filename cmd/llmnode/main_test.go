package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// discardLogger 返回丢弃全部输出的日志器，避免测试噪声。
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// TestLoadConfig 验证必填校验与默认值回退。
func TestLoadConfig(t *testing.T) {
	// 缺失必填项：NOTES_SERVER_URL。
	t.Setenv("NOTES_SERVER_URL", "")
	t.Setenv("NOTES_AUTH_TOKEN", "tok")
	if _, err := loadConfig(); err == nil {
		t.Fatal("缺少 NOTES_SERVER_URL 应返回错误")
	}

	// 缺失必填项：NOTES_NODE_TOKEN 与 NOTES_AUTH_TOKEN 均未设置。
	t.Setenv("NOTES_SERVER_URL", "https://notes.example.com/")
	t.Setenv("NOTES_AUTH_TOKEN", "")
	t.Setenv("NOTES_NODE_TOKEN", "")
	if _, err := loadConfig(); err == nil {
		t.Fatal("缺少令牌应返回错误")
	}

	// 齐全：serverURL 去掉尾部斜杠，OLLAMA_URL 取默认值，NODE_NAME 回退主机名。
	t.Setenv("NOTES_AUTH_TOKEN", "tok")
	t.Setenv("OLLAMA_URL", "")
	t.Setenv("OLLAMA_MODEL", "")
	t.Setenv("NODE_NAME", "")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() 返回错误: %v", err)
	}
	if cfg.serverURL != "https://notes.example.com" {
		t.Fatalf("serverURL = %q, 期望去掉尾部斜杠", cfg.serverURL)
	}
	if cfg.ollamaURL != defaultOllamaURL {
		t.Fatalf("ollamaURL = %q, 期望默认值 %q", cfg.ollamaURL, defaultOllamaURL)
	}
	if cfg.nodeName == "" {
		t.Fatal("nodeName 应回退到主机名，不应为空")
	}

	// 显式设置 OLLAMA_URL / NODE_NAME 时按设置取值。
	t.Setenv("OLLAMA_URL", "http://127.0.0.1:11434/")
	t.Setenv("NODE_NAME", "home-nas")
	cfg, err = loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() 返回错误: %v", err)
	}
	if cfg.ollamaURL != "http://127.0.0.1:11434" || cfg.nodeName != "home-nas" {
		t.Fatalf("配置未按环境变量生效: %+v", cfg)
	}
}

// fakeServer 模拟服务端：注册 + 轮询 + 结果回传，并把收到的回传体记录下来。
type fakeServer struct {
	polls    int                 // 已发生的轮询次数
	tasks    []task              // 依次返回的任务；耗尽后返回 204
	reported []map[string]string // 收到的结果回传体
	authSeen string              // 最近一次请求携带的 Authorization 头
}

// start 启动 httptest 服务端并返回其地址。
func (f *fakeServer) start(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.authSeen = r.Header.Get("Authorization")
		switch {
		case r.URL.Path == "/api/llm/nodes/register":
			_ = json.NewEncoder(w).Encode(map[string]string{"node_name": "home-nas", "status": "registered"})
		case r.URL.Path == "/api/llm/tasks/poll":
			if f.polls >= len(f.tasks) {
				f.polls++
				w.WriteHeader(http.StatusNoContent)
				return
			}
			_ = json.NewEncoder(w).Encode(f.tasks[f.polls])
			f.polls++
		case strings.HasPrefix(r.URL.Path, "/api/llm/tasks/") && strings.HasSuffix(r.URL.Path, "/result"):
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			f.reported = append(f.reported, body)
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// fakeOllama 模拟 Ollama：记录收到的 chat 请求，固定返回一条助手回复。
type fakeOllama struct {
	model    string
	messages []message
	status   int // 非 0 时返回该状态码（用于测试失败路径）
}

// start 启动 httptest 服务端并返回其地址。
func (f *fakeOllama) start(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		var req chatRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		f.model = req.Model
		f.messages = req.Messages
		if f.status != 0 {
			http.Error(w, "推理失败", f.status)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"choices": []map[string]any{
				{"message": message{Role: "assistant", Content: "本地摘要结果"}},
			},
		})
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// TestProcessOneHappyPath 验证「注册 → 轮询领取 → 本地推理 → 回传结果」全流程。
func TestProcessOneHappyPath(t *testing.T) {
	server := &fakeServer{tasks: []task{{
		ID:      7,
		Kind:    "summarize",
		Payload: `{"model":"qwen2.5:7b","messages":[{"role":"user","content":"总结这段"}]}`,
		Route:   "local",
		Status:  "running",
	}}}
	ollama := &fakeOllama{}

	cfg := config{
		serverURL: server.start(t),
		authToken: "node-token",
		ollamaURL: ollama.start(t),
		model:     "ignored-default",
		nodeName:  "home-nas",
	}
	n := newNode(cfg, discardLogger())
	ctx := context.Background()

	if err := n.register(ctx); err != nil {
		t.Fatalf("register() 返回错误: %v", err)
	}
	if server.authSeen != "Bearer node-token" {
		t.Fatalf("注册未携带 Bearer 令牌: %q", server.authSeen)
	}

	processed, err := n.processOne(ctx)
	if err != nil {
		t.Fatalf("processOne() 返回错误: %v", err)
	}
	if !processed {
		t.Fatal("processOne() 应报告处理了任务")
	}

	// payload 自带的 model 优先于默认模型；messages 原样转发给 Ollama。
	if ollama.model != "qwen2.5:7b" {
		t.Fatalf("Ollama 收到 model = %q, 期望 payload 中的 qwen2.5:7b", ollama.model)
	}
	if len(ollama.messages) != 1 || ollama.messages[0].Content != "总结这段" {
		t.Fatalf("Ollama 收到 messages = %+v", ollama.messages)
	}

	if len(server.reported) != 1 {
		t.Fatalf("回传次数 = %d, 期望 1", len(server.reported))
	}
	if got := server.reported[0]["result"]; got != "本地摘要结果" {
		t.Fatalf("回传 result = %q, 期望本地摘要结果", got)
	}
	if _, ok := server.reported[0]["error"]; ok {
		t.Fatalf("成功路径不应回传 error 字段: %+v", server.reported[0])
	}

	// 队列已空：下一轮返回 204，processOne 报告未处理任务。
	processed, err = n.processOne(ctx)
	if err != nil {
		t.Fatalf("空队列 processOne() 返回错误: %v", err)
	}
	if processed {
		t.Fatal("空队列时 processOne() 不应报告处理了任务")
	}
}

// TestProcessOneInferenceFailure 验证推理失败时仍回传 error 字段（任务不会卡在 running）。
func TestProcessOneInferenceFailure(t *testing.T) {
	server := &fakeServer{tasks: []task{{
		ID:      8,
		Kind:    "summarize",
		Payload: `{"messages":[{"role":"user","content":"hi"}]}`,
		Route:   "local",
		Status:  "running",
	}}}
	ollama := &fakeOllama{status: http.StatusInternalServerError}

	cfg := config{
		serverURL: server.start(t),
		authToken: "node-token",
		ollamaURL: ollama.start(t),
		model:     "qwen2.5:7b",
		nodeName:  "home-nas",
	}
	n := newNode(cfg, discardLogger())

	processed, err := n.processOne(context.Background())
	if err != nil {
		t.Fatalf("processOne() 返回错误: %v", err)
	}
	if !processed {
		t.Fatal("processOne() 应报告处理了任务")
	}
	if len(server.reported) != 1 {
		t.Fatalf("回传次数 = %d, 期望 1", len(server.reported))
	}
	if msg := server.reported[0]["error"]; !strings.Contains(msg, "500") {
		t.Fatalf("回传 error = %q, 期望包含状态码 500", msg)
	}

	// payload 未自带 model 时回退到配置的默认模型。
	if ollama.model != "qwen2.5:7b" {
		t.Fatalf("Ollama 收到 model = %q, 期望默认 qwen2.5:7b", ollama.model)
	}
}

// TestProcessOneInvalidPayload 验证 payload 非法时回传失败原因而不调用 Ollama。
func TestProcessOneInvalidPayload(t *testing.T) {
	server := &fakeServer{tasks: []task{{
		ID:      9,
		Kind:    "summarize",
		Payload: `not-json`,
		Route:   "local",
		Status:  "running",
	}}}
	ollama := &fakeOllama{}

	cfg := config{
		serverURL: server.start(t),
		authToken: "node-token",
		ollamaURL: ollama.start(t),
		nodeName:  "home-nas",
	}
	n := newNode(cfg, discardLogger())

	if _, err := n.processOne(context.Background()); err != nil {
		t.Fatalf("processOne() 返回错误: %v", err)
	}
	if len(server.reported) != 1 || !strings.Contains(server.reported[0]["error"], "payload") {
		t.Fatalf("回传内容 = %+v, 期望含 payload 解析失败原因", server.reported)
	}
	if ollama.model != "" || len(ollama.messages) != 0 {
		t.Fatalf("payload 非法时不应调用 Ollama: model=%q messages=%+v", ollama.model, ollama.messages)
	}
}

// TestNodeAuthTokenSelection 验证节点令牌选择：优先 NOTES_NODE_TOKEN，
// 未配置或为空白时回退 NOTES_AUTH_TOKEN，两者皆空时返回空。
func TestNodeAuthTokenSelection(t *testing.T) {
	// 两者都配置：优先节点令牌。
	t.Setenv("NOTES_NODE_TOKEN", "node-tok")
	t.Setenv("NOTES_AUTH_TOKEN", "main-tok")
	if got := nodeAuthToken(); got != "node-tok" {
		t.Fatalf("nodeAuthToken() = %q, 期望优先取 NOTES_NODE_TOKEN", got)
	}

	// 仅配置主令牌：回退主令牌。
	t.Setenv("NOTES_NODE_TOKEN", "")
	t.Setenv("NOTES_AUTH_TOKEN", "main-tok")
	if got := nodeAuthToken(); got != "main-tok" {
		t.Fatalf("nodeAuthToken() = %q, 期望回退 NOTES_AUTH_TOKEN", got)
	}

	// 节点令牌为空白：同样回退主令牌。
	t.Setenv("NOTES_NODE_TOKEN", "  ")
	t.Setenv("NOTES_AUTH_TOKEN", "main-tok")
	if got := nodeAuthToken(); got != "main-tok" {
		t.Fatalf("空白 NOTES_NODE_TOKEN 应回退主令牌, got %q", got)
	}

	// 均未配置：返回空。
	t.Setenv("NOTES_NODE_TOKEN", "")
	t.Setenv("NOTES_AUTH_TOKEN", "")
	if got := nodeAuthToken(); got != "" {
		t.Fatalf("均未配置应返回空, got %q", got)
	}
}

// TestLoadConfigUsesNodeToken 验证 loadConfig 采用（优先的）节点令牌。
func TestLoadConfigUsesNodeToken(t *testing.T) {
	t.Setenv("NOTES_SERVER_URL", "https://notes.example.com")
	t.Setenv("NOTES_NODE_TOKEN", "node-tok")
	t.Setenv("NOTES_AUTH_TOKEN", "main-tok")
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() 返回错误: %v", err)
	}
	if cfg.authToken != "node-tok" {
		t.Fatalf("authToken = %q, 期望节点令牌", cfg.authToken)
	}
}
