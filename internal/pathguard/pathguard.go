// Package pathguard 是「仓库内相对路径」安全规则的唯一实现。
//
// 五个入口共用本包，规则不再各写一份（历史上同一不变量有五份实现，靠注释
// 「两处必须同步修改」维系，一处漏改就会出现「API 能写、登记层拒绝」这类死角）：
//
//   - internal/api 的 cleanRelPath（REST 文件端点）
//   - internal/registry 的 normalizeResourcePath（登记表键规范化）
//   - internal/registry 的 isDotName（bootstrap 逐目录项判定）
//   - internal/webdav 的 hasDotSegment（对外出口策略）
//   - internal/gitver 的 (*Repo).resolve（仓库内相对路径 → 绝对路径）
//
// 本包只做判定与规范化，不产出用户可见文案：错误以哨兵形式返回，由调用方按自己的
// 错误码与中文文案包装（各入口文案历史上不同，本包不强行统一）。
//
// 本包只依赖标准库。
package pathguard

import (
	"errors"
	"path"
	"path/filepath"
	"strings"
)

// 哨兵错误：调用方按类别映射成各自的错误码与中文文案（本包不产出用户可见文案）。
var (
	// ErrNUL 表示路径含 NUL 字节。
	ErrNUL = errors.New("路径含 NUL 字节")
	// ErrParentSegment 表示路径含 ".." 段（原始分段，非 Clean 之后）。
	ErrParentSegment = errors.New(`路径含 ".." 段`)
	// ErrGitSegment 表示路径含 .git 段（大小写不敏感）。
	ErrGitSegment = errors.New("路径含 .git 段")
	// ErrDotSegment 表示路径含以 '.' 开头的段。
	ErrDotSegment = errors.New("路径含以 '.' 开头的段")
	// ErrEmpty 表示路径规范化后为空（空串、"/"、"." 等）。
	ErrEmpty = errors.New("路径规范化后为空")
)

// Options 的零值表示最严格口径：拒绝空路径、拒绝 ".." 段、拒绝点段。
//
// 三个开关只能放宽，不能收紧——需要比零值更严格的调用方没有表达方式，
// 这种调用方目前也不存在。
type Options struct {
	// AllowEmpty 允许规范化结果为空（WebDAV 挂载根本身、gitver 的仓库根）。
	AllowEmpty bool
	// AllowParentSegments 允许 ".." 段：Clean 后折叠到根内，而不是拒绝。
	AllowParentSegments bool
	// AllowDotSegments 允许 .git 段与以 '.' 开头的段。
	AllowDotSegments bool
}

// CleanRel 把「仓库内相对路径」规范化为根内逻辑相对路径。
//
// 规则严格按序（任一先命中即返回）：
//  1. 含 NUL 字节 → ErrNUL；
//  2. 反斜杠转 '/'（filepath.ToSlash）；
//  3. 未放宽 ".." 时，在**原始分段**上任一段为 ".." → ErrParentSegment
//     （注意是原始分段而非 Clean 之后：a/../b 折叠后是 b，仍须拒绝）；
//  4. 去前导 '/'、合并重复斜杠、折叠 '.'；
//  5. 结果为空或 "." → AllowEmpty 为真返回 ""，否则 ErrEmpty；
//  6. 未放宽点段时，Clean 后任一段为 .git（大小写不敏感）→ ErrGitSegment，
//     任一段以 '.' 开头 → ErrDotSegment（先判 .git 再判点段）；
//  7. 返回 clean。
//
// 本函数**不做 TrimSpace**：TrimSpace 属于调用方语义（api / registry 侧现在
// TrimSpace，gitver 侧不 TrimSpace），由调用方在调用前自行处理。
func CleanRel(rel string, opts Options) (string, error) {
	if strings.ContainsRune(rel, 0) {
		return "", ErrNUL
	}

	slashed := filepath.ToSlash(rel)

	if !opts.AllowParentSegments {
		for _, seg := range strings.Split(slashed, "/") {
			if seg == ".." {
				return "", ErrParentSegment
			}
		}
	}

	clean := strings.TrimPrefix(path.Clean("/"+slashed), "/")

	if clean == "" || clean == "." {
		if opts.AllowEmpty {
			return "", nil
		}
		return "", ErrEmpty
	}

	if !opts.AllowDotSegments {
		for _, seg := range strings.Split(clean, "/") {
			if strings.EqualFold(seg, ".git") {
				return "", ErrGitSegment
			}
			if strings.HasPrefix(seg, ".") {
				return "", ErrDotSegment
			}
		}
	}

	return clean, nil
}

// IsDotName 判断单个目录项名字是否为点路径（.git 或任何以 '.' 开头的名字）。
//
// 供逐层回调的目录遍历使用：点目录整棵被剪掉后，「逐项检查名字」等价于
// 「检查路径的全部段」。
func IsDotName(name string) bool {
	return strings.EqualFold(name, ".git") || strings.HasPrefix(name, ".")
}

// HasDotSegment 判断路径是否含点段（.git 或任何以 '.' 开头的段）。
//
// 刻意传 AllowDotSegments: true：让 CleanRel 只做「NUL 检查 + .. 折叠 + 空判断」，
// 点段判定由下面的循环承担。否则 CleanRel 会先以错误形式返回点段，错误分支与
// 循环的判定结论虽然一致，但「点段由谁判」会变成靠巧合成立的耦合。
// 折叠 .. 是为与 WebDAV 出口既有语义一致（a/../b 折叠为 b 后不构成点段）。
//
// 语义要点（与历史实现逐字等价，不得收紧）：
//   - 允许空路径：挂载根本身（""、"/"）折叠后为空，不算点路径；
//   - ".." 走折叠而非拒绝：a/../b 折叠为 b，其中没有点段，故返回 false。
//
// 返回 true 即「拒绝」。CleanRel 返回错误时一律按拒绝处理：错误只可能来自
// NUL（无法判定，宁拒）——点段已由 AllowDotSegments 放行，不会在此报错。
func HasDotSegment(rel string) bool {
	clean, err := CleanRel(rel, Options{AllowEmpty: true, AllowParentSegments: true, AllowDotSegments: true})
	if err != nil {
		return true
	}
	if clean == "" {
		return false
	}
	for _, seg := range strings.Split(clean, "/") {
		if strings.EqualFold(seg, ".git") || strings.HasPrefix(seg, ".") {
			return true
		}
	}
	return false
}
