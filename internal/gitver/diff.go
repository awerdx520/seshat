// 本文件实现 M5.2 的历史浏览能力：文件两个版本之间的文本差异（Diff）
// 与把工作区文件恢复到指定版本（Revert）。
//
// 两个方法都复用 merge.go 中已有的 FileContent 读取历史内容，因此不重复
// 实现版本解析与路径规范化；写入路径（Revert）遵循与 webdav 端点一致的
// 模式——先改工作区文件，再调用 Repo.Commit 追加一条提交，历史只增不改。
package gitver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"notes/internal/logging"
)

// maxDiffCells 是逐行 diff 使用动态规划表的单元数上限。
//
// 表大小约为行数乘积；超过上限（如两个巨大的文件）时退化为按位置对齐的
// 逐行比较，避免为一次 diff 申请过大的内存。阈值 1<<20 个 int32 单元
// 约 4 MiB，足以覆盖正常笔记文件。
const maxDiffCells = 1 << 20

// Diff 返回文件 name 从版本 fromHash 到版本 toHash 的逐行文本差异，
// 采用 unified diff 风格：
//
//	--- a/<path>
//	+++ b/<path>
//	@@ -1,<旧行数> +1,<新行数> @@
//	 上下文行
//	-被删除的行
//	+被新增的行
//
// 两版本内容相同时返回空串。fromHash/toHash 为 git revision 字符串（完整/
// 短 hash、HEAD、分支名等）；版本无法解析返回 logging.ErrInvalidArgument，
// 文件在该版本不存在返回 logging.ErrNotFound。
func (r *Repo) Diff(name, fromHash, toHash string) (string, error) {
	// FileContent 内部自带互斥锁，此处依次读取两个版本即可（不可再持锁，
	// sync.Mutex 不可重入）。
	from, err := r.FileContent(name, fromHash)
	if err != nil {
		return "", err
	}
	to, err := r.FileContent(name, toHash)
	if err != nil {
		return "", err
	}
	if from == to {
		return "", nil
	}

	oldLines := splitLines(from)
	newLines := splitLines(to)

	// MVP 实现：整个文件作为单个 hunk，逐行对比输出增删与上下文行；
	// 不细分 hunk、不省略公共行（简洁优先，客户端整段展示足够）。
	var b strings.Builder
	clean := cleanTreePath(name)
	fmt.Fprintf(&b, "--- a/%s\n+++ b/%s\n", clean, clean)
	fmt.Fprintf(&b, "@@ -1,%d +1,%d @@\n", len(oldLines), len(newLines))
	for _, line := range diffLines(oldLines, newLines) {
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return b.String(), nil
}

// Revert 把工作区文件 name 恢复到版本 hash 处的内容：读取该版本内容写回
// 工作区，随后追加一条提交（commit message 形如 "revert: <path> 恢复到 <hash>"）。
//
// 文件不存在（工作区或该版本中）时自动创建（含父目录）。文件在该版本不存在
// 返回 logging.ErrNotFound，版本无法解析返回 logging.ErrInvalidArgument。
// 恢复到与当前内容相同的版本时不产生新提交（沿用 Commit 的语义）。
func (r *Repo) Revert(name, hash string) error {
	content, err := r.FileContent(name, hash)
	if err != nil {
		return err
	}

	full, err := r.resolve(name)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("恢复 %s 时创建目录失败", name))
	}
	// 与 webdav 端点的写入路径一致：先落盘工作区文件，再提交一次，
	// 提交阶段由 Repo.Commit 自行持锁串行化。
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		return logging.Wrap(err, logging.ErrInternal,
			fmt.Sprintf("恢复 %s 到版本 %s 失败", name, hash))
	}
	return r.Commit(fmt.Sprintf("revert: %s 恢复到 %s", cleanTreePath(name), shortHash(hash)))
}

// splitLines 把内容按行切分；内容以换行结尾时去掉末尾的空元素，
// 使行数与编辑器中的「行」一致。
func splitLines(content string) []string {
	if content == "" {
		return nil
	}
	lines := strings.Split(content, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// diffLines 返回带前缀的 diff 行序列（" " 上下文、"-" 删除、"+" 新增），
// 用最长公共子序列对齐两版内容；规模超限时退化为按位置对齐的比较。
func diffLines(oldLines, newLines []string) []string {
	if len(oldLines)*len(newLines) > maxDiffCells {
		return naiveDiffLines(oldLines, newLines)
	}

	// lcs[i][j] = oldLines[i:] 与 newLines[j:] 的最长公共子序列长度。
	n, m := len(oldLines), len(newLines)
	lcs := make([][]int32, n+1)
	for i := range lcs {
		lcs[i] = make([]int32, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if oldLines[i] == newLines[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else if lcs[i+1][j] >= lcs[i][j+1] {
				lcs[i][j] = lcs[i+1][j]
			} else {
				lcs[i][j] = lcs[i][j+1]
			}
		}
	}

	out := make([]string, 0, n+m)
	i, j := 0, 0
	for i < n && j < m {
		switch {
		case oldLines[i] == newLines[j]:
			out = append(out, " "+oldLines[i])
			i++
			j++
		case lcs[i+1][j] >= lcs[i][j+1]:
			out = append(out, "-"+oldLines[i])
			i++
		default:
			out = append(out, "+"+newLines[j])
			j++
		}
	}
	for ; i < n; i++ {
		out = append(out, "-"+oldLines[i])
	}
	for ; j < m; j++ {
		out = append(out, "+"+newLines[j])
	}
	return out
}

// naiveDiffLines 是超限时的退化实现：逐位置比较，长度不等时多出的行全部
// 记为删除或新增。
func naiveDiffLines(oldLines, newLines []string) []string {
	common := len(oldLines)
	if len(newLines) < common {
		common = len(newLines)
	}

	out := make([]string, 0, len(oldLines)+len(newLines))
	for i := 0; i < common; i++ {
		if oldLines[i] == newLines[i] {
			out = append(out, " "+oldLines[i])
			continue
		}
		out = append(out, "-"+oldLines[i], "+"+newLines[i])
	}
	for _, line := range oldLines[common:] {
		out = append(out, "-"+line)
	}
	for _, line := range newLines[common:] {
		out = append(out, "+"+line)
	}
	return out
}

// shortHash 把 commit hash 截断为前 12 位（仅用于提交信息展示；过短的
// revision 字符串原样返回）。
func shortHash(hash string) string {
	const abbrev = 12
	if len(hash) > abbrev {
		return hash[:abbrev]
	}
	return hash
}
