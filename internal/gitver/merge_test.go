package gitver

import (
	"errors"
	"testing"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"

	"seshat/internal/logging"
)

// commitContent 写入 name 后提交，返回新提交的完整 hash。
func commitContent(t *testing.T, repo *Repo, root, name, content, message string) string {
	t.Helper()
	writeFile(t, root, name, content)
	if err := repo.Commit(message); err != nil {
		t.Fatalf("Commit(%q) 失败: %v", message, err)
	}
	return headHash(t, repo)
}

// headHash 返回当前 HEAD 指向提交的完整 hash。
func headHash(t *testing.T, repo *Repo) string {
	t.Helper()
	ref, err := repo.repo.Head()
	if err != nil {
		t.Fatalf("读取 HEAD 失败: %v", err)
	}
	return ref.Hash().String()
}

// checkoutBranch 从 from 指定的提交创建并切换到新分支。
func checkoutBranch(t *testing.T, repo *Repo, from, branch string) {
	t.Helper()
	wt, err := repo.repo.Worktree()
	if err != nil {
		t.Fatalf("获取工作区失败: %v", err)
	}
	if err := wt.Checkout(&git.CheckoutOptions{
		Hash:   plumbing.NewHash(from),
		Branch: plumbing.NewBranchReferenceName(branch),
		Create: true,
	}); err != nil {
		t.Fatalf("切换到分支 %s 失败: %v", branch, err)
	}
}

// mergeFixture 构造「共同祖先 + 两个分叉分支」的历史：
//
//	c1(共同祖先) ──┬── c2(feature 分支)
//	               └── c3(other 分支, HEAD)
//
// 因此 MergeBase(c2, c3) == c1。这便是自有客户端遇到 412 时的场景：
// 本地基线 c2 与远端最新版 c3 岔开，共同祖先是 c1。
func mergeFixture(t *testing.T) (repo *Repo, root, c1, c2, c3 string) {
	t.Helper()
	repo, root = openTestRepo(t)

	c1 = commitContent(t, repo, root, "a.org", "祖先内容\n", "c1 祖先")

	checkoutBranch(t, repo, c1, "feature")
	c2 = commitContent(t, repo, root, "a.org", "第二版内容\n", "c2 分支A")

	checkoutBranch(t, repo, c1, "other")
	c3 = commitContent(t, repo, root, "a.org", "第三版内容\n", "c3 分支B")

	return repo, root, c1, c2, c3
}

// writeOrphanCommit 直接在仓库对象库中写入一个无父提交（孤立提交），
// 用于验证「无共同祖先」的分支。它绕过工作区，因此不改变 HEAD。
func writeOrphanCommit(t *testing.T, repo *Repo, name, content, message string) string {
	t.Helper()
	store := repo.repo.Storer

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

	sig := object.Signature{Name: identityName, Email: identityEmail, When: time.Now()}
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

// TestMergeBaseReturnsCommonAncestor 验证 MergeBase 返回两个分叉分支的共同祖先，
// 且支持短 hash 与「祖先自身」的退化情形。
func TestMergeBaseReturnsCommonAncestor(t *testing.T) {
	repo, _, c1, c2, c3 := mergeFixture(t)

	got, err := repo.MergeBase(c2, c3)
	if err != nil {
		t.Fatalf("MergeBase(c2, c3) 失败: %v", err)
	}
	if got != c1 {
		t.Errorf("MergeBase(c2, c3) = %s, 期望共同祖先 %s", got, c1)
	}

	// 短 hash 同样可解析。
	got, err = repo.MergeBase(c2[:8], c3[:8])
	if err != nil {
		t.Fatalf("MergeBase(短 hash) 失败: %v", err)
	}
	if got != c1 {
		t.Errorf("MergeBase(短 hash) = %s, 期望 %s", got, c1)
	}

	// 参数顺序不影响结果。
	if got, err = repo.MergeBase(c3, c2); err != nil || got != c1 {
		t.Errorf("MergeBase(c3, c2) = %q, %v; 期望 %s", got, err, c1)
	}

	// 一个是另一个的祖先时，共同祖先是该祖先本身（与 git merge-base 一致）。
	if got, err = repo.MergeBase(c1, c2); err != nil || got != c1 {
		t.Errorf("MergeBase(c1, c2) = %q, %v; 期望 %s", got, err, c1)
	}

	// 非法版本返回错误。
	if _, err = repo.MergeBase("nonexistent-rev", c3); err == nil {
		t.Error("MergeBase(非法版本) 期望错误，得到 nil")
	}
}

// TestMergeBaseWithoutCommonAncestor 验证无共同祖先时返回空串与明确错误。
func TestMergeBaseWithoutCommonAncestor(t *testing.T) {
	repo, root := openTestRepo(t)
	c1 := commitContent(t, repo, root, "a.org", "内容\n", "c1")

	orphan := writeOrphanCommit(t, repo, "orphan.org", "孤立内容\n", "孤立提交")

	got, err := repo.MergeBase(orphan, c1)
	if err == nil {
		t.Fatalf("无共同祖先时期望错误，得到 %q, nil", got)
	}
	if got != "" {
		t.Errorf("无共同祖先时返回值 = %q, 期望空串", got)
	}
}

// TestFileContentAtCommit 验证按版本读取文件内容，以及不存在文件返回 ErrNotFound。
func TestFileContentAtCommit(t *testing.T) {
	repo, _, c1, c2, c3 := mergeFixture(t)

	cases := []struct {
		name   string
		commit string
		want   string
	}{
		{"祖先版本", c1, "祖先内容\n"},
		{"分支A版本", c2, "第二版内容\n"},
		{"分支B最新版本", c3, "第三版内容\n"},
	}
	for _, tc := range cases {
		got, err := repo.FileContent("a.org", tc.commit)
		if err != nil {
			t.Fatalf("FileContent(a.org, %s) 失败: %v", tc.name, err)
		}
		if got != tc.want {
			t.Errorf("%s: FileContent = %q, 期望 %q", tc.name, got, tc.want)
		}
	}

	// 前导 "/" 与 "./" 路径等价。
	for _, p := range []string{"/a.org", "./a.org", "sub/../a.org"} {
		got, err := repo.FileContent(p, c1)
		if err != nil || got != "祖先内容\n" {
			t.Errorf("FileContent(%q, c1) = %q, %v; 期望 %q", p, got, err, "祖先内容\n")
		}
	}

	// 该版本不存在的文件返回 ErrNotFound。
	_, err := repo.FileContent("missing.org", c1)
	var appErr *logging.AppError
	if !errors.As(err, &appErr) {
		t.Fatalf("FileContent(不存在) 错误 = %v, 期望 *logging.AppError", err)
	}
	if appErr.Code != logging.ErrNotFound {
		t.Errorf("FileContent(不存在) 错误码 = %q, 期望 %q", appErr.Code, logging.ErrNotFound)
	}
}

// TestFileHistory 验证 FileHistory 只返回含该文件的提交，且按时间倒序（新到旧）。
func TestFileHistory(t *testing.T) {
	repo, root := openTestRepo(t)

	// 首个提交只含 b.org，不含 a.org：该提交不应出现在 a.org 的历史中。
	commitContent(t, repo, root, "b.org", "无关文件\n", "c1 无 a.org")
	c2 := commitContent(t, repo, root, "a.org", "第一版\n", "c2")
	c3 := commitContent(t, repo, root, "a.org", "第二版\n", "c3")
	c4 := commitContent(t, repo, root, "a.org", "第三版\n", "c4")

	history, err := repo.FileHistory("a.org")
	if err != nil {
		t.Fatalf("FileHistory 失败: %v", err)
	}
	if len(history) != 3 {
		t.Fatalf("FileHistory 条目数 = %d, 期望 3（不含 a.org 的提交应被过滤）", len(history))
	}

	wantHashes := []string{c4, c3, c2}
	wantMessages := []string{"c4", "c3", "c2"}
	for i := range wantHashes {
		if history[i].Hash != wantHashes[i] {
			t.Errorf("history[%d].Hash = %s, 期望 %s（应按时间倒序）", i, history[i].Hash, wantHashes[i])
		}
		if history[i].Message != wantMessages[i] {
			t.Errorf("history[%d].Message = %q, 期望 %q", i, history[i].Message, wantMessages[i])
		}
		if history[i].When.IsZero() {
			t.Errorf("history[%d].When 为零值", i)
		}
	}

	// 从未出现的文件：空历史，无错误。
	empty, err := repo.FileHistory("missing.org")
	if err != nil {
		t.Fatalf("FileHistory(不存在) 失败: %v", err)
	}
	if len(empty) != 0 {
		t.Errorf("FileHistory(不存在) 条目数 = %d, 期望 0", len(empty))
	}
}
