package llm

import (
	"context"
	"testing"
)

// directStubClient 是本测试专用的 Client 实现，用于验证「非 *LocalNodeClient 的
// 本地后端」被 LocalDirectAvailable 视为已配置。
type directStubClient struct{}

func (directStubClient) Chat(context.Context, []Message) (string, error) { return "stub", nil }

func TestLocalDirectAvailableConfiguredURL(t *testing.T) {
	router := NewRouter(nil, NewLocal("http://node.local:11434").WithModel("qwen2.5:7b"))
	if !router.LocalDirectAvailable() {
		t.Error("显式配置 URL 时应返回 true")
	}
}

func TestLocalDirectAvailableDefaultURL(t *testing.T) {
	router := NewRouter(nil, NewLocal(""))
	if router.LocalDirectAvailable() {
		t.Error("未显式配置 URL（回退默认地址）时应返回 false")
	}
}

func TestLocalDirectAvailableBlankURL(t *testing.T) {
	router := NewRouter(nil, NewLocal("   "))
	if router.LocalDirectAvailable() {
		t.Error("仅含空白的 URL 视为未配置，应返回 false")
	}
}

func TestLocalDirectAvailableNoLocalBackend(t *testing.T) {
	router := NewRouter(NewCloud("k", "http://cloud.invalid", "m"), nil)
	if router.LocalDirectAvailable() {
		t.Error("未提供本地后端时应返回 false")
	}
}

func TestLocalDirectAvailableNonDirectClient(t *testing.T) {
	router := NewRouter(nil, directStubClient{})
	if !router.LocalDirectAvailable() {
		t.Error("非 LocalNodeClient 的本地后端应视为已配置，返回 true")
	}
}

func TestLocalDirectAvailableNilRouter(t *testing.T) {
	var router *Router
	if router.LocalDirectAvailable() {
		t.Error("nil Router 应返回 false")
	}
}
