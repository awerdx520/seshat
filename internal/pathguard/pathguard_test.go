package pathguard

import (
	"errors"
	"path/filepath"
	"testing"
)

// TestCleanRel 是 CleanRel 的拒绝矩阵与规范化矩阵。
//
// 断言一律走 errors.Is（哨兵类别），不断言错误文本——文案归调用方，本包不对它负责。
func TestCleanRel(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		opts    Options
		want    string
		wantErr error
	}{
		// —— 空路径类：零值口径拒绝 ——
		{name: "空串", in: "", wantErr: ErrEmpty},
		{name: "仅斜杠", in: "/", wantErr: ErrEmpty},
		{name: "单点", in: ".", wantErr: ErrEmpty},
		{name: "点加斜杠", in: "./", wantErr: ErrEmpty},

		// —— 规范化类：前导斜杠 / 重复斜杠 / 点段折叠 ——
		{name: "重复前导斜杠", in: "//a.org", want: "a.org"},
		{name: "前导斜杠", in: "/a.org", want: "a.org"},
		{name: "中间重复斜杠", in: "a//b", want: "a/b"},
		{name: "中间单点段", in: "a/./b", want: "a/b"},
		{name: "前导点段", in: "./a.org", want: "a.org"},
		{name: "普通相对路径", in: "a/b.org", want: "a/b.org"},

		// —— ".." 段：默认口径拒绝（原始分段，不看 Clean 结果）——
		{name: "父段加文件名", in: "a/../b", wantErr: ErrParentSegment},
		{name: "仅父段", in: "..", wantErr: ErrParentSegment},
		{name: "父段前缀", in: "../x", wantErr: ErrParentSegment},
		{name: "尾部父段", in: "a/b/..", wantErr: ErrParentSegment},

		// —— .git 段：大小写不敏感（只对 ".git" 本身的大小写变体成立）——
		{name: "git 段前缀", in: ".git/x", wantErr: ErrGitSegment},
		{name: "git 段大写", in: ".GIT/x", wantErr: ErrGitSegment},
		{name: "git 段在中间", in: "a/.git/b", wantErr: ErrGitSegment},
		{
			// "A.GIT" 不是 ".git" 的大小写变体（少了前导点），也不以 '.' 开头，
			// 因此历史上五处实现都放行——这里显式锁定，防止有人按「名字里含 GIT 就拒」
			// 收紧口径（收紧会改变既有行为）。
			name: "A.GIT 不是 git 段",
			in:   "A.GIT/x",
			want: "A.GIT/x",
		},

		// —— 点段 ——
		{name: "隐藏文件名", in: ".hidden", wantErr: ErrDotSegment},

		// —— 分隔符与空白：本包不做 TrimSpace，>ToSlash 只按平台分隔符行事 ——
		{
			// Linux 的 filepath.Separator 就是 '/'，反斜杠不是分隔符，ToSlash 为恒等变换，
			// 故反斜杠原样保留（与五处历史实现逐字等价）。用 filepath.ToSlash 表达期望，
			// 使断言在分隔符不同的平台上同样成立。
			name: "反斜杠不额外切分",
			in:   `a\b.org`,
			want: filepath.ToSlash(`a\b.org`),
		},
		{
			// 尾空格必须保留：TrimSpace 是调用方语义（api/registry 会做，gitver 不会）。
			// 若本包偷偷 TrimSpace，gitver 侧「不 TrimSpace」的差异就被抹掉了。
			name: "尾空格保留",
			in:   "a.org ",
			want: "a.org ",
		},

		// —— NUL ——
		{name: "含 NUL", in: "a\x00b", wantErr: ErrNUL},
		{name: "仅 NUL", in: "\x00", wantErr: ErrNUL},

		// —— 选项组合：三个开关只能放宽 ——
		{name: "AllowEmpty 放行空路径", in: "", opts: Options{AllowEmpty: true}, want: ""},
		{name: "AllowParentSegments 折叠父段", in: "a/../b", opts: Options{AllowParentSegments: true}, want: "b"},
		{name: "AllowDotSegments 放行点段", in: ".hidden", opts: Options{AllowDotSegments: true}, want: ".hidden"},
		{
			name: "全放开后折叠父段",
			in:   "../x",
			opts: Options{AllowEmpty: true, AllowParentSegments: true, AllowDotSegments: true},
			want: "x",
		},
		{
			name: "全放开后结果为空",
			in:   "/",
			opts: Options{AllowEmpty: true, AllowParentSegments: true, AllowDotSegments: true},
			want: "",
		},
		{
			// 只放开 AllowDotSegments 不影响 ".." 的拒绝口径。
			name:    "只放开点段仍拒父段",
			in:      "a/../b",
			opts:    Options{AllowDotSegments: true},
			wantErr: ErrParentSegment,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := CleanRel(tc.in, tc.opts)
			if tc.wantErr != nil {
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("CleanRel(%q, %+v) 期望错误 %v，实际 err=%v", tc.in, tc.opts, tc.wantErr, err)
				}
				if got != "" {
					t.Fatalf("CleanRel(%q, %+v) 出错时应返回空串，实际 %q", tc.in, tc.opts, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("CleanRel(%q, %+v) 意外错误: %v", tc.in, tc.opts, err)
			}
			if got != tc.want {
				t.Fatalf("CleanRel(%q, %+v) = %q，期望 %q", tc.in, tc.opts, got, tc.want)
			}
		})
	}
}

// TestIsDotName 覆盖单段名字判定。
func TestIsDotName(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{name: "小写 git", in: ".git", want: true},
		{name: "大写 git", in: ".GIT", want: true},
		{name: "隐藏文件", in: ".hidden", want: true},
		{name: "普通文件", in: "a.org", want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsDotName(tc.in); got != tc.want {
				t.Fatalf("IsDotName(%q) = %v，期望 %v", tc.in, got, tc.want)
			}
		})
	}
}

// TestHasDotSegment 锁定「只判点段、父段折叠到根内」的历史语义（不得收紧）。
func TestHasDotSegment(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{name: "空串是挂载根", in: "", want: false},
		{name: "斜杠是挂载根", in: "/", want: false},
		{name: "git 段在中间", in: "a/.git/b", want: true},
		{name: "隐藏文件名", in: ".hidden", want: true},
		{name: "父段折叠后无点段", in: "a/../b", want: false},
		{name: "父段折叠后仍有点段", in: "a/../.hidden", want: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := HasDotSegment(tc.in); got != tc.want {
				t.Fatalf("HasDotSegment(%q) = %v，期望 %v", tc.in, got, tc.want)
			}
		})
	}
}
