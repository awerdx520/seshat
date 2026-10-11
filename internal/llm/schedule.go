package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
)

// 本文件实现「遗忘性复习」的两个部分：
//   - SM-2 间隔重复算法（纯逻辑，不依赖 LLM，见 SM2State / SM2Next / SM2Due）；
//   - 由 LLM 从笔记正文生成问答式复习卡片（见 ReviewCard / GenerateCards）。
//
// 两者相互独立：算法只维护调度状态，卡片生成只负责内容提炼。
// 文件内所有辅助符号均带 sm2/card 前缀，避免与同包其他 LLM 任务产生命名冲突。

// —— SM-2 间隔重复算法 ——

// SM2State 是一张复习卡片的调度状态，由 SM-2 算法自身维护，不含卡片内容。
// 字段含义遵循 SuperMemo SM-2 的原始定义。
type SM2State struct {
	// Repetitions 是连续答对的次数：quality >= 3 时累加，quality < 3 时归零。
	Repetitions int
	// EaseFactor 是易度因子，新卡片建议初始值 2.5，下限 1.3。
	EaseFactor float64
	// IntervalDays 是当前复习间隔（天）。
	IntervalDays int
	// DueAt 是下次到期时间；零值表示尚未安排（视为已到期）。
	DueAt time.Time
}

// SM-2 算法常量。
const (
	// sm2MinQuality / sm2MaxQuality 是评分 quality 的合法区间（含端点）。
	sm2MinQuality = 0
	sm2MaxQuality = 5
	// sm2PassQuality 是判定「答对」的最低评分，低于它的评分视为遗忘。
	sm2PassQuality = 3
	// sm2DefaultEaseFactor 是新卡片的默认易度因子。
	sm2DefaultEaseFactor = 2.5
	// sm2MinEaseFactor 是易度因子下限，防止间隔被压缩得过短。
	sm2MinEaseFactor = 1.3
)

// SM2Next 依据本次评分 quality（0-5）计算并返回下一个调度状态。
//
// 参数 state 为当前状态，nil 或零值时按新卡片处理；该入参不会被修改，
// 返回值是新的状态对象。DueAt 基于当前时间计算为 interval 个日历天之后。
//
// 算法规则：
//   - 易度因子每次评分都会更新：EF' = EF + (0.1 - (5-q)*(0.08 + (5-q)*0.02))，
//     并夹在 [1.3, +∞)。
//   - quality < 3：视为遗忘，重复次数归零，间隔重置为 1 天。
//   - quality >= 3：重复次数累加；首次间隔 1 天，第二次 6 天，
//     其后为 round(上次间隔 × 新 EF)。
//
// quality 会被夹到 [0, 5]，越界输入不会破坏 EF 的稳定性。
func SM2Next(state *SM2State, quality int) *SM2State {
	return sm2NextAt(state, quality, time.Now())
}

// sm2NextAt 是 SM2Next 的可注入时钟版本，便于确定性测试。
func sm2NextAt(state *SM2State, quality int, now time.Time) *SM2State {
	quality = sm2ClampQuality(quality)

	ef := sm2DefaultEaseFactor
	repetitions := 0
	interval := 0
	if state != nil {
		ef = state.EaseFactor
		repetitions = state.Repetitions
		interval = state.IntervalDays
	}
	if ef <= 0 {
		// 零值 / 非法 EF 视为新卡片默认值。
		ef = sm2DefaultEaseFactor
	}

	// 无论评分高低都更新易度因子（SM-2 原始定义）。
	delta := float64(5 - quality)
	ef += 0.1 - delta*(0.08+delta*0.02)
	if ef < sm2MinEaseFactor {
		ef = sm2MinEaseFactor
	}

	if quality < sm2PassQuality {
		// 遗忘：重置进度，次日再复习。
		repetitions = 0
		interval = 1
	} else {
		repetitions++
		switch {
		case repetitions == 1:
			interval = 1
		case repetitions == 2:
			interval = 6
		default:
			interval = int(math.Round(float64(interval) * ef))
			if interval < 1 {
				interval = 1
			}
		}
	}

	return &SM2State{
		Repetitions:  repetitions,
		EaseFactor:   ef,
		IntervalDays: interval,
		DueAt:        now.AddDate(0, 0, interval),
	}
}

// SM2Due 判断卡片在 now 时刻是否已到期。
// DueAt 为零值（从未安排复习）时同样返回 true。
func SM2Due(state SM2State, now time.Time) bool {
	return !now.Before(state.DueAt)
}

// sm2ClampQuality 将 quality 夹到合法区间 [0, 5]。
func sm2ClampQuality(quality int) int {
	if quality < sm2MinQuality {
		return sm2MinQuality
	}
	if quality > sm2MaxQuality {
		return sm2MaxQuality
	}
	return quality
}

// —— LLM 复习卡片生成 ——

// ReviewCard 是一张复习卡片，仅包含问答两面。
type ReviewCard struct {
	// Question 是问题面。
	Question string `json:"question"`
	// Answer 是答案面。
	Answer string `json:"answer"`
}

// cardSystemPrompt 是指示模型输出复习卡片的系统提示词。
const cardSystemPrompt = `你是复习卡片生成助手。请从用户提供的笔记正文中提炼若干问答式复习卡片，` +
	`覆盖其中的关键概念、定义与事实。只输出 JSON 数组，元素形如 ` +
	`[{"question":"问题","answer":"答案"}]，不要输出任何解释文字或 Markdown 代码围栏。`

// GenerateCards 调用 LLM 从笔记正文 text 生成复习卡片。
//
// 提示词要求模型返回 JSON 数组 [{question, answer}]；实际回复允许被 Markdown
// 代码围栏包裹或夹带少量解释文字，解析时会自动剥离。解析后丢弃 question 或
// answer 为空的条目；若无任何有效卡片则返回错误。
//
// c 为 nil、text 为空白、或模型回复不可解析时均返回错误。
func GenerateCards(ctx context.Context, c Client, text string) ([]ReviewCard, error) {
	if c == nil {
		return nil, fmt.Errorf("llm: 生成复习卡片需要非空 Client")
	}
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("llm: 生成复习卡片需要非空笔记正文")
	}

	reply, err := c.Chat(ctx, []Message{
		{Role: RoleSystem, Content: cardSystemPrompt},
		{Role: RoleUser, Content: text},
	})
	if err != nil {
		return nil, fmt.Errorf("llm: 生成复习卡片失败: %w", err)
	}
	return parseCards(reply)
}

// parseCards 解析模型回复为复习卡片列表。
func parseCards(reply string) ([]ReviewCard, error) {
	payload := extractCardsJSON(stripCardFence(reply))
	if payload == "" {
		return nil, fmt.Errorf("llm: 复习卡片响应不含 JSON: %s", summarize([]byte(reply)))
	}

	var items []ReviewCard
	if err := json.Unmarshal([]byte(payload), &items); err != nil {
		return nil, fmt.Errorf("llm: 解析复习卡片 JSON 失败: %w", err)
	}

	cards := make([]ReviewCard, 0, len(items))
	for _, it := range items {
		q := strings.TrimSpace(it.Question)
		a := strings.TrimSpace(it.Answer)
		if q == "" || a == "" {
			continue
		}
		cards = append(cards, ReviewCard{Question: q, Answer: a})
	}
	if len(cards) == 0 {
		return nil, fmt.Errorf("llm: 未生成有效复习卡片: %s", summarize([]byte(reply)))
	}
	return cards, nil
}

// cardFenceOpenRe / cardFenceCloseRe 匹配 Markdown 代码围栏的首尾标记（含可选语言标注）。
var (
	cardFenceOpenRe  = regexp.MustCompile("^```[a-zA-Z0-9_-]*[ \t]*\r?\n?")
	cardFenceCloseRe = regexp.MustCompile("\r?\n?[ \t]*```[ \t]*$")
)

// stripCardFence 去掉回复外层可能存在的 Markdown ``` 代码围栏。
// 无围栏时仅去除首尾空白后原样返回。
func stripCardFence(reply string) string {
	t := strings.TrimSpace(reply)
	if !strings.HasPrefix(t, "```") {
		return t
	}
	t = cardFenceOpenRe.ReplaceAllString(t, "")
	t = cardFenceCloseRe.ReplaceAllString(t, "")
	return strings.TrimSpace(t)
}

// extractCardsJSON 从可能夹带解释文字的文本中截取最外层的 JSON 数组或对象。
// 找不到起始定界符时返回空串。
func extractCardsJSON(s string) string {
	t := strings.TrimSpace(s)
	start := strings.IndexAny(t, "[{")
	if start < 0 {
		return ""
	}
	closer := byte(']')
	if t[start] == '{' {
		closer = '}'
	}
	end := strings.LastIndexByte(t, closer)
	if end < start {
		return ""
	}
	return t[start : end+1]
}
