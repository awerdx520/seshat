package api

import (
	"embed"
	"io/fs"
	"net/http"
)

// 本文件把 Web UI 静态资源（web/ 目录）编译进服务端二进制，并通过 http
// 处理器对外提供 /（首页）与 /static/（静态资源）两个公开路由。
//
// 说明：go:embed 不能引用上级目录，故资源置于本包目录下的 web/；embed.go
// 与资源同目录，可用相对路径 "web" 直接嵌入。
//
// webAssets 嵌入 web/ 目录下的全部静态资源（index.html 与 static/ 子目录）。
//
//go:embed web
var webAssets embed.FS

// mustSubFS 返回 webAssets 中 root 子目录对应的文件系统；嵌入资源在构建期
// 已确定，路径缺失属程序性错误，故直接 panic 以便尽早暴露。
func mustSubFS(root string) fs.FS {
	sub, err := fs.Sub(webAssets, root)
	if err != nil {
		panic("api: 解析嵌入的 Web 静态资源失败: " + err.Error())
	}
	return sub
}

// mustReadFile 读取 webAssets 中的嵌入文件；路径缺失属程序性错误，直接 panic。
func mustReadFile(name string) []byte {
	data, err := webAssets.ReadFile(name)
	if err != nil {
		panic("api: 读取嵌入的 Web 资源失败: " + err.Error())
	}
	return data
}

// webSecurityHeaders 统一设置 Web UI（首页与静态资源）的安全响应头。
//
// 三条头各挡一类攻击面：
//   - X-Content-Type-Options: nosniff —— 阻止浏览器把响应嗅探成未声明的类型；
//   - X-Frame-Options: DENY —— 禁止被任意站点 iframe 嵌入（点击劫持）；
//   - Content-Security-Policy —— 只允许同源资源，禁用 object/base。
//
// CSP 取值说明（script-src 不含 'unsafe-inline'）：web/index.html 只通过
// <link rel="stylesheet" href="/static/style.css"> 与 <script src="/static/app.js">
// 外链资源，全文件无内联 <script>/<style>，也无 style= 属性或 javascript: URL；
// app.js 仅用 textContent 写 DOM，不拼接 HTML。故无需为兼容而放宽 CSP——内联脚本
// 在本项目的 Web UI 里不存在，一旦将来出现会被 CSP 直接拦下（这正是想要的效果）。
//
// style-src / img-src / connect-src 均由 default-src 'self' 兜底：样式表是同源文件，
// 页面按需 fetch 同源 /api/*，均在允许范围内。
const webUISecurityPolicy = "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'"

// setWebUISecurityHeaders 把 Web UI 的安全响应头写入 w。
func setWebUISecurityHeaders(w http.ResponseWriter) {
	header := w.Header()
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("X-Frame-Options", "DENY")
	header.Set("Content-Security-Policy", webUISecurityPolicy)
}

// webIndexHandler 提供 Web UI 首页：直接返回嵌入的 index.html。
//
// 不经 http.FileServer——后者对以 "index.html" 结尾的请求路径会返回 301
// 重定向（net/http/fs.go 的规范化行为），对首页这种单文件返回并无意义。
func webIndexHandler() http.Handler {
	indexHTML := mustReadFile("web/index.html")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setWebUISecurityHeaders(w)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
}

// webStaticHandler 提供 /static/ 下的静态资源（对应 web/static 目录）。
//
// 安全头加在 StripPrefix 之外：静态资源（尤其 .js/.css）同样需要 nosniff 与 CSP，
// 否则内联/嗅探类问题会从静态资源侧绕过首页的策略。
func webStaticHandler() http.Handler {
	fileServer := http.FileServer(http.FS(mustSubFS("web/static")))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setWebUISecurityHeaders(w)
		http.StripPrefix("/static/", fileServer).ServeHTTP(w, r)
	})
}
