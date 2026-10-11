package llm

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// capturedRequest 记录 mock 服务收到的请求，供断言使用。
type capturedRequest struct {
	method string
	path   string
	auth   string
	body   chatRequest
}

// newMockServer 启动一个 OpenAI 兼容的 mock 服务：
// 返回固定 content，并把收到的请求写入 captured。
func newMockServer(t *testing.T, status int, content string) (*httptest.Server, *capturedRequest) {
	t.Helper()
	captured := &capturedRequest{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured.method = r.Method
		captured.path = r.URL.Path
		captured.auth = r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &captured.body)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if status >= http.StatusOK && status < http.StatusMultipleChoices {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"choices": []map[string]any{
					{"message": map[string]any{"role": RoleAssistant, "content": content}},
				},
			})
			return
		}
		_, _ = w.Write([]byte(`{"error":{"message":"mock failure"}}`))
	}))
	t.Cleanup(server.Close)
	return server, captured
}

func TestCloudClientChat(t *testing.T) {
	server, captured := newMockServer(t, http.StatusOK, "你好，世界")
	client := NewCloud("sk-test-key", server.URL, "deepseek-chat")

	got, err := client.Chat(context.Background(), []Message{
		{Role: RoleSystem, Content: "你是助手"},
		{Role: RoleUser, Content: "打个招呼"},
	})
	if err != nil {
		t.Fatalf("Chat 返回错误: %v", err)
	}
	if got != "你好，世界" {
		t.Errorf("content = %q, 期望 %q", got, "你好，世界")
	}

	if captured.method != http.MethodPost {
		t.Errorf("method = %q, 期望 POST", captured.method)
	}
	if captured.path != "/chat/completions" {
		t.Errorf("path = %q, 期望 /chat/completions", captured.path)
	}
	if captured.auth != "Bearer sk-test-key" {
		t.Errorf("Authorization = %q, 期望 Bearer sk-test-key", captured.auth)
	}
	if captured.body.Model != "deepseek-chat" {
		t.Errorf("model = %q, 期望 deepseek-chat", captured.body.Model)
	}
	if len(captured.body.Messages) != 2 {
		t.Fatalf("messages 数量 = %d, 期望 2", len(captured.body.Messages))
	}
	if captured.body.Messages[0].Role != RoleSystem || captured.body.Messages[0].Content != "你是助手" {
		t.Errorf("首条消息 = %+v, 期望 system/你是助手", captured.body.Messages[0])
	}
	if captured.body.Messages[1].Role != RoleUser || captured.body.Messages[1].Content != "打个招呼" {
		t.Errorf("次条消息 = %+v, 期望 user/打个招呼", captured.body.Messages[1])
	}
}

func TestCloudClientNon2xx(t *testing.T) {
	server, _ := newMockServer(t, http.StatusUnauthorized, "")

	_, err := NewCloud("bad", server.URL, "").Chat(context.Background(), []Message{
		{Role: RoleUser, Content: "hi"},
	})
	if err == nil {
		t.Fatal("期望非 2xx 返回错误，实际为 nil")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("错误信息应含状态码 401，实际: %v", err)
	}
	if !strings.Contains(err.Error(), "mock failure") {
		t.Errorf("错误信息应含响应体摘要，实际: %v", err)
	}
}

func TestCloudClientDefaults(t *testing.T) {
	client := NewCloud("k", "", "")
	if client.baseURL != defaultCloudBaseURL {
		t.Errorf("baseURL = %q, 期望 %q", client.baseURL, defaultCloudBaseURL)
	}
	if client.model != defaultCloudModel {
		t.Errorf("model = %q, 期望 %q", client.model, defaultCloudModel)
	}
}

func TestLocalNodeClientChat(t *testing.T) {
	server, captured := newMockServer(t, http.StatusOK, "本地回复")
	client := NewLocal(server.URL).WithModel("qwen2.5:7b")

	got, err := client.Chat(context.Background(), []Message{{Role: RoleUser, Content: "hi"}})
	if err != nil {
		t.Fatalf("Chat 返回错误: %v", err)
	}
	if got != "本地回复" {
		t.Errorf("content = %q, 期望 %q", got, "本地回复")
	}
	if captured.path != "/v1/chat/completions" {
		t.Errorf("path = %q, 期望 /v1/chat/completions", captured.path)
	}
	if captured.body.Model != "qwen2.5:7b" {
		t.Errorf("model = %q, 期望 qwen2.5:7b", captured.body.Model)
	}
	if captured.auth != "" {
		t.Errorf("本地节点不应发送 Authorization，实际 = %q", captured.auth)
	}
}

func TestLocalNodeClientDefaultURL(t *testing.T) {
	if got := NewLocal("").baseURL; got != defaultLocalNodeURL {
		t.Errorf("baseURL = %q, 期望 %q", got, defaultLocalNodeURL)
	}
}

func TestRouterRouteSelection(t *testing.T) {
	cloudServer, cloudCaptured := newMockServer(t, http.StatusOK, "来自云端")
	localServer, localCaptured := newMockServer(t, http.StatusOK, "来自本地")

	router := NewRouter(
		NewCloud("k", cloudServer.URL, "deepseek-chat"),
		NewLocal(localServer.URL).WithModel("m"),
	)

	t.Run("RouteCloud 走云端", func(t *testing.T) {
		got, err := router.ChatRoute(context.Background(), RouteCloud, []Message{{Role: RoleUser, Content: "x"}})
		if err != nil {
			t.Fatalf("ChatRoute 返回错误: %v", err)
		}
		if got != "来自云端" {
			t.Errorf("content = %q, 期望 来自云端", got)
		}
		if cloudCaptured.method == "" {
			t.Error("云端后端未被调用")
		}
		if localCaptured.method != "" {
			t.Error("本地后端不应被调用")
		}
	})

	t.Run("RouteLocal 走本地", func(t *testing.T) {
		got, err := router.ChatRoute(context.Background(), RouteLocal, []Message{{Role: RoleUser, Content: "x"}})
		if err != nil {
			t.Fatalf("ChatRoute 返回错误: %v", err)
		}
		if got != "来自本地" {
			t.Errorf("content = %q, 期望 来自本地", got)
		}
		if localCaptured.method == "" {
			t.Error("本地后端未被调用")
		}
	})

	t.Run("Chat 默认走云端", func(t *testing.T) {
		got, err := router.Chat(context.Background(), []Message{{Role: RoleUser, Content: "x"}})
		if err != nil {
			t.Fatalf("Chat 返回错误: %v", err)
		}
		if got != "来自云端" {
			t.Errorf("content = %q, 期望 来自云端", got)
		}
	})
}

func TestRouterUnconfiguredBackend(t *testing.T) {
	router := NewRouter(nil, nil)

	if _, err := router.ChatRoute(context.Background(), RouteCloud, []Message{{Role: RoleUser, Content: "x"}}); err == nil {
		t.Error("云端未配置时应返回错误")
	}
	if _, err := router.ChatRoute(context.Background(), RouteLocal, []Message{{Role: RoleUser, Content: "x"}}); err == nil {
		t.Error("本地未配置时应返回错误")
	}
}

func TestChatCompletionsRejectsEmptyMessages(t *testing.T) {
	server, _ := newMockServer(t, http.StatusOK, "x")
	client := NewCloud("k", server.URL, "m")
	if _, err := client.Chat(context.Background(), nil); err == nil {
		t.Error("空消息列表应返回错误")
	}
}
