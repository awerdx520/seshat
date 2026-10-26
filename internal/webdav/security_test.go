// 本文件覆盖 SandboxContent 中间件：给 WebDAV 出口补 nosniff 与 CSP: sandbox，
// 且不得干扰 inner handler 的状态码与响应体（WebDAV 客户端靠它们做协议判断）。
package webdav

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestSandboxContentSetsHeaders 验证两条响应头在 200 与 404 两条分支上都存在。
//
// 覆盖 404 分支是刻意的：x/net/webdav 的错误响应走另一条写响应路径，而在中间件
// 里「先设头再调用 next」的写法对两条分支都成立——用例把它锁住，避免将来有人把
// 设头挪到 next 之后（那时若 next.WriteHeader 已发出，头就写不进去了）。
func TestSandboxContentSetsHeaders(t *testing.T) {
	cases := []struct {
		name string
		code int
		body string
	}{
		{"200", http.StatusOK, "hello"},
		{"404", http.StatusNotFound, "not found"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(c.code)
				_, _ = w.Write([]byte(c.body))
			})

			rec := httptest.NewRecorder()
			SandboxContent(inner).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/dav/x.html", nil))

			if got := rec.Header().Get("X-Content-Type-Options"); got != "nosniff" {
				t.Errorf("X-Content-Type-Options = %q, 期望 nosniff", got)
			}
			if got := rec.Header().Get("Content-Security-Policy"); got != "sandbox" {
				t.Errorf("Content-Security-Policy = %q, 期望 sandbox", got)
			}
			// 头之外一律透传：状态码与响应体必须原样到达客户端。
			if rec.Code != c.code {
				t.Errorf("状态码 = %d, 期望 %d（中间件不得改写状态码）", rec.Code, c.code)
			}
			if rec.Body.String() != c.body {
				t.Errorf("响应体 = %q, 期望 %q（中间件不得改写响应体）", rec.Body.String(), c.body)
			}
		})
	}
}

// TestSandboxContentKeepsContentType 验证中间件不改写 Content-Type：WebDAV 客户端
// 依赖服务端按扩展名给出的类型处理文件（Calibre / Obsidian 等），sandbox 的语义是
// 「让文档进入不透明源」而不是「改变类型」。
func TestSandboxContentKeepsContentType(t *testing.T) {
	const want = "text/html; charset=utf-8"
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", want)
		_, _ = w.Write([]byte("<script>alert(1)</script>"))
	})

	rec := httptest.NewRecorder()
	SandboxContent(inner).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/dav/x.html", nil))

	if got := rec.Header().Get("Content-Type"); got != want {
		t.Errorf("Content-Type = %q, 期望原样透传 %q", got, want)
	}
	if got := rec.Header().Get("Content-Disposition"); got != "" {
		t.Errorf("Content-Disposition = %q, 期望为空（sandbox 不强制下载）", got)
	}
}
