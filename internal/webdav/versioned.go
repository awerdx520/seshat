// 本文件实现 WebDAV 端点的 git 版本化：把 ETag 绑定到工作区内容的
// git blob hash，并在写方法处理完成后自动提交一次。
package webdav

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/net/webdav"

	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/index"
	"seshat/internal/registry"
)

// writeMethods 是会产生工作区变更、因此需要在处理后自动提交的 HTTP 方法。
// 读方法（GET/PROPFIND/OPTIONS/HEAD）不在此列，不会触发提交。
var writeMethods = map[string]bool{
	http.MethodPut:    true,
	http.MethodDelete: true,
	"MKCOL":           true,
	"MOVE":            true,
	"COPY":            true,
	"PROPPATCH":       true,
}

// VersionedHandler 在 NewHandler 的基础上增加 git 版本化：
//
//   - 文件系统换成 versionedFS，使 Stat/OpenFile 返回的 os.FileInfo
//     实现 webdav.ETager，PROPFIND 的 getetag 属性即工作区内容的 blob hash；
//   - 写方法（PUT/DELETE/MOVE/COPY/MKCOL/PROPPATCH）在 handler.ServeHTTP
//     返回后自动提交一次，commit message 为
//     "webdav <source>: <method> <path>"；提交失败只记录日志，不影响响应。
//
// root 为挂载根目录，authenticator 负责认证，source 标记端点来源，
// repo 为目标 git 仓库（Open 自同一 root）。NewHandler 保持原签名不变，
// 本函数是新增入口。
//
// 警告：本入口不含点路径与软链守卫，生产请使用 ...WithRegistry 变体
// （同文件的 VersionedHandlerWithRegistry / NewPolicyVersionedHandlerWithRegistry）。
func VersionedHandler(root string, authenticator *auth.Authenticator, source Source, repo *gitver.Repo) http.Handler {
	handler := newDAVHandler(davPrefix, newVersionedFS(root, repo))
	return authenticator.Middleware(commitAfterWrite(source, repo, handler))
}

// commitAfterWrite 包装 next：注入来源标记后转发请求，
// 若是写方法则在内层 handler 返回后提交一次工作区变更。
func commitAfterWrite(source Source, repo *gitver.Repo, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), sourceKey, source)
		next.ServeHTTP(w, r.WithContext(ctx))

		method := strings.ToUpper(r.Method)
		if repo == nil || !writeMethods[method] {
			return
		}

		message := fmt.Sprintf("webdav %s: %s %s", SourceFromContext(ctx), method, r.URL.Path)
		if err := repo.Commit(message); err != nil {
			// 提交失败不中断响应，仅记录；请求本身已处理完成。
			log.Printf("webdav: %s %s 后自动提交失败: %v", method, r.URL.Path, err)
		}
	})
}

// orgSuffix 是需要纳入全文索引的笔记文件后缀；其它类型的文件不进索引。
const orgSuffix = ".org"

// VersionedHandlerWithIndex 在 VersionedHandler 的基础上，额外在写操作完成后
// 维护 FTS 全文索引（见 internal/index）：
//
//   - PUT：若目标为 .org，读取落盘后的内容更新其索引；
//   - DELETE：删除该路径的索引；
//   - MOVE：删除源索引，并在目标为 .org 时建立目标索引；
//   - COPY：仅建立目标索引（源文件仍存在，其索引保持不变）。
//
// 索引在响应处理完成后、文件已落盘时进行，失败只记录日志、不影响已发出的响应，
// 与 commit 失败的处理一致。repo 或 indexer 为 nil 时对应环节自动跳过。
//
// root、authenticator、source、repo 语义同 VersionedHandler；indexer 为全文
// 索引器。原 VersionedHandler 签名保持不变，本函数是新增入口；
// 前缀固定为默认的 davPrefix，且挂载根即仓库根（offset 为空），需要自定义前缀
// 或挂载根为仓库子目录时用 NewPolicyVersionedHandler。
func VersionedHandlerWithIndex(root string, authenticator *auth.Authenticator, source Source, repo *gitver.Repo, indexer *index.Indexer) http.Handler {
	return newPolicyVersionedHandler(root, authenticator, source, PolicyOptions{}, repo, indexer, davPrefix, "")
}

// VersionedHandlerWithRegistry 在 VersionedHandlerWithIndex 的基础上，额外把成功的
// 写操作登记进 registry（resources + changes，见 registryAfterWrite）：
//
//   - 写方法返回 2xx 后，按方法推导事件（PUT → create/update、DELETE → delete、
//     MOVE → rename、COPY → 目标 create），rev 取 commit 之后的 Repo.Head()；
//   - 失败响应（4xx/5xx）不产生任何事件；登记失败只记日志，不影响响应。
//
// 处理链由外到内依次为：认证 → 全文索引 → 身份登记 → git commit → WebDAV。
// reg 为 nil 时行为与 VersionedHandlerWithIndex 完全一致；注册前需先对其调用
// SetRoots（首根 tag 即登记使用的逻辑根）。
//
// root、authenticator、source、repo、indexer 语义同 VersionedHandlerWithIndex；
// 前缀固定为 davPrefix 且挂载根即仓库根。对外出口请用
// NewPolicyVersionedHandlerWithRegistry。
func VersionedHandlerWithRegistry(root string, authenticator *auth.Authenticator, source Source, repo *gitver.Repo, indexer *index.Indexer, reg *registry.Service) http.Handler {
	return newPolicyVersionedHandlerWithRegistry(root, authenticator, source, PolicyOptions{},
		repo, indexer, reg, davPrefix, "", firstRootTag(reg))
}

// indexAfterWrite 包装 next：请求处理完成后，若为成功响应（2xx）则按写方法
// 维护相应的全文索引。以状态码为准可避免失败的写请求（文件未变更却返回 4xx/5xx）
// 误删或误写索引。
//
// root 为 handler 的挂载根；prefix 为该 handler 的 URL 前缀；offset 为挂载根相对
// 仓库根（repo root）的偏移，用于把请求路径还原为「仓库内相对路径」作为索引 key
// （读文件仍以挂载根为基准，见 updateIndexAfterWrite）。
func indexAfterWrite(root, prefix, offset string, indexer *index.Indexer, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		if indexer == nil {
			return
		}
		if rec.status < http.StatusOK || rec.status >= http.StatusMultipleChoices {
			return
		}
		updateIndexAfterWrite(root, prefix, offset, indexer, r)
	})
}

// statusRecorder 包装 ResponseWriter 以记录写出的状态码，供后置钩子判断写请求
// 是否成功。缺省状态码为 0，表示 handler 未显式写出状态（仅在进行 body 写入时
// 记为 200）。webdav.Handler 总会显式 WriteHeader，故正常路径下状态码非 0。
type statusRecorder struct {
	http.ResponseWriter
	status int
}

// WriteHeader 记录状态码后转发。
func (rec *statusRecorder) WriteHeader(code int) {
	rec.status = code
	rec.ResponseWriter.WriteHeader(code)
}

// Write 在未显式写出状态码时按隐式 200 记录，随后转发。
func (rec *statusRecorder) Write(b []byte) (int, error) {
	if rec.status == 0 {
		rec.status = http.StatusOK
	}
	return rec.ResponseWriter.Write(b)
}

// updateIndexAfterWrite 依据请求方法与路径更新全文索引。仅在 next 返回后调用
// （此时写操作已完成、文件已落盘），索引失败仅记日志。
//
// prefix 为该 handler 的 URL 前缀，offset 为挂载根相对仓库根的偏移；两者共同把
// 请求路径映射为索引 key：
//
//	挂载根相对路径（读文件用，基于 root）= indexRelPath(prefix, raw)
//	仓库相对路径（索引 key）= path.Join(offset, 挂载根相对路径)
//
// offset 为空（挂载根即仓库根）时索引 key 与挂载根相对路径相同，与内部端点一致。
func updateIndexAfterWrite(root, prefix, offset string, indexer *index.Indexer, r *http.Request) {
	// keyOf 返回索引 key：仓库内相对路径。rel 为空（无法解析）时返回空串，
	// 避免把 offset 本身当成路径误删/误写。
	keyOf := func(raw string) string {
		rel := indexRelPath(prefix, raw)
		if rel == "" {
			return ""
		}
		return path.Join(offset, rel)
	}

	switch strings.ToUpper(r.Method) {
	case http.MethodPut:
		rel := indexRelPath(prefix, r.URL.Path)
		if !strings.HasSuffix(rel, orgSuffix) {
			return
		}
		indexFile(root, indexer, offset, rel)
	case http.MethodDelete:
		if err := indexer.Delete(keyOf(r.URL.Path)); err != nil {
			log.Printf("webdav: DELETE %s 后删除索引失败: %v", r.URL.Path, err)
		}
	case "MOVE", "COPY":
		// MOVE 后源已不存在，删除其索引；COPY 源仍保留，不动其索引。
		if strings.EqualFold(r.Method, "MOVE") {
			if err := indexer.Delete(keyOf(r.URL.Path)); err != nil {
				log.Printf("webdav: MOVE %s 后删除源索引失败: %v", r.URL.Path, err)
			}
		}
		dst := indexRelPath(prefix, r.Header.Get("Destination"))
		if strings.HasSuffix(dst, orgSuffix) {
			indexFile(root, indexer, offset, dst)
		}
	}
}

// indexFile 读取挂载根 root 下 rel 对应的文件内容并更新其全文索引，失败仅记日志。
// rel 是挂载根相对路径（用于定位文件），offset 是挂载根相对仓库根的偏移，二者拼出
// 索引 key（仓库内相对路径）。
func indexFile(root string, indexer *index.Indexer, offset, rel string) {
	key := path.Join(offset, rel)
	content, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		log.Printf("webdav: 读取 %s 以更新索引失败: %v", key, err)
		return
	}
	if err := indexer.Index(key, string(content)); err != nil {
		log.Printf("webdav: 更新 %s 索引失败: %v", key, err)
	}
}

// indexRelPath 把 WebDAV 的请求路径或 Destination 头规范化为挂载根相对路径。
// 输入可能是绝对 URL（MOVE/COPY 的 Destination）或绝对路径，统一取 Path 部分、
// 剥掉 prefix（该 handler 的 URL 前缀，如 "/dav" 或 "/public"）后再交由 blobPath
// 归一。无法解析时返回空串。对对外出口（挂载根为仓库子目录）而言，该结果是
// 「挂载根相对路径」，需再叠加 offset 才是仓库内相对路径（见 updateIndexAfterWrite）。
func indexRelPath(prefix, raw string) string {
	if raw == "" {
		return ""
	}
	if u, err := url.Parse(raw); err == nil && u.Path != "" {
		raw = u.Path
	}
	return blobPath(strings.TrimPrefix(raw, prefix))
}

// versionedFS 包装任意 webdav.FileSystem，让返回的 FileInfo 携带 blob hash ETag。
//
// offset 是该文件系统挂载根相对 git 仓库根（repo root）的偏移，形如 "public"；
// 空串表示挂载根即仓库根。webdav 请求路径是「挂载根相对路径」，而 repo.BlobHash
// 需要「仓库内相对路径」，故 ETag 计算时须拼上 offset，否则对外出口（挂载在仓库
// 子目录）会解析到仓库中不存在的路径，blob hash 退化为空、getetag 回退到启发式。
type versionedFS struct {
	fs     webdav.FileSystem
	repo   *gitver.Repo
	offset string
}

// newVersionedFS 以 root 为挂载根构造 versionedFS。root 即仓库根，偏移为空。
func newVersionedFS(root string, repo *gitver.Repo) versionedFS {
	return wrapVersionedFS(webdav.Dir(root), repo, "")
}

// wrapVersionedFS 在底层文件系统 fs 之上叠加 ETag 能力，构造 versionedFS。
// 可包装 webdav.Dir，也可包装访问策略包装（如 ReadOnlyFS/ExtWhitelistFS），
// 使「策略 + 版本化」可叠加组合。
//
// offset 为 fs 挂载根相对仓库根的偏移（空表示挂载根即仓库根），用于把请求路径
// 映射为仓库内相对路径后计算 blob hash。
func wrapVersionedFS(fs webdav.FileSystem, repo *gitver.Repo, offset string) versionedFS {
	return versionedFS{fs: fs, repo: repo, offset: offset}
}

// Mkdir 创建目录（直接委托底层文件系统）。
func (fs versionedFS) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	return fs.fs.Mkdir(ctx, name, perm)
}

// OpenFile 打开文件，并把返回的 File 包装成带 ETag 能力的实现。
func (fs versionedFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	f, err := fs.fs.OpenFile(ctx, name, flag, perm)
	if err != nil {
		return nil, err
	}
	return &versionedFile{File: f, name: name, fs: fs}, nil
}

// RemoveAll 删除文件或目录。
func (fs versionedFS) RemoveAll(ctx context.Context, name string) error {
	return fs.fs.RemoveAll(ctx, name)
}

// Rename 重命名/移动资源。
func (fs versionedFS) Rename(ctx context.Context, oldName, newName string) error {
	return fs.fs.Rename(ctx, oldName, newName)
}

// Stat 返回文件信息，包装后的 FileInfo 实现 webdav.ETager。
func (fs versionedFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	fi, err := fs.fs.Stat(ctx, name)
	if err != nil {
		return nil, err
	}
	return versionedInfo{FileInfo: fi, name: name, fs: fs}, nil
}

// versionedFile 包装 webdav.File，使 Stat/Readdir 返回的
// FileInfo 也携带 blob hash ETag。
type versionedFile struct {
	webdav.File
	name string
	fs   versionedFS
}

// Stat 返回包装后的 FileInfo。
func (f *versionedFile) Stat() (os.FileInfo, error) {
	fi, err := f.File.Stat()
	if err != nil {
		return nil, err
	}
	return versionedInfo{FileInfo: fi, name: f.name, fs: f.fs}, nil
}

// Readdir 列出目录项，逐项包装成带 ETag 能力的 FileInfo。
func (f *versionedFile) Readdir(count int) ([]os.FileInfo, error) {
	infos, err := f.File.Readdir(count)
	if err != nil {
		return nil, err
	}
	out := make([]os.FileInfo, len(infos))
	for i, fi := range infos {
		out[i] = versionedInfo{FileInfo: fi, name: path.Join(f.name, fi.Name()), fs: f.fs}
	}
	return out, nil
}

// versionedInfo 包装 os.FileInfo 并实现 webdav.ETager：
// 普通文件的 ETag 取工作区内容的 git blob hash（带引号，符合 getetag 格式）。
type versionedInfo struct {
	os.FileInfo
	name string
	fs   versionedFS
}

// ETag 返回 `"<blob hash>"`。
//
// 请求路径经 blobPath 归一后叠加 offset（挂载根相对仓库根的偏移）得到仓库内
// 相对路径；offset 为空时与仓库根路径一致。
//
// 目录与非普通文件不适合内容哈希，返回 webdav.ErrNotImplemented，
// 由调用方回退到默认实现（mtime+size 启发式）；此时 getetag 属性
// 也不会向 DAV collection 广告。
func (info versionedInfo) ETag(ctx context.Context) (string, error) {
	if info.fs.repo == nil || info.FileInfo.IsDir() || !info.FileInfo.Mode().IsRegular() {
		return "", webdav.ErrNotImplemented
	}

	hash, err := info.fs.repo.BlobHash(path.Join(info.fs.offset, blobPath(info.name)))
	if err != nil {
		return "", err
	}
	if hash == "" {
		return "", webdav.ErrNotImplemented
	}
	return `"` + hash + `"`, nil
}

// blobPath 把 webdav 的请求路径（以 "/" 开头，可能含 ".."）规范化为
// 仓库内的相对路径。
func blobPath(name string) string {
	return strings.TrimPrefix(path.Clean("/"+name), "/")
}
