package auth

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
)

// basicCredential 返回 user:token 的 Basic Authorization 头取值。
func basicCredential(user, token string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+token))
}

// newRequest 构造带指定 Authorization 头的请求；header 为空表示不带该头。
func newRequest(t *testing.T, header string) *http.Request {
	t.Helper()
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	if header != "" {
		r.Header.Set("Authorization", header)
	}
	return r
}

// TestAuthenticateBearerValid 验证正确的 Bearer 令牌通过。
func TestAuthenticateBearerValid(t *testing.T) {
	a := New("s3cret")
	if !a.Authenticate(newRequest(t, "Bearer s3cret")) {
		t.Error("正确的 Bearer 令牌应通过")
	}
}

// TestAuthenticateBearerInvalid 验证错误的 Bearer 令牌被拒绝。
func TestAuthenticateBearerInvalid(t *testing.T) {
	a := New("s3cret")
	if a.Authenticate(newRequest(t, "Bearer wrong")) {
		t.Error("错误的 Bearer 令牌应被拒绝")
	}
}

// TestAuthenticateMissingHeader 验证缺失 Authorization 头被拒绝。
func TestAuthenticateMissingHeader(t *testing.T) {
	a := New("s3cret")
	if a.Authenticate(newRequest(t, "")) {
		t.Error("缺失 Authorization 头应被拒绝")
	}
}

// TestAuthenticateBasicValid 验证正确的 Basic 凭证（base64(user:token)）通过。
func TestAuthenticateBasicValid(t *testing.T) {
	a := New("s3cret")
	if !a.Authenticate(newRequest(t, basicCredential("alice", "s3cret"))) {
		t.Error("正确的 Basic 凭证应通过")
	}
}

// TestAuthenticateBasicInvalid 验证错误密码或非法 Base64 的 Basic 凭证被拒绝。
func TestAuthenticateBasicInvalid(t *testing.T) {
	a := New("s3cret")
	cases := map[string]string{
		"错误密码":      basicCredential("alice", "wrong"),
		"非法 Base64": "Basic !!!not-base64!!!",
	}
	for name, header := range cases {
		if a.Authenticate(newRequest(t, header)) {
			t.Errorf("%s 的 Basic 凭证应被拒绝", name)
		}
	}
}

// TestAuthenticateEmptyTokenRejectsAll 验证未配置令牌时拒绝所有请求（安全默认）。
func TestAuthenticateEmptyTokenRejectsAll(t *testing.T) {
	a := New("")
	cases := map[string]string{
		"Bearer 空令牌":        "Bearer ",
		"Bearer 非空令牌":       "Bearer anything",
		"Basic 任意凭证":        basicCredential("alice", "anything"),
		"无 Authorization 头": "",
	}
	for name, header := range cases {
		if a.Authenticate(newRequest(t, header)) {
			t.Errorf("空令牌下 %s 应被拒绝", name)
		}
	}
}

// TestMiddlewareUnauthorized 验证未认证请求返回 401、WWW-Authenticate 头且不透传。
func TestMiddlewareUnauthorized(t *testing.T) {
	a := New("s3cret")
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
	})

	rec := httptest.NewRecorder()
	a.Middleware(next).ServeHTTP(rec, newRequest(t, "Bearer wrong"))

	if called {
		t.Error("未认证请求不应透传到 next")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("状态码 = %d, 期望 %d", rec.Code, http.StatusUnauthorized)
	}
	if got := rec.Header().Get("WWW-Authenticate"); got != "Bearer" {
		t.Errorf("WWW-Authenticate = %q, 期望 \"Bearer\"", got)
	}
}

// TestMiddlewareEmptyTokenUnauthorized 验证未配置令牌时中间件仍返回 401。
func TestMiddlewareEmptyTokenUnauthorized(t *testing.T) {
	a := New("")
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("空令牌下不应透传到 next")
	})

	rec := httptest.NewRecorder()
	a.Middleware(next).ServeHTTP(rec, newRequest(t, "Bearer anything"))

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("状态码 = %d, 期望 %d", rec.Code, http.StatusUnauthorized)
	}
	if got := rec.Header().Get("WWW-Authenticate"); got != "Bearer" {
		t.Errorf("WWW-Authenticate = %q, 期望 \"Bearer\"", got)
	}
}

// TestMiddlewareAuthenticated 验证认证通过后透传到 next。
func TestMiddlewareAuthenticated(t *testing.T) {
	a := New("s3cret")
	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusTeapot)
	})

	rec := httptest.NewRecorder()
	a.Middleware(next).ServeHTTP(rec, newRequest(t, "Bearer s3cret"))

	if !called {
		t.Error("认证通过后应透传到 next")
	}
	if rec.Code != http.StatusTeapot {
		t.Errorf("状态码 = %d, 期望 %d（next 的响应）", rec.Code, http.StatusTeapot)
	}
}
