// Package api_test 覆盖 M5.2 的差异查询与版本恢复端点：
// GET /api/versions/{path...}/diff 与 POST /api/revert。
//
// 端点依赖真实的 go-git 仓库，因此沿用 versions_test.go 的夹具构造方式：
// 在临时目录打开仓库、制造提交历史，再经 api.NewHandlerFull 组装处理器
// （复用 M5.1 引入的完整构造，不重复定义）。
package api_test

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/storage"
)

// newFullHandler 用 NewHandlerFull 组装处理器（indexer 为 nil，仅验证版本相关端点）。
func newFullHandler(t *testing.T, repo *gitver.Repo) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return api.NewHandlerFull(db, repo, nil, auth.New(testToken))
}

// diffEnv 构造「a.org 两版内容」的仓库，返回处理器、工作区根与提交 hash（旧→新）。
func diffEnv(t *testing.T) (http.Handler, *gitver.Repo, string, []string) {
	t.Helper()
	repo, root := openRepo(t)
	h := newFullHandler(t, repo)

	var commits []string
	for i, content := range []string{"第一版\n", "第二版\n"} {
		writeRepoFile(t, root, "a.org", content)
		if err := repo.Commit(fmt.Sprintf("c%d", i+1)); err != nil {
			t.Fatalf("Commit c%d 失败: %v", i+1, err)
		}
		commits = append(commits, repoHead(t, repo))
	}
	return h, repo, root, commits
}

// TestVersionsDiffEndpoint 验证 diff 端点返回 200 与含增删标记的 unified diff 文本。
func TestVersionsDiffEndpoint(t *testing.T) {
	h, _, _, commits := diffEnv(t)

	target := fmt.Sprintf("/api/versions/a.org/diff?from=%s&to=%s", commits[0], commits[1])
	rec := do(t, h, http.MethodGet, target, testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}

	diff, _ := decodeJSON(t, rec)["diff"].(string)
	for _, want := range []string{"--- a/a.org", "+++ b/a.org", "@@ ", "-第一版", "+第二版"} {
		if !strings.Contains(diff, want) {
			t.Errorf("diff 缺少 %q，实际:\n%s", want, diff)
		}
	}
}

// TestVersionsDiffSubdir 验证含子目录的多段路径也能查询差异。
func TestVersionsDiffSubdir(t *testing.T) {
	repo, root := openRepo(t)
	h := newFullHandler(t, repo)

	var commits []string
	for i, content := range []string{"子目录第一版\n", "子目录第二版\n"} {
		writeRepoFile(t, root, "sub/dir/b.org", content)
		if err := repo.Commit(fmt.Sprintf("s%d", i+1)); err != nil {
			t.Fatalf("Commit s%d 失败: %v", i+1, err)
		}
		commits = append(commits, repoHead(t, repo))
	}

	target := fmt.Sprintf("/api/versions/sub/dir/b.org/diff?from=%s&to=%s", commits[0], commits[1])
	rec := do(t, h, http.MethodGet, target, testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	if diff, _ := decodeJSON(t, rec)["diff"].(string); !strings.Contains(diff, "-子目录第一版") {
		t.Errorf("子目录 diff 内容不符合预期:\n%s", diff)
	}
}

// TestVersionsDiffBadRequest 验证缺少 from/to 或版本非法时返回 400。
func TestVersionsDiffBadRequest(t *testing.T) {
	h, _, _, commits := diffEnv(t)

	cases := []struct {
		name   string
		target string
	}{
		{"缺少 from 与 to", "/api/versions/a.org/diff"},
		{"缺少 to", "/api/versions/a.org/diff?from=" + commits[0]},
		{"缺少 from", "/api/versions/a.org/diff?to=" + commits[1]},
		{"from 非法", "/api/versions/a.org/diff?from=deadbeef&to=" + commits[1]},
		{"to 非法", "/api/versions/a.org/diff?from=" + commits[0] + "&to=deadbeef"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodGet, tc.target, testToken, nil, nil)
			assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
		})
	}
}

// TestVersionsDiffNotFound 验证文件在该版本不存在时返回 404。
func TestVersionsDiffNotFound(t *testing.T) {
	h, _, _, commits := diffEnv(t)

	target := fmt.Sprintf("/api/versions/missing.org/diff?from=%s&to=%s", commits[0], commits[1])
	rec := do(t, h, http.MethodGet, target, testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")
}

// TestRevertEndpoint 验证 revert 端点把工作区文件恢复到指定版本并返回新提交 hash。
func TestRevertEndpoint(t *testing.T) {
	h, _, root, commits := diffEnv(t)

	rec := do(t, h, http.MethodPost, "/api/revert", testToken,
		map[string]string{"path": "a.org", "hash": commits[0]}, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}

	body := decodeJSON(t, rec)
	if body["status"] != "reverted" {
		t.Errorf("status = %v, 期望 \"reverted\"", body["status"])
	}
	newHash, _ := body["hash"].(string)
	if newHash == "" || newHash == commits[1] {
		t.Errorf("hash = %q, 期望 revert 产生的新提交 hash（旧 HEAD=%s）", newHash, commits[1])
	}

	// 工作区文件已恢复为第一版内容。
	got, err := os.ReadFile(filepath.Join(root, "a.org"))
	if err != nil {
		t.Fatalf("读取工作区文件失败: %v", err)
	}
	if string(got) != "第一版\n" {
		t.Errorf("工作区内容 = %q, 期望 %q", string(got), "第一版\n")
	}
}

// TestRevertBadRequest 验证 path/hash 为空时返回 400。
func TestRevertBadRequest(t *testing.T) {
	h, _, _, commits := diffEnv(t)

	cases := []struct {
		name string
		body map[string]string
	}{
		{"path 为空", map[string]string{"path": "", "hash": commits[0]}},
		{"hash 为空", map[string]string{"path": "a.org", "hash": ""}},
		{"均为空", map[string]string{"path": "", "hash": ""}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodPost, "/api/revert", testToken, tc.body, nil)
			assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
		})
	}
}

// TestRevertNotFound 验证文件在该版本不存在时返回 404、版本非法时返回 400。
func TestRevertNotFound(t *testing.T) {
	h, _, _, commits := diffEnv(t)

	rec := do(t, h, http.MethodPost, "/api/revert", testToken,
		map[string]string{"path": "missing.org", "hash": commits[0]}, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")

	invalid := do(t, h, http.MethodPost, "/api/revert", testToken,
		map[string]string{"path": "a.org", "hash": "deadbeef"}, nil)
	assertErrorCode(t, invalid, http.StatusBadRequest, "invalid_argument")
}

// TestRevertUnauthorized 验证 revert 端点同样走 Bearer 认证中间件。
func TestRevertUnauthorized(t *testing.T) {
	h, _, _, commits := diffEnv(t)

	rec := do(t, h, http.MethodPost, "/api/revert", "",
		map[string]string{"path": "a.org", "hash": commits[0]}, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("缺失令牌时状态码 = %d, 期望 401", rec.Code)
	}
}

// TestRevertRejectsUnsafePath 验证 revert 的路径必须过与其它写端点相同的严格口径。
//
// 为什么这条不变量必须单独锁：repo.Revert 落到 gitver.resolve，那里为了按名字取
// blob 而把 AllowDotSegments / AllowParentSegments 全开；若 handleRevert 不先过
// cleanRelPath，隐藏文件（.hidden.org）与 .git 内部路径都能经 revert 落盘，绕过
// 「隐藏文件不可写」「.git 不可经 API 访问」两条不变量。
//
// hash 传任意非空值即可：路径校验发生在 repo.Revert 之前，不会触达 hash 解析。
func TestRevertRejectsUnsafePath(t *testing.T) {
	h, _, root, commits := diffEnv(t)

	cases := []struct{ name, path string }{
		{"隐藏文件", ".hidden.org"},
		{"git 内部路径", ".git/config"},
		{"上跳段", "../outside.org"},
		{"点目录", ".obsidian/workspace.json"},
		{"NUL 字节", "a\x00.org"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodPost, "/api/revert", testToken,
				map[string]string{"path": tc.path, "hash": commits[0]}, nil)
			assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
		})
	}

	// 落盘副作用必须为零：被拒的隐藏文件不得出现在工作区（哪怕内容为空）。
	if _, err := os.Stat(filepath.Join(root, ".hidden.org")); !os.IsNotExist(err) {
		t.Fatalf("隐藏文件经 revert 落盘了: stat err = %v", err)
	}
}
