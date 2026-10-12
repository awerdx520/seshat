package webdav

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"golang.org/x/net/webdav"

	"seshat/internal/auth"
	"seshat/internal/gitver"
)

// newVersionedServer 在 root 上打开版本化仓库并启动测试服务器。
func newVersionedServer(t *testing.T, root string) (string, *gitver.Repo) {
	t.Helper()
	repo, err := gitver.Open(root)
	if err != nil {
		t.Fatalf("gitver.Open(%s) 失败: %v", root, err)
	}
	srv := httptest.NewServer(VersionedHandler(root, auth.New(testToken), SourceInternal, repo))
	t.Cleanup(srv.Close)
	return srv.URL, repo
}

// commitCount 返回仓库当前提交数量。
func commitCount(t *testing.T, repo *gitver.Repo) int {
	t.Helper()
	entries, err := repo.Log(0)
	if err != nil {
		t.Fatalf("Log 失败: %v", err)
	}
	return len(entries)
}

// TestVersionedPutCreatesCommit 验证 PUT 后仓库新增一次提交，
// 且 commit message 记录了来源、方法与路径。
func TestVersionedPutCreatesCommit(t *testing.T) {
	root := t.TempDir()
	base, repo := newVersionedServer(t, root)

	if got := commitCount(t, repo); got != 0 {
		t.Fatalf("初始提交数 = %d, 期望 0", got)
	}

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/put.org", "* 内容\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	if got := commitCount(t, repo); got != 1 {
		t.Fatalf("PUT 后提交数 = %d, 期望 1", got)
	}

	entries, err := repo.Log(1)
	if err != nil {
		t.Fatalf("Log 失败: %v", err)
	}
	const want = "webdav internal: PUT /dav/put.org"
	if !strings.HasSuffix(entries[0], want) {
		t.Errorf("commit message = %q, 期望以 %q 结尾", entries[0], want)
	}
}

// TestVersionedGetDoesNotCommit 验证读方法（GET/PROPFIND）不产生新提交。
func TestVersionedGetDoesNotCommit(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 标题\n")
	base, repo := newVersionedServer(t, root)

	// GET 两次：不应产生任何提交。
	for range 2 {
		resp := doRequest(t, http.MethodGet, base+davPrefix+"/note.org", "", basicAuthHeader(testToken))
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusOK)
		}
	}

	const propfindBody = `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>`
	req, err := http.NewRequest("PROPFIND", base+davPrefix+"/note.org", strings.NewReader(propfindBody))
	if err != nil {
		t.Fatalf("构造 PROPFIND 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	req.Header.Set("Depth", "0")
	req.Header.Set("Content-Type", "application/xml")

	pfResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PROPFIND 请求失败: %v", err)
	}
	pfResp.Body.Close()
	if pfResp.StatusCode != http.StatusMultiStatus {
		t.Fatalf("PROPFIND 状态码 = %d, 期望 %d", pfResp.StatusCode, http.StatusMultiStatus)
	}

	if got := commitCount(t, repo); got != 0 {
		t.Errorf("读请求后提交数 = %d, 期望 0", got)
	}
}

// TestVersionedPropfindETag 验证 PROPFIND 的 getetag 返回工作区内容的
// git blob hash（与 gitver.BlobHash 一致）。
func TestVersionedPropfindETag(t *testing.T) {
	const content = "* etag 测试\n"
	const propfindBody = `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>`

	root := t.TempDir()
	base, repo := newVersionedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/etag.org", content, basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	req, err := http.NewRequest("PROPFIND", base+davPrefix+"/etag.org", strings.NewReader(propfindBody))
	if err != nil {
		t.Fatalf("构造 PROPFIND 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	req.Header.Set("Depth", "0")
	req.Header.Set("Content-Type", "application/xml")

	pfResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PROPFIND 请求失败: %v", err)
	}
	defer pfResp.Body.Close()
	if pfResp.StatusCode != http.StatusMultiStatus {
		t.Fatalf("PROPFIND 状态码 = %d, 期望 %d", pfResp.StatusCode, http.StatusMultiStatus)
	}

	body, err := io.ReadAll(pfResp.Body)
	if err != nil {
		t.Fatalf("读取 PROPFIND 响应失败: %v", err)
	}

	hash, err := repo.BlobHash("etag.org")
	if err != nil {
		t.Fatalf("BlobHash 失败: %v", err)
	}
	if hash == "" {
		t.Fatal("BlobHash 返回空串")
	}

	want := `"` + hash + `"`
	if !strings.Contains(string(body), want) {
		t.Errorf("PROPFIND 响应未包含 ETag %s:\n%s", want, body)
	}
}

// TestVersionedFSEtag 直接验证 versionedFS 返回的 FileInfo 实现
// webdav.ETager，且 ETag 随工作区内容即时变化（与提交时序解耦）。
func TestVersionedFSEtag(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "a.org", "* a\n")

	repo, err := gitver.Open(root)
	if err != nil {
		t.Fatalf("gitver.Open 失败: %v", err)
	}
	fs := newVersionedFS(root, repo)
	ctx := context.Background()

	etagOf := func(name string) string {
		t.Helper()
		fi, err := fs.Stat(ctx, name)
		if err != nil {
			t.Fatalf("Stat(%s) 失败: %v", name, err)
		}
		etager, ok := fi.(webdav.ETager)
		if !ok {
			t.Fatalf("Stat(%s) 返回的 FileInfo 未实现 webdav.ETager", name)
		}
		etag, err := etager.ETag(ctx)
		if err != nil {
			t.Fatalf("ETag(%s) 失败: %v", name, err)
		}
		return etag
	}

	hash, err := repo.BlobHash("a.org")
	if err != nil {
		t.Fatalf("BlobHash 失败: %v", err)
	}
	if got, want := etagOf("/a.org"), `"`+hash+`"`; got != want {
		t.Errorf("ETag = %s, 期望 %s", got, want)
	}

	// 通过 OpenFile 拿到的 File.Stat 同样实现 ETager。
	f, err := fs.OpenFile(ctx, "/a.org", os.O_RDONLY, 0)
	if err != nil {
		t.Fatalf("OpenFile 失败: %v", err)
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		t.Fatalf("File.Stat 失败: %v", err)
	}
	etager, ok := fi.(webdav.ETager)
	if !ok {
		t.Fatal("File.Stat 返回的 FileInfo 未实现 webdav.ETager")
	}
	if got, err := etager.ETag(ctx); err != nil || got != `"`+hash+`"` {
		t.Errorf("File.Stat ETag = %s, %v; 期望 %s, nil", got, err, `"`+hash+`"`)
	}

	// 内容改变但尚未提交：ETag 立即变化（与 commit 时序解耦）。
	mustWriteFile(t, root, "a.org", "* a 修改后\n")
	newHash, err := repo.BlobHash("a.org")
	if err != nil {
		t.Fatalf("BlobHash 失败: %v", err)
	}
	if newHash == hash {
		t.Fatal("内容变化后 blob hash 未变化")
	}
	if got := etagOf("/a.org"); got != `"`+newHash+`"` {
		t.Errorf("修改后 ETag = %s, 期望 %s", got, `"`+newHash+`"`)
	}

	// 目录不提供内容 ETag：返回 webdav.ErrNotImplemented。
	dirInfo, err := fs.Stat(ctx, "/")
	if err != nil {
		t.Fatalf("Stat(/) 失败: %v", err)
	}
	dirEtag, ok := dirInfo.(webdav.ETager)
	if !ok {
		t.Fatal("目录 FileInfo 未实现 webdav.ETager")
	}
	if _, err := dirEtag.ETag(ctx); err != webdav.ErrNotImplemented {
		t.Errorf("目录 ETag 错误 = %v, 期望 webdav.ErrNotImplemented", err)
	}
}

// TestVersionedUnauthorizedNoCommit 验证未认证的写请求被拒绝且不产生提交。
func TestVersionedUnauthorizedNoCommit(t *testing.T) {
	root := t.TempDir()
	base, repo := newVersionedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/x.org", "* x\n", basicAuthHeader("wrong"))
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusUnauthorized)
	}
	if got := commitCount(t, repo); got != 0 {
		t.Errorf("未认证写请求后提交数 = %d, 期望 0", got)
	}
}
