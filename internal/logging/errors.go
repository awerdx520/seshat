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
