// Package webdav 提供 notes 服务的 WebDAV 端点。
//
// 端点的双重定位：内部同步通道（自有客户端，SourceInternal）与对外标准出口
// （外部应用，SourceExternal）。两者复用同一套认证与处理逻辑，差别只在
// 挂载的根目录（笔记根目录 vs. 对外公开目录）与写入时记录的来源标记。
//
// 范围限制：golang.org/x/net/webdav 的 Dir 自带路径逃逸防护（先对请求路径
// 做 path.Clean("/"+name)，".." 无法越过挂载根），挂载根即笔记目录，因此
// 项目根下的 .git/、配置文件与附件原始库天然不在挂载范围内；对外端点把根
// 挂到 Public 子目录即可实现「范围受限」。
package webdav

import (
	"context"
	"net/http"

	"golang.org/x/net/webdav"

	"notes/internal/auth"
)

// davPrefix 是 WebDAV 端点使用的默认 URL 前缀，需与路由挂载路径一致。
//
// 各构造函数默认使用它；对外出口等挂载在其它前缀下的端点，可通过带 prefix
// 参数的构造函数（如 NewPolicyVersionedHandler）覆盖，从而使 PROPFIND 等
// 响应生成的 href 与真实挂载点一致。
const davPrefix = "/dav"

// newDAVHandler 用给定 URL 前缀与文件系统构造底层 webdav.Handler。
//
// prefix 必须与 handler 的挂载路径一致：webdav.Handler 以它剥掉请求路径前缀，
// 并以它拼接 PROPFIND 等响应中的 href；前缀不匹配的请求会返回 404。
func newDAVHandler(prefix string, fs webdav.FileSystem) *webdav.Handler {
	return &webdav.Handler{
		Prefix:     prefix,
		FileSystem: fs,
		LockSystem: webdav.NewMemLS(),
	}
}

// Source 标记一次 WebDAV 请求的来源，供写入后的 git commit 记录使用。
type Source string

const (
	// SourceInternal 表示请求来自自有客户端（内部同步通道）。
	SourceInternal Source = "internal"
	// SourceExternal 表示请求来自外部应用（对外标准出口）。
	SourceExternal Source = "external"
)

// contextKey 是本包私有的 context 键类型，避免与其他包的键发生冲突。
type contextKey struct{}

// sourceKey 是来源标记在 context 中的键。
var sourceKey = contextKey{}

// NewHandler 构造 WebDAV HTTP handler。
//
// root 是挂载根目录（内部端点传笔记根目录，对外端点传公开目录）；
// authenticator 负责认证（WebDAV 客户端使用 Basic）；source 标记本端点的
// 请求来源，认证通过后写入请求 context。
//
// 处理顺序：认证中间件 → 注入来源标记 → webdav.Handler，即先拒绝未认证
// 请求，再为已认证请求附加来源标记，最后交给 WebDAV 处理器。
func NewHandler(root string, authenticator *auth.Authenticator, source Source) http.Handler {
	handler := newDAVHandler(davPrefix, webdav.Dir(root))
	return authenticator.Middleware(injectSource(source, handler))
}

// injectSource 包装 next：把 source 写入请求 context 后转发。
func injectSource(source Source, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), sourceKey, source)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// SourceFromContext 返回请求 context 中的来源标记；
// 没有来源标记（或标记类型不符）时返回空串。
func SourceFromContext(ctx context.Context) Source {
	source, _ := ctx.Value(sourceKey).(Source)
	return source
}
