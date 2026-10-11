package gitver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// 已知内容的 git blob hash（由 git hash-object --stdin 独立得到，用于交叉验证）。
const (
	helloBlobHash = "ce013625030ba8dba906f756967f9e9ca394464a" // "hello\n"
	emptyBlobHash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" // ""
)

// openTestRepo 在临时目录上打开（并首次初始化）仓库。
func openTestRepo(t *testing.T) (*Repo, string) {
	t.Helper()
	root := t.TempDir()
	repo, err := Open(root)
	if err != nil {
		t.Fatalf("Open(%s) 失败: %v", root, err)
	}
	return repo, root
}

// writeFile 在 root 下写入文件，失败即终止测试。
func writeFile(t *testing.T, root, name, content string) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("写入 %s 失败: %v", name, err)
	}
}

// logCount 返回当前提交数量。
func logCount(t *testing.T, repo *Repo) int {
	t.Helper()
	entries, err := repo.Log(0)
	if err != nil {
		t.Fatalf("Log 失败: %v", err)
	}
	return len(entries)
}

// TestOpenInitializesRepo 验证 Open 在空目录上初始化仓库、
// 在已有仓库上能再次打开，并设置了默认提交身份。
func TestOpenInitializesRepo(t *testing.T) {
	root := t.TempDir()

	repo, err := Open(root)
	if err != nil {
		t.Fatalf("首次 Open 失败: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, ".git")); err != nil {
		t.Fatalf(".git 目录不存在: %v", err)
	}

	cfg, err := repo.repo.Config()
	if err != nil {
		t.Fatalf("读取配置失败: %v", err)
	}
	if cfg.User.Name != "notes" || cfg.User.Email != "notes@local" {
		t.Errorf("默认身份 = %q <%q>, 期望 notes <notes@local>", cfg.User.Name, cfg.User.Email)
	}

	// 再次 Open 应当打开已存在的仓库，而不是重新初始化。
	reopened, err := Open(root)
	if err != nil {
		t.Fatalf("再次 Open 失败: %v", err)
	}
	if got := logCount(t, reopened); got != 0 {
		t.Errorf("新仓库提交数 = %d, 期望 0", got)
	}
}

// TestCommitOnlyWhenChanged 验证有变更时产生提交、无变更时不产生空提交。
func TestCommitOnlyWhenChanged(t *testing.T) {
	repo, root := openTestRepo(t)

	// 仓库刚初始化且无文件：无变更，不应产生提交。
	if err := repo.Commit("空提交尝试"); err != nil {
		t.Fatalf("无变更 Commit 返回错误: %v", err)
	}
	if got := logCount(t, repo); got != 0 {
		t.Fatalf("无变更时提交数 = %d, 期望 0", got)
	}

	// 首次写入：产生一个提交。
	writeFile(t, root, "a.org", "* a\n")
	if err := repo.Commit("webdav internal: PUT a.org"); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}
	if got := logCount(t, repo); got != 1 {
		t.Fatalf("首次提交后提交数 = %d, 期望 1", got)
	}

	// 无变更再次提交：提交数不变。
	if err := repo.Commit("无变更"); err != nil {
		t.Fatalf("无变更 Commit 返回错误: %v", err)
	}
	if got := logCount(t, repo); got != 1 {
		t.Fatalf("无变更再次提交后提交数 = %d, 期望 1", got)
	}

	// 修改内容：产生第二个提交。
	writeFile(t, root, "a.org", "* a 修改\n")
	if err := repo.Commit("webdav internal: PUT a.org"); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}
	if got := logCount(t, repo); got != 2 {
		t.Fatalf("修改后提交数 = %d, 期望 2", got)
	}
}

// TestBlobHash 验证 BlobHash 计算与 git 对象格式一致，
// 且对不存在的文件返回空串。
func TestBlobHash(t *testing.T) {
	repo, root := openTestRepo(t)

	writeFile(t, root, "hello.txt", "hello\n")
	writeFile(t, root, "empty.txt", "")

	cases := []struct {
		name  string
		want  string
		paths []string
	}{
		{name: "hello.txt", want: helloBlobHash, paths: []string{"hello.txt", "/hello.txt", "./hello.txt"}},
		{name: "empty.txt", want: emptyBlobHash, paths: []string{"empty.txt"}},
	}

	for _, tc := range cases {
		for _, p := range tc.paths {
			got, err := repo.BlobHash(p)
			if err != nil {
				t.Fatalf("BlobHash(%q) 失败: %v", p, err)
			}
			if got != tc.want {
				t.Errorf("BlobHash(%q) = %q, 期望 %q", p, got, tc.want)
			}
		}
	}

	// 不存在的文件返回空串。
	got, err := repo.BlobHash("missing.txt")
	if err != nil {
		t.Fatalf("BlobHash(不存在) 返回错误: %v", err)
	}
	if got != "" {
		t.Errorf("BlobHash(不存在) = %q, 期望空串", got)
	}

	// 目录没有内容哈希，返回空串。
	if got, err := repo.BlobHash("."); err != nil || got != "" {
		t.Errorf("BlobHash(.) = %q, %v; 期望空串, nil", got, err)
	}

	// ".." 被规范化到工作区根内（与 webdav.Dir 同策略），
	// 因此不能读取仓库外的同名文件。
	base := t.TempDir()
	repoRoot := filepath.Join(base, "repo")
	if err := os.Mkdir(repoRoot, 0o755); err != nil {
		t.Fatalf("创建仓库目录失败: %v", err)
	}
	if err := os.WriteFile(filepath.Join(base, "secret.txt"), []byte("secret\n"), 0o644); err != nil {
		t.Fatalf("写入仓库外文件失败: %v", err)
	}

	scoped, err := Open(repoRoot)
	if err != nil {
		t.Fatalf("Open(%s) 失败: %v", repoRoot, err)
	}

	// 仓库根内不存在 secret.txt：规范化后路径仍在根内，因此返回空串，
	// 而不是仓库外 secret.txt 的 hash。
	escaped, err := scoped.BlobHash("../secret.txt")
	if err != nil {
		t.Fatalf("BlobHash(../secret.txt) 失败: %v", err)
	}
	if escaped != "" {
		t.Errorf("BlobHash(../secret.txt) = %q, 期望空串（不得读到工作区外的文件）", escaped)
	}

	// 规范化后与根内路径等价（"a/../hello.txt" == "hello.txt"）。
	writeFile(t, repoRoot, "hello.txt", "hello\n")
	if got, err := scoped.BlobHash("a/../hello.txt"); err != nil || got != helloBlobHash {
		t.Errorf("BlobHash(a/../hello.txt) = %q, %v; 期望 %q", got, err, helloBlobHash)
	}
}

// TestCommitConcurrent 验证多 goroutine 并发提交不会 panic、
// 不会损坏数据（内容与提交历史均一致）。
func TestCommitConcurrent(t *testing.T) {
	repo, root := openTestRepo(t)

	const workers = 8
	var wg sync.WaitGroup
	errs := make([]error, workers)

	for i := range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			content := fmt.Sprintf("* 并发内容 %d\n", i)
			if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("c%d.org", i)), []byte(content), 0o644); err != nil {
				errs[i] = err
				return
			}
			errs[i] = repo.Commit(fmt.Sprintf("webdav internal: PUT c%d.org", i))
		}()
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("worker %d 失败: %v", i, err)
		}
	}

	// 数据未损坏：每个文件内容仍然是各自写入的内容。
	for i := range workers {
		path := filepath.Join(root, fmt.Sprintf("c%d.org", i))
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读取 c%d.org 失败: %v", i, err)
		}
		want := fmt.Sprintf("* 并发内容 %d\n", i)
		if string(content) != want {
			t.Errorf("c%d.org 内容 = %q, 期望 %q", i, string(content), want)
		}
	}

	// 提交历史可读且数量合理（串行化下 1..workers 条）。
	count := logCount(t, repo)
	if count < 1 || count > workers {
		t.Errorf("并发提交后提交数 = %d, 期望 1..%d", count, workers)
	}

	// 每个文件都已进入版本库（blob hash 与 git 计算一致）。
	hash, err := repo.BlobHash("c0.org")
	if err != nil || hash == "" {
		t.Errorf("BlobHash(c0.org) = %q, %v; 期望非空", hash, err)
	}
}

// TestLogReturnsHistory 验证 Log 返回最近的提交（新到旧）并尊重 limit。
func TestLogReturnsHistory(t *testing.T) {
	repo, root := openTestRepo(t)

	messages := []string{
		"webdav internal: PUT a.org",
		"webdav external: PUT b.org",
		"webdav internal: DELETE a.org",
	}
	for i, name := range []string{"a.org", "b.org", "c.org"} {
		writeFile(t, root, name, fmt.Sprintf("* 第 %d 次\n", i))
		if err := repo.Commit(messages[i]); err != nil {
			t.Fatalf("第 %d 次 Commit 失败: %v", i, err)
		}
	}

	entries, err := repo.Log(0)
	if err != nil {
		t.Fatalf("Log 失败: %v", err)
	}
	if len(entries) != len(messages) {
		t.Fatalf("Log 条目数 = %d, 期望 %d", len(entries), len(messages))
	}

	// 最新提交在最前，格式为 "<40 位 hash> <message>"。
	first := entries[0]
	parts := strings.SplitN(first, " ", 2)
	if len(parts) != 2 {
		t.Fatalf("Log 条目格式 = %q, 期望 \"<hash> <message>\"", first)
	}
	if len(parts[0]) != 40 {
		t.Errorf("hash 长度 = %d, 期望 40 (%q)", len(parts[0]), parts[0])
	}
	if parts[1] != messages[len(messages)-1] {
		t.Errorf("最新 message = %q, 期望 %q", parts[1], messages[len(messages)-1])
	}

	// limit 生效。
	limited, err := repo.Log(2)
	if err != nil {
		t.Fatalf("Log(2) 失败: %v", err)
	}
	if len(limited) != 2 {
		t.Errorf("Log(2) 条目数 = %d, 期望 2", len(limited))
	}
}
