// 本文件实现对外 WebDAV 出口的符号链接守卫（symlinkGuardFS）。
//
// 背景：golang.org/x/net/webdav 的 webdav.Dir 明确不做符号链接检查（其类型文档
// 写着 "Dir does not prevent traversal of symbolic links within its directory
// tree, including links that reference locations outside of the tree"）。因此只要
// 挂载根内存在一条指向根外的软链（如 leak -> /etc/passwd），GET 就会读到根外
// 文件、PUT 就会改写根外文件、DELETE 会删掉根外目标、MOVE 还会借软链把内容搬到
// 别处。策略包装层（只读 / 扩展名白名单 / 点路径）只看请求路径的字符串形态，
// 同样拦不住这条路径。
//
// 本包装按「逐级 Lstat，遇到软链即拒」的口径，把软链从出口可达路径集中彻底剔除：
// 不区分软链指向根内还是根外，只要请求路径的父链或目标自身含软链就拒绝。这比
// internal/api 的 physicalPathChecked 更严（后者允许「父链软链解析后仍在根内」），
// 属于有意收紧：规则更简单、可机械验证，且不会因为日后根内新增软链而放宽。
//
// 错误一律包裹 os.ErrPermission，用途有二：一是调用方可用
// errors.Is(err, os.ErrPermission) 判定；二是 webdav 自身的 PROPFIND 遍历对每个
// 子项先 Stat，命中权限错误后由 handlePropfindError 把它当成「无权限，静默跳过
// 该子项」，响应仍是 207 Multi-Status，不会因为根内存在软链而整棵目录列举失败。
package webdav

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/net/webdav"
)

// symlinkGuardFS 包装任意 webdav.FileSystem，并绑定一个物理根：请求路径的
// 父链或目标自身只要含有符号链接，读与写一律拒绝。
//
// Readdir（列目录）有意不在此处过滤：OpenFile 返回的仍是底层 webdav.File，
// 目录内容原样列出。拒绝的语义由 Stat / OpenFile 承担——webdav 遍历时对每个
// 子项先 Stat，命中权限错误就静默跳过，故被拒条目不会出现在 PROPFIND 响应里。
type symlinkGuardFS struct {
	fs   webdav.FileSystem
	root string // 已 EvalSymlinks 的绝对路径
}

// newSymlinkGuardFS 返回在 root 内拒绝符号链接的文件系统包装。
// root 在构造时经 filepath.EvalSymlinks 归一（部署根常是软链）。
//
// 归一失败（根尚不存在、或中间段无权限）时退化为 filepath.Abs 的结果：此时
// 逐级 Lstat 会在第一个不存在的段处停下并放行，与「路径看起来还不存在」的
// 既有语义一致，不会因为一次失败的解析把整棵出口锁死。
func newSymlinkGuardFS(fs webdav.FileSystem, root string) symlinkGuardFS {
	base, err := filepath.Abs(root)
	if err != nil {
		base = filepath.Clean(root)
	}
	if resolved, err := filepath.EvalSymlinks(base); err == nil {
		base = resolved
	}
	return symlinkGuardFS{fs: fs, root: base}
}

// errSymlinkBlocked 构造「请求路径含符号链接」的拒绝错误。
// 包裹 os.ErrPermission 的原因见文件头注释（PROPFIND 静默跳过 + errors.Is 判定）。
// 错误信息只带请求路径，不带物理路径——后者属服务端部署细节。
func errSymlinkBlocked(name string) error {
	return fmt.Errorf("对外出口拒绝跟随符号链接 %q（父链或目标自身是软链）: %w", name, os.ErrPermission)
}

// cleanRel 把 WebDAV 请求路径折叠成挂载根相对路径（无前导斜杠、无 ".."、无重复斜杠）。
//
// 折叠口径与 webdav.Dir.resolve 一致（都先 path.Clean("/"+name)），保证「检查的
// 路径」与「实际打开的路径」是同一个：否则 "/./a.org"、"//a.org" 这类等价写法
// 可能与检查口径错位，形成绕过。
func cleanRel(name string) string {
	clean := strings.TrimPrefix(path.Clean("/"+filepath.ToSlash(name)), "/")
	if clean == "." {
		return ""
	}
	return clean
}

// checkPath 校验 name（挂载根相对路径，可含前导 "/"）：
//  1. 逐级检查父目录链：任何一级是符号链接 → 拒绝（无论指向根内还是根外）；
//  2. 目标自身若存在且为符号链接 → 拒绝。
//
// 返回 os.ErrPermission 包装的错误。
//
// 实现：从 fs.root 起把折叠后的每一段依次拼上并 os.Lstat（不跟随），任何一段
// 的 Mode 含 os.ModeSymlink 即拒。遇到不存在的段立即停止：该段之后的段必然也
// 不存在（目录都还没建），而 PUT 新建深层路径时父目录由 MKCOL 逐级创建，届时
// 新路径的每一段都真实存在、会被下一次请求重新校验。
//
// 不做 EvalSymlinks 前缀比对：本口径不含任何软链中间段，故「解析后仍在根内」
// 这类情况也在拒绝之列，无需再算真实路径。
func (fs symlinkGuardFS) checkPath(name string) error {
	rel := cleanRel(name)
	if rel == "" {
		// 挂载根本身在构造时已 EvalSymlinks，天然不是软链，无需逐段检查。
		return nil
	}
	cur := fs.root
	for _, seg := range strings.Split(rel, "/") {
		cur = filepath.Join(cur, seg)
		info, err := os.Lstat(cur)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return nil
			}
			// 其他错误（EACCES、EINVAL、IO 故障）无法确认链路是否安全，保守拒绝。
			return fmt.Errorf("对外出口无法校验路径 %q 的父链，保守拒绝（%v）: %w",
				name, err, os.ErrPermission)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errSymlinkBlocked(name)
		}
	}
	return nil
}

// Mkdir 在创建目录前校验路径（如 MKCOL /leak，leak 是指向根外的软链）。
func (fs symlinkGuardFS) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	if err := fs.checkPath(name); err != nil {
		return err
	}
	return fs.fs.Mkdir(ctx, name, perm)
}

// OpenFile 在读与写两种模式下都校验路径：读会读到根外内容（软链跟随），
// 写会改掉根外文件（os.OpenFile 跟随软链），二者都必须拦。
func (fs symlinkGuardFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if err := fs.checkPath(name); err != nil {
		return nil, err
	}
	return fs.fs.OpenFile(ctx, name, flag, perm)
}

// RemoveAll 在删除前校验路径：os.RemoveAll 对软链本身只删链接，但经软链的
// 父目录进入（如 /alias/x，alias -> 根外目录）会删掉根外内容，故同样要拦。
func (fs symlinkGuardFS) RemoveAll(ctx context.Context, name string) error {
	if err := fs.checkPath(name); err != nil {
		return err
	}
	return fs.fs.RemoveAll(ctx, name)
}

// Rename 对源与目标都做软链检查：既禁止「把内容写进软链」（MOVE /a.org → /leak），
// 也禁止「从软链移出」（MOVE /leak → /b.org）。
func (fs symlinkGuardFS) Rename(ctx context.Context, oldName, newName string) error {
	if err := fs.checkPath(oldName); err != nil {
		return err
	}
	if err := fs.checkPath(newName); err != nil {
		return err
	}
	return fs.fs.Rename(ctx, oldName, newName)
}

// Stat 在返回元信息前校验路径：PROPFIND/GET/HEAD 的入口都会先 Stat，且 webdav
// 的 MOVE/COPY 也会先 Stat 源与目标——在此拦截可让这些路径尽早被拒。
func (fs symlinkGuardFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	if err := fs.checkPath(name); err != nil {
		return nil, err
	}
	return fs.fs.Stat(ctx, name)
}
