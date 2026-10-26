package api

import "net/http"

// securityHeaders 给服务端全部路由补基础安全响应头。
//
// 覆盖范围：handler() 返回的整棵 mux（/api/、Web UI 首页、/static/）。/dav/ 与
// /public/ 由 internal/webdav 自己的 server 提供，不在本中间件范围内。
//
// 三条头各挡一类攻击面：
//   - X-Content-Type-Options: nosniff —— 阻止浏览器把响应嗅探成未声明的类型
//     （错误响应的 JSON 体、下载内容都曾被嗅探过）；
//   - X-Frame-Options: DENY —— 禁止被任意站点 iframe 嵌入（点击劫持）；
//   - Referrer-Policy: no-referrer —— 不把请求 URL（含文件路径）经 Referer
//     泄漏给第三方资源。
//
// 刻意不设 Content-Security-Policy：Web UI 的 CSP 含 script-src 'self'
// （见 embed.go 的 webUISecurityPolicy），若由本中间件统一设置会覆盖它，
// 导致 app.js 被拦、Web UI 白屏。CSP 仍由 setWebUISecurityHeaders 负责。
//
// 刻意不设 Strict-Transport-Security：TLS 在反向代理终止，服务端判断不了
// 真实 scheme，HSTS 交给反代（与 docs/security.md 口径一致）。
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}
