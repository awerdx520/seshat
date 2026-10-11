package gitver

import (
	"errors"
	"fmt"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"

	"notes/internal/logging"
)

// HistoryEntry 描述某文件在一次提交中的出现：提交 hash、提交信息与提交时间。
//
// 供客户端与后续历史浏览（M5.2）使用；Hash 为完整 40 位十六进制字符串。
type HistoryEntry struct {
	Hash    string
	Message string
	When    time.Time
}

// MergeBase 返回两个版本的最佳共同祖先（merge-base）的完整 commit hash。
//
// a、b 为 git revision 字符串（支持完整 hash、短 hash、HEAD、分支名等），
// 经 repo.ResolveRevision 解析。行为对齐 `git merge-base a b`：
// 供自有客户端在 ETag 冲突（412）时取出「共同祖先」，与「最新版」一起在
// 客户端完成三方合并。两者无共同祖先时返回空串与明确错误。
func (r *Repo) MergeBase(a, b string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	commitA, err := r.commitFor(a)
	if err != nil {
		return "", err
	}
	commitB, err := r.commitFor(b)
	if err != nil {
		return "", err
	}

	// go-git 的 MergeBase 返回全部「最佳共同祖先」（criss-cross 合并下可能
	// 多于一个）；常规场景只有一个，取首个即 git merge-base 的结果。
	bases, err := commitA.MergeBase(commitB)
	if err != nil {
		return "", fmt.Errorf("计算 %s 与 %s 的共同祖先失败: %w", a, b, err)
	}
	if len(bases) == 0 {
		// 分属互不相连的历史（如孤立分支）：无共同祖先。
		return "", fmt.Errorf("版本 %s 与 %s 无共同祖先", a, b)
	}
	return bases[0].Hash.String(), nil
}

// FileContent 返回文件 name 在版本 commitHash 处的内容。
//
// name 为仓库内相对路径（允许前导 "/"），与 webdav.Dir 的策略一致，先经
// path.Clean("/"+name) 规范化，".." 因此无法逃出仓库根。文件在该版本不存在
// 时返回包装为 logging.ErrNotFound 的错误，版本无法解析时返回
// logging.ErrInvalidArgument。
func (r *Repo) FileContent(name, commitHash string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	commit, err := r.commitFor(commitHash)
	if err != nil {
		return "", err
	}

	file, err := commit.File(cleanTreePath(name))
	if err != nil {
		if errors.Is(err, object.ErrFileNotFound) ||
			errors.Is(err, object.ErrDirectoryNotFound) {
			return "", logging.Wrap(err, logging.ErrNotFound,
				fmt.Sprintf("文件 %s 在版本 %s 中不存在", name, commitHash))
		}
		return "", logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("读取 %s 在版本 %s 的内容失败", name, commitHash))
	}

	content, err := file.Contents()
	if err != nil {
		return "", logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("读取 %s 在版本 %s 的内容失败", name, commitHash))
	}
	return content, nil
}

// FileHistory 返回文件 name 在 HEAD 可达历史中出现过的提交，按提交时间倒序
// （新到旧），每个条目含提交 hash、提交信息与提交时间。
//
// 供客户端与后续历史浏览（M5.2）使用：只有确实包含该文件的提交才会出现。
// 仓库尚无提交或该文件从未出现时返回 nil。
func (r *Repo) FileHistory(name string) ([]HistoryEntry, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	head, err := r.repo.Head()
	if errors.Is(err, plumbing.ErrReferenceNotFound) {
		// 空仓库：尚无任何提交。
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取 HEAD 失败: %w", err)
	}

	clean := cleanTreePath(name)
	iter, err := r.repo.Log(&git.LogOptions{
		From:  head.Hash(),
		Order: git.LogOrderCommitterTime,
	})
	if err != nil {
		return nil, fmt.Errorf("遍历提交历史失败: %w", err)
	}
	defer iter.Close()

	var out []HistoryEntry
	err = iter.ForEach(func(c *object.Commit) error {
		if _, err := c.File(clean); err != nil {
			if errors.Is(err, object.ErrFileNotFound) ||
				errors.Is(err, object.ErrDirectoryNotFound) {
				// 该提交中不存在此文件，跳过。
				return nil
			}
			return err
		}
		out = append(out, HistoryEntry{
			Hash:    c.Hash.String(),
			Message: strings.TrimSpace(c.Message),
			When:    c.Committer.When,
		})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("遍历提交历史失败: %w", err)
	}

	// 显式按提交时间倒序，保证输出顺序稳定（不依赖遍历实现）。
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].When.After(out[j].When)
	})
	return out, nil
}

// commitFor 把 revision 字符串（完整/短 hash、HEAD、分支名等）解析为提交对象。
func (r *Repo) commitFor(rev string) (*object.Commit, error) {
	hash, err := r.repo.ResolveRevision(plumbing.Revision(rev))
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInvalidArgument,
			fmt.Sprintf("解析版本 %q 失败", rev))
	}
	commit, err := r.repo.CommitObject(*hash)
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("读取版本 %q 失败", rev))
	}
	return commit, nil
}

// cleanTreePath 把仓库内相对路径（允许前导 "/"）规范化为 git tree 内的路径。
// 与 resolve 同策略：path.Clean("/"+name) 后去掉前导 "/"，".." 因此被规范化
// 到仓库根内，无法逃出。
func cleanTreePath(name string) string {
	return strings.TrimPrefix(path.Clean("/"+filepath.ToSlash(name)), "/")
}
