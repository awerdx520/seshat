package llm

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// analyzeFakeClient 是文档分析测试专用的 Client 替身：返回预设内容/错误，
// 并记录最近一次调用收到的消息。独立命名以避免与同包其他测试替身冲突。
type analyzeFakeClient struct {
	// reply 是 Chat 返回的预设内容。
	reply string
	// err 是 Chat 返回的预设错误，非 nil 时优先返回。
	err error
	// lastMessages 记录最近一次 Chat 调用收到的消息，供断言。
	lastMessages []Message
}

// Chat 实现 Client 接口，返回预设内容并记录入参。
func (f *analyzeFakeClient) Chat(_ context.Context, messages []Message) (string, error) {
	f.lastMessages = messages
	if f.err != nil {
		return "", f.err
	}
	return f.reply, nil
}

func TestAnalyzeDocumentParsesJSON(t *testing.T) {
	reply := `{
		"title": "Go 并发编程",
		"sections": [
			{"heading": "Goroutine", "summary": "轻量级线程"},
			{"heading": "Channel", "summary": "goroutine 间通信"}
		],
		"terms": ["goroutine", "channel"],
		"entities": ["Go", "Google"]
	}`
	c := &analyzeFakeClient{reply: reply}

	got, err := AnalyzeDocument(context.Background(), c, "任意原文")
	if err != nil {
		t.Fatalf("AnalyzeDocument 返回错误: %v", err)
	}
	if got.Title != "Go 并发编程" {
		t.Errorf("Title = %q, 期望 %q", got.Title, "Go 并发编程")
	}
	if len(got.Sections) != 2 {
		t.Fatalf("Sections 数量 = %d, 期望 2", len(got.Sections))
	}
	if got.Sections[0].Heading != "Goroutine" || got.Sections[0].Summary != "轻量级线程" {
		t.Errorf("首个章节 = %+v, 期望 Goroutine/轻量级线程", got.Sections[0])
	}
	if len(got.Terms) != 2 || got.Terms[1] != "channel" {
		t.Errorf("Terms = %v, 期望含 [goroutine channel]", got.Terms)
	}
	if len(got.Entities) != 2 || got.Entities[0] != "Go" {
		t.Errorf("Entities = %v, 期望含 [Go Google]", got.Entities)
	}
}

func TestAnalyzeDocumentStripsJSONFence(t *testing.T) {
	c := &analyzeFakeClient{reply: "```json\n{\"title\":\"围栏\",\"sections\":[],\"terms\":[],\"entities\":[]}\n```"}

	got, err := AnalyzeDocument(context.Background(), c, "原文")
	if err != nil {
		t.Fatalf("围栏内容应能解析，实际错误: %v", err)
	}
	if got.Title != "围栏" {
		t.Errorf("Title = %q, 期望 %q", got.Title, "围栏")
	}
}

func TestStripJSONFence(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"无围栏原样", `{"a":1}`, `{"a":1}`},
		{"json 围栏", "```json\n{\"a\":1}\n```", `{"a":1}`},
		{"无语言围栏", "```\n{\"a\":1}\n```", `{"a":1}`},
		{"单行 json 围栏", "```json{\"a\":1}```", `{"a":1}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := stripJSONFence(tc.in); got != tc.want {
				t.Errorf("stripJSONFence(%q) = %q, 期望 %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestAnalyzeDocumentInvalidJSON(t *testing.T) {
	c := &analyzeFakeClient{reply: "这不是 JSON"}

	_, err := AnalyzeDocument(context.Background(), c, "原文")
	if err == nil {
		t.Fatal("非法 JSON 应返回错误，实际为 nil")
	}
	if !strings.Contains(err.Error(), "解析失败") {
		t.Errorf("错误信息应提示解析失败，实际: %v", err)
	}
}

func TestAnalyzeDocumentEmptyReply(t *testing.T) {
	c := &analyzeFakeClient{reply: "   "}

	if _, err := AnalyzeDocument(context.Background(), c, "原文"); err == nil {
		t.Fatal("空内容应返回错误，实际为 nil")
	}
}

func TestAnalyzeDocumentChatError(t *testing.T) {
	sentinel := errors.New("boom")
	c := &analyzeFakeClient{err: sentinel}

	_, err := AnalyzeDocument(context.Background(), c, "原文")
	if err == nil {
		t.Fatal("Chat 出错时应返回错误，实际为 nil")
	}
	if !errors.Is(err, sentinel) {
		t.Errorf("错误应包装原始错误，实际: %v", err)
	}
}

func TestAnalyzeDocumentNilClient(t *testing.T) {
	if _, err := AnalyzeDocument(context.Background(), nil, "原文"); err == nil {
		t.Fatal("nil Client 应返回错误，实际为 nil")
	}
}

func TestAnalyzeDocumentPromptContainsText(t *testing.T) {
	const text = "这是一段关于量子计算的独特原文内容。"
	c := &analyzeFakeClient{reply: `{"title":"t","sections":[],"terms":[],"entities":[]}`}

	if _, err := AnalyzeDocument(context.Background(), c, text); err != nil {
		t.Fatalf("AnalyzeDocument 返回错误: %v", err)
	}
	if len(c.lastMessages) != 2 {
		t.Fatalf("消息数量 = %d, 期望 2（system + user）", len(c.lastMessages))
	}
	if c.lastMessages[0].Role != RoleSystem {
		t.Errorf("首条消息角色 = %q, 期望 %q", c.lastMessages[0].Role, RoleSystem)
	}
	if !strings.Contains(c.lastMessages[0].Content, "JSON") {
		t.Errorf("system prompt 应要求输出 JSON，实际: %q", c.lastMessages[0].Content)
	}
	if c.lastMessages[1].Role != RoleUser {
		t.Errorf("次条消息角色 = %q, 期望 %q", c.lastMessages[1].Role, RoleUser)
	}
	if c.lastMessages[1].Content != text {
		t.Errorf("user 消息应包含原文，实际: %q，期望 %q", c.lastMessages[1].Content, text)
	}
}
