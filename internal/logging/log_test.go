package logging

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

func TestParseLevel(t *testing.T) {
	cases := []struct {
		in   string
		want slog.Level
	}{
		{"debug", slog.LevelDebug},
		{"DEBUG", slog.LevelDebug},
		{" Debug ", slog.LevelDebug},
		{"info", slog.LevelInfo},
		{"", slog.LevelInfo},
		{"verbose", slog.LevelInfo}, // 未知级别回退 info
		{"warn", slog.LevelWarn},
		{"warning", slog.LevelWarn},
		{"error", slog.LevelError},
		{" ERROR", slog.LevelError},
	}
	for _, c := range cases {
		if got := ParseLevel(c.in); got != c.want {
			t.Errorf("ParseLevel(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestNewAppliesLevel(t *testing.T) {
	ctx := context.Background()

	debugLogger := New("debug")
	if !debugLogger.Enabled(ctx, slog.LevelDebug) {
		t.Error("New(\"debug\") 应启用 debug 级别")
	}

	errorLogger := New("error")
	if errorLogger.Enabled(ctx, slog.LevelWarn) {
		t.Error("New(\"error\") 不应启用 warn 级别")
	}
	if !errorLogger.Enabled(ctx, slog.LevelError) {
		t.Error("New(\"error\") 应启用 error 级别")
	}
}

func TestDefaultAndSetDefault(t *testing.T) {
	original := slog.Default()
	t.Cleanup(func() { slog.SetDefault(original) })

	custom := New("warn")
	SetDefault(custom)
	if Default() != custom {
		t.Error("SetDefault 后 Default() 应返回自定义 logger")
	}
}

func TestRequestID(t *testing.T) {
	if got := RequestID(context.Background()); got != "" {
		t.Errorf("无请求 ID 时应返回空字符串，得到 %q", got)
	}

	ctx := WithRequestID(context.Background(), "req-123")
	if got := RequestID(ctx); got != "req-123" {
		t.Errorf("RequestID = %q, want %q", got, "req-123")
	}

	// 覆盖已有值
	ctx = WithRequestID(ctx, "req-456")
	if got := RequestID(ctx); got != "req-456" {
		t.Errorf("RequestID = %q, want %q", got, "req-456")
	}

	// nil context 不应 panic
	if got := RequestID(nil); got != "" {
		t.Errorf("nil context 应返回空字符串，得到 %q", got)
	}
	if got := RequestID(WithRequestID(nil, "req-nil")); got != "req-nil" {
		t.Errorf("WithRequestID(nil, ...) 后 RequestID = %q, want %q", got, "req-nil")
	}
}

func TestRequestIDAttr(t *testing.T) {
	attr := RequestIDAttr(WithRequestID(context.Background(), "abc"))
	if attr.Key != RequestIDField {
		t.Errorf("attr.Key = %q, want %q", attr.Key, RequestIDField)
	}
	if got := attr.Value.String(); got != "abc" {
		t.Errorf("attr 值 = %q, want %q", got, "abc")
	}
}

func TestWithLogger(t *testing.T) {
	var buf bytes.Buffer
	base := slog.New(slog.NewJSONHandler(&buf, nil))

	ctx := WithRequestID(context.Background(), "req-42")
	WithLogger(ctx, base).Info("hello")
	if !strings.Contains(buf.String(), `"request_id":"req-42"`) {
		t.Errorf("日志应含 request_id 属性，输出：%s", buf.String())
	}

	buf.Reset()
	WithLogger(context.Background(), base).Info("no-id")
	if strings.Contains(buf.String(), RequestIDField) {
		t.Errorf("无请求 ID 时不应附加 request_id 属性，输出：%s", buf.String())
	}

	// nil logger 应回退到默认 logger，且不 panic
	WithLogger(context.Background(), nil).Info("nil-safe")
}
