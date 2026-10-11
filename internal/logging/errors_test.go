package logging

import (
	"errors"
	"testing"
)

func TestNewAppError(t *testing.T) {
	err := NewAppError(ErrNotFound, "笔记不存在")
	if err.Code != ErrNotFound {
		t.Errorf("Code = %q, want %q", err.Code, ErrNotFound)
	}
	if err.Message != "笔记不存在" {
		t.Errorf("Message = %q, want %q", err.Message, "笔记不存在")
	}
	if got := err.Error(); got != "笔记不存在" {
		t.Errorf("Error() = %q, want %q", got, "笔记不存在")
	}
	if err.Unwrap() != nil {
		t.Errorf("无底层错误时 Unwrap() 应为 nil，得到 %v", err.Unwrap())
	}
}

func TestWrapAppError(t *testing.T) {
	base := errors.New("sql: no rows in result set")
	err := Wrap(base, ErrNotFound, "笔记不存在")

	if err.Code != ErrNotFound {
		t.Errorf("Code = %q, want %q", err.Code, ErrNotFound)
	}
	if got := err.Error(); got != "笔记不存在: sql: no rows in result set" {
		t.Errorf("Error() = %q", got)
	}
	if !errors.Is(err, base) {
		t.Error("errors.Is 应能穿透到被包装的底层错误")
	}

	var appErr *AppError
	if !errors.As(err, &appErr) {
		t.Fatal("errors.As 应能取出 *AppError")
	}
	if appErr.Code != ErrNotFound {
		t.Errorf("errors.As 后 Code = %q, want %q", appErr.Code, ErrNotFound)
	}
}

func TestAppErrorWithoutMessageOrCause(t *testing.T) {
	// 只有错误码
	if got := NewAppError(ErrInternal, "").Error(); got != string(ErrInternal) {
		t.Errorf("Error() = %q, want %q", got, string(ErrInternal))
	}

	// 无消息但有底层错误：保留错误码以便诊断
	err := Wrap(errors.New("boom"), ErrInternal, "")
	if got := err.Error(); got != "internal: boom" {
		t.Errorf("Error() = %q, want %q", got, "internal: boom")
	}
	if !errors.Is(err, err.Unwrap()) {
		t.Error("Unwrap 应返回原始底层错误")
	}
}

func TestErrorCodesDistinct(t *testing.T) {
	codes := []Code{
		ErrInvalidArgument, ErrUnauthorized, ErrForbidden,
		ErrNotFound, ErrConflict, ErrInternal,
	}
	seen := make(map[Code]bool, len(codes))
	for _, c := range codes {
		if c == "" {
			t.Error("错误码不应为空字符串")
		}
		if seen[c] {
			t.Errorf("错误码重复：%q", c)
		}
		seen[c] = true
	}
}
