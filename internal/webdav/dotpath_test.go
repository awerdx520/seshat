// 本文件测试对外出口的点路径拒绝（dotPathFS）：.git 内部目录与隐藏文件/隐藏目录
// 既不可读也不可写，规则与 internal/registry 的 normalizeResourcePath 同口径。
//
// 断言口径补充（与 golang.org/x/net/webdav 的实际错误映射有关）：
//   - GET/HEAD 与 PUT 的 OpenFile 错误被 webdav 统一映射为 404（handleGetHeadPost /
//     handlePut 对非 IsNotExist 错误返回 StatusNotFound），故断言「非 2xx 且未泄露
//     内容、未落盘」，而非硬编码 403；
//   - MOVE 的目标检查走 moveFiles → fs.Stat(dst)，权限错误映射为 403；
//   - PROPFIND 的遍历对每个子项先 Stat，命中权限错误后由 handlePropfindError 静默
//     跳过该子项，响应仍是 207 Multi-Status。
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

// TestDotPathFSRejectsDotPaths 直接验证 dotPathFS 的读/写方法都拒绝点路径，
// 且包装不影响普通路径与挂载根本身。
func TestDotPathFSRejectsDotPaths(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("创建 .git 目录失败: %v", err)
	}
	mustWriteFile(t, root, ".git/config", "[core]\n")
	mustWriteFile(t, root, "note.org", "* 内容\n")

	fs := newDotPathFS(webdav.Dir(root))
	ctx := context.Background()

	// 放行：普通路径、挂载根本身（""、"/"）、折叠 ./ 后不再是点段的写法。
	for _, name := range []string{"note.org", "/note.org", "", "/", "/./note.org"} {
		if hasDotSegment(name) {
			t.Errorf("路径 %q 被判为点路径，期望放行", name)
		}
		if _, err := fs.Stat(ctx, name); err != nil {
			t.Errorf("Stat(%q) 应放行，实际错误: %v", name, err)
		}
	}

	// 拒绝：读写都拒（读 .git/config 会泄露 remote URL）。
	denied := []string{"/.git/config", "/.git", "sub/.git/HEAD", "/.hidden/x", "/.gitignore", "/sub/.cache"}
	for _, name := range denied {
		if !hasDotSegment(name) {
			t.Errorf("路径 %q 未被判为点路径", name)
		}
		if _, err := fs.OpenFile(ctx, name, os.O_RDONLY, 0); !errors.Is(err, os.ErrPermission) {
			t.Errorf("只读 OpenFile(%q) err = %v, 期望 os.ErrPermission", name, err)
		}
		if _, err := fs.OpenFile(ctx, name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644); !errors.Is(err, os.ErrPermission) {
			t.Errorf("写 OpenFile(%q) err = %v, 期望 os.ErrPermission", name, err)
		}
		if _, err := fs.Stat(ctx, name); !errors.Is(err, os.ErrPermission) {
			t.Errorf("Stat(%q) err = %v, 期望 os.ErrPermission", name, err)
		}
		if err := fs.Mkdir(ctx, name, 0o755); !errors.Is(err, os.ErrPermission) {
			t.Errorf("Mkdir(%q) err = %v, 期望 os.ErrPermission", name, err)
		}
		if err := fs.RemoveAll(ctx, name); !errors.Is(err, os.ErrPermission) {
			t.Errorf("RemoveAll(%q) err = %v, 期望 os.ErrPermission", name, err)
		}
		// Rename 的源与目标都检查。
		if err := fs.Rename(ctx, name, "moved.org"); !errors.Is(err, os.ErrPermission) {
			t.Errorf("Rename(%q → moved.org) err = %v, 期望 os.ErrPermission（源检查）", name, err)
		}
		if err := fs.Rename(ctx, "note.org", name); !errors.Is(err, os.ErrPermission) {
			t.Errorf("Rename(note.org → %q) err = %v, 期望 os.ErrPermission（目标检查）", name, err)
		}
	}

	// 大小写不敏感的 .git 段同样拒绝。
	if !hasDotSegment("/.GIT/config") {
		t.Error("/.GIT/config 应被判为点路径（.git 段大小写不敏感）")
	}

	// 拒绝后底层文件未被修改：.git/config 内容原样。
	raw, err := os.ReadFile(filepath.Join(root, ".git", "config"))
	if err != nil {
		t.Fatalf("读取 .git/config 失败: %v", err)
	}
	if string(raw) != "[core]\n" {
		t.Errorf(".git/config 内容 = %q, 期望未被修改", string(raw))
	}
}

// TestDotPathPutRejected 验证 PUT 无法写入 .git（既不覆盖 .git/config，也不新建文件）。
func TestDotPathPutRejected(t *testing.T) {
	root := t.TempDir()
	base, _, _, _ := newRegistryServer(t, root)
	// newRegistryServer 会初始化 git 仓库，故 .git/config 真实存在；以其当前内容为基线。
	configPath := filepath.Join(root, ".git", "config")
	baseline, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("读取 .git/config 基线失败: %v", err)
	}

	// 覆盖既有 .git/config。
	resp := doRequest(t, http.MethodPut, base+davPrefix+"/.git/config", "[core]\n\tbare = true\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("PUT /.git/config 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("读取 .git/config 失败: %v", err)
	}
	if string(raw) != string(baseline) {
		t.Errorf(".git/config 被改写为 %q, 期望保持不变", string(raw))
	}

	// 在 .git 下新建文件。
	resp = doRequest(t, http.MethodPut, base+davPrefix+"/.git/newfile", "x", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("PUT /.git/newfile 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, ".git", "newfile")); !os.IsNotExist(err) {
		t.Errorf(".git/newfile 不应被创建，实际 stat 错误: %v", err)
	}

	// 根下的点文件同样不可写。
	resp = doRequest(t, http.MethodPut, base+davPrefix+"/.gitignore", "*.tmp\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("PUT /.gitignore 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, ".gitignore")); !os.IsNotExist(err) {
		t.Errorf(".gitignore 不应被创建，实际 stat 错误: %v", err)
	}
}

// TestDotPathGetRejected 验证 GET 无法读取 .git/config（remote URL 泄露面）。
func TestDotPathGetRejected(t *testing.T) {
	root := t.TempDir()
	base, _, _, _ := newRegistryServer(t, root)
	// newRegistryServer 会初始化 git 仓库，故 root/.git/config 真实存在。
	if _, err := os.Stat(filepath.Join(root, ".git", "config")); err != nil {
		t.Fatalf("测试前提不成立：.git/config 不存在: %v", err)
	}

	resp := doRequest(t, http.MethodGet, base+davPrefix+"/.git/config", "", basicAuthHeader(testToken))
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		t.Fatalf("读取响应体失败: %v", err)
	}
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("GET /.git/config 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	for _, leak := range []string{"repositoryformatversion", "[core]"} {
		if strings.Contains(string(body), leak) {
			t.Errorf("响应体泄露了 .git/config 内容（含 %q）:\n%s", leak, string(body))
		}
	}
}

// TestDotPathMoveRejected 验证 MOVE 的两个方向都被拒：写进 .git 与从 .git 移出，
// 且源文件保持原样。
func TestDotPathMoveRejected(t *testing.T) {
	const content = "* 内容\n"
	root := t.TempDir()
	mustWriteFile(t, root, "a.org", content)
	base, _, _, _ := newRegistryServer(t, root)

	// 写进 .git：源文件必须仍在。
	resp := doMethod(t, "MOVE", base+davPrefix+"/a.org", base+davPrefix+"/.git/x")
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("MOVE a.org → .git/x 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	raw, err := os.ReadFile(filepath.Join(root, "a.org"))
	if err != nil {
		t.Fatalf("MOVE 被拒后源文件应仍在: %v", err)
	}
	if string(raw) != content {
		t.Errorf("源文件内容 = %q, 期望 %q", string(raw), content)
	}
	if _, err := os.Stat(filepath.Join(root, ".git", "x")); !os.IsNotExist(err) {
		t.Errorf(".git/x 不应被创建，实际 stat 错误: %v", err)
	}

	// 从 .git 移出（会泄露 remote URL 的路径）：目标不得出现。
	resp = doMethod(t, "MOVE", base+davPrefix+"/.git/config", base+davPrefix+"/leak.org")
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("MOVE .git/config → leak.org 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, "leak.org")); !os.IsNotExist(err) {
		t.Errorf("leak.org 不应被创建，实际 stat 错误: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".git", "config")); err != nil {
		t.Errorf(".git/config 不应被移走: %v", err)
	}
}

// TestDotPathPropfindRootStillMultistatus 验证拒绝点路径不影响列目录：
// PROPFIND / 仍是 207，正常文件可见，被拒的点条目被 webdav 静默跳过（不报错）。
func TestDotPathPropfindRootStillMultistatus(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 内容\n")
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
	if !strings.Contains(string(body), "/dav/note.org") {
		t.Errorf("PROPFIND / 响应未包含 /dav/note.org:\n%s", string(body))
	}
	// .git 存在但被静默跳过：既不是 500，也不出现在响应里。
	if strings.Contains(string(body), ".git") {
		t.Errorf("PROPFIND / 响应不应列出 .git 条目:\n%s", string(body))
	}

	// 直接 PROPFIND 点路径本身仍被拒（Stat 权限错误 → 405 Method Not Allowed）。
	resp = propfindRequest(t, base+davPrefix+"/.git", "0")
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("PROPFIND /.git 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
}

// propfindRequest 发送带指定 Depth 的 PROPFIND 请求（认证使用测试令牌）。
func propfindRequest(t *testing.T, url, depth string) *http.Response {
	t.Helper()
	const body = `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>`
	req, err := http.NewRequest("PROPFIND", url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("构造 PROPFIND 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	req.Header.Set("Depth", depth)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PROPFIND %s 请求失败: %v", url, err)
	}
	return resp
}
