// 本文件实现「归纳总结」能力：把长文档或一组笔记交给 LLM，生成整体摘要
// 和用于聚类的主题标签，并把 LLM 返回的 JSON 解析为结构化结果。
//
// 该能力仅依赖本包的 Client 接口（见 client.go），不关心后端是云端还是
// 本地节点，因此可复用于任意 Client 实现。

package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Summary 是对一段或多段笔记内容做归纳总结后的结果。
type Summary struct {
	// Text 是整体摘要正文。
	Text string `json:"text"`
	// Tags 是用于聚类的主题标签，已去除首尾空白、丢弃空项并去重，保持模型给出的先后顺序。
	Tags []string `json:"tags"`
}

// summarySystemPrompt 是归纳总结使用的系统提示词。
// 明确要求只输出 JSON 并给出字段结构，以减少模型自由发挥、便于解析。
const summarySystemPrompt = `你是一个笔记归纳助手。请阅读用户提供的笔记内容，生成一段整体摘要和一组用于聚类的标签。

请只输出一个 JSON 对象，不要输出任何解释文字或 Markdown 代码围栏，结构如下：
{
  "text": "整体摘要正文",
  "tags": ["标签1", "标签2"]
}

字段说明：
- text：对笔记内容的整体概括，语言与原文一致；
- tags：3 到 8 个概括主题的关键词，用于把相关笔记聚为一类。

请确保输出为合法 JSON。`

// summaryNoteSeparator 是合并多篇笔记时插入的分隔线，用于向模型标示各篇边界。
const summaryNoteSeparator = "\n\n---\n\n"

// Summarize 对单篇长文档 / 笔记生成摘要与聚类标签。
//
// text 为空（或仅含空白）时直接返回错误，不调用后端；c 为 nil 时返回错误；
// Chat 失败或回复无法解析为预期 JSON 时返回错误。
func Summarize(ctx context.Context, c Client, text string) (*Summary, error) {
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("llm: 待归纳的文本为空")
	}
	return summarizeWithPrompt(ctx, c, text)
}

// SummarizeMany 对多篇笔记组成的集合生成整体摘要与聚类标签。
//
// 各篇以分隔线拼接后一次性提交，便于模型做跨篇聚类；空（或仅含空白）的
// 文本项会被跳过，全部为空时返回错误；c 为 nil 时返回错误。
func SummarizeMany(ctx context.Context, c Client, texts []string) (*Summary, error) {
	parts := make([]string, 0, len(texts))
	for _, text := range texts {
		if strings.TrimSpace(text) == "" {
			continue
		}
		parts = append(parts, text)
	}
	if len(parts) == 0 {
		return nil, fmt.Errorf("llm: 待归纳的笔记集为空")
	}
	return summarizeWithPrompt(ctx, c, strings.Join(parts, summaryNoteSeparator))
}

// summarizeWithPrompt 构造归纳提示词、调用客户端并解析返回的 JSON。
func summarizeWithPrompt(ctx context.Context, c Client, content string) (*Summary, error) {
	if c == nil {
		return nil, fmt.Errorf("llm: 归纳总结的 Client 为 nil")
	}

	reply, err := c.Chat(ctx, []Message{
		{Role: RoleSystem, Content: summarySystemPrompt},
		{Role: RoleUser, Content: content},
	})
	if err != nil {
		return nil, fmt.Errorf("llm: 归纳总结调用失败: %w", err)
	}
	return parseSummary(reply)
}

// parseSummary 把模型回复解析为 Summary。
//
// 模型常把 JSON 包在 Markdown 代码围栏中或在前后附加说明文字，因此解析前
// 先剥离围栏，再截取首个 '{' 到最后一个 '}' 之间的对象文本。
func parseSummary(reply string) (*Summary, error) {
	jsonText := extractSummaryJSON(stripSummaryFence(reply))
	if jsonText == "" {
		// 复用 cloud.go 的 summarize 生成单行摘要，避免把整段回复塞进错误信息。
		return nil, fmt.Errorf("llm: 回复不含 JSON 对象: %s", summarize([]byte(reply)))
	}

	var summary Summary
	if err := json.Unmarshal([]byte(jsonText), &summary); err != nil {
		return nil, fmt.Errorf("llm: 解析摘要 JSON 失败: %w", err)
	}

	summary.Text = strings.TrimSpace(summary.Text)
	if summary.Text == "" {
		return nil, fmt.Errorf("llm: 摘要 JSON 缺少 text 字段")
	}
	summary.Tags = normalizeSummaryTags(summary.Tags)
	return &summary, nil
}

// stripSummaryFence 去除内容首尾的 Markdown 代码围栏（```json ... ``` 或 ``` ... ```），
// 并去掉紧随起始围栏的语言标记（如 json）。无围栏时原样返回（已去首尾空白）。
func stripSummaryFence(content string) string {
	s := strings.TrimSpace(content)
	if !strings.HasPrefix(s, "```") {
		return s
	}

	// 去掉起始围栏标记。
	s = strings.TrimPrefix(s, "```")
	if idx := strings.Index(s, "\n"); idx >= 0 {
		// 首个换行前是语言标记（可能为空），一并去掉。
		s = s[idx+1:]
	} else if len(s) >= 4 && strings.EqualFold(s[:4], "json") {
		// 单行形式 ```json{...}```：没有换行可依，直接剥离语言标记。
		s = s[4:]
	}

	// 去掉结束围栏及其后内容。
	if idx := strings.LastIndex(s, "```"); idx >= 0 {
		s = s[:idx]
	}
	return strings.TrimSpace(s)
}

// extractSummaryJSON 截取首个 '{' 到最后一个 '}' 之间的内容，容忍 JSON 前后的说明文字。
// 找不到成对的花括号时返回空字符串。
func extractSummaryJSON(content string) string {
	start := strings.Index(content, "{")
	end := strings.LastIndex(content, "}")
	if start < 0 || end < start {
		return ""
	}
	return strings.TrimSpace(content[start : end+1])
}

// normalizeSummaryTags 清理标签：去除首尾空白、丢弃空项、按首次出现顺序去重。
func normalizeSummaryTags(tags []string) []string {
	if len(tags) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(tags))
	out := make([]string, 0, len(tags))
	for _, tag := range tags {
		tag = strings.TrimSpace(tag)
		if tag == "" {
			continue
		}
		if _, ok := seen[tag]; ok {
			continue
		}
		seen[tag] = struct{}{}
		out = append(out, tag)
	}
	return out
}
