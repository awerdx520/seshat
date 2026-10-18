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
//     WriteAndCommitIf 更进一步，把「条件比较」（If-Match / 仅创建）也纳入
//     同一临界区，使「判断所依据的内容」与「被覆盖的内容」必然是同一份。
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

	"seshat/internal/logging"
)

// identityName / identityEmail 是版本化仓库的默认提交身份。
const (
	identityName  = "seshat"
	identityEmail = "seshat@local"
)

// ErrBlobMismatch 表示条件写入（WriteAndCommitIf）的前提不成立：目标当前内容的
// git blob hash 与期望值不符，或期望「不存在」但目标已存在。
//
// 命中本错误时工作区内容与提交历史均未被修改。上层（api）把它映射为 HTTP 412，
// 因此这里用包级哨兵值而非 logging.Code：调用方用 errors.Is 判定即可，无需
// 依赖日志/错误码包的映射约定。
var ErrBlobMismatch = errors.New("条件写入失败：目标内容与期望不一致")

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
// （user.name=seshat、user.email=seshat@local）。
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

// WriteAndCommitIf 在同一个持锁临界区内完成「读当前 blob → 条件比较 →
// 写文件 → 提交」，消除检查与写入之间的时间窗（TOCTOU）。
//
// 条件语义：
//   - wantAbsent 为 true 时要求目标当前不存在（不存在 = 非普通文件/不存在）；
//     已存在则返回 ErrBlobMismatch，不写入。
//   - wantAbsent 为 false 且 wantBlob 非空时，要求当前内容的 git blob hash
//     等于 wantBlob；不等（含文件不存在）则返回 ErrBlobMismatch，不写入。
//   - wantAbsent 为 false 且 wantBlob 为空时，无条件写入（等价 WriteAndCommit）。
//
// wantAbsent 优先于 wantBlob。返回 created（写入前目标是否不存在）；不满足条件
// 时工作区与提交历史均未被修改。写入内容与当前一致时 commitLocked 不产生空提交。
//
// 与「先 BlobHash 再 WriteAndCommit」相比的区别：后者两次调用各有一次加锁，
// 期间别的写入者可以插进来改内容，导致基于旧内容的判断被用于覆盖新内容；
// 本方法把判定与写入放进同一临界区，因此判断所依据的内容就是被覆盖的内容。
func (r *Repo) WriteAndCommitIf(name, content, msg, wantBlob string, wantAbsent bool) (created bool, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	cur, exists, err := r.blobHashLocked(name)
	if err != nil {
		return false, err
	}

	switch {
	case wantAbsent:
		if exists {
			return false, ErrBlobMismatch
		}
	case wantBlob != "":
		// 文件不存在时 cur 为空串，与任何非空 wantBlob 都不相等——覆盖「目标
		// 已消失」这一情形，避免按旧内容的期望把文件重新创建出来。
		if cur != wantBlob {
			return false, ErrBlobMismatch
		}
	}

	created = !exists
	if err := r.writeAndCommitLocked(name, content, msg); err != nil {
		// 写入/提交失败：工作区状态不确定，created 不再具备意义。
		return false, err
	}
	return created, nil
}

// RenameAndCommit 在同一个持锁临界区内把工作区文件或目录从 oldName 移到
// newName，随后提交一次，commit message 为 msg。
//
// 语义：
//   - oldName / newName 均为仓库内相对路径（允许前导 "/"），经 resolveAny 规范化，
//     ".." 无法逃出仓库根，且都不允许指向仓库根自身（ErrInvalidArgument）；
//   - oldName 不存在返回 ErrNotFound（持锁内用 Lstat 判定，避免与并发提交交错）；
//   - newName 的父目录不存在时自动创建（含多级）；
//   - 目标已存在时按 os.Rename 语义处理（同名文件覆盖；非空目录替换失败）。
//
// 「移动文件」与「提交」构成单一临界区，因此与 WriteAndCommit / Commit / BlobHash
// 等经同一把锁串行化的操作之间不存在「已移动、尚未提交」的时间窗。工作区无变更时
// commitLocked 不产生空提交（例如程序崩溃后重放同一改名）。
func (r *Repo) RenameAndCommit(oldName, newName, msg string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	src, err := r.resolveAny(oldName)
	if err != nil {
		return logging.Wrap(err, logging.ErrInvalidArgument,
			fmt.Sprintf("改名源路径 %s 非法", oldName))
	}
	dst, err := r.resolveAny(newName)
	if err != nil {
		return logging.Wrap(err, logging.ErrInvalidArgument,
			fmt.Sprintf("改名目标路径 %s 非法", newName))
	}

	if _, err := os.Lstat(src); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return logging.Wrap(err, logging.ErrNotFound,
				fmt.Sprintf("改名源路径 %s 不存在", oldName))
		}
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("读取改名源路径 %s 失败", oldName))
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("改名目标 %s 的父目录创建失败", newName))
	}
	if err := os.Rename(src, dst); err != nil {
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("把 %s 改名为 %s 失败", oldName, newName))
	}
	return r.commitLocked(msg)
}

// RemoveAndCommit 在同一个持锁临界区内删除工作区文件或目录（目录递归删除），
// 随后提交一次，commit message 为 msg。
//
// name 为仓库内相对路径（允许前导 "/"），经 resolveAny 规范化：删除操作尤其
// 不能容忍歧义，故指向仓库根自身（"." 或空串规范化后）返回 ErrInvalidArgument，
// 绝不递归删除整个工作区。name 不存在返回 ErrNotFound；删除后无工作区变更
// （例如重放已删除的路径）时不产生空提交。
func (r *Repo) RemoveAndCommit(name, msg string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	target, err := r.resolveAny(name)
	if err != nil {
		return logging.Wrap(err, logging.ErrInvalidArgument,
			fmt.Sprintf("删除路径 %s 非法", name))
	}

	if _, err := os.Lstat(target); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return logging.Wrap(err, logging.ErrNotFound,
				fmt.Sprintf("删除路径 %s 不存在", name))
		}
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("读取删除路径 %s 失败", name))
	}
	if err := os.RemoveAll(target); err != nil {
		return logging.Wrap(err, logging.ErrInternal, fmt.Sprintf("删除 %s 失败", name))
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

	hash, _, err := r.blobHashLocked(name)
	return hash, err
}

// blobHashLocked 是 BlobHash 的持锁内部实现，假定调用方已持有 r.mu。
// sync.Mutex 不可重入，故抽成无锁版本，供 WriteAndCommitIf 在同一临界区内
// 复用同一套哈希算法（避免重复持锁导致死锁，也避免另写一份算法产生偏差）。
//
// hash 为空串表示「目标当前没有内容」；exists 表示目标当前是否是存在的普通
// 文件（目录等非普通文件按「不存在」处理，与 BlobHash 的空串语义一致）。
func (r *Repo) blobHashLocked(name string) (hash string, exists bool, err error) {
	full, err := r.resolve(name)
	if err != nil {
		return "", false, err
	}

	info, err := os.Stat(full)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("读取 %s 状态失败: %w", name, err)
	}
	if !info.Mode().IsRegular() {
		// 目录等非普通文件没有内容哈希。
		return "", false, nil
	}

	content, err := os.ReadFile(full)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("读取 %s 失败: %w", name, err)
	}
	return blobHash(content), true, nil
}

// Head 返回当前 HEAD 的提交 hash（十六进制）。
//
// 空仓库（尚无任何提交）返回空串与 nil error，便于调用方把「无 rev」当作
// 正常状态处理。与其它工作区/索引操作共用同一把互斥锁。
func (r *Repo) Head() (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	head, err := r.repo.Head()
	if errors.Is(err, plumbing.ErrReferenceNotFound) {
		// 空仓库：尚无任何提交。
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("读取 HEAD 失败: %w", err)
	}
	return head.Hash().String(), nil
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

// resolveAny 是 resolve 的加强版：同样把仓库内相对路径解析为工作区绝对路径，
// 并额外拒绝「规范化后指向仓库根自身」的路径（空串、"//"、"."、"a/.." 等）。
//
// 与 resolve 分开而不改 resolve 的原因：BlobHash / WriteAndCommit 有意把这类输入
// 视作「仓库根下的空路径」（写入时由 os.WriteFile 报错），而改名的源/目标与删除
// 的目标都不存在「整个仓库根」这种合法对象——尤其 RemoveAndCommit 若接受仓库根，
// 一次调用就会递归删掉全部笔记，故必须在此明确拒绝。
func (r *Repo) resolveAny(name string) (string, error) {
	full, err := r.resolve(name)
	if err != nil {
		return "", err
	}
	if full == r.root {
		return "", fmt.Errorf("路径 %q 指向仓库根，不能作为文件或目录路径", name)
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
