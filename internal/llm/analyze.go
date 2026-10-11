package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// DocumentAnalysis 是对一篇文档进行解析分析后的结构化结果。
type DocumentAnalysis struct {
	// Title 是文档标题，无法判断时为空字符串。
	Title string `json:"title"`
	// Sections 是按文档结构划分的章节列表。
	Sections []Section `json:"sections"`
	// Terms 是文档中出现的关键术语。
	Terms []string `json:"terms"`
	// Entities 是文档中出现的命名实体（人名、机构、产品等）。
	Entities []string `json:"entities"`
}

// Section 是文档中的一个章节，包含标题与摘要。
type Section struct {
	// Heading 是章节标题。
	Heading string `json:"heading"`
	// Summary 是该章节的内容摘要。
	Summary string `json:"summary"`
}

// analyzeSystemPrompt 是文档解析分析使用的系统提示词。
// 明确要求 LLM 只输出 JSON，并给出字段结构与含义，减少自由发挥。
const analyzeSystemPrompt = `你是一个文档解析助手。请阅读用户提供的文档，并只输出一个 JSON 对象，不要输出任何解释、开场白或多余文本。

JSON 结构如下：
{
  "title": "文档标题",
  "sections": [
    {"heading": "章节标题", "summary": "该章节的摘要"}
  ],
  "terms": ["关键术语1", "关键术语2"],
  "entities": ["实体1", "实体2"]
}

字段说明：
- title：文档标题，无法判断时使用空字符串；
- sections：按文档结构划分的章节，每项包含章节标题与内容摘要；
- terms：文档中的关键术语列表；
- entities：文档中出现的实体列表（人名、机构、产品、地点等）。

请确保输出为合法 JSON。`

// AnalyzeDocument 调用 LLM 对文本进行解析分析，返回结构化的文档分析结果。
// c 为 nil 时直接返回错误；Chat 失败或返回内容无法解析为 JSON 时返回错误。
func AnalyzeDocument(ctx context.Context, c Client, text string) (*DocumentAnalysis, error) {
	if c == nil {
		return nil, fmt.Errorf("llm: 文档分析需要非 nil 的 Client")
	}

	content, err := c.Chat(ctx, []Message{
		{Role: RoleSystem, Content: analyzeSystemPrompt},
		{Role: RoleUser, Content: text},
	})
	if err != nil {
		return nil, fmt.Errorf("llm: 文档分析调用失败: %w", err)
	}

	return parseDocumentAnalysis(content)
}

// parseDocumentAnalysis 将 LLM 返回的内容解析为 DocumentAnalysis。
// 解析前会先剥离可能存在的 Markdown 代码围栏，以便容忍 ```json ... ``` 形式。
func parseDocumentAnalysis(content string) (*DocumentAnalysis, error) {
	cleaned := stripJSONFence(content)
	if cleaned == "" {
		return nil, fmt.Errorf("llm: 文档分析结果为空")
	}

	var analysis DocumentAnalysis
	if err := json.Unmarshal([]byte(cleaned), &analysis); err != nil {
		return nil, fmt.Errorf("llm: 文档分析结果 JSON 解析失败: %w", err)
	}
	return &analysis, nil
}

// stripJSONFence 去除内容首尾的 Markdown 代码围栏（```json ... ``` 或 ``` ... ```），
// 并去掉紧随起始围栏的语言标记（如 json）。无围栏时原样返回（去除首尾空白）。
func stripJSONFence(content string) string {
	s := strings.TrimSpace(content)
	if !strings.HasPrefix(s, "```") {
		return s
	}

	// 去掉起始围栏标记。
	s = strings.TrimPrefix(s, "```")
	// 去掉围栏后紧跟的语言标记（如 json），直到换行为止。
	if idx := strings.Index(s, "\n"); idx >= 0 {
		if lang := strings.TrimSpace(s[:idx]); lang == "" || strings.EqualFold(lang, "json") {
			s = s[idx+1:]
		}
	} else if len(s) >= 4 && strings.EqualFold(s[:4], "json") {
		// 单行形式 ```json{...}``` ：无换行可依，直接剥离语言标记。
		s = s[4:]
	}

	// 去掉结束围栏及其后内容。
	if idx := strings.LastIndex(s, "```"); idx >= 0 {
		s = s[:idx]
	}
	return strings.TrimSpace(s)
}
