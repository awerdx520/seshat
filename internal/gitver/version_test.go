package gitver

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"seshat/internal/logging"
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
	if cfg.User.Name != "seshat" || cfg.User.Email != "seshat@local" {
		t.Errorf("默认身份 = %q <%q>, 期望 seshat <seshat@local>", cfg.User.Name, cfg.User.Email)
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

// logHeadHash 取 Log(1) 中最新提交的 hash，作为 Head 的交叉验证基准。
func logHeadHash(t *testing.T, repo *Repo) string {
	t.Helper()
	entries, err := repo.Log(1)
	if err != nil {
		t.Fatalf("Log(1) 失败: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("Log(1) 条目数 = %d, 期望 1", len(entries))
	}
	parts := strings.SplitN(entries[0], " ", 2)
	if len(parts) != 2 {
		t.Fatalf("Log(1) 条目格式 = %q, 期望 \"<hash> <message>\"", entries[0])
	}
	return parts[0]
}

// TestHeadEmptyRepo 验证空仓库（尚无任何提交）上 Head 返回空串与 nil error，
// 而不是把「无 rev」当作错误抛给调用方。
func TestHeadEmptyRepo(t *testing.T) {
	repo, _ := openTestRepo(t)

	hash, err := repo.Head()
	if err != nil {
		t.Fatalf("空仓库 Head 返回错误: %v", err)
	}
	if hash != "" {
		t.Errorf("空仓库 Head = %q, 期望空串", hash)
	}
}

// TestHeadAfterCommit 验证提交一次后 Head 与 Log(1) 中的 hash 一致，
// 且无变更的再次 Commit 不改变 HEAD。
func TestHeadAfterCommit(t *testing.T) {
	repo, root := openTestRepo(t)

	writeFile(t, root, "a.org", "* a\n")
	if err := repo.Commit("webdav internal: PUT a.org"); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	hash, err := repo.Head()
	if err != nil {
		t.Fatalf("Head 失败: %v", err)
	}
	if hash == "" {
		t.Fatal("提交后 Head 为空串")
	}
	if len(hash) != 40 {
		t.Errorf("Head 长度 = %d, 期望 40 (%q)", len(hash), hash)
	}
	if want := logHeadHash(t, repo); hash != want {
		t.Errorf("Head = %q, 期望与 Log(1) 一致 %q", hash, want)
	}

	// 无变更提交不产生新提交，HEAD 保持不变。
	if err := repo.Commit("无变更"); err != nil {
		t.Fatalf("无变更 Commit 返回错误: %v", err)
	}
	if again, err := repo.Head(); err != nil || again != hash {
		t.Errorf("无变更提交后 Head = %q, %v; 期望 %q, nil", again, err, hash)
	}
}

// TestHeadAfterTwoCommits 验证提交两次后 Head 返回最新提交的 hash，
// 与 Log(1) 一致且不等于第一次的 hash。
func TestHeadAfterTwoCommits(t *testing.T) {
	repo, root := openTestRepo(t)

	writeFile(t, root, "a.org", "* 第 1 次\n")
	if err := repo.Commit("webdav internal: PUT a.org"); err != nil {
		t.Fatalf("首次 Commit 失败: %v", err)
	}
	first, err := repo.Head()
	if err != nil {
		t.Fatalf("首次 Head 失败: %v", err)
	}
	if first == "" {
		t.Fatal("首次提交后 Head 为空串")
	}

	writeFile(t, root, "a.org", "* 第 2 次\n")
	if err := repo.Commit("webdav internal: PUT a.org"); err != nil {
		t.Fatalf("第二次 Commit 失败: %v", err)
	}
	second, err := repo.Head()
	if err != nil {
		t.Fatalf("第二次 Head 失败: %v", err)
	}

	if second == first {
		t.Errorf("两次提交后 Head 未推进: 仍为 %q", second)
	}
	if want := logHeadHash(t, repo); second != want {
		t.Errorf("Head = %q, 期望与 Log(1) 一致 %q", second, want)
	}

	// 与 Log(0) 的历史顺序交叉验证：最新在前，第二个即旧 HEAD。
	entries, err := repo.Log(0)
	if err != nil {
		t.Fatalf("Log(0) 失败: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("提交数 = %d, 期望 2", len(entries))
	}
	if got := strings.SplitN(entries[1], " ", 2)[0]; got != first {
		t.Errorf("历史中的旧提交 = %q, 期望 %q", got, first)
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

// TestRenameAndCommitFile 验证重命名文件：旧路径消失、新路径内容不变、追加一次提交。
func TestRenameAndCommitFile(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	if err := repo.RenameAndCommit("a.org", "sub/b.org", "改名 a.org → sub/b.org"); err != nil {
		t.Fatalf("RenameAndCommit 失败: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "a.org")); !os.IsNotExist(err) {
		t.Errorf("旧路径仍存在（err=%v）", err)
	}
	content, err := os.ReadFile(filepath.Join(root, "sub", "b.org"))
	if err != nil {
		t.Fatalf("读取新路径失败: %v", err)
	}
	if string(content) != "hello\n" {
		t.Errorf("新路径内容 = %q, 期望 %q", string(content), "hello\n")
	}
	if got := logCount(t, repo); got != before+1 {
		t.Errorf("提交数 = %d, 期望 %d（改名应追加一次提交）", got, before+1)
	}
	if hash, err := repo.BlobHash("a.org"); err != nil || hash != "" {
		t.Errorf("旧路径 BlobHash = (%q,%v), 期望空串", hash, err)
	}
	if hash, err := repo.BlobHash("sub/b.org"); err != nil || hash == "" {
		t.Errorf("新路径 BlobHash = (%q,%v), 期望非空", hash, err)
	}
}

// TestRenameAndCommitDirectory 验证重命名目录：整棵子树搬迁、追加一次提交。
func TestRenameAndCommitDirectory(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("old/a.org", "A\n", "写 old/a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	if err := repo.WriteAndCommit("old/deep/b.org", "B\n", "写 old/deep/b.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	if err := repo.RenameAndCommit("old", "new", "改名目录 old → new"); err != nil {
		t.Fatalf("RenameAndCommit 失败: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "old")); !os.IsNotExist(err) {
		t.Errorf("旧目录仍存在（err=%v）", err)
	}
	for _, rel := range []string{filepath.Join("new", "a.org"), filepath.Join("new", "deep", "b.org")} {
		if _, err := os.Stat(filepath.Join(root, rel)); err != nil {
			t.Errorf("新方案下 %s 不可读: %v", rel, err)
		}
	}
	if got := logCount(t, repo); got != before+1 {
		t.Errorf("提交数 = %d, 期望 %d", got, before+1)
	}
}

// TestRemoveAndCommitFile 验证删除文件：文件消失、追加一次提交、不产生空提交之外的副作用。
func TestRemoveAndCommitFile(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	if err := repo.RemoveAndCommit("a.org", "删除 a.org"); err != nil {
		t.Fatalf("RemoveAndCommit 失败: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "a.org")); !os.IsNotExist(err) {
		t.Errorf("文件仍存在（err=%v）", err)
	}
	if got := logCount(t, repo); got != before+1 {
		t.Errorf("提交数 = %d, 期望 %d（删除应追加一次提交）", got, before+1)
	}
}

// TestRemoveAndCommitDirectory 验证删除目录：整棵子树消失、追加一次提交。
func TestRemoveAndCommitDirectory(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("dir/a.org", "A\n", "写 dir/a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	if err := repo.WriteAndCommit("dir/sub/b.org", "B\n", "写 dir/sub/b.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	if err := repo.RemoveAndCommit("dir", "删除目录 dir"); err != nil {
		t.Fatalf("RemoveAndCommit 失败: %v", err)
	}

	if _, err := os.Stat(filepath.Join(root, "dir")); !os.IsNotExist(err) {
		t.Errorf("目录仍存在（err=%v）", err)
	}
	if got := logCount(t, repo); got != before+1 {
		t.Errorf("提交数 = %d, 期望 %d", got, before+1)
	}
}

// TestRenameAndRemoveAndCommitMissing 验证源路径不存在时返回 ErrNotFound 且不产生提交。
func TestRenameAndRemoveAndCommitMissing(t *testing.T) {
	repo, _ := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	if err := repo.RenameAndCommit("nope.org", "b.org", "改名"); err == nil {
		t.Fatal("重命名不存在的文件应失败")
	} else {
		assertAppErrorCode(t, err, logging.ErrNotFound)
	}
	if err := repo.RemoveAndCommit("nope.org", "删除"); err == nil {
		t.Fatal("删除不存在的文件应失败")
	} else {
		assertAppErrorCode(t, err, logging.ErrNotFound)
	}
	if got := logCount(t, repo); got != before {
		t.Errorf("提交数 = %d, 期望 %d（失败的操作不应产生提交）", got, before)
	}
}

// TestRenameAndRemoveAndCommitEscape 验证路径无法逃出仓库根：指向仓库根或含 ".."
// 的入参不会触达根外文件。
func TestRenameAndRemoveAndCommitEscape(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}

	// 仓库根之外的文件：任何入参都不得删除或改名它。
	outside := filepath.Join(filepath.Dir(root), "outside.org")
	if err := os.WriteFile(outside, []byte("outside\n"), 0o644); err != nil {
		t.Fatalf("写入根外文件失败: %v", err)
	}
	t.Cleanup(func() { _ = os.Remove(outside) })

	// ".." 被 resolve 吸收为根内路径，因此这条命令只会命中根内的 outside.org
	// （不存在）→ ErrNotFound；根外文件必须完好。
	if err := repo.RemoveAndCommit("../outside.org", "删除"); err == nil {
		t.Fatal("根外文件不应被删除")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatalf("根外文件被删除或不可读: %v", err)
	}

	// 指向仓库根自身不是合法的工作区路径。
	if err := repo.RemoveAndCommit(".", "删除仓库根"); err == nil {
		t.Fatal("删除仓库根应失败")
	} else {
		assertAppErrorCode(t, err, logging.ErrInvalidArgument)
	}
	if err := repo.RenameAndCommit(".", "x", "改名仓库根"); err == nil {
		t.Fatal("重命名仓库根应失败")
	} else {
		assertAppErrorCode(t, err, logging.ErrInvalidArgument)
	}
}

// readFile 读取 root 下文件内容，失败即终止测试（条件写测试据此断言「内容未变」）。
func readFile(t *testing.T, root, name string) string {
	t.Helper()
	content, err := os.ReadFile(filepath.Join(root, name))
	if err != nil {
		t.Fatalf("读取 %s 失败: %v", name, err)
	}
	return string(content)
}

// TestWriteAndCommitIfCreateWhenAbsent 验证 wantAbsent=true 且目标不存在：
// 成功创建、created=true，工作区内容与提交均落地。
func TestWriteAndCommitIfCreateWhenAbsent(t *testing.T) {
	repo, root := openTestRepo(t)

	created, err := repo.WriteAndCommitIf("new.org", "hello\n", "创建 new.org", "", true)
	if err != nil {
		t.Fatalf("WriteAndCommitIf 失败: %v", err)
	}
	if !created {
		t.Error("created = false, 期望 true（写入前目标不存在）")
	}
	if got := readFile(t, root, "new.org"); got != "hello\n" {
		t.Errorf("内容 = %q, 期望 %q", got, "hello\n")
	}
	if n := logCount(t, repo); n != 1 {
		t.Errorf("提交数 = %d, 期望 1", n)
	}
	if hash, hashErr := repo.BlobHash("new.org"); hashErr != nil || hash != helloBlobHash {
		t.Errorf("BlobHash = %q (err=%v), 期望 %q", hash, hashErr, helloBlobHash)
	}
}

// TestWriteAndCommitIfAbsentRejectsExisting 验证 wantAbsent=true 且目标已存在：
// 返回 ErrBlobMismatch，内容不变，且不产生新提交。
func TestWriteAndCommitIfAbsentRejectsExisting(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "old\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	created, err := repo.WriteAndCommitIf("a.org", "new\n", "覆盖 a.org", "", true)
	if err == nil {
		t.Fatal("目标已存在时 wantAbsent 应返回错误")
	}
	if !errors.Is(err, ErrBlobMismatch) {
		t.Errorf("err = %v, 期望 ErrBlobMismatch", err)
	}
	if created {
		t.Error("created = true, 期望 false（条件不成立时未创建）")
	}
	if got := readFile(t, root, "a.org"); got != "old\n" {
		t.Errorf("内容 = %q, 期望保持 %q（条件不成立不得写入）", got, "old\n")
	}
	if n := logCount(t, repo); n != before {
		t.Errorf("提交数 = %d, 期望 %d（条件不成立不得产生提交）", n, before)
	}
}

// TestWriteAndCommitIfBlobMatch 验证 wantBlob 与当前内容一致：写入成功、created=false。
func TestWriteAndCommitIfBlobMatch(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	created, err := repo.WriteAndCommitIf("a.org", "hello world\n", "更新 a.org", helloBlobHash, false)
	if err != nil {
		t.Fatalf("WriteAndCommitIf 失败: %v", err)
	}
	if created {
		t.Error("created = true, 期望 false（写入前目标已存在）")
	}
	if got := readFile(t, root, "a.org"); got != "hello world\n" {
		t.Errorf("内容 = %q, 期望 %q", got, "hello world\n")
	}
	if n := logCount(t, repo); n != before+1 {
		t.Errorf("提交数 = %d, 期望 %d", n, before+1)
	}
	if hash, hashErr := repo.BlobHash("a.org"); hashErr != nil || hash != blobHash([]byte("hello world\n")) {
		t.Errorf("写入后 BlobHash = %q (err=%v), 期望新内容的 blob", hash, hashErr)
	}
}

// TestWriteAndCommitIfBlobMismatchRejects 验证 wantBlob 与当前内容不符：
// 返回 ErrBlobMismatch，内容不变。
func TestWriteAndCommitIfBlobMismatchRejects(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	// emptyBlobHash 是空内容的 blob，与当前 "hello\n" 不符。
	created, err := repo.WriteAndCommitIf("a.org", "new\n", "覆盖 a.org", emptyBlobHash, false)
	if err == nil {
		t.Fatal("wantBlob 不符时应返回错误")
	}
	if !errors.Is(err, ErrBlobMismatch) {
		t.Errorf("err = %v, 期望 ErrBlobMismatch", err)
	}
	if created {
		t.Error("created = true, 期望 false")
	}
	if got := readFile(t, root, "a.org"); got != "hello\n" {
		t.Errorf("内容 = %q, 期望保持 %q", got, "hello\n")
	}
	if n := logCount(t, repo); n != before {
		t.Errorf("提交数 = %d, 期望 %d（条件不成立不得产生提交）", n, before)
	}
}

// TestWriteAndCommitIfBlobMissingFile 验证 wantBlob 非空但文件不存在：
// 返回 ErrBlobMismatch，且不会把文件「凭旧 hash」重新创建出来。
func TestWriteAndCommitIfBlobMissingFile(t *testing.T) {
	repo, root := openTestRepo(t)

	created, err := repo.WriteAndCommitIf("ghost.org", "hello\n", "创建 ghost.org", helloBlobHash, false)
	if err == nil {
		t.Fatal("文件不存在且 wantBlob 非空时应返回错误")
	}
	if !errors.Is(err, ErrBlobMismatch) {
		t.Errorf("err = %v, 期望 ErrBlobMismatch", err)
	}
	if created {
		t.Error("created = true, 期望 false")
	}
	if _, statErr := os.Stat(filepath.Join(root, "ghost.org")); !os.IsNotExist(statErr) {
		t.Errorf("文件被创建（stat err=%v），期望不存在", statErr)
	}
	if n := logCount(t, repo); n != 0 {
		t.Errorf("提交数 = %d, 期望 0", n)
	}
}

// TestWriteAndCommitIfUnconditional 验证 wantBlob 为空且 wantAbsent=false：
// 无条件写入（等价 WriteAndCommit），已存在文件被覆盖。
func TestWriteAndCommitIfUnconditional(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "old\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	created, err := repo.WriteAndCommitIf("a.org", "old2\n", "覆盖 a.org", "", false)
	if err != nil {
		t.Fatalf("无条件写入失败: %v", err)
	}
	if created {
		t.Error("created = true, 期望 false（目标已存在）")
	}
	if got := readFile(t, root, "a.org"); got != "old2\n" {
		t.Errorf("内容 = %q, 期望 %q", got, "old2\n")
	}
	if n := logCount(t, repo); n != before+1 {
		t.Errorf("提交数 = %d, 期望 %d", n, before+1)
	}

	// 目标不存在时无条件写入同样成功，且 created=true。
	created, err = repo.WriteAndCommitIf("b.org", "B\n", "创建 b.org", "", false)
	if err != nil {
		t.Fatalf("无条件创建失败: %v", err)
	}
	if !created {
		t.Error("created = false, 期望 true（目标不存在）")
	}
	if got := readFile(t, root, "b.org"); got != "B\n" {
		t.Errorf("内容 = %q, 期望 %q", got, "B\n")
	}
}

// TestWriteAndCommitIfConcurrentSameBlob 验证并发条件写：两个 goroutine 用同一
// wantBlob 同时写同一文件，恰好一个成功、另一个 ErrBlobMismatch，最终内容等于
// 成功者的内容。这是 TOCTOU 的核心回归用例（需 -race 运行）。
func TestWriteAndCommitIfConcurrentSameBlob(t *testing.T) {
	repo, root := openTestRepo(t)
	if err := repo.WriteAndCommit("a.org", "hello\n", "写 a.org"); err != nil {
		t.Fatalf("WriteAndCommit 失败: %v", err)
	}
	before := logCount(t, repo)

	contents := []string{"来自 A\n", "来自 B\n"}
	errs := make([]error, len(contents))
	createdFlags := make([]bool, len(contents))

	var wg sync.WaitGroup
	for i, content := range contents {
		wg.Add(1)
		go func(i int, content string) {
			defer wg.Done()
			createdFlags[i], errs[i] = repo.WriteAndCommitIf(
				"a.org", content, fmt.Sprintf("并发写 a.org #%d", i), helloBlobHash, false)
		}(i, content)
	}
	wg.Wait()

	winner := -1
	for i, err := range errs {
		switch {
		case err == nil:
			winner = i
			if createdFlags[i] {
				t.Errorf("成功者 #%d 的 created = true, 期望 false（目标原已存在）", i)
			}
		case errors.Is(err, ErrBlobMismatch):
			// 预期：另一个 goroutine 已改了内容，条件不再成立。
		default:
			t.Errorf("goroutine #%d 返回意外错误: %v", i, err)
		}
	}
	if winner < 0 {
		t.Fatalf("没有 goroutine 成功，错误列表: %v", errs)
	}

	if got := readFile(t, root, "a.org"); got != contents[winner] {
		t.Errorf("最终内容 = %q, 期望成功者写入的 %q", got, contents[winner])
	}
	if n := logCount(t, repo); n != before+1 {
		t.Errorf("提交数 = %d, 期望 %d（只有成功者产生一次提交）", n, before+1)
	}
}
