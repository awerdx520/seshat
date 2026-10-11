// Package logging 提供服务端统一的结构化日志与错误包装骨架。
//
// 日志基于标准库 log/slog（Go 1.21+ 内置，无外部依赖）：默认输出 JSON 到
// stdout（便于日志采集），并支持通过 context 让 request_id 贯穿整条请求链路。
package logging

import (
	"context"
	"log/slog"
	"os"
	"strings"
)

// contextKey 是本包私有的 context 键类型，避免与其他包的键冲突。
type contextKey struct{}

// requestIDKey 是存放请求 ID 的 context 键。
var requestIDKey = contextKey{}

// RequestIDField 是请求 ID 在日志属性中的字段名。
const RequestIDField = "request_id"

// ParseLevel 将字符串日志级别解析为 slog.Level。
//
// 支持 debug/info/warn/warning/error（大小写不敏感，忽略首尾空白）；
// 无法识别或为空时回退到 slog.LevelInfo。
func ParseLevel(level string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(level)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// New 按给定级别构造结构化 logger（JSON handler，输出到 stdout）。
//
// level 无法识别时按 info 处理。
func New(level string) *slog.Logger {
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: ParseLevel(level),
	})
	return slog.New(handler)
}

// Init 构造 logger 并设为 slog 包级默认 logger，供服务启动时统一初始化。
func Init(level string) *slog.Logger {
	logger := New(level)
	slog.SetDefault(logger)
	return logger
}

// Default 返回当前 slog 包级默认 logger。
func Default() *slog.Logger {
	return slog.Default()
}

// SetDefault 设置 slog 包级默认 logger。
func SetDefault(logger *slog.Logger) {
	slog.SetDefault(logger)
}

// WithRequestID 返回携带请求 ID 的 context 副本。
// 传入 nil context 时从 context.Background() 派生，避免 panic。
func WithRequestID(ctx context.Context, id string) context.Context {
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithValue(ctx, requestIDKey, id)
}

// RequestID 从 context 提取请求 ID；不存在或 ctx 为 nil 时返回空字符串。
func RequestID(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	id, ok := ctx.Value(requestIDKey).(string)
	if !ok {
		return ""
	}
	return id
}

// RequestIDAttr 返回 request_id 的 slog 属性，便于在日志中贯穿请求链路。
// context 中无请求 ID 时返回空值属性（值为空字符串）。
func RequestIDAttr(ctx context.Context) slog.Attr {
	return slog.String(RequestIDField, RequestID(ctx))
}

// WithLogger 返回附带了当前请求 request_id 属性的 logger。
// context 中无请求 ID 时原样返回 logger；logger 为 nil 时回退到默认 logger。
func WithLogger(ctx context.Context, logger *slog.Logger) *slog.Logger {
	if logger == nil {
		logger = slog.Default()
	}
	if RequestID(ctx) == "" {
		return logger
	}
	return logger.With(RequestIDAttr(ctx))
}
