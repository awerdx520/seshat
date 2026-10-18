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
		ErrInvalidUID, ErrUnknownUID,
		ErrETagMismatch, ErrRootReadOnly, ErrRescanInProgress,
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

// TestRescanErrorCodeWireValue 锁定重扫并发拒绝的错误码字符串值。
//
// rescan_in_progress 直接出现在 REST 响应体的 error.code 里，客户端据此决定
// 「稍后重试」而非「改参数」，属对外契约，故用测试固定其字面值与语义区分。
func TestRescanErrorCodeWireValue(t *testing.T) {
	if got := string(ErrRescanInProgress); got != "rescan_in_progress" {
		t.Errorf("ErrRescanInProgress = %q, want %q", got, "rescan_in_progress")
	}
	// 与 conflict 分开：重扫并发是「服务端忙」，与业务乐观锁冲突不是一回事。
	if ErrRescanInProgress == ErrConflict {
		t.Error("rescan_in_progress 不得复用 conflict 的码值")
	}
	if ErrRescanInProgress == ErrForbidden {
		t.Error("rescan_in_progress 不得复用 forbidden 的码值（客户端需区分忙与无权）")
	}
}

// TestUIDErrorCodeWireValues 锁定 uid 相关错误码的对外字符串值与语义区分。
//
// 这两个码直接出现在 REST 响应体的 error.code 与客户端分支判断里，属对外契约，
// 故用测试而非注释固定，避免改名后客户端静默失配。
func TestUIDErrorCodeWireValues(t *testing.T) {
	if got := string(ErrInvalidUID); got != "invalid_uid" {
		t.Errorf("ErrInvalidUID = %q, want %q", got, "invalid_uid")
	}
	if got := string(ErrUnknownUID); got != "unknown_uid" {
		t.Errorf("ErrUnknownUID = %q, want %q", got, "unknown_uid")
	}
	if ErrInvalidUID == ErrUnknownUID {
		t.Error("invalid_uid 与 unknown_uid 必须是不同错误码（参数错 vs 资源不存在）")
	}
	// 新码不得与既有 not_found 混同：unknown_uid 是它的语义细化。
	if ErrUnknownUID == ErrNotFound {
		t.Error("unknown_uid 不得复用 not_found 的码值")
	}
}

// TestConditionalWriteErrorCodeWireValues 锁定 M7 B3 的两个写路径错误码。
//
// etag_mismatch（412）与 root_read_only（403）都进入 REST 响应体的 error.code，
// 客户端据此选择「重新拉取内容再重试」或「放弃写入」，属对外契约，故用测试固定。
func TestConditionalWriteErrorCodeWireValues(t *testing.T) {
	if got := string(ErrETagMismatch); got != "etag_mismatch" {
		t.Errorf("ErrETagMismatch = %q, want %q", got, "etag_mismatch")
	}
	if got := string(ErrRootReadOnly); got != "root_read_only" {
		t.Errorf("ErrRootReadOnly = %q, want %q", got, "root_read_only")
	}
	if ErrETagMismatch == ErrRootReadOnly {
		t.Error("etag_mismatch 与 root_read_only 必须是不同错误码（冲突 vs 不允许写）")
	}
	if ErrETagMismatch == ErrConflict {
		t.Error("etag_mismatch 不得复用 conflict 的码值（客户端需区分乐观锁失败与业务冲突）")
	}
	if ErrRootReadOnly == ErrForbidden {
		t.Error("root_read_only 不得复用 forbidden 的码值（客户端需区分根只读与权限不足）")
	}
}
