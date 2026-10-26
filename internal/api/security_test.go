// 本文件覆盖「基础安全响应头覆盖全部路由」这一不变量（计划 D2 / T2）：
// handler() 返回值的最外层套 securityHeaders，使 /api/ 的成功 JSON 响应、认证失败
// 401、错误响应的 4xx/5xx 分支、Web UI 首页与 /static/ 静态资源都带
// nosniff / X-Frame-Options / Referrer-Policy 三条头。
//
// 同时锁定两条「不做」的边界：
//   - 中间件不设 CSP：Web UI 的 CSP 仍必须是 setWebUISecurityHeaders 的取值
//     （含 script-src 'self'），否则 app.js 被拦、Web UI 白屏；
//   - /api/ 的 JSON 响应不得出现 CSP，避免与 Web UI 的 CSP 混淆。
//
// 与 embed_test.go 的分工：那边只覆盖公开的 Web UI 资源（首页 + 静态资源）；
// 本文件补 /api/ 一侧（含 writeError 这条最易漏的写响应分支）。
package api_test

import (
	"net/http"
	"strings"
	"testing"
)

// assertBaseSecurityHeaders 断言响应带齐 securityHeaders 中间件统一设置的三条基础头。
func assertBaseSecurityHeaders(t *testing.T, label string, headers http.Header) {
	t.Helper()

	cases := []struct{ name, want string }{
		{"X-Content-Type-Options", "nosniff"},
		{"X-Frame-Options", "DENY"},
		{"Referrer-Policy", "no-referrer"},
	}
	for _, c := range cases {
		if got := headers.Get(c.name); got != c.want {
			t.Errorf("%s %s = %q, 期望 %q", label, c.name, got, c.want)
		}
	}
}

// assertWebUICSPIntact 断言 CSP 仍是 Web UI 的取值（由 setWebUISecurityHeaders 设置），
// 即中间件没有把它覆盖成别的策略。
func assertWebUICSPIntact(t *testing.T, label string, headers http.Header) {
	t.Helper()

	csp := headers.Get("Content-Security-Policy")
	if csp == "" {
		t.Fatalf("%s 缺少 Content-Security-Policy（Web UI 的 CSP 不得被中间件覆盖为空）", label)
	}
	for _, want := range []string{"default-src 'self'", "script-src 'self'", "object-src 'none'", "base-uri 'none'"} {
		if !strings.Contains(csp, want) {
			t.Errorf("%s Content-Security-Policy = %q, 缺少 %q", label, csp, want)
		}
	}
}

// TestSecurityHeadersWebUIIndex 验证 Web UI 首页同时带基础安全头与原有 CSP。
func TestSecurityHeadersWebUIIndex(t *testing.T) {
	env := newFileEnv(t)

	rec := doRaw(t, env.handler, http.MethodGet, "/", "", nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET / 状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	assertBaseSecurityHeaders(t, "GET /", rec.Header())
	assertWebUICSPIntact(t, "GET /", rec.Header())
}

// TestSecurityHeadersStaticAsset 验证 /static/ 下的真实静态资源带基础安全头与 CSP。
func TestSecurityHeadersStaticAsset(t *testing.T) {
	env := newFileEnv(t)

	rec := doRaw(t, env.handler, http.MethodGet, "/static/app.js", "", nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /static/app.js 状态码 = %d, 期望 200", rec.Code)
	}
	assertBaseSecurityHeaders(t, "GET /static/app.js", rec.Header())
	assertWebUICSPIntact(t, "GET /static/app.js", rec.Header())
}

// TestSecurityHeadersAPIJSONNoCSP 验证 /api/ 成功响应的基础头齐全，且不含 CSP。
func TestSecurityHeadersAPIJSONNoCSP(t *testing.T) {
	env := newFileEnv(t)

	rec := doRaw(t, env.handler, http.MethodGet, "/api/roots", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/roots 状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	assertBaseSecurityHeaders(t, "GET /api/roots", rec.Header())
	if csp := rec.Header().Get("Content-Security-Policy"); csp != "" {
		t.Errorf("GET /api/roots Content-Security-Policy = %q, 期望为空（CSP 只属 Web UI）", csp)
	}
}

// TestSecurityHeadersAPIErrorPath 验证错误响应同样带基础头。
//
// 缺认证时 401 由 auth.Middleware 的 writeUnauthorized 写出，不经过任何 handler，
// 正是「安全头只加在 handler 内」会漏掉的路径；因此这条断言最关键。
func TestSecurityHeadersAPIErrorPath(t *testing.T) {
	env := newFileEnv(t)

	rec := doRaw(t, env.handler, http.MethodGet, "/api/roots", "", nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("GET /api/roots（无令牌）状态码 = %d, 期望 401 (body=%q)", rec.Code, rec.Body.String())
	}
	assertBaseSecurityHeaders(t, "GET /api/roots（401）", rec.Header())
	if csp := rec.Header().Get("Content-Security-Policy"); csp != "" {
		t.Errorf("GET /api/roots（401）Content-Security-Policy = %q, 期望为空", csp)
	}

	// 已认证但参数/资源不存在（writeError 的 4xx 分支）。
	badUID := doRaw(t, env.handler, http.MethodGet, "/api/progress/not-a-uid", testToken, nil, nil)
	if badUID.Code != http.StatusBadRequest {
		t.Fatalf("GET /api/progress/not-a-uid 状态码 = %d, 期望 400 (body=%q)", badUID.Code, badUID.Body.String())
	}
	assertBaseSecurityHeaders(t, "GET /api/progress/not-a-uid（400）", badUID.Header())
}

// TestSecurityHeadersUnknownRoute 验证不存在的路由（404）也带基础安全头。
func TestSecurityHeadersUnknownRoute(t *testing.T) {
	env := newFileEnv(t)

	rec := doRaw(t, env.handler, http.MethodGet, "/api/nope", testToken, nil, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /api/nope 状态码 = %d, 期望 404 (body=%q)", rec.Code, rec.Body.String())
	}
	assertBaseSecurityHeaders(t, "GET /api/nope", rec.Header())
}

// TestSecurityHeadersFileDownload 验证文件下载响应同样带基础安全头。
//
// 只断言安全头存在：Content-Type / Content-Disposition 的取值属 T3 的判定改造
// （主动内容白名单），与本任务无关；这里用被动内容 .org 以避开 T3 的变更面。
func TestSecurityHeadersFileDownload(t *testing.T) {
	env := newFileEnv(t)

	writeFileOK(t, env.handler, "/api/files/sec.org", "* 标题\n")
	rec := doRaw(t, env.handler, http.MethodGet, "/api/files/sec.org", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/files/sec.org 状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	assertBaseSecurityHeaders(t, "GET /api/files/sec.org", rec.Header())
	if csp := rec.Header().Get("Content-Security-Policy"); csp != "" {
		t.Errorf("GET /api/files/sec.org Content-Security-Policy = %q, 期望为空", csp)
	}
}
