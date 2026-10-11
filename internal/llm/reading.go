// 本文件实现「阅读行为分析」能力：根据阅读统计数据（阅读进度数、批注数、
// 最近批注片段、已读完文档数）构造提示词，交给 LLM 生成阅读画像与改进建议，
// 并把返回的 JSON 解析为结构化结果。
//
// 与 analyze.go / review.go 一致，本能力只依赖本包的 Client 接口
// （见 client.go），不关心后端是云端还是本地节点，因此可复用于任意 Client 实现。
// 消息内容不经加密（无 E2EE）。
package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// ReadingInput 是阅读行为分析的输入统计，由调用方（如 API 层）从
// reading_progress / annotations 表中汇总后传入。
type ReadingInput struct {
	// ProgressCount 是有阅读进度的文档数。
	ProgressCount int
	// AnnotationCount 是批注总数。
	AnnotationCount int
	// RecentAnnotations 是最近的批注内容片段，按时间从新到旧排列。
	// 超出上限的条数会被截断，仅用于向 LLM 提供上下文。
	RecentAnnotations []string
	// CompletedDocs 是已读完的文档数。
	CompletedDocs int
}

// ReadingInsight 是阅读行为分析的结果。
type ReadingInsight struct {
	// Profile 是对该读者阅读习惯的一句话画像。
	Profile string `json:"profile"`
	// Suggestions 是改进阅读习惯的建议列表；无建议时为空切片。
	Suggestions []string `json:"suggestions"`
}

// readingSystemPrompt 是阅读行为分析使用的系统提示词。
// 明确要求 LLM 只输出 JSON，并给出字段结构，减少自由发挥。
const readingSystemPrompt = `你是一名阅读行为分析助手。请根据用户提供的阅读统计数据，生成一份简洁的阅读画像与改进建议。

请只输出一个 JSON 对象，不要输出任何解释、开场白或 Markdown 代码围栏。JSON 结构如下：
{
  "profile": "对该读者阅读习惯的一句话画像",
  "suggestions": ["改进建议1", "改进建议2"]
}

字段说明：
- profile：基于进度、批注与完成情况对该读者阅读习惯的概括；
- suggestions：2 到 4 条具体、可执行的改进建议；数据不足时给出入门建议。

请确保输出为合法 JSON。`

// maxRecentAnnotations 限制提示词中引用的最近批注条数，避免提示词过长。
const maxRecentAnnotations = 10

// maxAnnotationFragmentBytes 限制单条批注片段进入提示词的最大字节数。
const maxAnnotationFragmentBytes = 120

// maxReadingErrorBytes 限制错误信息中原始响应摘要的最大字节数。
const maxReadingErrorBytes = 200

// AnalyzeReading 调用 LLM 对阅读统计进行分析，返回结构化的阅读画像与建议。
//
// c 为 nil 时直接返回错误；Chat 失败或返回内容无法解析为 JSON 时返回错误。
// 当输入为空（无进度、无批注、无完成文档）时，仍会构造提示词并调用 LLM，
// 由模型给出入门建议。
func AnalyzeReading(ctx context.Context, c Client, in ReadingInput) (*ReadingInsight, error) {
	if c == nil {
		return nil, fmt.Errorf("llm: 阅读行为分析需要非 nil 的 Client")
	}

	content, err := c.Chat(ctx, []Message{
		{Role: RoleSystem, Content: readingSystemPrompt},
		{Role: RoleUser, Content: buildReadingPrompt(in)},
	})
	if err != nil {
		return nil, fmt.Errorf("llm: 阅读行为分析调用失败: %w", err)
	}

	return parseReadingInsight(content)
}

// buildReadingPrompt 根据阅读统计构造用户消息正文。
func buildReadingPrompt(in ReadingInput) string {
	var b strings.Builder
	b.WriteString("以下是一名读者的阅读统计数据：\n")
	fmt.Fprintf(&b, "- 有阅读进度的文档数：%d\n", in.ProgressCount)
	fmt.Fprintf(&b, "- 批注总数：%d\n", in.AnnotationCount)
	fmt.Fprintf(&b, "- 已读完的文档数：%d\n", in.CompletedDocs)
	b.WriteString("- 最近的批注片段：\n")

	if len(in.RecentAnnotations) == 0 {
		b.WriteString("  （暂无批注）\n")
	} else {
		limit := len(in.RecentAnnotations)
		if limit > maxRecentAnnotations {
			limit = maxRecentAnnotations
		}
		for i := 0; i < limit; i++ {
			fragment := truncateReading(in.RecentAnnotations[i], maxAnnotationFragmentBytes)
			fmt.Fprintf(&b, "  %d. %s\n", i+1, fragment)
		}
	}

	if isReadingInputEmpty(in) {
		b.WriteString("\n说明：该读者目前暂无阅读进度、批注或已读完的文档。\n")
	}

	b.WriteString("\n请依据以上数据生成阅读画像与改进建议。")
	return b.String()
}

// isReadingInputEmpty 判断输入是否为空（无任何阅读数据）。
func isReadingInputEmpty(in ReadingInput) bool {
	return in.ProgressCount == 0 &&
		in.AnnotationCount == 0 &&
		in.CompletedDocs == 0 &&
		len(in.RecentAnnotations) == 0
}

// parseReadingInsight 把模型回复解析为 ReadingInsight。
// 解析前先做容错预处理：剥离 Markdown 代码围栏、截取 JSON 对象，以容忍
// 模型在 JSON 前后附加说明文字。
func parseReadingInsight(raw string) (*ReadingInsight, error) {
	jsonText := extractReadingJSON(raw)
	if jsonText == "" {
		return nil, fmt.Errorf(
			"llm: 阅读分析响应中未找到 JSON 对象: %q",
			truncateReading(raw, maxReadingErrorBytes))
	}

	var insight ReadingInsight
	if err := json.Unmarshal([]byte(jsonText), &insight); err != nil {
		return nil, fmt.Errorf("llm: 阅读分析结果 JSON 解析失败: %w", err)
	}
	return &insight, nil
}

// extractReadingJSON 从模型回复中提取 JSON 对象文本：
//  1. 去除首尾空白；
//  2. 若整体被 Markdown 代码围栏（```json ... ``` 或 ``` ... ```）包裹，剥离围栏；
//  3. 截取首个 '{' 到最后一个 '}' 之间的内容，容忍 JSON 前后的说明文字。
//
// 找不到 JSON 对象时返回空字符串。
func extractReadingJSON(raw string) string {
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

// truncateReading 把字符串按字节截断到至多 n 字节，便于在提示词或错误信息中
// 展示摘要（按 UTF-8 字符边界截断，避免产生非法字节序列）。
func truncateReading(s string, n int) string {
	if len(s) <= n {
		return s
	}
	// 回退到最后一个完整 UTF-8 字符边界。
	cut := n
	for cut > 0 && !utf8StartOfRune(s[cut]) {
		cut--
	}
	return s[:cut] + "..."
}

// utf8StartOfRune 判断字节 b 是否是 UTF-8 字符的起始字节（非 10xxxxxx）。
func utf8StartOfRune(b byte) bool {
	return b&0xC0 != 0x80
}
