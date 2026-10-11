package auth

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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

// TestMiddlewareUnauthorized 验证未认证请求返回 401、统一 JSON 错误体、
// WWW-Authenticate 头且不透传。
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
	assertUnauthorizedJSON(t, rec)
}

// assertUnauthorizedJSON 断言 401 响应体是统一格式的 JSON 错误体
// {"error":{"code":"unauthorized","message":...}}，Content-Type 为 application/json。
// 与 internal/api 的统一错误体保持一致，便于客户端统一解析。
func assertUnauthorizedJSON(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("Content-Type = %q, 期望含 application/json", ct)
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("401 响应体不是合法 JSON: %v (body=%q)", err, rec.Body.String())
	}
	if body.Error.Code != "unauthorized" {
		t.Errorf("error.code = %q, 期望 \"unauthorized\"", body.Error.Code)
	}
	if body.Error.Message == "" {
		t.Error("error.message 不应为空")
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
	assertUnauthorizedJSON(t, rec)
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

// TestAuthenticateNodeUsesNodeToken 验证配置节点令牌后，节点端点校验节点令牌：
// 节点令牌通过、主令牌被拒绝（角色隔离）。
func TestAuthenticateNodeUsesNodeToken(t *testing.T) {
	a := NewWithNodeToken("main", "node")
	if !a.AuthenticateNode(newRequest(t, "Bearer node")) {
		t.Error("节点令牌应通过节点端点认证")
	}
	if a.AuthenticateNode(newRequest(t, "Bearer main")) {
		t.Error("主令牌不应通过节点端点认证")
	}
}

// TestAuthenticateNodeFallsBackToMainToken 验证未配置节点令牌时节点端点回退接受主令牌。
func TestAuthenticateNodeFallsBackToMainToken(t *testing.T) {
	a := NewWithNodeToken("main", "")
	if !a.AuthenticateNode(newRequest(t, "Bearer main")) {
		t.Error("未配置节点令牌时应回退接受主令牌")
	}
}

// TestAuthenticateNodeEmptyRejectsAll 验证主令牌与节点令牌均未配置时节点端点拒绝所有请求。
func TestAuthenticateNodeEmptyRejectsAll(t *testing.T) {
	a := NewWithNodeToken("", "")
	if a.AuthenticateNode(newRequest(t, "Bearer anything")) {
		t.Error("未配置任何令牌时节点端点应拒绝请求")
	}
}

// TestMainTokenRejectsNodeToken 验证主令牌端点不接受节点令牌（反向隔离）。
func TestMainTokenRejectsNodeToken(t *testing.T) {
	a := NewWithNodeToken("main", "node")
	if a.Authenticate(newRequest(t, "Bearer node")) {
		t.Error("节点令牌不应通过主端点认证")
	}
	if !a.Authenticate(newRequest(t, "Bearer main")) {
		t.Error("主令牌应通过主端点认证")
	}
}

// TestNodeMiddleware 验证节点中间件：节点令牌透传、主令牌返回 401 且不透传。
func TestNodeMiddleware(t *testing.T) {
	a := NewWithNodeToken("main", "node")

	called := false
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusTeapot)
	})

	// 节点令牌：透传。
	rec := httptest.NewRecorder()
	a.NodeMiddleware(next).ServeHTTP(rec, newRequest(t, "Bearer node"))
	if !called || rec.Code != http.StatusTeapot {
		t.Errorf("节点令牌应透传到 next: called=%v code=%d", called, rec.Code)
	}

	// 主令牌：401 且不透传。
	called = false
	rec = httptest.NewRecorder()
	a.NodeMiddleware(next).ServeHTTP(rec, newRequest(t, "Bearer main"))
	if called {
		t.Error("主令牌不应透传到节点 handler")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("状态码 = %d, 期望 %d", rec.Code, http.StatusUnauthorized)
	}
	assertUnauthorizedJSON(t, rec)
}
