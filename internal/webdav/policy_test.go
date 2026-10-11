package webdav

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/net/webdav"

	"notes/internal/auth"
)

// newPolicyTestServer 以 opts 策略在 root 上启动对外出口测试服务器，返回 base URL。
func newPolicyTestServer(t *testing.T, root string, opts PolicyOptions) string {
	t.Helper()
	srv := httptest.NewServer(NewPolicyHandler(root, auth.New(testToken), SourceExternal, opts))
	t.Cleanup(srv.Close)
	return srv.URL
}

// TestReadOnlyFSRejectsWrites 验证 ReadOnlyFS 的写方法一律返回权限错误，
// 读方法（只读 OpenFile、Stat）正常透传。
func TestReadOnlyFSRejectsWrites(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 内容\n")

	fs := NewReadOnlyFS(webdav.Dir(root))
	ctx := context.Background()

	// 读：只读 OpenFile 与 Stat 应正常。
	f, err := fs.OpenFile(ctx, "note.org", os.O_RDONLY, 0)
	if err != nil {
		t.Fatalf("只读 OpenFile 失败: %v", err)
	}
	f.Close()
	if _, err := fs.Stat(ctx, "note.org"); err != nil {
		t.Fatalf("Stat 失败: %v", err)
	}

	// 写：各写方法都应返回 os.ErrPermission。
	checks := map[string]error{
		"写模式 OpenFile": fsOpenFileWrite(fs, ctx, "new.org"),
		"Mkdir":        fs.Mkdir(ctx, "sub", 0o755),
		"RemoveAll":    fs.RemoveAll(ctx, "note.org"),
		"Rename":       fs.Rename(ctx, "note.org", "renamed.org"),
	}
	for name, err := range checks {
		if !errors.Is(err, os.ErrPermission) {
			t.Errorf("%s err = %v, 期望 os.ErrPermission", name, err)
		}
	}
}

// fsOpenFileWrite 以写模式打开 name，仅返回错误供断言使用。
func fsOpenFileWrite(fs ReadOnlyFS, ctx context.Context, name string) error {
	f, err := fs.OpenFile(ctx, name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	f.Close()
	return nil
}

// TestExtWhitelistFSWriteByExt 验证 ExtWhitelistFS 仅放行白名单内扩展名的写入。
func TestExtWhitelistFSWriteByExt(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "existing.exe", "binary")

	fs := NewExtWhitelistFS(webdav.Dir(root), []string{".org", ".md"})
	ctx := context.Background()

	// 白名单内可写。
	f, err := fs.OpenFile(ctx, "new.org", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatalf("白名单内写失败: %v", err)
	}
	f.Close()

	// 白名单外拒写。
	if _, err := fs.OpenFile(ctx, "bad.exe", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644); !errors.Is(err, os.ErrPermission) {
		t.Errorf("白名单外写 err = %v, 期望 os.ErrPermission", err)
	}

	// 读不受限：读非白名单文件应成功。
	rf, err := fs.OpenFile(ctx, "existing.exe", os.O_RDONLY, 0)
	if err != nil {
		t.Fatalf("读取非白名单文件失败: %v", err)
	}
	rf.Close()
}

// TestExtWhitelistFSNormalizesExts 验证扩展名比较忽略大小写、允许省略前导点。
func TestExtWhitelistFSNormalizesExts(t *testing.T) {
	root := t.TempDir()
	fs := NewExtWhitelistFS(webdav.Dir(root), []string{"ORG", " .Md "})
	ctx := context.Background()

	for _, name := range []string{"a.org", "b.ORG", "c.md"} {
		f, err := fs.OpenFile(ctx, name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			t.Errorf("%s 应被允许写入，实际错误: %v", name, err)
			continue
		}
		f.Close()
	}
	if _, err := fs.OpenFile(ctx, "d.txt", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644); !errors.Is(err, os.ErrPermission) {
		t.Errorf("d.txt 应被拒绝，实际错误: %v", err)
	}
}

// TestExtWhitelistFSEmptyAllowsAll 验证空白名单不限制扩展名。
func TestExtWhitelistFSEmptyAllowsAll(t *testing.T) {
	root := t.TempDir()
	fs := NewExtWhitelistFS(webdav.Dir(root), nil)

	f, err := fs.OpenFile(context.Background(), "any.bin", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatalf("空白名单下写应放行，实际错误: %v", err)
	}
	f.Close()
}

// TestNewPolicyHandlerReadOnly 验证只读策略经 handler 组合后生效：读放行、写被拒且不落盘。
func TestNewPolicyHandlerReadOnly(t *testing.T) {
	const content = "* 内容\n"
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", content)
	base := newPolicyTestServer(t, root, PolicyOptions{ReadOnly: true})

	// 读放行。
	resp := doRequest(t, http.MethodGet, base+davPrefix+"/note.org", "", basicAuthHeader(testToken))
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		t.Fatalf("读取响应体失败: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusOK)
	}
	if string(body) != content {
		t.Errorf("GET 内容 = %q, 期望 %q", string(body), content)
	}

	// 写被拒（webdav 包把 OpenFile 的权限错误映射为非 2xx），且文件未落盘。
	resp = doRequest(t, http.MethodPut, base+davPrefix+"/new.org", "* 新\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("只读下 PUT 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, "new.org")); !os.IsNotExist(err) {
		t.Errorf("只读下不应产生文件，实际 stat 错误: %v", err)
	}
}

// TestNewPolicyHandlerAllowExts 验证扩展名白名单经 handler 组合后生效。
func TestNewPolicyHandlerAllowExts(t *testing.T) {
	root := t.TempDir()
	base := newPolicyTestServer(t, root, PolicyOptions{AllowExts: []string{".org", ".md"}})

	// 白名单内 PUT 成功。
	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* a\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("白名单内 PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	// 白名单外 PUT 被拒，且不落盘。
	resp = doRequest(t, http.MethodPut, base+davPrefix+"/b.exe", "binary", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("白名单外 PUT 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, "b.exe")); !os.IsNotExist(err) {
		t.Errorf("白名单外不应产生文件，实际 stat 错误: %v", err)
	}
}

// TestNewPolicyHandlerReadOnlyWithWhitelist 验证只读优先于白名单：
// 即便目标扩展名在白名单内，只读出口仍拒绝写入。
func TestNewPolicyHandlerReadOnlyWithWhitelist(t *testing.T) {
	root := t.TempDir()
	base := newPolicyTestServer(t, root, PolicyOptions{ReadOnly: true, AllowExts: []string{".org"}})

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/ok.org", "* ok\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Errorf("只读下 PUT 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(root, "ok.org")); !os.IsNotExist(err) {
		t.Errorf("只读下不应产生文件，实际 stat 错误: %v", err)
	}
}
