package llm

import (
	"context"
	"errors"
	"math"
	"strings"
	"testing"
	"time"
)

// approxEqual 比较浮点数，容忍 SM-2 中的舍入误差。
func approxEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-9
}

// —— SM2Next ——

func TestSM2NextNewCard(t *testing.T) {
	before := time.Now()
	got := SM2Next(nil, 5)

	if got.Repetitions != 1 {
		t.Errorf("新卡片首次答对后 Repetitions = %d, 期望 1", got.Repetitions)
	}
	if !approxEqual(got.EaseFactor, 2.6) {
		t.Errorf("quality=5 时 EaseFactor = %v, 期望 2.6", got.EaseFactor)
	}
	if got.IntervalDays != 1 {
		t.Errorf("首次间隔 = %d, 期望 1", got.IntervalDays)
	}
	scheduleAssertDueAtNear(t, got.DueAt, before.AddDate(0, 0, 1))
}

func TestSM2NextSecondReview(t *testing.T) {
	state := &SM2State{Repetitions: 1, EaseFactor: 2.6, IntervalDays: 1}
	got := SM2Next(state, 5)

	if got.Repetitions != 2 {
		t.Errorf("二次复习后 Repetitions = %d, 期望 2", got.Repetitions)
	}
	if got.IntervalDays != 6 {
		t.Errorf("二次间隔 = %d, 期望 6", got.IntervalDays)
	}
	if !approxEqual(got.EaseFactor, 2.7) {
		t.Errorf("二次复习后 EaseFactor = %v, 期望 2.7", got.EaseFactor)
	}
}

func TestSM2NextSubsequentUsesEaseFactor(t *testing.T) {
	state := &SM2State{Repetitions: 2, EaseFactor: 2.5, IntervalDays: 6}
	got := SM2Next(state, 5)

	if got.Repetitions != 3 {
		t.Errorf("Repetitions = %d, 期望 3", got.Repetitions)
	}
	if !approxEqual(got.EaseFactor, 2.6) {
		t.Fatalf("EaseFactor = %v, 期望 2.6", got.EaseFactor)
	}
	// interval = round(6 * 2.6) = round(15.6) = 16
	if got.IntervalDays != 16 {
		t.Errorf("后续间隔 = %d, 期望 16 (round(6*2.6))", got.IntervalDays)
	}
}

func TestSM2NextFailureResetsProgress(t *testing.T) {
	state := &SM2State{Repetitions: 4, EaseFactor: 2.6, IntervalDays: 30}
	got := SM2Next(state, 2)

	if got.Repetitions != 0 {
		t.Errorf("遗忘后 Repetitions = %d, 期望 0", got.Repetitions)
	}
	if got.IntervalDays != 1 {
		t.Errorf("遗忘后间隔 = %d, 期望 1", got.IntervalDays)
	}
	// EF = 2.6 + (0.1 - 3*(0.08+3*0.02)) = 2.6 - 0.32 = 2.28
	if !approxEqual(got.EaseFactor, 2.28) {
		t.Errorf("遗忘后 EaseFactor = %v, 期望 2.28", got.EaseFactor)
	}
}

func TestSM2NextEaseFactorFloor(t *testing.T) {
	state := &SM2State{Repetitions: 1, EaseFactor: 1.3, IntervalDays: 6}
	got := SM2Next(state, 0)

	if !approxEqual(got.EaseFactor, 1.3) {
		t.Errorf("EF 下限失效：EaseFactor = %v, 期望 1.3", got.EaseFactor)
	}
	if got.Repetitions != 0 || got.IntervalDays != 1 {
		t.Errorf("评分 0 应重置进度，实际 Rep=%d Interval=%d", got.Repetitions, got.IntervalDays)
	}
}

func TestSM2NextQualityFourKeepsEaseFactor(t *testing.T) {
	// q=4 时 EF 修正项恰为 0，易度因子保持不变。
	got := SM2Next(nil, 4)
	if !approxEqual(got.EaseFactor, 2.5) {
		t.Errorf("quality=4 时 EaseFactor = %v, 期望 2.5", got.EaseFactor)
	}
}

func TestSM2NextUsesDefaultEaseFactorForZeroState(t *testing.T) {
	state := &SM2State{} // EF 为零值，应回退到默认 2.5
	got := SM2Next(state, 5)
	if !approxEqual(got.EaseFactor, 2.6) {
		t.Errorf("零值 EF 未回退默认值：EaseFactor = %v, 期望 2.6", got.EaseFactor)
	}
}

func TestSM2NextClampsQuality(t *testing.T) {
	high := SM2Next(nil, 9)
	if high.Repetitions != 1 || !approxEqual(high.EaseFactor, 2.6) {
		t.Errorf("越界高分未夹到 5：%+v", high)
	}
	low := SM2Next(&SM2State{Repetitions: 2, EaseFactor: 2.5, IntervalDays: 6}, -3)
	if low.Repetitions != 0 || low.IntervalDays != 1 {
		t.Errorf("越界低分未夹到 0：%+v", low)
	}
}

func TestSM2NextDoesNotMutateInput(t *testing.T) {
	state := &SM2State{Repetitions: 2, EaseFactor: 2.5, IntervalDays: 6, DueAt: time.Unix(0, 0)}
	snapshot := *state

	_ = SM2Next(state, 5)

	if *state != snapshot {
		t.Errorf("SM2Next 修改了入参：%+v，期望 %+v", *state, snapshot)
	}
}

func TestSM2NextDueAtMatchesInterval(t *testing.T) {
	// 用可注入时钟的 sm2NextAt 做确定性断言。
	now := time.Date(2026, 3, 15, 8, 30, 0, 0, time.UTC)
	got := sm2NextAt(&SM2State{Repetitions: 2, EaseFactor: 2.5, IntervalDays: 6}, 5, now)

	want := now.AddDate(0, 0, 16) // round(6*2.6) = 16 天
	if !got.DueAt.Equal(want) {
		t.Errorf("DueAt = %v, 期望 %v", got.DueAt, want)
	}

	// 公开入口 SM2Next 走真实时钟，允许分钟级偏差。
	before := time.Now()
	live := SM2Next(nil, 5)
	scheduleAssertDueAtNear(t, live.DueAt, before.AddDate(0, 0, live.IntervalDays))
}

// scheduleAssertDueAtNear 断言 got 与 want 相差不超过 1 分钟（公开入口内部使用 time.Now()）。
func scheduleAssertDueAtNear(t *testing.T, got, want time.Time) {
	t.Helper()
	if d := got.Sub(want); d < -time.Minute || d > time.Minute {
		t.Errorf("DueAt = %v, 期望约 %v（偏差 %v）", got, want, d)
	}
}

// —— SM2Due ——

func TestSM2Due(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name  string
		state SM2State
		want  bool
	}{
		{"到期时间已过", SM2State{DueAt: now.Add(-time.Hour)}, true},
		{"恰好到期", SM2State{DueAt: now}, true},
		{"尚未到期", SM2State{DueAt: now.Add(time.Hour)}, false},
		{"零值视为到期", SM2State{}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := SM2Due(tc.state, now); got != tc.want {
				t.Errorf("SM2Due = %v, 期望 %v", got, tc.want)
			}
		})
	}
}

// —— GenerateCards ——

// scheduleFakeClient 是 Client 的测试替身，记录收到的消息并返回预设回复。
type scheduleFakeClient struct {
	reply string
	err   error

	called   bool
	messages []Message
}

func (f *scheduleFakeClient) Chat(_ context.Context, messages []Message) (string, error) {
	f.called = true
	f.messages = messages
	return f.reply, f.err
}

func TestGenerateCardsParsesPlainJSON(t *testing.T) {
	client := &scheduleFakeClient{reply: `[{"question":"Q1","answer":"A1"},{"question":"Q2","answer":"A2"}]`}

	cards, err := GenerateCards(context.Background(), client, "笔记正文")
	if err != nil {
		t.Fatalf("GenerateCards 返回错误: %v", err)
	}
	if len(cards) != 2 {
		t.Fatalf("卡片数量 = %d, 期望 2", len(cards))
	}
	if cards[0].Question != "Q1" || cards[0].Answer != "A1" {
		t.Errorf("首张卡片 = %+v, 期望 Q1/A1", cards[0])
	}

	if len(client.messages) != 2 {
		t.Fatalf("发送消息数 = %d, 期望 2", len(client.messages))
	}
	if client.messages[0].Role != RoleSystem {
		t.Errorf("首条消息角色 = %q, 期望 system", client.messages[0].Role)
	}
	if client.messages[1].Role != RoleUser || client.messages[1].Content != "笔记正文" {
		t.Errorf("次条消息 = %+v, 期望 user/笔记正文", client.messages[1])
	}
}

func TestGenerateCardsStripsCodeFence(t *testing.T) {
	client := &scheduleFakeClient{reply: "```json\n[{\"question\":\"Q\",\"answer\":\"A\"}]\n```"}

	cards, err := GenerateCards(context.Background(), client, "正文")
	if err != nil {
		t.Fatalf("带围栏的回复解析失败: %v", err)
	}
	if len(cards) != 1 || cards[0].Question != "Q" {
		t.Errorf("卡片 = %+v, 期望单张 Q", cards)
	}
}

func TestGenerateCardsStripsBareFenceAndProse(t *testing.T) {
	reply := "这是你的复习卡片：\n```\n[{\"question\":\"Q\",\"answer\":\"A\"}]\n```\n希望对你有帮助。"
	client := &scheduleFakeClient{reply: reply}

	cards, err := GenerateCards(context.Background(), client, "正文")
	if err != nil {
		t.Fatalf("围栏夹带说明文字时解析失败: %v", err)
	}
	if len(cards) != 1 || cards[0].Answer != "A" {
		t.Errorf("卡片 = %+v, 期望单张 A", cards)
	}
}

func TestGenerateCardsSkipsEmptyFields(t *testing.T) {
	client := &scheduleFakeClient{reply: `[{"question":"","answer":"A"},{"question":"Q","answer":"A"}]`}

	cards, err := GenerateCards(context.Background(), client, "正文")
	if err != nil {
		t.Fatalf("GenerateCards 返回错误: %v", err)
	}
	if len(cards) != 1 {
		t.Fatalf("卡片数量 = %d, 期望 1（空字段应被丢弃）", len(cards))
	}
	if cards[0].Question != "Q" {
		t.Errorf("保留的卡片 = %+v, 期望 Q", cards[0])
	}
}

func TestGenerateCardsInvalidJSON(t *testing.T) {
	client := &scheduleFakeClient{reply: "[{question: Q1]"}

	_, err := GenerateCards(context.Background(), client, "正文")
	if err == nil {
		t.Fatal("非法 JSON 应返回错误")
	}
	if !strings.Contains(err.Error(), "解析") {
		t.Errorf("错误信息应说明解析失败，实际: %v", err)
	}
}

func TestGenerateCardsNoJSON(t *testing.T) {
	client := &scheduleFakeClient{reply: "抱歉，我无法处理这个请求。"}

	if _, err := GenerateCards(context.Background(), client, "正文"); err == nil {
		t.Fatal("回复不含 JSON 时应返回错误")
	}
}

func TestGenerateCardsEmptyArray(t *testing.T) {
	client := &scheduleFakeClient{reply: "[]"}

	if _, err := GenerateCards(context.Background(), client, "正文"); err == nil {
		t.Fatal("空卡片数组应返回错误")
	}
}

func TestGenerateCardsRejectsEmptyInput(t *testing.T) {
	client := &scheduleFakeClient{reply: "[]"}

	if _, err := GenerateCards(context.Background(), client, "   \n\t "); err == nil {
		t.Fatal("空白正文应返回错误")
	}
	if client.called {
		t.Error("正文非法时不应调用 LLM")
	}
}

func TestGenerateCardsRejectsNilClient(t *testing.T) {
	if _, err := GenerateCards(context.Background(), nil, "正文"); err == nil {
		t.Fatal("nil Client 应返回错误")
	}
}

func TestGenerateCardsPropagatesClientError(t *testing.T) {
	sentinel := errors.New("后端不可用")
	client := &scheduleFakeClient{err: sentinel}

	_, err := GenerateCards(context.Background(), client, "正文")
	if err == nil {
		t.Fatal("客户端错误应向上传播")
	}
	if !errors.Is(err, sentinel) {
		t.Errorf("错误未包装原始错误: %v", err)
	}
}
