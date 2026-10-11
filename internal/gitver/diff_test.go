package gitver

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"notes/internal/logging"
)

// assertAppErrorCode 断言 err 是带指定错误码的 AppError（跨测试文件共用）。
func assertAppErrorCode(t *testing.T, err error, code logging.Code) {
	t.Helper()
	var appErr *logging.AppError
	if !errors.As(err, &appErr) {
		t.Fatalf("错误 = %v, 期望 *logging.AppError", err)
	}
	if appErr.Code != code {
		t.Fatalf("错误码 = %q, 期望 %q", appErr.Code, code)
	}
}

// diffFixture 构造 a.org 的两版内容（c1 → c2），返回仓库、工作区根与提交 hash。
func diffFixture(t *testing.T) (repo *Repo, root, c1, c2 string) {
	t.Helper()
	repo, root = openTestRepo(t)
	c1 = commitContent(t, repo, root, "a.org", "第一行\n第二行\n第三行\n", "c1")
	c2 = commitContent(t, repo, root, "a.org", "第一行\n第二行改\n第三行\n第四行\n", "c2")
	return repo, root, c1, c2
}

// TestDiffShowsAddedAndRemovedLines 验证 Diff 输出含 unified diff 的文件头、
// hunk 头与增删行标记，且反向 diff 的增删标记互换、相同版本无输出。
func TestDiffShowsAddedAndRemovedLines(t *testing.T) {
	repo, _, c1, c2 := diffFixture(t)

	diff, err := repo.Diff("a.org", c1, c2)
	if err != nil {
		t.Fatalf("Diff 失败: %v", err)
	}
	for _, want := range []string{
		"--- a/a.org\n",
		"+++ b/a.org\n",
		"@@ ",
		" 第一行\n", // 未变行作为上下文保留
		"-第二行\n",
		"+第二行改\n",
		"+第四行\n",
	} {
		if !strings.Contains(diff, want) {
			t.Errorf("Diff 输出缺少 %q:\n%s", want, diff)
		}
	}

	// 反向 diff：增删标记互换。
	reverse, err := repo.Diff("a.org", c2, c1)
	if err != nil {
		t.Fatalf("反向 Diff 失败: %v", err)
	}
	if !strings.Contains(reverse, "-第二行改\n") || !strings.Contains(reverse, "+第二行\n") {
		t.Errorf("反向 Diff 未互换增删标记:\n%s", reverse)
	}

	// 相同版本：无差异，输出为空串。
	same, err := repo.Diff("a.org", c1, c1)
	if err != nil {
		t.Fatalf("Diff(相同版本) 失败: %v", err)
	}
	if same != "" {
		t.Errorf("Diff(相同版本) = %q, 期望空串", same)
	}
}

// TestDiffErrors 验证非法版本返回 invalid_argument、文件不存在返回 not_found。
func TestDiffErrors(t *testing.T) {
	repo, _, c1, c2 := diffFixture(t)

	if _, err := repo.Diff("a.org", "deadbeef", c2); err != nil {
		assertAppErrorCode(t, err, logging.ErrInvalidArgument)
	} else {
		t.Error("Diff(非法 from) 期望错误，得到 nil")
	}

	if _, err := repo.Diff("a.org", c1, "not-a-rev"); err != nil {
		assertAppErrorCode(t, err, logging.ErrInvalidArgument)
	} else {
		t.Error("Diff(非法 to) 期望错误，得到 nil")
	}

	if _, err := repo.Diff("missing.org", c1, c2); err != nil {
		assertAppErrorCode(t, err, logging.ErrNotFound)
	} else {
		t.Error("Diff(文件不存在) 期望错误，得到 nil")
	}
}

// TestRevertRestoresContentAndCommits 验证 Revert 把工作区文件恢复到历史版本，
// 并以追加新提交（而非改写历史）的方式落库。
func TestRevertRestoresContentAndCommits(t *testing.T) {
	repo, root, c1, c2 := diffFixture(t)

	if err := repo.Revert("a.org", c1); err != nil {
		t.Fatalf("Revert 失败: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(root, "a.org"))
	if err != nil {
		t.Fatalf("读取工作区文件失败: %v", err)
	}
	if string(got) != "第一行\n第二行\n第三行\n" {
		t.Errorf("工作区内容 = %q, 期望恢复为 c1 的内容", string(got))
	}

	newHead := headHash(t, repo)
	if newHead == c2 {
		t.Errorf("Revert 后 HEAD 仍为 %s，期望产生了新提交", c2)
	}
	if n := logCount(t, repo); n != 3 {
		t.Errorf("提交数 = %d, 期望 3（c1、c2 加 revert 提交）", n)
	}

	content, err := repo.FileContent("a.org", newHead)
	if err != nil {
		t.Fatalf("读取新版本内容失败: %v", err)
	}
	if content != "第一行\n第二行\n第三行\n" {
		t.Errorf("新版本内容 = %q, 期望恢复后的内容", content)
	}
}

// TestRevertRecreatesDeletedFile 验证 Revert 能重建已被删除的文件（含父目录）。
func TestRevertRecreatesDeletedFile(t *testing.T) {
	repo, root, c1, _ := diffFixture(t)

	if err := os.Remove(filepath.Join(root, "a.org")); err != nil {
		t.Fatalf("删除文件失败: %v", err)
	}
	if err := repo.Commit("删除 a.org"); err != nil {
		t.Fatalf("提交删除失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "a.org")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("前置条件不成立：a.org 应已被删除（err=%v）", err)
	}

	if err := repo.Revert("a.org", c1); err != nil {
		t.Fatalf("Revert 失败: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(root, "a.org"))
	if err != nil {
		t.Fatalf("读取恢复后的文件失败: %v", err)
	}
	if string(got) != "第一行\n第二行\n第三行\n" {
		t.Errorf("恢复后内容 = %q, 期望 c1 的内容", string(got))
	}
}

// TestRevertErrors 验证文件在该版本不存在返回 not_found、版本非法返回 invalid_argument。
func TestRevertErrors(t *testing.T) {
	repo, _, c1, _ := diffFixture(t)

	if err := repo.Revert("missing.org", c1); err != nil {
		assertAppErrorCode(t, err, logging.ErrNotFound)
	} else {
		t.Error("Revert(文件不存在) 期望错误，得到 nil")
	}

	if err := repo.Revert("a.org", "deadbeef"); err != nil {
		assertAppErrorCode(t, err, logging.ErrInvalidArgument)
	} else {
		t.Error("Revert(版本非法) 期望错误，得到 nil")
	}
}
