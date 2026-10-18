// 本文件测试出口的符号链接守卫（symlinkGuardFS）：挂载根内任何软链（指向根外
// 或指向根内）都不得被读写删移，且正常路径与「根自身是软链」的部署形态不受影响。
//
// 断言口径（与 golang.org/x/net/webdav 的错误映射有关，详见 dotpath_test.go）：
//   - GET/HEAD 与 PUT 的 OpenFile 错误被 webdav 统一映射为 404；
//   - DELETE / MOVE 走先 Stat（MOVE 还查目标）→ 权限错误映射为非 2xx；
//   - PROPFIND 遍历对每个子项先 Stat，命中权限错误后静默跳过子项，响应仍是 207。
//
// 因此 HTTP 层一律断言「非 2xx + 外部文件未被读写」，不硬编码具体状态码；
// 文件系统层则直接断言 errors.Is(err, os.ErrPermission)。
package webdav

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/net/webdav"
)

// mustSymlink 创建符号链接；平台不支持时跳过用例（Windows 非管理员账户常见）。
func mustSymlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("创建符号链接 %s -> %s 失败（平台可能不支持）: %v", link, target, err)
	}
}

// mustMkdir 创建测试目录，失败即终止测试。
func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("创建目录 %s 失败: %v", path, err)
	}
}

// TestSymlinkGuardFSRejectsSymlinkFile 验证根内软链 leak -> 根外文件时，
// 读、写、删、Stat、Mkdir、两个方向的 Rename 全部被拒，且外部文件毫发无损。
func TestSymlinkGuardFSRejectsSymlinkFile(t *testing.T) {
	const secret = "SECRET\n"
	root := t.TempDir()
	outsideDir := t.TempDir()
	outsidePath := filepath.Join(outsideDir, "outside.txt")
	if err := os.WriteFile(outsidePath, []byte(secret), 0o644); err != nil {
		t.Fatalf("写入根外文件失败: %v", err)
	}
	mustWriteFile(t, root, "a.org", "* a\n")
	mustSymlink(t, outsidePath, filepath.Join(root, "leak"))

	fs := newSymlinkGuardFS(webdav.Dir(root), root)
	ctx := context.Background()

	// GET（只读 OpenFile）：不得跟随软链读到根外内容。
	if _, err := fs.OpenFile(ctx, "/leak", os.O_RDONLY, 0); !errors.Is(err, os.ErrPermission) {
		t.Errorf("只读 OpenFile(/leak) err = %v, 期望 os.ErrPermission", err)
	}
	// PUT（写模式 OpenFile）：不得改写根外文件。
	if _, err := fs.OpenFile(ctx, "/leak", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644); !errors.Is(err, os.ErrPermission) {
		t.Errorf("写 OpenFile(/leak) err = %v, 期望 os.ErrPermission", err)
	}
	// DELETE。
	if err := fs.RemoveAll(ctx, "/leak"); !errors.Is(err, os.ErrPermission) {
		t.Errorf("RemoveAll(/leak) err = %v, 期望 os.ErrPermission", err)
	}
	// Stat（PROPFIND/HEAD 的入口）。
	if _, err := fs.Stat(ctx, "/leak"); !errors.Is(err, os.ErrPermission) {
		t.Errorf("Stat(/leak) err = %v, 期望 os.ErrPermission", err)
	}
	// MKCOL。
	if err := fs.Mkdir(ctx, "/leak", 0o755); !errors.Is(err, os.ErrPermission) {
		t.Errorf("Mkdir(/leak) err = %v, 期望 os.ErrPermission", err)
	}
	// MOVE a.org -> leak（目标是软链）：源文件不得被搬走或覆盖根外文件。
	if err := fs.Rename(ctx, "/a.org", "/leak"); !errors.Is(err, os.ErrPermission) {
		t.Errorf("Rename(/a.org → /leak) err = %v, 期望 os.ErrPermission（目标检查）", err)
	}
	// MOVE leak -> b.org（源是软链）：内容不得被导出到根内。
	if err := fs.Rename(ctx, "/leak", "/b.org"); !errors.Is(err, os.ErrPermission) {
		t.Errorf("Rename(/leak → /b.org) err = %v, 期望 os.ErrPermission（源检查）", err)
	}

	// 外部文件未被读/写/删。
	raw, err := os.ReadFile(outsidePath)
	if err != nil {
		t.Fatalf("根外文件应仍存在: %v", err)
	}
	if string(raw) != secret {
		t.Errorf("根外文件内容 = %q, 期望原样 %q", string(raw), secret)
	}
	// 根内源文件仍在，目标未生成。
	if _, err := os.Stat(filepath.Join(root, "a.org")); err != nil {
		t.Errorf("被拒的 MOVE 不应移走 a.org: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "b.org")); !os.IsNotExist(err) {
		t.Errorf("b.org 不应被创建，实际 stat 错误: %v", err)
	}
}

// TestSymlinkGuardFSParentSymlinkToOutsideRejected 验证父目录软链 alias -> 根外目录时，
// /alias/x 的读与写都被拒，且根外文件内容不变。
func TestSymlinkGuardFSParentSymlinkToOutsideRejected(t *testing.T) {
	const secret = "SECRET\n"
	root := t.TempDir()
	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "x.org")
	if err := os.WriteFile(outsideFile, []byte(secret), 0o644); err != nil {
		t.Fatalf("写入根外文件失败: %v", err)
	}
	mustSymlink(t, outsideDir, filepath.Join(root, "alias"))

	fs := newSymlinkGuardFS(webdav.Dir(root), root)
	ctx := context.Background()

	// GET /alias/x.org。
	if _, err := fs.OpenFile(ctx, "/alias/x.org", os.O_RDONLY, 0); !errors.Is(err, os.ErrPermission) {
		t.Errorf("只读 OpenFile(/alias/x.org) err = %v, 期望 os.ErrPermission", err)
	}
	// PUT /alias/x.org（新建 + 覆盖两种意图都不得穿出根）。
	if _, err := fs.OpenFile(ctx, "/alias/x.org", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644); !errors.Is(err, os.ErrPermission) {
		t.Errorf("写 OpenFile(/alias/x.org) err = %v, 期望 os.ErrPermission", err)
	}
	// 更深一层的不存在子路径同样被父链上的软链挡住。
	if _, err := fs.OpenFile(ctx, "/alias/new/deep.org", os.O_WRONLY|os.O_CREATE, 0o644); !errors.Is(err, os.ErrPermission) {
		t.Errorf("写 OpenFile(/alias/new/deep.org) err = %v, 期望 os.ErrPermission（父链软链）", err)
	}
	// 目录本身的 Stat 也被拒（否则 PROPFIND 会列出根外目录内容）。
	if _, err := fs.Stat(ctx, "/alias"); !errors.Is(err, os.ErrPermission) {
		t.Errorf("Stat(/alias) err = %v, 期望 os.ErrPermission", err)
	}

	// 根外文件内容不变，且没有新增文件。
	raw, err := os.ReadFile(outsideFile)
	if err != nil {
		t.Fatalf("根外文件应仍存在: %v", err)
	}
	if string(raw) != secret {
		t.Errorf("根外文件内容 = %q, 期望原样 %q", string(raw), secret)
	}
	if _, err := os.Stat(filepath.Join(outsideDir, "new")); !os.IsNotExist(err) {
		t.Errorf("根外目录不应出现 new/，实际 stat 错误: %v", err)
	}
}

// TestSymlinkGuardFSParentSymlinkInsideRootRejected 验证父目录软链即使指向根内
// （alias -> real）也被拒：本守卫的口径是「路径不含任何软链中间段」，比
// internal/api 的「解析后仍在根内」更严，避免日后根内软链被换指向而失守。
func TestSymlinkGuardFSParentSymlinkInsideRootRejected(t *testing.T) {
	const content = "* 根内内容\n"
	root := t.TempDir()
	mustMkdir(t, filepath.Join(root, "real"))
	mustWriteFile(t, root, "real/x.org", content)
	mustSymlink(t, filepath.Join(root, "real"), filepath.Join(root, "alias"))

	fs := newSymlinkGuardFS(webdav.Dir(root), root)
	ctx := context.Background()

	if _, err := fs.OpenFile(ctx, "/alias/x.org", os.O_RDONLY, 0); !errors.Is(err, os.ErrPermission) {
		t.Errorf("只读 OpenFile(/alias/x.org) err = %v, 期望 os.ErrPermission（父链软链指向根内也拒）", err)
	}
	if _, err := fs.OpenFile(ctx, "/alias/x.org", os.O_WRONLY|os.O_TRUNC, 0o644); !errors.Is(err, os.ErrPermission) {
		t.Errorf("写 OpenFile(/alias/x.org) err = %v, 期望 os.ErrPermission", err)
	}
	if err := fs.RemoveAll(ctx, "/alias/x.org"); !errors.Is(err, os.ErrPermission) {
		t.Errorf("RemoveAll(/alias/x.org) err = %v, 期望 os.ErrPermission", err)
	}

	// 直连真实目录的路径仍放行（守卫只针对软链，不针对根内路径）。
	if _, err := fs.Stat(ctx, "/real/x.org"); err != nil {
		t.Errorf("Stat(/real/x.org) 应放行，实际错误: %v", err)
	}
	// 被拒的写没有改动根内文件。
	raw, err := os.ReadFile(filepath.Join(root, "real", "x.org"))
	if err != nil {
		t.Fatalf("读取根内文件失败: %v", err)
	}
	if string(raw) != content {
		t.Errorf("根内文件内容 = %q, 期望原样 %q", string(raw), content)
	}
}

// TestSymlinkGuardFSAllowsNormalPaths 验证无软链的正常路径全部放行：
// 已存在的文件、子目录内文件、以及尚不存在的深层路径（其父目录还没建）。
func TestSymlinkGuardFSAllowsNormalPaths(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "a.org", "* a\n")
	mustMkdir(t, filepath.Join(root, "sub"))
	mustWriteFile(t, root, "sub/b.org", "* b\n")

	fs := newSymlinkGuardFS(webdav.Dir(root), root)
	ctx := context.Background()

	// 等价写法都要放行（折叠口径与 webdav.Dir.resolve 一致）。
	for _, name := range []string{"a.org", "/a.org", "//a.org", "/./a.org", "sub/b.org", "/sub//b.org", "", "/"} {
		if err := fs.checkPath(name); err != nil {
			t.Errorf("checkPath(%q) = %v, 期望放行", name, err)
		}
	}

	// 已存在的文件：Stat 与只读 OpenFile 都必须真的成功。
	if _, err := fs.Stat(ctx, "/sub/b.org"); err != nil {
		t.Errorf("Stat(/sub/b.org) 应成功，实际错误: %v", err)
	}
	f, err := fs.OpenFile(ctx, "/a.org", os.O_RDONLY, 0)
	if err != nil {
		t.Fatalf("只读 OpenFile(/a.org) 应成功，实际错误: %v", err)
	}
	_ = f.Close()

	// 尚不存在的深层路径：checkPath 放行（遇到不存在的段就停止），
	// Stat 返回「不存在」而非权限错误——否则 PUT 新建深层路径会被误拒。
	for _, name := range []string{"/new", "/new/dir", "/new/dir/c.org"} {
		if err := fs.checkPath(name); err != nil {
			t.Errorf("checkPath(%q) = %v, 期望放行（父目录尚未创建）", name, err)
		}
		if _, err := fs.Stat(ctx, name); errors.Is(err, os.ErrPermission) {
			t.Errorf("Stat(%q) 返回权限错误，期望 os.ErrNotExist 类错误", name)
		}
	}

	// 逐级创建后写入正常路径仍成功（PUT 建父目录的真实流程）。
	mustMkdir(t, filepath.Join(root, "new", "dir"))
	if _, err := fs.OpenFile(ctx, "/new/dir/c.org", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644); err != nil {
		t.Errorf("写 OpenFile(/new/dir/c.org) 应放行，实际错误: %v", err)
	}
}

// TestSymlinkGuardFSRootIsSymlink 验证部署根自身是软链时（A/root -> B）正常路径
// 仍放行：构造时 EvalSymlinks 把根归一，检查基准因此与真实目录一致。
func TestSymlinkGuardFSRootIsSymlink(t *testing.T) {
	realRoot := t.TempDir()
	mustWriteFile(t, realRoot, "a.org", "* a\n")
	linkParent := t.TempDir()
	linkRoot := filepath.Join(linkParent, "root")
	mustSymlink(t, realRoot, linkRoot)

	fs := newSymlinkGuardFS(webdav.Dir(linkRoot), linkRoot)

	wantRoot, err := filepath.EvalSymlinks(linkRoot)
	if err != nil {
		t.Fatalf("EvalSymlinks(%s) 失败: %v", linkRoot, err)
	}
	if fs.root != wantRoot {
		t.Errorf("守卫根 = %q, 期望归一后的 %q", fs.root, wantRoot)
	}

	ctx := context.Background()
	if _, err := fs.Stat(ctx, "/a.org"); err != nil {
		t.Errorf("Stat(/a.org) 经软链根应放行，实际错误: %v", err)
	}
	// 读写也需要真的落到 B 上。
	if err := fs.Mkdir(ctx, "/sub", 0o755); err != nil {
		t.Fatalf("Mkdir(/sub) 经软链根应放行，实际错误: %v", err)
	}
	f, err := fs.OpenFile(ctx, "/sub/b.org", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatalf("写 OpenFile(/sub/b.org) 经软链根应放行，实际错误: %v", err)
	}
	_ = f.Close()
	if _, err := os.Stat(filepath.Join(realRoot, "sub", "b.org")); err != nil {
		t.Errorf("文件应落在真实根 %s 下: %v", realRoot, err)
	}
}

// TestSymlinkGuardHTTPRejectsSymlinkPaths 通过完整 handler 链（认证 → 索引 →
// 登记 → commit → WebDAV，含 dotPathFS + symlinkGuardFS + versionedFS）验证：
// 经软链的 GET/PUT/DELETE/MOVE 全部非 2xx，且根外文件未创建、未泄露。
func TestSymlinkGuardHTTPRejectsSymlinkPaths(t *testing.T) {
	const secret = "SECRET\n"
	root := t.TempDir()
	mustWriteFile(t, root, "a.org", "* a\n")
	outsideDir := t.TempDir()
	outsideSecret := filepath.Join(outsideDir, "leak.txt")
	if err := os.WriteFile(outsideSecret, []byte(secret), 0o644); err != nil {
		t.Fatalf("写入根外文件失败: %v", err)
	}
	// link -> 根外目录：既可读根外文件，也可在根外建文件。
	mustSymlink(t, outsideDir, filepath.Join(root, "link"))
	base, _, _, _ := newRegistryServer(t, root)

	// GET 经软链：非 2xx，且响应体不含根外内容。
	resp := doRequest(t, http.MethodGet, base+davPrefix+"/link/leak.txt", "", basicAuthHeader(testToken))
	body, readErr := io.ReadAll(resp.Body)
	resp.Body.Close()
	if readErr != nil {
		t.Fatalf("读取响应体失败: %v", readErr)
	}
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("GET /link/leak.txt 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if strings.Contains(string(body), "SECRET") {
		t.Errorf("GET /link/leak.txt 泄露了根外内容:\n%s", string(body))
	}

	// PUT 经软链（目标目录是软链，且该子路径还不存在）：非 2xx 且根外无新文件。
	resp = doRequest(t, http.MethodPut, base+davPrefix+"/link/x.org", "* 越界\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("PUT /link/x.org 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(outsideDir, "x.org")); !os.IsNotExist(err) {
		t.Errorf("根外 x.org 不应被创建，实际 stat 错误: %v", err)
	}

	// DELETE 经软链：非 2xx，根外文件仍在。
	resp = doRequest(t, http.MethodDelete, base+davPrefix+"/link/leak.txt", "", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("DELETE /link/leak.txt 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(outsideSecret); err != nil {
		t.Errorf("根外文件不应被删除: %v", err)
	}

	// MOVE 到软链：非 2xx，源仍在、根外文件内容不变。
	resp = doMethod(t, "MOVE", base+davPrefix+"/a.org", base+davPrefix+"/link/leak.txt")
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("MOVE a.org → /link/leak.txt 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, "a.org")); err != nil {
		t.Errorf("被拒的 MOVE 不应移走 a.org: %v", err)
	}
	raw, err := os.ReadFile(outsideSecret)
	if err != nil {
		t.Fatalf("根外文件应仍存在: %v", err)
	}
	if string(raw) != secret {
		t.Errorf("根外文件内容 = %q, 期望原样 %q", string(raw), secret)
	}
}

// TestSymlinkGuardPropfindSkipsSymlinkEntry 验证根内存在软链不影响目录列举：
// PROPFIND / 仍是 207，正常文件可见，软链条目被 webdav 静默跳过（权限错误语义）。
func TestSymlinkGuardPropfindSkipsSymlinkEntry(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 内容\n")
	mustSymlink(t, t.TempDir(), filepath.Join(root, "link"))
	base, _, _, _ := newRegistryServer(t, root)

	resp := propfindRequest(t, base+davPrefix+"/", "1")
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		t.Fatalf("读取响应体失败: %v", err)
	}
	if resp.StatusCode != http.StatusMultiStatus {
		t.Fatalf("PROPFIND / 状态码 = %d, 期望 %d\n%s", resp.StatusCode, http.StatusMultiStatus, string(body))
	}
	if !strings.Contains(string(body), davPrefix+"/note.org") {
		t.Errorf("PROPFIND / 响应未包含 %s/note.org:\n%s", davPrefix, string(body))
	}
	if strings.Contains(string(body), davPrefix+"/link") {
		t.Errorf("PROPFIND / 响应不应列出软链条目 link:\n%s", string(body))
	}

	// 直接 PROPFIND 软链本身仍被拒（Stat 权限错误 → 非 207）。
	resp = propfindRequest(t, base+davPrefix+"/link", "0")
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("PROPFIND /link 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
}
