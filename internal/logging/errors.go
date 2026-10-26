package logging

import "fmt"

// Code 是稳定、机器可读的错误码（由上层映射为 HTTP 状态码等对外表示）。
type Code string

// 错误码常量。
//
// 注意：它们是错误码（Code）而非 error 值，不能用 errors.Is 与 error 直接比较；
// 取码方式：
//
//	var appErr *logging.AppError
//	if errors.As(err, &appErr) && appErr.Code == logging.ErrNotFound { ... }
const (
	ErrInvalidArgument Code = "invalid_argument"
	ErrUnauthorized    Code = "unauthorized"
	ErrForbidden       Code = "forbidden"
	ErrNotFound        Code = "not_found"
	ErrConflict        Code = "conflict"
	ErrInternal        Code = "internal"

	// ErrInvalidUID 表示 uid 形态非法（非 26 位 Crockford Base32），对外映射为 400。
	ErrInvalidUID Code = "invalid_uid"
	// ErrUnknownUID 表示 uid 形态合法但未登记或已墓碑，对外映射为 404。
	// 与 ErrNotFound 分开：客户端据此区分「参数写错」与「服务端确实没有该资源」，
	// 从而判断该重建本地缓存还是修参数。
	ErrUnknownUID Code = "unknown_uid"

	// ErrETagMismatch 表示条件写的前提不成立（If-Match 的 ETag 与当前内容不符，
	// 或 If-None-Match: * 命中已存在的资源），对外映射为 412。内容未被修改。
	ErrETagMismatch Code = "etag_mismatch"
	// ErrRootReadOnly 表示目标根不接受写操作（书库根按需读取、不进 git），
	// 对外映射为 403。客户端据此回退为只读展示，而不是重试。
	ErrRootReadOnly Code = "root_read_only"
	// ErrRescanInProgress 表示已有一次全量重扫在进行中，本次请求被拒绝，
	// 对外映射为 409。重扫是维护动作且写登记表，同一时刻只允许一次；
	// 客户端据此稍后重试，而不是把它当成参数错误去修改请求。
	ErrRescanInProgress Code = "rescan_in_progress"
	// ErrRateLimited 表示同一维护动作被请求得过于频繁（如距上次全量重扫结束
	// 不足最小间隔），对外映射为 429，通常伴随 Retry-After 头。
	// 与 ErrRescanInProgress 分开：409 是「此刻正有同类操作在跑」，429 是
	// 「上一次已结束但离得太近」，两者客户端的正确动作不同（前者等当前结束，
	// 后者按 Retry-After 退避），混用会让客户端无法判断该等多久。
	ErrRateLimited Code = "rate_limited"
)

// AppError 是应用统一错误类型：错误码 + 用户可读信息 + 底层错误。
//
// 错误码用于程序判定与对外映射，Message 面向用户展示，Err 保留原始错误
// 以便 errors.Is / errors.As 穿透与排查。
type AppError struct {
	Code    Code
	Message string
	Err     error
}

// NewAppError 构造只含错误码与用户可读信息的 AppError（无底层错误）。
//
// 命名说明：本包已有 New(level string) *slog.Logger（日志初始化入口），
// Go 不支持函数重载，故错误构造器命名为 NewAppError 以避免同包符号冲突。
func NewAppError(code Code, message string) *AppError {
	return &AppError{Code: code, Message: message}
}

// Wrap 在底层错误之上包装错误码与用户可读信息。
func Wrap(err error, code Code, message string) *AppError {
	return &AppError{Code: code, Message: message, Err: err}
}

// Error 实现 error 接口，按「用户可读信息: 底层错误」拼接。
func (e *AppError) Error() string {
	if e == nil {
		return "<nil>"
	}
	switch {
	case e.Message != "" && e.Err != nil:
		return fmt.Sprintf("%s: %v", e.Message, e.Err)
	case e.Message != "":
		return e.Message
	case e.Err != nil:
		return fmt.Sprintf("%s: %v", e.Code, e.Err)
	default:
		return string(e.Code)
	}
}

// Unwrap 返回底层错误，支持 errors.Is / errors.As 穿透。
func (e *AppError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}
