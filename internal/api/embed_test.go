// 本文件覆盖 Web UI（嵌入的 web/ 资源）对外暴露时的安全响应头：
// 首页 GET / 与静态资源 GET /static/* 都必须带 nosniff / X-Frame-Options / CSP，
// 且首页 HTML 本身不含内联 <script>/<style> —— 这是 CSP 取 script-src 'self'
// （不含 'unsafe-inline'）的前提，一旦将来有人加入内联脚本，本测试会立即失败，
// 从而避免「CSP 被静默放宽」或「页面功能被 CSP 拦断」两种退化。
package api_test

import (
	"net/http"
	"strings"
	"testing"
)

// assertWebUISecurityHeaders 断言响应带齐 Web UI 的三条安全头。
func assertWebUISecurityHeaders(t *testing.T, label string, headers http.Header) {
	t.Helper()

	if got := headers.Get("X-Content-Type-Options"); got != "nosniff" {
		t.Errorf("%s X-Content-Type-Options = %q, 期望 nosniff", label, got)
	}
	if got := headers.Get("X-Frame-Options"); got != "DENY" {
		t.Errorf("%s X-Frame-Options = %q, 期望 DENY", label, got)
	}
	csp := headers.Get("Content-Security-Policy")
	for _, want := range []string{
		"default-src 'self'",
		"script-src 'self'",
		"object-src 'none'",
		"base-uri 'none'",
	} {
		if !strings.Contains(csp, want) {
			t.Errorf("%s Content-Security-Policy = %q, 缺少 %q", label, csp, want)
		}
	}
}

// TestWebUISecurityHeaders 验证首页与静态资源都带安全响应头。
func TestWebUISecurityHeaders(t *testing.T) {
	env := newFileEnv(t)

	// 首页是公开资源（浏览器导航无法带 Authorization 头），故不带令牌请求。
	index := doRaw(t, env.handler, http.MethodGet, "/", "", nil, nil)
	if index.Code != http.StatusOK {
		t.Fatalf("GET / 状态码 = %d, 期望 200 (body=%q)", index.Code, index.Body.String())
	}
	if ct := index.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("GET / Content-Type = %q, 期望 text/html", ct)
	}
	assertWebUISecurityHeaders(t, "GET /", index.Header())

	js := doRaw(t, env.handler, http.MethodGet, "/static/app.js", "", nil, nil)
	if js.Code != http.StatusOK {
		t.Fatalf("GET /static/app.js 状态码 = %d, 期望 200", js.Code)
	}
	assertWebUISecurityHeaders(t, "GET /static/app.js", js.Header())

	css := doRaw(t, env.handler, http.MethodGet, "/static/style.css", "", nil, nil)
	if css.Code != http.StatusOK {
		t.Fatalf("GET /static/style.css 状态码 = %d, 期望 200", css.Code)
	}
	assertWebUISecurityHeaders(t, "GET /static/style.css", css.Header())
}

// TestWebUIIndexHasNoInlineCode 是 CSP 取值的机械不变量：首页 HTML 不得含内联
// <script>/<style>，也不得含 style= 属性或 javascript: URL。
//
// 若本测试失败，说明页面引入了内联代码——此时要么把内联代码外链化（首选），要么
// 在放宽 CSP 的同时在报告/文档里显式记录这一权衡；不得默默放宽。
func TestWebUIIndexHasNoInlineCode(t *testing.T) {
	env := newFileEnv(t)

	index := doRaw(t, env.handler, http.MethodGet, "/", "", nil, nil)
	if index.Code != http.StatusOK {
		t.Fatalf("GET / 状态码 = %d, 期望 200", index.Code)
	}
	html := index.Body.String()

	if strings.Contains(html, "<style") {
		t.Error("首页含内联 <style> 块，与 CSP default-src 'self' 冲突")
	}
	for rest := html; ; {
		idx := strings.Index(rest, "<script")
		if idx < 0 {
			break
		}
		tag := rest[idx:]
		if end := strings.IndexByte(tag, '>'); end >= 0 {
			tag = tag[:end]
		}
		if !strings.Contains(tag, " src=") {
			t.Errorf("首页含内联 <script>（无 src）: %q", tag)
		}
		rest = rest[idx+len("<script"):]
	}
	if strings.Contains(strings.ToLower(html), "javascript:") {
		t.Error("首页含 javascript: URL，与 CSP script-src 'self' 冲突")
	}
	if strings.Contains(html, " style=") {
		t.Error("首页含 style= 内联样式属性，会被 CSP default-src 'self' 拦截")
	}
}
