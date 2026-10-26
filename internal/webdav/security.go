// WebDAV 出口的响应头加固：/dav/ 与 /public/ 是「第三方客户端 + 浏览器」共用的
// 双出口，REST 侧的主动内容白名单（internal/api/files.go）覆盖不到它们。

package webdav

import "net/http"

// SandboxContent 给 WebDAV 出口（/dav/ 与 /public/）补两条响应头。
//
// 为什么需要：WebDAV 的 Content-Type 由 x/net/webdav 按扩展名推断并内联返回，
// 因此 PUT 一个 x.html 再让浏览器直接导航到该 URL，脚本就在与服务端同源的
// 文档里执行——可读取 Web UI 存在 localStorage 里的访问令牌。REST 侧已由
// 主动内容白名单封堵（internal/api/files.go），这里是同一风险的最后一个出口。
//
// 为什么用 CSP: sandbox 而不是强制 attachment：attachment 会破坏 Calibre /
// Obsidian 等按 Content-Type 处理文件的 WebDAV 客户端；sandbox 只让文档进入
// 不透明源、禁掉脚本与同源 DOM 访问，字节内容与 Content-Type 均不变，客户端无感。
//
// 导出而非包内私有：唯一装配点是 cmd/server/main.go（包 main），无法调用未导出
// 符号；把包装逻辑复制到 main 会让「出口加固」出现第二份实现。
func SandboxContent(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", "sandbox")
		next.ServeHTTP(w, r)
	})
}
