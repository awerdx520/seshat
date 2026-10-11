package llm

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
)

// summarizeFakeClient 是 Client 的测试替身：返回预设回复或错误，并记录收到的消息。
type summarizeFakeClient struct {
	reply string
	err   error
	calls int
	last  []Message
}

func (f *summarizeFakeClient) Chat(_ context.Context, messages []Message) (string, error) {
	f.calls++
	f.last = messages
	if f.err != nil {
		return "", f.err
	}
	return f.reply, nil
}

// summarizeMessagesContent 拼接一次调用中所有消息的正文，便于断言提示词内容。
func summarizeMessagesContent(messages []Message) string {
	var b strings.Builder
	for _, m := range messages {
		b.WriteString(m.Content)
		b.WriteString("\n")
	}
	return b.String()
}

func TestSummarizeSingleDocument(t *testing.T) {
	fake := &summarizeFakeClient{reply: `{"text": "本文介绍 Go 并发模型", "tags": ["Go", "并发"]}`}

	got, err := Summarize(context.Background(), fake, "goroutine 是 Go 中的轻量级线程……")
	if err != nil {
		t.Fatalf("Summarize 返回错误: %v", err)
	}
	if got.Text != "本文介绍 Go 并发模型" {
		t.Errorf("Text = %q, 期望 %q", got.Text, "本文介绍 Go 并发模型")
	}
	if want := []string{"Go", "并发"}; !slices.Equal(got.Tags, want) {
		t.Errorf("Tags = %v, 期望 %v", got.Tags, want)
	}

	if fake.calls != 1 {
		t.Fatalf("Chat 调用次数 = %d, 期望 1", fake.calls)
	}
	if len(fake.last) != 2 || fake.last[0].Role != RoleSystem {
		t.Fatalf("消息结构 = %+v, 期望首条为 system 提示词", fake.last)
	}
	joined := summarizeMessagesContent(fake.last)
	if !strings.Contains(joined, "goroutine") {
		t.Errorf("提示词应携带原始文本，实际: %s", joined)
	}
	if !strings.Contains(joined, "tags") {
		t.Errorf("提示词应要求输出含 tags 的 JSON，实际: %s", joined)
	}
}

func TestSummarizeManyClusters(t *testing.T) {
	fake := &summarizeFakeClient{reply: `{"text": "三篇笔记围绕阅读、同步与 LLM 接入", "tags": ["阅读", "同步", "LLM"]}`}

	texts := []string{"第一篇：epub 阅读器设计", "第二篇：WebDAV 同步协议", "第三篇：LLM 接入层"}
	got, err := SummarizeMany(context.Background(), fake, texts)
	if err != nil {
		t.Fatalf("SummarizeMany 返回错误: %v", err)
	}
	if got.Text != "三篇笔记围绕阅读、同步与 LLM 接入" {
		t.Errorf("Text = %q", got.Text)
	}
	if want := []string{"阅读", "同步", "LLM"}; !slices.Equal(got.Tags, want) {
		t.Errorf("Tags = %v, 期望 %v", got.Tags, want)
	}

	if fake.calls != 1 {
		t.Fatalf("Chat 调用次数 = %d, 期望 1（多篇应合并为一次调用）", fake.calls)
	}
	joined := summarizeMessagesContent(fake.last)
	for _, want := range []string{"第一篇", "第二篇", "第三篇"} {
		if !strings.Contains(joined, want) {
			t.Errorf("合并提示词应包含 %q，实际: %s", want, joined)
		}
	}
}

func TestSummarizeManySkipsBlankTexts(t *testing.T) {
	fake := &summarizeFakeClient{reply: `{"text": "摘要", "tags": ["x"]}`}

	if _, err := SummarizeMany(context.Background(), fake, []string{"  ", "", "有效内容"}); err != nil {
		t.Fatalf("SummarizeMany 返回错误: %v", err)
	}
	joined := summarizeMessagesContent(fake.last)
	if !strings.Contains(joined, "有效内容") {
		t.Errorf("提示词应包含非空文本，实际: %s", joined)
	}
}

func TestSummarizeRejectsEmptyInput(t *testing.T) {
	fake := &summarizeFakeClient{reply: `{"text": "摘要", "tags": ["x"]}`}

	if _, err := Summarize(context.Background(), fake, "   \n\t "); err == nil {
		t.Error("空文本应返回错误")
	}
	if _, err := SummarizeMany(context.Background(), fake, []string{"", "  "}); err == nil {
		t.Error("全空笔记集应返回错误")
	}
	if fake.calls != 0 {
		t.Errorf("输入为空时不应调用后端，实际调用 %d 次", fake.calls)
	}
}

func TestSummarizeParseFailure(t *testing.T) {
	fake := &summarizeFakeClient{reply: "抱歉，我无法完成该任务。"}

	_, err := Summarize(context.Background(), fake, "一段文本")
	if err == nil {
		t.Fatal("非 JSON 回复应返回错误")
	}
	if !strings.Contains(err.Error(), "JSON") {
		t.Errorf("错误信息应说明 JSON 解析问题，实际: %v", err)
	}
}

func TestSummarizeStripsCodeFence(t *testing.T) {
	// 模型常把 JSON 包在 Markdown 代码围栏里，甚至加上前后说明文字。
	fake := &summarizeFakeClient{reply: "好的，结果如下：\n```json\n{\"text\": \"围栏中的摘要\", \"tags\": [\"a\", \"b\"]}\n```\n"}

	got, err := Summarize(context.Background(), fake, "一段文本")
	if err != nil {
		t.Fatalf("Summarize 返回错误: %v", err)
	}
	if got.Text != "围栏中的摘要" {
		t.Errorf("Text = %q, 期望 %q", got.Text, "围栏中的摘要")
	}
	if want := []string{"a", "b"}; !slices.Equal(got.Tags, want) {
		t.Errorf("Tags = %v, 期望 %v", got.Tags, want)
	}
}

func TestSummarizePropagatesClientError(t *testing.T) {
	wantErr := errors.New("后端不可用")
	fake := &summarizeFakeClient{err: wantErr}

	_, err := Summarize(context.Background(), fake, "一段文本")
	if !errors.Is(err, wantErr) {
		t.Errorf("err = %v, 期望包装 %v", err, wantErr)
	}
}
