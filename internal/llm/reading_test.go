package llm

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// fakeReadingClient 是阅读分析测试用的假 Client：
// 记录收到的消息，并按预设内容/错误返回，无需真实网络请求。
type fakeReadingClient struct {
	resp string
	err  error
	got  []Message
}

func (f *fakeReadingClient) Chat(_ context.Context, messages []Message) (string, error) {
	f.got = messages
	return f.resp, f.err
}

// userPrompt 返回假客户端收到的最后一条 user 消息内容，便于断言 prompt 构造。
func (f *fakeReadingClient) userPrompt() string {
	for i := len(f.got) - 1; i >= 0; i-- {
		if f.got[i].Role == RoleUser {
			return f.got[i].Content
		}
	}
	return ""
}

func TestAnalyzeReadingSuccess(t *testing.T) {
	tests := []struct {
		name string
		resp string
	}{
		{
			name: "裸 JSON",
			resp: `{"profile":"深度阅读者","suggestions":["保持每日阅读","多做批注"]}`,
		},
		{
			name: "Markdown 代码围栏包裹",
			resp: "```json\n{\"profile\":\"深度阅读者\",\"suggestions\":[\"保持每日阅读\",\"多做批注\"]}\n```",
		},
		{
			name: "前后夹杂解释文字",
			resp: "好的，以下是分析结果：\n{\"profile\":\"深度阅读者\",\"suggestions\":[\"保持每日阅读\",\"多做批注\"]}\n希望有帮助。",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := &fakeReadingClient{resp: tt.resp}
			in := ReadingInput{
				ProgressCount:     5,
				AnnotationCount:   12,
				RecentAnnotations: []string{"重点概念A", "疑问B"},
				CompletedDocs:     3,
			}

			got, err := AnalyzeReading(context.Background(), client, in)
			if err != nil {
				t.Fatalf("AnalyzeReading 返回错误: %v", err)
			}
			if got == nil {
				t.Fatal("返回值不应为 nil")
			}
			if got.Profile != "深度阅读者" {
				t.Errorf("Profile = %q, 期望 %q", got.Profile, "深度阅读者")
			}
			want := []string{"保持每日阅读", "多做批注"}
			if len(got.Suggestions) != len(want) {
				t.Fatalf("Suggestions 数量 = %d, 期望 %d", len(got.Suggestions), len(want))
			}
			for i := range want {
				if got.Suggestions[i] != want[i] {
					t.Errorf("Suggestions[%d] = %q, 期望 %q", i, got.Suggestions[i], want[i])
				}
			}
		})
	}
}

func TestAnalyzeReadingEmptyInput(t *testing.T) {
	client := &fakeReadingClient{resp: `{"profile":"新读者","suggestions":["从一篇短文开始"]}`}

	got, err := AnalyzeReading(context.Background(), client, ReadingInput{})
	if err != nil {
		t.Fatalf("空输入不应返回错误: %v", err)
	}
	if got == nil || got.Profile != "新读者" {
		t.Fatalf("空输入解析结果异常: %+v", got)
	}

	// 空输入仍应构造出可用的 prompt，并明确提示暂无数据。
	if len(client.got) == 0 {
		t.Fatal("空输入也应调用 LLM 构造 prompt")
	}
	if p := client.userPrompt(); !strings.Contains(p, "暂无") {
		t.Errorf("空输入 prompt 应提示暂无数据，实际: %q", p)
	}
}

func TestAnalyzeReadingPromptContainsAnnotations(t *testing.T) {
	client := &fakeReadingClient{resp: `{"profile":"x","suggestions":[]}`}

	in := ReadingInput{
		ProgressCount:     2,
		AnnotationCount:   4,
		RecentAnnotations: []string{"批注片段一号", "批注片段二号"},
		CompletedDocs:     1,
	}
	if _, err := AnalyzeReading(context.Background(), client, in); err != nil {
		t.Fatalf("AnalyzeReading 返回错误: %v", err)
	}

	prompt := client.userPrompt()
	for _, fragment := range in.RecentAnnotations {
		if !strings.Contains(prompt, fragment) {
			t.Errorf("prompt 应包含批注片段 %q，实际: %q", fragment, prompt)
		}
	}
	if !strings.Contains(prompt, "4") || !strings.Contains(prompt, "2") {
		t.Errorf("prompt 应包含批注数 4 与进度数 2，实际: %q", prompt)
	}
}

func TestAnalyzeReadingParseFailure(t *testing.T) {
	tests := []struct {
		name string
		resp string
	}{
		{name: "非 JSON 文本", resp: "抱歉，我无法分析。"},
		{name: "空回复", resp: ""},
		{name: "非法 JSON", resp: `{"profile": }`},
		{name: "缺少花括号", resp: `"profile":"x"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := &fakeReadingClient{resp: tt.resp}
			got, err := AnalyzeReading(context.Background(), client, ReadingInput{ProgressCount: 1})
			if err == nil {
				t.Fatalf("期望解析失败返回错误，实际 got=%+v", got)
			}
		})
	}
}

func TestAnalyzeReadingPropagatesClientError(t *testing.T) {
	wantErr := errors.New("后端不可用")
	client := &fakeReadingClient{err: wantErr}

	_, err := AnalyzeReading(context.Background(), client, ReadingInput{ProgressCount: 1})
	if err == nil {
		t.Fatal("客户端错误应被传播")
	}
	if !errors.Is(err, wantErr) {
		t.Errorf("错误应包装原始错误，实际: %v", err)
	}
}
