// Package gitver 提供基于 go-git 的轻量版本化能力（纯 Go，无 CGO）。
//
// 设计要点：
//   - 工作区即仓库：Open 打开（或初始化）笔记根目录下的 git 仓库，
//     写入始终作用于工作区文件，提交由调用方在写操作完成后显式触发。
//   - ETag 与提交时序解耦：BlobHash 直接由工作区当前内容计算 git blob
//     hash（sha1("blob <size>\0<content>")），未提交的内容也有稳定 ETag。
//   - 并发串行化：一把互斥锁串行化所有涉及工作区与 git 索引的操作（提交、
//     内容哈希、历史读取，以及在锁内完成「写工作区文件 + 提交」的
//     WriteAndCommit），避免「读内容」与「暂存/提交」交错导致的竞态。
//     注意：若调用方绕过本锁直接改工作区文件、再单独调用 Commit（例如
//     webdav 端点自行落盘），其「落盘 + 提交」不在同一临界区内，本锁不
//     覆盖该时间窗；需要「写文件 + 提交」原子性的调用方应改用 WriteAndCommit。
package gitver

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"

	"notes/internal/logging"
)

// identityName / identityEmail 是版本化仓库的默认提交身份。
const (
	identityName  = "notes"
	identityEmail = "notes@local"
)

// Repo 是一个受并发保护的 git 工作区仓库。
type Repo struct {
	repo *git.Repository

	// root 是工作区根目录的绝对路径，BlobHash 用它定位工作区文件。
	root string

	// mu 串行化所有涉及工作区/索引的操作：提交、内容哈希、历史读取，
	// 以及在锁内完成「写工作区文件 + 提交」的 WriteAndCommit。
	mu sync.Mutex
}

// Open 打开 path 下的 git 仓库；若该路径下不存在仓库（无 .git），
// 则用 git.PlainInit 就地初始化，并写入默认提交身份
// （user.name=notes、user.email=notes@local）。
func Open(path string) (*Repo, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("解析仓库路径 %s 失败: %w", path, err)
	}

	repo, err := git.PlainOpen(abs)
	if errors.Is(err, git.ErrRepositoryNotExists) {
		repo, err = git.PlainInit(abs, false)
	}
	if err != nil {
		return nil, fmt.Errorf("打开/初始化 git 仓库 %s 失败: %w", abs, err)
	}

	r := &Repo{repo: repo, root: abs}
	if err := r.ensureIdentity(); err != nil {
		return nil, err
	}
	return r, nil
}

// ensureIdentity 保证仓库配置里有默认提交身份，缺失或不同则写入。
func (r *Repo) ensureIdentity() error {
	cfg, err := r.repo.Config()
	if err != nil {
		return fmt.Errorf("读取仓库配置失败: %w", err)
	}
	if cfg.User.Name == identityName && cfg.User.Email == identityEmail {
		return nil
	}

	cfg.User.Name = identityName
	cfg.User.Email = identityEmail
	if err := r.repo.SetConfig(cfg); err != nil {
		return fmt.Errorf("写入仓库配置失败: %w", err)
	}
	return nil
}

// Root 返回工作区根目录的绝对路径。
func (r *Repo) Root() string {
	return r.root
}

// Commit 把工作区的全部变更暂存并提交，commit message 为 message。
//
// 无任何变更时直接返回 nil，不产生空提交。提交本身全程持锁，因此并发提交
// 被串行化，不会互相覆盖索引。注意：本方法只保护「暂存 + 提交」，不覆盖
// 调用方在调用前对工作区文件的写入；需要「写文件 + 提交」原子性的调用方
// 应使用 WriteAndCommit。
func (r *Repo) Commit(message string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.commitLocked(message)
}

// commitLocked 是 Commit 的持锁实现，假定调用方已持有 r.mu。
// sync.Mutex 不可重入，故拆出无锁版本供 WriteAndCommit 等在临界区内复用。
func (r *Repo) commitLocked(message string) error {
	wt, err := r.repo.Worktree()
	if err != nil {
		return fmt.Errorf("获取工作区失败: %w", err)
	}

	if _, err := wt.Add("."); err != nil {
		return fmt.Errorf("暂存变更失败: %w", err)
	}

	status, err := wt.Status()
	if err != nil {
		return fmt.Errorf("读取工作区状态失败: %w", err)
	}
	if status.IsClean() {
		// 无可提交变更：不产生空提交。
		return nil
	}

	_, err = wt.Commit(message, &git.CommitOptions{
		Author:    commitIdentity(),
		Committer: commitIdentity(),
	})
	if err != nil {
		return fmt.Errorf("提交失败: %w", err)
	}
	return nil
}

// WriteAndCommit 在同一个持锁临界区内把 content 写入工作区文件 name，
// 随后提交一次，commit message 为 msg。
//
// name 为仓库内相对路径（允许前导 "/"），与 BlobHash/Revert 同策略规范化，
// ".." 无法逃出仓库根；父目录不存在时自动创建（含多级）。「写文件」与
// 「提交」构成单一临界区，因此与其它经同一把锁串行化的操作（Commit、
// WriteAndCommit、Revert、BlobHash 等）之间不存在「已写文件、尚未提交」的
// 时间窗，避免并发写覆盖同一文件（TOCTOU）。写入内容与当前一致时，
// commitLocked 不会产生新提交，语义同 Commit。
func (r *Repo) WriteAndCommit(name, content, msg string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.writeAndCommitLocked(name, content, msg)
}

// writeAndCommitLocked 是 WriteAndCommit 的持锁实现，假定调用方已持有 r.mu。
func (r *Repo) writeAndCommitLocked(name, content, msg string) error {
	full, err := r.resolve(name)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("写入 %s 时创建父目录失败", name))
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("写入 %s 失败", name))
	}
	return r.commitLocked(msg)
}

// BlobHash 返回工作区文件内容的 git blob hash（十六进制）：
// sha1("blob <size>\0<content>")，与 git 对象格式一致。
//
// name 为仓库内相对路径（允许前导 "/"）。与 webdav.Dir 的策略一致，
// 路径先经 path.Clean("/"+name) 规范化，因此 ".." 无法逃出工作区根
// （不存在的文件，或不是普通文件如目录时，返回空串与 nil error）。
func (r *Repo) BlobHash(name string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	full, err := r.resolve(name)
	if err != nil {
		return "", err
	}

	info, err := os.Stat(full)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("读取 %s 状态失败: %w", name, err)
	}
	if !info.Mode().IsRegular() {
		// 目录等非普通文件没有内容哈希。
		return "", nil
	}

	content, err := os.ReadFile(full)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("读取 %s 失败: %w", name, err)
	}
	return blobHash(content), nil
}

// Log 返回最近的 limit 条提交（"<hash> <message>"，由新到旧）；
// limit <= 0 表示返回全部。仓库尚无提交时返回 nil。
func (r *Repo) Log(limit int) ([]string, error) {
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

	iter, err := r.repo.Log(&git.LogOptions{From: head.Hash()})
	if err != nil {
		return nil, fmt.Errorf("遍历提交历史失败: %w", err)
	}
	defer iter.Close()

	var out []string
	err = iter.ForEach(func(c *object.Commit) error {
		out = append(out, fmt.Sprintf("%s %s", c.Hash.String(), strings.TrimSpace(c.Message)))
		if limit > 0 && len(out) >= limit {
			return storer.ErrStop
		}
		return nil
	})
	if err != nil && !errors.Is(err, storer.ErrStop) {
		return nil, fmt.Errorf("遍历提交历史失败: %w", err)
	}
	return out, nil
}

// resolve 把仓库内相对路径（允许前导 "/"）解析为工作区内的绝对路径。
// 与 webdav.Dir 相同，先做 path.Clean("/"+name)，".." 因此被规范化到
// 挂载根内，无法逃出；若结果仍越界则返回错误（防御性兜底）。
func (r *Repo) resolve(name string) (string, error) {
	clean := strings.TrimPrefix(path.Clean("/"+filepath.ToSlash(name)), "/")
	full := filepath.Join(r.root, filepath.FromSlash(clean))

	rel, err := filepath.Rel(r.root, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("路径 %q 越出仓库根 %s", name, r.root)
	}
	return full, nil
}

// blobHash 按 git 对象格式计算内容哈希：sha1("blob <size>\0<content>")。
// 这里用的 SHA-1 是 git 对象标识（非密码学用途），与 git 保持互操作。
func blobHash(content []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(content))
	h.Write(content)
	return hex.EncodeToString(h.Sum(nil))
}

// commitIdentity 返回默认提交者身份与当前时间。
func commitIdentity() *object.Signature {
	return &object.Signature{
		Name:  identityName,
		Email: identityEmail,
		When:  time.Now(),
	}
}
