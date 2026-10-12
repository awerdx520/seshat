package webdav

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/index"
	"seshat/internal/storage"
)

// newPolicyVersionedServer 在 root 上以 opts 策略、prefix 前缀构造「访问策略 +
// git 版本化 + 全文索引」的对外 handler 并启动测试服务器（挂载根即仓库根，
// offset 为空），返回 base URL、索引器与仓库。
func newPolicyVersionedServer(t *testing.T, root string, opts PolicyOptions, prefix string) (string, *index.Indexer, *gitver.Repo) {
	t.Helper()
	return newPolicyVersionedServerAt(t, root, root, opts, prefix, "")
}

// newPolicyVersionedServerAt 以 repoRoot 打开 git 仓库与全文索引，在 mountRoot
// 上挂载对外 handler：offset 为 mountRoot 相对 repoRoot 的仓库内偏移（空串表示
// 两者相同）。用于覆盖「公开出口为笔记根子目录」的场景。返回 base URL、索引器
// 与仓库。
func newPolicyVersionedServerAt(t *testing.T, repoRoot, mountRoot string, opts PolicyOptions, prefix, offset string) (string, *index.Indexer, *gitver.Repo) {
	t.Helper()
	repo, err := gitver.Open(repoRoot)
	if err != nil {
		t.Fatalf("gitver.Open(%s) 失败: %v", repoRoot, err)
	}
	db, err := storage.Open(filepath.Join(t.TempDir(), "index.db"), "")
	if err != nil {
		t.Fatalf("storage.Open 失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	ix := index.New(db)
	srv := httptest.NewServer(NewPolicyVersionedHandler(
		mountRoot, auth.New(testToken), SourceExternal, opts, repo, ix, prefix, offset))
	t.Cleanup(srv.Close)
	return srv.URL, ix, repo
}

// TestPolicyVersionedPutCommitsAndIndexes 验证对外出口的写操作既产生 git 提交
// （commit message 记录 external 来源与 /public 前缀路径），又更新全文索引。
func TestPolicyVersionedPutCommitsAndIndexes(t *testing.T) {
	root := t.TempDir()
	base, ix, repo := newPolicyVersionedServer(t, root, PolicyOptions{AllowExts: []string{".org"}}, "/public")

	if got := commitCount(t, repo); got != 0 {
		t.Fatalf("初始提交数 = %d, 期望 0", got)
	}

	resp := doRequest(t, http.MethodPut, base+"/public/note.org", "* hello world\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	if got := commitCount(t, repo); got != 1 {
		t.Fatalf("对外 PUT 后提交数 = %d, 期望 1", got)
	}
	entries, err := repo.Log(1)
	if err != nil {
		t.Fatalf("Log 失败: %v", err)
	}
	const want = "webdav external: PUT /public/note.org"
	if !strings.HasSuffix(entries[0], want) {
		t.Errorf("commit message = %q, 期望以 %q 结尾", entries[0], want)
	}

	paths, err := ix.Search("hello", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !containsPath(paths, "note.org") {
		t.Fatalf("对外 PUT 后 Search 未命中 note.org: %v", paths)
	}
}

// TestPolicyVersionedPropfindHrefUsesPrefix 验证对外 handler 的 PROPFIND href 使用
// 其挂载前缀（/public）而非默认的 /dav，避免 href 越界。
func TestPolicyVersionedPropfindHrefUsesPrefix(t *testing.T) {
	const propfindBody = `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>`

	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 内容\n")
	base, _, _ := newPolicyVersionedServer(t, root, PolicyOptions{}, "/public")

	req, err := http.NewRequest("PROPFIND", base+"/public/", strings.NewReader(propfindBody))
	if err != nil {
		t.Fatalf("构造 PROPFIND 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	req.Header.Set("Depth", "1")
	req.Header.Set("Content-Type", "application/xml")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PROPFIND 请求失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMultiStatus {
		t.Fatalf("PROPFIND 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusMultiStatus)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取 PROPFIND 响应失败: %v", err)
	}
	if !strings.Contains(string(body), "/public/note.org") {
		t.Errorf("PROPFIND 响应未包含 /public/note.org:\n%s", body)
	}
	if strings.Contains(string(body), "/dav") {
		t.Errorf("PROPFIND 响应出现越界的 /dav 前缀:\n%s", body)
	}
}

// TestPolicyVersionedReadOnlyNoWrite 验证只读策略在最外层生效：写被拒，且不产生
// 提交、不更新索引。
func TestPolicyVersionedReadOnlyNoWrite(t *testing.T) {
	root := t.TempDir()
	base, ix, repo := newPolicyVersionedServer(t, root, PolicyOptions{ReadOnly: true}, "/public")

	resp := doRequest(t, http.MethodPut, base+"/public/new.org", "* blocked\n", basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode < http.StatusBadRequest {
		t.Fatalf("只读下 PUT 状态码 = %d, 期望 >= 400", resp.StatusCode)
	}
	if got := commitCount(t, repo); got != 0 {
		t.Errorf("只读写请求后提交数 = %d, 期望 0", got)
	}
	paths, err := ix.Search("blocked", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if len(paths) != 0 {
		t.Errorf("只读写请求后索引非空: %v", paths)
	}
}

// TestPolicyVersionedSubdirETagAndIndex 验证公开出口挂载在笔记根的子目录时，offset
// 被正确用于 ETag 与索引 key：
//
//   - PROPFIND 的 getetag 返回按「仓库内真实路径」（带 offset 前缀）计算的 blob
//     hash，而非 mtime/size 启发式；
//   - 全文索引 key 同样带 offset，与内部端点（以笔记根为基准）对齐，不再与内部
//     端点的同名文件发生 key 冲突。
func TestPolicyVersionedSubdirETagAndIndex(t *testing.T) {
	const content = "* public subdir token\n"
	const propfindBody = `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>`

	repoRoot := t.TempDir()
	mountRoot := filepath.Join(repoRoot, "public")
	if err := os.MkdirAll(mountRoot, 0o755); err != nil {
		t.Fatalf("创建公开出口目录失败: %v", err)
	}
	base, ix, repo := newPolicyVersionedServerAt(t, repoRoot, mountRoot,
		PolicyOptions{AllowExts: []string{".org"}}, "/public", "public")

	resp := doRequest(t, http.MethodPut, base+"/public/note.org", content, basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	// 文件确实落在笔记根的子目录内（即 git 仓库工作区内）。
	if _, err := os.Stat(filepath.Join(mountRoot, "note.org")); err != nil {
		t.Fatalf("PUT 后文件未落在公开出口目录: %v", err)
	}

	// 索引 key 为仓库内相对路径（带 offset），与内部端点一致；不得使用裸文件名。
	paths, err := ix.Search("subdir", 10)
	if err != nil {
		t.Fatalf("Search 失败: %v", err)
	}
	if !containsPath(paths, "public/note.org") {
		t.Errorf("索引 key 未带 offset（期望 public/note.org）: %v", paths)
	}
	if containsPath(paths, "note.org") {
		t.Errorf("索引 key 出现不带 offset 的裸路径，会与内部端点冲突: %v", paths)
	}

	// PROPFIND 的 getetag 应为仓库内路径 public/note.org 的 blob hash。
	req, err := http.NewRequest("PROPFIND", base+"/public/note.org", strings.NewReader(propfindBody))
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

	hash, err := repo.BlobHash("public/note.org")
	if err != nil {
		t.Fatalf("BlobHash(public/note.org) 失败: %v", err)
	}
	if hash == "" {
		t.Fatal("BlobHash(public/note.org) 返回空串，说明文件不在仓库路径上")
	}
	want := `"` + hash + `"`
	if !strings.Contains(string(body), want) {
		t.Errorf("PROPFIND 响应未包含仓库内路径的 ETag %s（疑似回退到启发式）:\n%s", want, body)
	}
}
