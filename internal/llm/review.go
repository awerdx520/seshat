// 本文件实现「笔记审查」能力：把 Org 笔记交给 LLM，审查错别字、
// 失效链接、引用不一致等问题，并把 LLM 返回的 JSON 解析为结构化报告。
//
// 该能力仅依赖本包的 Client 接口（见 client.go），不关心具体后端是云端
// 还是本地节点，因此可复用于任意 Client 实现。
package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// ReviewIssue 表示审查中发现的一条问题。
type ReviewIssue struct {
	// Type 是问题类别，取值如 typo（错别字）、broken_link（失效链接）、citation（引用不一致）。
	Type string `json:"type"`
	// Location 是问题所在位置，如行号、段落标题或链接所在小节。
	Location string `json:"location"`
	// Original 是出问题的原始文本片段。
	Original string `json:"original"`
	// Suggestion 是建议的修正内容。
	Suggestion string `json:"suggestion"`
	// Reason 是给出该判定的理由。
	Reason string `json:"reason"`
}

// ReviewReport 是一次笔记审查的汇总结果。
type ReviewReport struct {
	// Issues 是审查发现的问题列表；未发现问题时为空切片。
	Issues []ReviewIssue `json:"issues"`
	// Summary 是对笔记整体质量的概述。
	Summary string `json:"summary"`
}

// reviewSystemPrompt 是审查任务使用的系统提示词，要求模型只输出 JSON。
const reviewSystemPrompt = `你是一名严谨的中文技术笔记审查助手。请审查用户提供的 Org 笔记，重点检查以下三类问题：
1. 错别字（typo）：明显的中文或英文拼写错误；
2. 失效链接（broken_link）：指向不存在的文件、页面或锚点的链接；
3. 引用不一致（citation）：引用编号、来源或术语前后不一致。

请只输出一个 JSON 对象，不要输出任何解释性文字或 Markdown 代码围栏。JSON 结构如下：
{
  "issues": [
    {
      "type": "typo|broken_link|citation",
      "location": "问题所在位置",
      "original": "原始文本片段",
      "suggestion": "修改建议",
      "reason": "判定理由"
    }
  ],
  "summary": "整体审查概述"
}
若未发现问题，issues 请返回空数组。`

// ReviewNotes 使用给定 Client 审查一段 Org 笔记，返回结构化的审查报告。
//
// 它会构造系统提示词并要求模型输出 JSON，随后解析回复；解析时会自动剥离
// 常见的 Markdown 代码围栏，并容忍 JSON 前后多余的说明文字。
// c 为 nil 时直接返回错误。
func ReviewNotes(ctx context.Context, c Client, orgText string) (*ReviewReport, error) {
	if c == nil {
		return nil, fmt.Errorf("llm: ReviewNotes 的 Client 为 nil")
	}

	messages := []Message{
		{Role: RoleSystem, Content: reviewSystemPrompt},
		{Role: RoleUser, Content: orgText},
	}

	raw, err := c.Chat(ctx, messages)
	if err != nil {
		return nil, fmt.Errorf("llm: 审查笔记失败: %w", err)
	}

	report, err := parseReviewReport(raw)
	if err != nil {
		return nil, fmt.Errorf("llm: 解析审查结果失败: %w", err)
	}
	return report, nil
}

// parseReviewReport 把模型回复解析为 ReviewReport。
// 先做容错预处理（剥离代码围栏、截取 JSON 对象），再反序列化。
func parseReviewReport(raw string) (*ReviewReport, error) {
	jsonText := extractReviewJSON(raw)
	if jsonText == "" {
		return nil, fmt.Errorf("响应中未找到 JSON 对象: %q", truncateReview(raw, 200))
	}

	var report ReviewReport
	if err := json.Unmarshal([]byte(jsonText), &report); err != nil {
		return nil, fmt.Errorf("JSON 反序列化失败: %w", err)
	}
	return &report, nil
}

// extractReviewJSON 从模型回复中提取 JSON 对象文本：
//  1. 去除首尾空白；
//  2. 若整体被 Markdown 代码围栏（```json ... ``` 或 ``` ... ```）包裹，剥离围栏；
//  3. 截取首个 '{' 到最后一个 '}' 之间的内容，容忍 JSON 前后的说明文字。
//
// 找不到 JSON 对象时返回空字符串。
func extractReviewJSON(raw string) string {
	s := strings.TrimSpace(raw)

	// 剥离 Markdown 代码围栏。
	if strings.HasPrefix(s, "```") {
		if i := strings.Index(s, "\n"); i >= 0 {
			s = s[i+1:]
		}
		if i := strings.LastIndex(s, "```"); i >= 0 {
			s = s[:i]
		}
		s = strings.TrimSpace(s)
	}

	// 截取首个 '{' 到最后一个 '}' 之间的内容。
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return ""
	}
	return strings.TrimSpace(s[start : end+1])
}

// truncateReview 把字符串截断到至多 n 个字节，便于在错误信息中显示响应摘要。
func truncateReview(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
