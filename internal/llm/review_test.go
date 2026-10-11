package llm

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// reviewFakeClient 是审查单测专用的 Client 测试替身：
// 返回预设回复/错误，并记录调用次数与最近一次收到的消息。
type reviewFakeClient struct {
	// reply 是 Chat 返回的预设内容。
	reply string
	// err 是 Chat 返回的预设错误，非 nil 时优先返回。
	err error
	// messages 记录最近一次 Chat 调用收到的消息，供断言。
	messages []Message
	// calls 记录 Chat 被调用的次数。
	calls int
}

// Chat 实现 Client 接口，返回预设内容并记录入参。
func (f *reviewFakeClient) Chat(_ context.Context, messages []Message) (string, error) {
	f.calls++
	f.messages = messages
	if f.err != nil {
		return "", f.err
	}
	return f.reply, nil
}

func TestReviewNotesParsesJSON(t *testing.T) {
	reply := `{"issues":[{"type":"typo","location":"第 3 行","original":"因该","suggestion":"应该","reason":"错别字"},{"type":"broken_link","location":"第 8 行","original":"[[missing.org]]","suggestion":"修正链接目标","reason":"目标文件不存在"}],"summary":"发现 2 个问题"}`

	client := &reviewFakeClient{reply: reply}
	report, err := ReviewNotes(context.Background(), client, "* 标题\n因该这样做")
	if err != nil {
		t.Fatalf("ReviewNotes 返回错误: %v", err)
	}
	if len(report.Issues) != 2 {
		t.Fatalf("issues 数量 = %d, 期望 2", len(report.Issues))
	}
	first := report.Issues[0]
	if first.Type != "typo" || first.Location != "第 3 行" || first.Original != "因该" ||
		first.Suggestion != "应该" || first.Reason != "错别字" {
		t.Errorf("首个 issue = %+v, 与预期不符", first)
	}
	if report.Issues[1].Type != "broken_link" {
		t.Errorf("第二个 issue 类型 = %q, 期望 broken_link", report.Issues[1].Type)
	}
	if report.Summary != "发现 2 个问题" {
		t.Errorf("summary = %q, 期望 发现 2 个问题", report.Summary)
	}
}

func TestReviewNotesStripsCodeFence(t *testing.T) {
	reply := "```json\n{\"issues\":[{\"type\":\"citation\",\"location\":\"参考文献\",\"original\":\"[1]\",\"suggestion\":\"[2]\",\"reason\":\"编号不一致\"}],\"summary\":\"1 个问题\"}\n```"

	client := &reviewFakeClient{reply: reply}
	report, err := ReviewNotes(context.Background(), client, "文本 [1]")
	if err != nil {
		t.Fatalf("ReviewNotes 返回错误: %v", err)
	}
	if len(report.Issues) != 1 {
		t.Fatalf("issues 数量 = %d, 期望 1", len(report.Issues))
	}
	if report.Issues[0].Type != "citation" {
		t.Errorf("issue 类型 = %q, 期望 citation", report.Issues[0].Type)
	}
	if report.Summary != "1 个问题" {
		t.Errorf("summary = %q, 期望 1 个问题", report.Summary)
	}
}

func TestReviewNotesTolerantFenceWithLeadingText(t *testing.T) {
	reply := "好的，以下是审查结果：\n```\n{\"issues\":[],\"summary\":\"未发现问题\"}\n```\n希望有帮助。"

	client := &reviewFakeClient{reply: reply}
	report, err := ReviewNotes(context.Background(), client, "干净的笔记")
	if err != nil {
		t.Fatalf("ReviewNotes 返回错误: %v", err)
	}
	if len(report.Issues) != 0 {
		t.Errorf("issues 数量 = %d, 期望 0", len(report.Issues))
	}
	if report.Summary != "未发现问题" {
		t.Errorf("summary = %q, 期望 未发现问题", report.Summary)
	}
}

func TestReviewNotesInvalidJSON(t *testing.T) {
	client := &reviewFakeClient{reply: "这不是一个 JSON 对象"}
	_, err := ReviewNotes(context.Background(), client, "文本")
	if err == nil {
		t.Fatal("无效响应应返回错误，实际为 nil")
	}
}

func TestReviewNotesChatError(t *testing.T) {
	wantErr := errors.New("后端不可用")
	client := &reviewFakeClient{err: wantErr}
	_, err := ReviewNotes(context.Background(), client, "文本")
	if err == nil {
		t.Fatal("Chat 报错时应向上返回错误，实际为 nil")
	}
	if !errors.Is(err, wantErr) {
		t.Errorf("错误应包裹原始错误，实际: %v", err)
	}
}

func TestReviewNotesNilClient(t *testing.T) {
	if _, err := ReviewNotes(context.Background(), nil, "文本"); err == nil {
		t.Fatal("Client 为 nil 时应返回错误")
	}
}

func TestReviewNotesPromptContainsOrgText(t *testing.T) {
	const orgText = "* 我的标题\nhttps://example.invalid/失效\n段落内容"
	client := &reviewFakeClient{reply: `{"issues":[],"summary":"ok"}`}

	if _, err := ReviewNotes(context.Background(), client, orgText); err != nil {
		t.Fatalf("ReviewNotes 返回错误: %v", err)
	}

	if client.calls != 1 {
		t.Fatalf("Chat 调用次数 = %d, 期望 1", client.calls)
	}
	if len(client.messages) != 2 {
		t.Fatalf("消息数量 = %d, 期望 2", len(client.messages))
	}
	if client.messages[0].Role != RoleSystem {
		t.Errorf("首条消息角色 = %q, 期望 %q", client.messages[0].Role, RoleSystem)
	}
	if client.messages[1].Role != RoleUser {
		t.Errorf("次条消息角色 = %q, 期望 %q", client.messages[1].Role, RoleUser)
	}
	if client.messages[1].Content != orgText {
		t.Errorf("用户消息内容 = %q, 期望包含完整 org 文本 %q", client.messages[1].Content, orgText)
	}
	// 系统提示词应说明审查的三类问题与 JSON 输出要求。
	for _, want := range []string{"错别字", "失效链接", "引用不一致", "JSON"} {
		if !strings.Contains(client.messages[0].Content, want) {
			t.Errorf("系统提示词应包含 %q", want)
		}
	}
}
