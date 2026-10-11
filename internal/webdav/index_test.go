package webdav

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"notes/internal/auth"
	"notes/internal/gitver"
	"notes/internal/index"
	"notes/internal/storage"
)

// newIndexedServer 在 root 上打开版本化仓库与全文索引，启动带索引的测试服务器，
// 返回 base URL、索引器与仓库。
func newIndexedServer(t *testing.T, root string) (string, *index.Indexer, *gitver.Repo) {
	t.Helper()
	repo, err := gitver.Open(root)
	if err != nil {
		t.Fatalf("gitver.Open(%s) 失败: %v", root, err)
	}
	db, err := storage.Open(filepath.Join(t.TempDir(), "index.db"), "")
	if err != nil {
		t.Fatalf("storage.Open 失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	ix := index.New(db)
	srv := httptest.NewServer(
		VersionedHandlerWithIndex(root, auth.New(testToken), SourceInternal, repo, ix))
	t.Cleanup(srv.Close)
	return srv.URL, ix, repo
}

// containsPath 报告检索结果是否包含 want。
func containsPath(paths []string, want string) bool {
	for _, p := range paths {
		if p == want {
			return true
		}
	}
	return false
}

// TestIndexAfterPutAndDelete 验证经 WebDAV PUT 的 .org 文件可被全文检索命中，
// DELETE 后不再命中。
func TestIndexAfterPutAndDelete(t *testing.T) {
	root := t.TempDir()
	base, ix, _ := newIndexedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/note.org", "* hello world\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	paths, err := ix.Search("hello", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !containsPath(paths, "note.org") {
		t.Fatalf("PUT 后 Search 未命中 note.org: %v", paths)
	}

	resp = doRequest(t, http.MethodDelete, base+davPrefix+"/note.org", "", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusNoContent)
	}

	paths, err = ix.Search("hello", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if containsPath(paths, "note.org") {
		t.Fatalf("DELETE 后 Search 仍命中 note.org: %v", paths)
	}
}

// TestIndexAfterPutOverwrite 验证同一路径二次 PUT 后检索反映最新内容。
func TestIndexAfterPutOverwrite(t *testing.T) {
	root := t.TempDir()
	base, ix, _ := newIndexedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/note.org", "* firsttoken\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("首次 PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	resp = doRequest(t, http.MethodPut, base+davPrefix+"/note.org", "* secondtoken\n", basicAuthHeader(testToken))
	resp.Body.Close()
	// x/net/webdav v0.61.0 的 handlePut 对新建与覆盖一律返回 201。
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("覆盖 PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	old, err := ix.Search("firsttoken", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if containsPath(old, "note.org") {
		t.Errorf("覆盖 PUT 后旧内容仍命中: %v", old)
	}

	latest, err := ix.Search("secondtoken", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !containsPath(latest, "note.org") {
		t.Fatalf("覆盖 PUT 后新内容未命中: %v", latest)
	}
}

// TestIndexAfterMove 验证 MOVE 后源索引被删除、目标建立索引。
func TestIndexAfterMove(t *testing.T) {
	root := t.TempDir()
	base, ix, _ := newIndexedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* movedtoken\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	req, err := http.NewRequest("MOVE", base+davPrefix+"/a.org", nil)
	if err != nil {
		t.Fatalf("构造 MOVE 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	req.Header.Set("Destination", base+davPrefix+"/b.org")
	moveResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("MOVE 请求失败: %v", err)
	}
	moveResp.Body.Close()
	if moveResp.StatusCode != http.StatusCreated {
		t.Fatalf("MOVE 状态码 = %d, 期望 %d", moveResp.StatusCode, http.StatusCreated)
	}

	paths, err := ix.Search("movedtoken", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if containsPath(paths, "a.org") {
		t.Errorf("MOVE 后源 a.org 仍命中: %v", paths)
	}
	if !containsPath(paths, "b.org") {
		t.Fatalf("MOVE 后目标 b.org 未命中: %v", paths)
	}
}

// TestIndexSkipsNonOrg 验证非 .org 文件不进入全文索引。
func TestIndexSkipsNonOrg(t *testing.T) {
	root := t.TempDir()
	base, ix, _ := newIndexedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/note.txt", "plain token\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	paths, err := ix.Search("plain", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if containsPath(paths, "note.txt") {
		t.Fatalf("非 .org 文件被索引入库: %v", paths)
	}
}

// TestIndexUnchangedOnFailedWrite 验证失败的写请求（非 2xx）不触碰索引：
// MOVE 缺少 Destination 头被拒绝，源文件与其索引均应保持不变。
func TestIndexUnchangedOnFailedWrite(t *testing.T) {
	root := t.TempDir()
	base, ix, _ := newIndexedServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/a.org", "* kepttoken\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	// 不带 Destination 的 MOVE 会被 webdav 拒绝（4xx），源文件不变。
	req, err := http.NewRequest("MOVE", base+davPrefix+"/a.org", nil)
	if err != nil {
		t.Fatalf("构造 MOVE 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	moveResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("MOVE 请求失败: %v", err)
	}
	moveResp.Body.Close()
	if moveResp.StatusCode < 400 {
		t.Fatalf("无 Destination 的 MOVE 状态码 = %d, 期望 >= 400", moveResp.StatusCode)
	}

	paths, err := ix.Search("kepttoken", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !containsPath(paths, "a.org") {
		t.Fatalf("失败的 MOVE 误删了源索引 a.org: %v", paths)
	}
}
