// 本文件实现对外公开出口的访问策略：只读与扩展名白名单。
//
// 策略以 webdav.FileSystem 包装的方式叠加在裸 webdav.Dir 之上：读操作
// （只读 OpenFile、Stat）始终放行，写操作按策略拒绝。原有的 NewHandler /
// VersionedHandler 签名与行为保持不变，本文件仅新增 ReadOnlyFS、
// ExtWhitelistFS 与组合入口 NewPolicyHandler。
package webdav

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/net/webdav"

	"notes/internal/auth"
	"notes/internal/gitver"
	"notes/internal/index"
)

// isWriteFlag 判断 OpenFile 的 flag 是否含写意图。
//
// os.O_RDONLY 为 0，因此不能只凭「非 0」判断；这里显式覆盖所有需要写盘的
// 标志位（写方向、追加、创建、截断），只读打开（O_RDONLY）返回 false。
func isWriteFlag(flag int) bool {
	return flag&(os.O_WRONLY|os.O_RDWR|os.O_APPEND|os.O_CREATE|os.O_TRUNC) != 0
}

// errReadOnly 构造只读策略拒绝写操作的错误。
// 包裹 os.ErrPermission，使调用方可用 errors.Is(err, os.ErrPermission) 判定。
func errReadOnly(name string) error {
	return fmt.Errorf("对外出口为只读，拒绝写操作 %q: %w", name, os.ErrPermission)
}

// ReadOnlyFS 包装一个 webdav.FileSystem 使其只读：
// 写方法（OpenFile 写模式、Mkdir、RemoveAll、Rename）一律返回权限错误，
// 读方法（OpenFile 只读模式、Stat）原样透传底层实现。
type ReadOnlyFS struct {
	fs webdav.FileSystem
}

// NewReadOnlyFS 以底层 fs 构造只读包装。
func NewReadOnlyFS(fs webdav.FileSystem) ReadOnlyFS {
	return ReadOnlyFS{fs: fs}
}

// Mkdir 拒绝创建目录。
func (fs ReadOnlyFS) Mkdir(_ context.Context, name string, _ os.FileMode) error {
	return errReadOnly(name)
}

// OpenFile 只读模式下透传，写模式一律拒绝。
func (fs ReadOnlyFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if isWriteFlag(flag) {
		return nil, errReadOnly(name)
	}
	return fs.fs.OpenFile(ctx, name, flag, perm)
}

// RemoveAll 拒绝删除。
func (fs ReadOnlyFS) RemoveAll(_ context.Context, name string) error {
	return errReadOnly(name)
}

// Rename 拒绝重命名/移动。
func (fs ReadOnlyFS) Rename(_ context.Context, oldName, _ string) error {
	return errReadOnly(oldName)
}

// Stat 透传（读操作）。
func (fs ReadOnlyFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	return fs.fs.Stat(ctx, name)
}

// ExtWhitelistFS 包装一个 webdav.FileSystem，在写文件时校验目标扩展名：
// 仅当写模式 OpenFile 的目标扩展名落在白名单内才放行，否则返回权限错误；
// 读操作（只读 OpenFile、Stat、目录列举）不受限制。白名单为空表示不限制。
type ExtWhitelistFS struct {
	fs    webdav.FileSystem
	allow []string
}

// NewExtWhitelistFS 以底层 fs 与扩展名白名单 allow 构造包装。
// allow 中的元素会在构造时归一化（去空白、转小写、补前导点）后比较。
func NewExtWhitelistFS(fs webdav.FileSystem, allow []string) ExtWhitelistFS {
	return ExtWhitelistFS{fs: fs, allow: normalizeExts(allow)}
}

// Mkdir 透传（目录通常无扩展名，不纳入白名单约束）。
func (fs ExtWhitelistFS) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	return fs.fs.Mkdir(ctx, name, perm)
}

// OpenFile 在写模式下校验目标扩展名，读模式透传。
func (fs ExtWhitelistFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if isWriteFlag(flag) && !fs.allows(name) {
		return nil, errExtNotAllowed(name)
	}
	return fs.fs.OpenFile(ctx, name, flag, perm)
}

// RemoveAll 透传（删除不受扩展名限制）。
func (fs ExtWhitelistFS) RemoveAll(ctx context.Context, name string) error {
	return fs.fs.RemoveAll(ctx, name)
}

// Rename 透传。
//
// 注意：MOVE 走 Rename，本包装不对目标扩展名校验，因此理论上可把文件改名为
// 白名单外的扩展名；如需堵住该路径，应结合只读策略或在 handler 层按方法拦截。
func (fs ExtWhitelistFS) Rename(ctx context.Context, oldName, newName string) error {
	return fs.fs.Rename(ctx, oldName, newName)
}

// Stat 透传（读操作）。
func (fs ExtWhitelistFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	return fs.fs.Stat(ctx, name)
}

// allows 判断 name 的扩展名是否在白名单内；白名单为空时恒为 true。
func (fs ExtWhitelistFS) allows(name string) bool {
	if len(fs.allow) == 0 {
		return true
	}
	ext := strings.ToLower(filepath.Ext(name))
	for _, a := range fs.allow {
		if ext == a {
			return true
		}
	}
	return false
}

// errExtNotAllowed 构造扩展名不在白名单时的错误（包裹 os.ErrPermission）。
func errExtNotAllowed(name string) error {
	return fmt.Errorf("对外出口不允许写入扩展名 %q 的文件 %q: %w", filepath.Ext(name), name, os.ErrPermission)
}

// normalizeExts 归一化扩展名白名单：去首尾空白、转小写、补前导点，丢弃空项。
func normalizeExts(allow []string) []string {
	out := make([]string, 0, len(allow))
	for _, e := range allow {
		e = strings.ToLower(strings.TrimSpace(e))
		if e == "" {
			continue
		}
		if !strings.HasPrefix(e, ".") {
			e = "." + e
		}
		out = append(out, e)
	}
	return out
}

// PolicyOptions 配置对外出口的访问策略。
type PolicyOptions struct {
	// ReadOnly 为 true 时整个出口只读（所有写操作被拒）。
	ReadOnly bool
	// AllowExts 是允许写入的文件扩展名白名单（如 [".org", ".md"]），
	// 为空表示不限制扩展名。
	AllowExts []string
}

// policyFS 在裸 webdav.Dir(root) 之上按 opts 叠加访问策略包装：先扩展名白名单、
// 后只读，使只读位于最外层——只读时任何写操作都最先被拒，不依赖白名单是否命中。
// 读操作始终放行。返回的 FileSystem 可再交给版本化包装（wrapVersionedFS）叠加
// ETag 能力。
func policyFS(root string, opts PolicyOptions) webdav.FileSystem {
	var fs webdav.FileSystem = webdav.Dir(root)
	if len(opts.AllowExts) > 0 {
		fs = NewExtWhitelistFS(fs, opts.AllowExts)
	}
	if opts.ReadOnly {
		fs = NewReadOnlyFS(fs)
	}
	return fs
}

// NewPolicyHandler 构造带访问策略的对外 WebDAV handler。
//
// 在裸 webdav.Dir 之上按 PolicyOptions 叠加包装：先扩展名白名单、后只读，
// 使只读位于最外层——只读时任何写操作都最先被拒，不依赖白名单是否命中。
// 读操作始终放行。认证与来源注入链路与 NewHandler 完全一致（先认证，再注入
// 来源标记，最后交给 WebDAV 处理器）。前缀固定为默认的 davPrefix。
func NewPolicyHandler(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions) http.Handler {
	handler := newDAVHandler(davPrefix, policyFS(root, opts))
	return authenticator.Middleware(injectSource(source, handler))
}

// NewPolicyVersionedHandler 构造「访问策略 + git 版本化 + 全文索引」的对外 WebDAV
// handler：在 NewPolicyHandler 的访问策略之上叠加 versionedFS（ETag 绑定工作区
// blob hash）与写后钩子——写方法处理完成后自动提交一次工作区变更，并按方法维护
// FTS 全文索引（复用本包 commitAfterWrite / indexAfterWrite 逻辑）。
//
// prefix 为该 handler 的 URL 前缀，必须与其挂载路径一致（对外出口通常为
// "/public"）；webdav.Handler 以它剥掉请求路径前缀，并据此拼接 PROPFIND 等响应
// 中的 href，从而使 href 与真实挂载点对齐而非越界到默认的 "/dav"。
//
// 策略包装位于版本化包装之内层：只读出口的写操作仍最先被拒；随后 commit 钩子对
// 无变更工作区为 no-op，不产生空提交，索引钩子对非 2xx 响应直接跳过。repo /
// indexer 为 nil 时对应环节自动跳过；opts 为零值时等价于无访问策略
// （与 VersionedHandlerWithIndex 行为一致）。
func NewPolicyVersionedHandler(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions, repo *gitver.Repo, indexer *index.Indexer, prefix string) http.Handler {
	return newPolicyVersionedHandler(root, authenticator, source, opts, repo, indexer, prefix)
}

// newPolicyVersionedHandler 是 NewPolicyVersionedHandler 与 VersionedHandlerWithIndex
// 的共享实现：组装「认证 → 可选策略 → 版本化 FS → 写后 commit → 全文索引」处理链。
func newPolicyVersionedHandler(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions, repo *gitver.Repo, indexer *index.Indexer, prefix string) http.Handler {
	fs := wrapVersionedFS(policyFS(root, opts), repo)
	inner := commitAfterWrite(source, repo, newDAVHandler(prefix, fs))
	return authenticator.Middleware(indexAfterWrite(root, prefix, indexer, inner))
}
