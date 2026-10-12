// Package api_test 覆盖版本查询端点：文件历史、某版本内容、共同祖先与认证。
//
// 端点依赖 gitver.Repo（真实的 go-git 仓库），因此本文件的用例先在临时目录
// 打开仓库并制造提交历史，再经 api.NewHandlerWithRepo 组装处理器。
package api_test

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/storage"
)

// writeRepoFile 在工作区写入文件（自动创建父目录）。
func writeRepoFile(t *testing.T, root, name, content string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("创建目录失败: %v", err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("写入 %s 失败: %v", name, err)
	}
}

// repoHead 返回仓库当前 HEAD 提交的完整 hash。
func repoHead(t *testing.T, repo *gitver.Repo) string {
	t.Helper()
	entries, err := repo.Log(1)
	if err != nil {
		t.Fatalf("读取提交日志失败: %v", err)
	}
	if len(entries) == 0 {
		t.Fatalf("仓库尚无提交")
	}
	hash, _, _ := strings.Cut(entries[0], " ")
	return hash
}

// openRepo 在临时目录打开（初始化）一个 gitver 仓库。
func openRepo(t *testing.T) (*gitver.Repo, string) {
	t.Helper()
	root := t.TempDir()
	repo, err := gitver.Open(root)
	if err != nil {
		t.Fatalf("打开仓库失败: %v", err)
	}
	return repo, root
}

// newVersionHandler 组装挂载了版本查询端点与测试令牌的处理器。
func newVersionHandler(t *testing.T, repo *gitver.Repo) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return api.NewHandlerWithRepo(db, repo, auth.New(testToken))
}

// versionEnv 构造「a.org 三次提交」的线性历史，返回处理器、仓库与提交 hash 列表
// （由旧到新：commits[0]=c1、commits[1]=c2、commits[2]=c3，HEAD 为 commits[2]）。
func versionEnv(t *testing.T) (http.Handler, *gitver.Repo, []string) {
	t.Helper()
	repo, root := openRepo(t)

	var commits []string
	for i, content := range []string{"第一版\n", "第二版\n", "第三版\n"} {
		writeRepoFile(t, root, "a.org", content)
		if err := repo.Commit(fmt.Sprintf("c%d", i+1)); err != nil {
			t.Fatalf("Commit c%d 失败: %v", i+1, err)
		}
		commits = append(commits, repoHead(t, repo))
	}
	return newVersionHandler(t, repo), repo, commits
}

// TestVersionsFileHistory 验证文件历史返回当前 HEAD 与按时间倒序的提交列表。
func TestVersionsFileHistory(t *testing.T) {
	h, _, commits := versionEnv(t)

	rec := do(t, h, http.MethodGet, "/api/versions/a.org", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}

	body := decodeJSON(t, rec)
	if body["head"] != commits[2] {
		t.Fatalf("head = %v, 期望 %s", body["head"], commits[2])
	}

	history, ok := body["history"].([]any)
	if !ok {
		t.Fatalf("history 不是数组: %q", rec.Body.String())
	}
	if len(history) != 3 {
		t.Fatalf("history 条数 = %d, 期望 3", len(history))
	}

	wantMessages := []string{"c3", "c2", "c1"}
	for i, wantMsg := range wantMessages {
		entry, ok := history[i].(map[string]any)
		if !ok {
			t.Fatalf("history[%d] 不是对象: %v", i, history[i])
		}
		if entry["hash"] != commits[2-i] {
			t.Errorf("history[%d].hash = %v, 期望 %s", i, entry["hash"], commits[2-i])
		}
		if entry["message"] != wantMsg {
			t.Errorf("history[%d].message = %v, 期望 %q", i, entry["message"], wantMsg)
		}
		if when, _ := entry["when"].(string); when == "" {
			t.Errorf("history[%d].when 为空", i)
		}
	}
}

// TestVersionsFileHistoryEmptyIsArray 验证从未出现的文件返回空数组（而非 null）。
func TestVersionsFileHistoryEmptyIsArray(t *testing.T) {
	h, _, commits := versionEnv(t)

	rec := do(t, h, http.MethodGet, "/api/versions/missing.org", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"history":[]`) {
		t.Fatalf("空历史应序列化为 []，实际 body=%q", rec.Body.String())
	}
	if head := decodeJSON(t, rec)["head"]; head != commits[2] {
		t.Fatalf("head = %v, 期望 %s", head, commits[2])
	}
}

// TestVersionsSubdirHistory 验证 {path...} 通配可匹配含子目录的多段路径。
func TestVersionsSubdirHistory(t *testing.T) {
	repo, root := openRepo(t)
	h := newVersionHandler(t, repo)

	var commits []string
	for i := 0; i < 2; i++ {
		writeRepoFile(t, root, "sub/dir/b.org", fmt.Sprintf("版本%d\n", i+1))
		if err := repo.Commit(fmt.Sprintf("s%d", i+1)); err != nil {
			t.Fatalf("Commit s%d 失败: %v", i+1, err)
		}
		commits = append(commits, repoHead(t, repo))
	}

	rec := do(t, h, http.MethodGet, "/api/versions/sub/dir/b.org", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["head"] != commits[1] {
		t.Fatalf("head = %v, 期望 %s", body["head"], commits[1])
	}
	if history, _ := body["history"].([]any); len(history) != 2 {
		t.Fatalf("history 条数 = %d, 期望 2", len(history))
	}
}

// TestVersionsSubdirFileContent 验证子目录文件（多段路径）也能按 hash 取到内容。
//
// 这是「{path...} + hash 查询参数」方案的核心目标：原两段式
// GET /api/versions/{path}/{hash} 只能匹配两层路径，sub/a.org 的真实内容
// 端点 /api/versions/sub/a.org/<hash>（3 段）会落到历史处理器，取不到内容。
func TestVersionsSubdirFileContent(t *testing.T) {
	repo, root := openRepo(t)
	h := newVersionHandler(t, repo)

	var commits []string
	for i, content := range []string{"子目录第一版\n", "子目录第二版\n"} {
		writeRepoFile(t, root, "sub/a.org", content)
		if err := repo.Commit(fmt.Sprintf("sub%d", i+1)); err != nil {
			t.Fatalf("Commit sub%d 失败: %v", i+1, err)
		}
		commits = append(commits, repoHead(t, repo))
	}

	// 取子目录文件在旧版本（commits[0]）处的内容。
	rec := do(t, h, http.MethodGet,
		"/api/versions/sub/a.org?hash="+commits[0], testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["hash"] != commits[0] {
		t.Fatalf("hash = %v, 期望 %s", body["hash"], commits[0])
	}
	if body["content"] != "子目录第一版\n" {
		t.Fatalf("content = %q, 期望 %q", body["content"], "子目录第一版\n")
	}

	// 无 hash 时仍走历史分支：子目录路径的历史查询不受影响。
	hist := do(t, h, http.MethodGet, "/api/versions/sub/a.org", testToken, nil, nil)
	if hist.Code != http.StatusOK {
		t.Fatalf("历史状态码 = %d, 期望 200", hist.Code)
	}
	if hb := decodeJSON(t, hist); hb["head"] != commits[1] {
		t.Fatalf("历史 head = %v, 期望 %s", hb["head"], commits[1])
	}
}

// TestVersionsFileContent 验证按版本读取文件内容（hash 经查询参数传入）。
func TestVersionsFileContent(t *testing.T) {
	h, _, commits := versionEnv(t)

	rec := do(t, h, http.MethodGet, "/api/versions/a.org?hash="+commits[1], testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["hash"] != commits[1] {
		t.Fatalf("hash = %v, 期望 %s", body["hash"], commits[1])
	}
	if body["content"] != "第二版\n" {
		t.Fatalf("content = %q, 期望 %q", body["content"], "第二版\n")
	}
}

// TestVersionsFileContentNotFound 验证文件在该版本不存在时返回 404。
func TestVersionsFileContentNotFound(t *testing.T) {
	h, _, commits := versionEnv(t)

	rec := do(t, h, http.MethodGet, "/api/versions/missing.org?hash="+commits[2], testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")
}

// TestVersionsFileContentUnknownRevision 验证版本无法解析时返回 400。
func TestVersionsFileContentUnknownRevision(t *testing.T) {
	h, _, _ := versionEnv(t)

	rec := do(t, h, http.MethodGet, "/api/versions/a.org?hash=deadbeef", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestMergeBaseEndpoint 验证共同祖先查询的正确返回与参数校验。
func TestMergeBaseEndpoint(t *testing.T) {
	h, _, commits := versionEnv(t)

	// c2 是 c3 的祖先，共同祖先应为 c2。
	rec := do(t, h, http.MethodGet,
		"/api/merge-base?a="+commits[2]+"&b="+commits[1], testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	if got := decodeJSON(t, rec)["merge_base"]; got != commits[1] {
		t.Fatalf("merge_base = %v, 期望 %s", got, commits[1])
	}

	// 缺少参数 → 400。
	missing := do(t, h, http.MethodGet, "/api/merge-base?a="+commits[2], testToken, nil, nil)
	assertErrorCode(t, missing, http.StatusBadRequest, "invalid_argument")

	// 非法版本 → 400。
	invalid := do(t, h, http.MethodGet, "/api/merge-base?a=nope&b="+commits[1], testToken, nil, nil)
	assertErrorCode(t, invalid, http.StatusBadRequest, "invalid_argument")
}

// TestMergeBaseNoCommonAncestor 验证无共同祖先时返回 409。
func TestMergeBaseNoCommonAncestor(t *testing.T) {
	repo, root := openRepo(t)
	h := newVersionHandler(t, repo)

	writeRepoFile(t, root, "a.org", "第一版\n")
	if err := repo.Commit("c1"); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}
	c1 := repoHead(t, repo)

	// 直接向对象库写入一个无父提交（孤立提交），与 c1 分属不相连的历史。
	orphan := writeOrphanCommit(t, root, "orphan.org", "孤立内容\n", "孤立提交")

	rec := do(t, h, http.MethodGet, "/api/merge-base?a="+orphan+"&b="+c1, testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusConflict, "conflict")
}

// TestVersionsUnauthorized 验证版本端点走认证中间件，缺失/错误令牌一律 401。
func TestVersionsUnauthorized(t *testing.T) {
	h, _, _ := versionEnv(t)

	cases := []struct {
		name  string
		token string
	}{
		{"缺失令牌", ""},
		{"错误令牌", "wrong-token"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, target := range []string{
				"/api/versions/a.org",
				"/api/merge-base?a=HEAD&b=HEAD",
			} {
				rec := do(t, h, http.MethodGet, target, tc.token, nil, nil)
				if rec.Code != http.StatusUnauthorized {
					t.Fatalf("%s 状态码 = %d, 期望 401", target, rec.Code)
				}
			}
		})
	}
}

// TestNewHandlerWithoutRepoOmitsVersionRoutes 验证不传 repo 时版本查询路由不注册。
func TestNewHandlerWithoutRepoOmitsVersionRoutes(t *testing.T) {
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	h := api.NewHandler(db, auth.New(testToken))
	rec := do(t, h, http.MethodGet, "/api/versions/a.org", testToken, nil, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("未挂载版本路由时状态码 = %d, 期望 404", rec.Code)
	}
}

// writeOrphanCommit 直接在仓库对象库写入一个无父提交（孤立提交），返回其 hash。
// 绕过工作区，因此不改变 HEAD；用于制造「无共同祖先」的历史。
func writeOrphanCommit(t *testing.T, root, name, content, message string) string {
	t.Helper()

	g, err := git.PlainOpen(root)
	if err != nil {
		t.Fatalf("打开仓库失败: %v", err)
	}
	store := g.Storer

	blob := store.NewEncodedObject()
	blob.SetType(plumbing.BlobObject)
	bw, err := blob.Writer()
	if err != nil {
		t.Fatalf("获取 blob writer 失败: %v", err)
	}
	if _, err := bw.Write([]byte(content)); err != nil {
		t.Fatalf("写入 blob 失败: %v", err)
	}
	if err := bw.Close(); err != nil {
		t.Fatalf("关闭 blob writer 失败: %v", err)
	}
	blobHash, err := store.SetEncodedObject(blob)
	if err != nil {
		t.Fatalf("保存 blob 失败: %v", err)
	}

	tree := &object.Tree{Entries: []object.TreeEntry{{
		Name: name,
		Mode: filemode.Regular,
		Hash: blobHash,
	}}}
	treeObj := store.NewEncodedObject()
	if err := tree.Encode(treeObj); err != nil {
		t.Fatalf("编码 tree 失败: %v", err)
	}
	treeHash, err := store.SetEncodedObject(treeObj)
	if err != nil {
		t.Fatalf("保存 tree 失败: %v", err)
	}

	sig := object.Signature{Name: "seshat", Email: "seshat@local", When: time.Now()}
	commit := &object.Commit{
		Author:    sig,
		Committer: sig,
		Message:   message,
		TreeHash:  treeHash,
	}
	commitObj := store.NewEncodedObject()
	if err := commit.Encode(commitObj); err != nil {
		t.Fatalf("编码 commit 失败: %v", err)
	}
	commitHash, err := store.SetEncodedObject(commitObj)
	if err != nil {
		t.Fatalf("保存 commit 失败: %v", err)
	}
	return commitHash.String()
}
