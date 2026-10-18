// 本文件实现对外公开出口的访问策略：只读、扩展名白名单与点路径拒绝。
//
// 策略以 webdav.FileSystem 包装的方式叠加在裸 webdav.Dir 之上：读操作
// （只读 OpenFile、Stat）始终放行，写操作按策略拒绝。原有的 NewHandler /
// VersionedHandler 签名与行为保持不变，本文件仅新增 ReadOnlyFS、
// ExtWhitelistFS、dotPathFS 与组合入口 NewPolicyHandler。
package webdav

import (
	"context"
	"fmt"
	"net/http"
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

// errDotPath 构造点路径（.git 段或隐藏段）访问被拒时的错误。
// 包裹 os.ErrPermission：一是让调用方可用 errors.Is(err, os.ErrPermission) 判定，
// 二是让 webdav 自身的 PROPFIND 遍历把它当成「无权限，静默跳过」（见
// golang.org/x/net/webdav 的 handlePropfindError），从而不中断整个 Multi-Status。
func errDotPath(name string) error {
	return fmt.Errorf("对外出口拒绝访问点路径 %q（含 .git 段或以 '.' 开头的段）: %w", name, os.ErrPermission)
}

// hasDotSegment 判断 WebDAV 请求路径是否含「点段」。
//
// 判定口径与 internal/registry 的 normalizeResourcePath 一致：
//   - 先折叠路径（去前导斜杠、合并重复斜杠、折叠 "."）：使 "/a.org"、"//a.org"、
//     "/./a.org" 这类等价写法得到同一结论，避免「多写一个 './' 就绕过策略」；
//   - 折叠后任一段为 .git（大小写不敏感，兼顾大小写不敏感的卷）或以 '.' 开头
//     （隐藏文件/隐藏目录）即视为点路径。
//
// 挂载根本身（"" 或 "/"）折叠后为空串，不算点路径——否则 PROPFIND 根目录会被拒。
func hasDotSegment(name string) bool {
	slashed := filepath.ToSlash(name)
	clean := strings.TrimPrefix(path.Clean("/"+slashed), "/")
	if clean == "" {
		return false
	}
	for _, seg := range strings.Split(clean, "/") {
		if strings.EqualFold(seg, ".git") || strings.HasPrefix(seg, ".") {
			return true
		}
	}
	return false
}

// dotPathFS 包装一个 webdav.FileSystem，拒绝一切落在「点路径」上的访问：
// .git 内部目录（可泄露 remote URL、可破坏版本库）与隐藏文件/隐藏目录（编辑器
// 缓存、工具配置，不属于笔记内容）。规则与 registry 的 normalizeResourcePath
// 同口径，使「登记可接受的路径集」与「出口可访问的路径集」保持一致。
//
// 读写一律拒绝：读 .git/config 会泄露 remote URL 与凭据配置，读隐藏文件会泄露
// 服务端工具链细节，故 OpenFile 不做读写区分——只要路径命中点段就返回权限错误。
//
// Readdir（列目录）有意不过滤：包装返回的仍是底层 webdav.File，目录内容原样列出。
// 取舍说明：过滤 Readdir 会让「列目录看到的条目」与「能 Stat 到的条目」更不一致，
// 而拒绝访问的语义应该由 Stat/OpenFile 承担；实际观感上点条目也不会出现在
// PROPFIND 响应里——webdav 的遍历对每个子项先 Stat，命中本包装的权限错误后调用
// handlePropfindError，其行为正是「静默跳过该子项」，响应仍是 207 Multi-Status，
// 不会因为目录里存在 .git 而报错。
type dotPathFS struct {
	fs webdav.FileSystem
}

// newDotPathFS 以底层 fs 构造点路径拒绝包装。
func newDotPathFS(fs webdav.FileSystem) dotPathFS {
	return dotPathFS{fs: fs}
}

// Mkdir 拒绝在点路径上创建目录（如 MKCOL /.git）。
func (fs dotPathFS) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	if hasDotSegment(name) {
		return errDotPath(name)
	}
	return fs.fs.Mkdir(ctx, name, perm)
}

// OpenFile 对点路径一律拒绝——读写都不放行（读 .git/config 会泄露 remote URL）。
func (fs dotPathFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if hasDotSegment(name) {
		return nil, errDotPath(name)
	}
	return fs.fs.OpenFile(ctx, name, flag, perm)
}

// RemoveAll 拒绝删除点路径（含 DELETE /.git 这类整棵删除）。
func (fs dotPathFS) RemoveAll(ctx context.Context, name string) error {
	if hasDotSegment(name) {
		return errDotPath(name)
	}
	return fs.fs.RemoveAll(ctx, name)
}

// Rename 对源与目标都做点路径检查：既禁止「写进点路径」（MOVE /a.org → /.git/x），
// 也禁止「从点路径移出」（MOVE /.git/config → /leak.org）。
func (fs dotPathFS) Rename(ctx context.Context, oldName, newName string) error {
	if hasDotSegment(oldName) {
		return errDotPath(oldName)
	}
	if hasDotSegment(newName) {
		return errDotPath(newName)
	}
	return fs.fs.Rename(ctx, oldName, newName)
}

// Stat 拒绝点路径的元信息查询（PROPFIND/GET/HEAD 的入口都会先 Stat）。
func (fs dotPathFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	if hasDotSegment(name) {
		return nil, errDotPath(name)
	}
	return fs.fs.Stat(ctx, name)
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
//
// 注意：本函数不含点路径拒绝，点路径包装（dotPathFS）由版本化链路在 wrapVersionedFS
// 之前单独套一层（见 newPolicyVersionedHandlerWithRegistry）；NewPolicyHandler 不带
// 版本化，其行为保持不变。
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
//
// 警告：本入口不含点路径与软链守卫，生产请使用 ...WithRegistry 变体
// （NewPolicyVersionedHandlerWithRegistry 会叠加 dotPathFS 与 symlinkGuardFS）。
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
// offset 为挂载根 root 相对 git 仓库根（repo root）的偏移，形如 "public"；空串
// 表示 root 即仓库根（内部端点与「Public == 笔记根」的场景）。对外出口挂载在
// 笔记根的子目录时，请求路径是「挂载根相对路径」而 BlobHash/索引 key 需要
// 「仓库内相对路径」，故必须以 offset 前缀补齐，否则 ETag 会解析到仓库中不存在
// 的路径（blob hash 为空、getetag 退化为 mtime 启发式），索引 key 也会与内部
// 端点（以仓库根为基准）错位冲突。
//
// 策略包装位于版本化包装之内层：只读出口的写操作仍最先被拒；随后 commit 钩子对
// 无变更工作区为 no-op，不产生空提交，索引钩子对非 2xx 响应直接跳过。repo /
// indexer 为 nil 时对应环节自动跳过；opts 为零值时等价于无访问策略
// （与 VersionedHandlerWithIndex 行为一致）。
//
// 无论 opts 如何取值，本入口都会叠加点路径拒绝（dotPathFS）与软链守卫
// （symlinkGuardFS）：.git 与隐藏文件/隐藏目录既不可读也不可写，请求路径的
// 父链或目标自身含符号链接时也一律拒绝（详见 dotPathFS / symlinkGuardFS 的说明）。
func NewPolicyVersionedHandler(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions, repo *gitver.Repo, indexer *index.Indexer, prefix, offset string) http.Handler {
	return newPolicyVersionedHandler(root, authenticator, source, opts, repo, indexer, prefix, offset)
}

// NewPolicyVersionedHandlerWithRegistry 在 NewPolicyVersionedHandler 的基础上，额外
// 把成功的写操作登记进 registry（resources + changes，详见 registryAfterWrite）。
//
// 处理链（外层 → 内层）：
//
//	认证 → 全文索引 → 身份登记 → git commit → WebDAV
//
// 身份登记位于 commit 之外层，故 rev 取 commit 之后的 HEAD；位于索引内层，故索引
// 仍在登记之后更新。reg 为 nil 时行为与 NewPolicyVersionedHandler 完全一致；
// 日志根标签取 reg 的首根（调用前需先 SetRoots）。
//
// 其余参数语义（root / opts / prefix / offset / repo / indexer）与
// NewPolicyVersionedHandler 完全一致：对外出口挂在笔记根子目录时必须传 offset
// （如 "public"），否则 ETag、索引 key 与登记路径都会错位。
func NewPolicyVersionedHandlerWithRegistry(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions, repo *gitver.Repo, indexer *index.Indexer, reg *registry.Service, prefix, offset string) http.Handler {
	return newPolicyVersionedHandlerWithRegistry(root, authenticator, source, opts,
		repo, indexer, reg, prefix, offset, firstRootTag(reg))
}

// newPolicyVersionedHandler 是 NewPolicyVersionedHandler 与 VersionedHandlerWithIndex
// 的共享实现：组装「认证 → 可选策略 → 版本化 FS → 写后 commit → 全文索引」处理链。
// offset 为挂载根相对仓库根的偏移，透传给 versionedFS 与索引钩子。
func newPolicyVersionedHandler(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions, repo *gitver.Repo, indexer *index.Indexer, prefix, offset string) http.Handler {
	return newPolicyVersionedHandlerWithRegistry(root, authenticator, source, opts, repo, indexer, nil, prefix, offset, "")
}

// newPolicyVersionedHandlerWithRegistry 是带身份登记的共享实现：在 commit 钩子外层
// 插入 registryAfterWrite（rootTag 为登记使用的逻辑根标签），索引钩子保持在最外层。
// reg 为 nil 时不插入登记钩子，处理链与 newPolicyVersionedHandler 逐层一致。
//
// 文件系统包装顺序（内 → 外）：
//
//	webdav.Dir → 扩展名白名单 → 只读 → symlinkGuardFS → dotPathFS → versionedFS
//
// dotPathFS 位于 policyFS 之上、versionedFS 之下：点路径在最靠近盘面的策略层就被
// 拒绝，且必须先于版本化包装——否则 versionedFS.Stat 会把 ETag 计算（blob hash）
// 作用到 .git 内部路径上。只读与白名单语义不变：只读仍在最内层最先拒绝写操作。
//
// symlinkGuardFS 夹在策略层与 dotPathFS 之间（绑定同一个物理根 root）：点路径
// 检查是纯字符串判断、成本更低，故放在更外层先拒；软链接检查才需要打盘（逐级
// Lstat）。它同时位于 versionedFS 之内，避免 ETag 计算作用到软链路径上。裸
// webdav.Dir 会跟随软链，若无这一层，根内一条 leak -> /etc/passwd 就能读写根外
// 文件（详见 symlink.go 文件头）。
func newPolicyVersionedHandlerWithRegistry(root string, authenticator *auth.Authenticator, source Source, opts PolicyOptions, repo *gitver.Repo, indexer *index.Indexer, reg *registry.Service, prefix, offset, rootTag string) http.Handler {
	fs := wrapVersionedFS(newDotPathFS(newSymlinkGuardFS(policyFS(root, opts), root)), repo, offset)
	inner := commitAfterWrite(source, repo, newDAVHandler(prefix, fs))
	if reg != nil {
		// 登记钩子包在 commit 外层（拿到 commit 后的 HEAD），索引钩子再包其外层。
		inner = registryAfterWrite(rootTag, prefix, offset, reg, repo, inner)
	}
	return authenticator.Middleware(indexAfterWrite(root, prefix, offset, indexer, inner))
}
