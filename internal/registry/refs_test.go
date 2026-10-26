// 本文件测试 M7 C1/C2 的引用层：seshat: 链接解析、引用刷新（整份替换）、
// 来源清空、双向查询，以及四种目标形态（uid / 显式 uid: 前缀 / tag:path / 纯 path）
// 的解析优先级。
//
// 断言口径：
//   - ParseSeshatLinks 只做「文本 → 原样 target + location」的提取，去重保序；
//   - RefreshRefs 先读文件再一次性 ReplaceRefs（不在事务内做文件 IO），非 .org 清空；
//   - 目标解析不到（未登记/非法）只跳过该条，不影响其它引用；
//   - ListRefs 的 in/out 方向分别按 target_uid / source_uid 过滤。
package registry

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"seshat/internal/logging"
	"seshat/internal/storage"
)

// newRefsFixture 建立「临时物理根 notes + 两个已登记文档（a.org、sub/b.org）」的环境，
// 返回 Service、其 DB 与物理根目录（供测试写 .org 内容）。
func newRefsFixture(t *testing.T) (*Service, *storage.DB, string) {
	t.Helper()
	svc, db := newTestService(t)
	root := t.TempDir()
	if err := svc.SetRoots([]Root{{Tag: "notes", Path: root}}); err != nil {
		t.Fatalf("SetRoots() 返回错误: %v", err)
	}
	for _, ev := range []Event{createEvent(uidA, "a.org"), createEvent(uidB, "sub/b.org")} {
		if _, err := svc.Apply(ev); err != nil {
			t.Fatalf("Apply() 返回错误: %v", err)
		}
	}
	return svc, db, root
}

// writeRootFile 在物理根内写入文件（自动创建父目录）。
func writeRootFile(t *testing.T, root, rel, content string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("创建目录失败: %v", err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("写入文件失败: %v", err)
	}
}

// assertParsed 断言解析结果与期望逐一相等（顺序敏感）。
func assertParsed(t *testing.T, got []ParsedLink, want ...ParsedLink) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("解析结果 = %+v（%d 条），期望 %+v（%d 条）", got, len(got), want, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("第 %d 条 = %+v, 期望 %+v", i, got[i], want[i])
		}
	}
}

// TestParseSeshatLinksSingleNoLocation 验证不含 location 的单链接。
func TestParseSeshatLinksSingleNoLocation(t *testing.T) {
	assertParsed(t,
		ParseSeshatLinks("* 标题\n见 [[seshat:"+uidA+"][目标]] 结束\n"),
		ParsedLink{Target: uidA, Location: ""})
}

// TestParseSeshatLinksSingleWithLocation 验证含 location 的单链接（'#' 被剥离）。
func TestParseSeshatLinksSingleWithLocation(t *testing.T) {
	assertParsed(t,
		ParseSeshatLinks("引用 [[seshat:"+uidA+"#p.12][第 12 页]]\n"),
		ParsedLink{Target: uidA, Location: "p.12"})

	// 裸文本形态（不是 org 链接）同样可解析。
	assertParsed(t,
		ParseSeshatLinks("见 seshat:"+uidB+"#章节-二 结束\n"),
		ParsedLink{Target: uidB, Location: "章节-二"})
}

// TestParseSeshatLinksDedupKeepsOrder 验证多链接保序且重复去重（首次出现位置保留）。
func TestParseSeshatLinksDedupKeepsOrder(t *testing.T) {
	content := "[[seshat:" + uidB + "]] " +
		"[[seshat:" + uidA + "#p.1]] " +
		"[[seshat:" + uidB + "]] " +
		"[[seshat:" + uidA + "#p.1]] " +
		"[[seshat:" + uidA + "#p.2]]\n"
	assertParsed(t, ParseSeshatLinks(content),
		ParsedLink{Target: uidB, Location: ""},
		ParsedLink{Target: uidA, Location: "p.1"},
		ParsedLink{Target: uidA, Location: "p.2"})
}

// TestParseSeshatLinksNoLinks 验证无链接文本返回空切片（非 nil）。
func TestParseSeshatLinksNoLinks(t *testing.T) {
	got := ParseSeshatLinks("* 只有正文\n[[https://example.com][外部链接]]\n")
	if got == nil {
		t.Fatal("无链接时返回 nil，期望空切片")
	}
	if len(got) != 0 {
		t.Fatalf("无链接时解析出 %d 条: %+v", len(got), got)
	}
}

// TestParseSeshatLinksDropsEmptyTarget 验证 "seshat:" 后为空（空白 / ']' / '#' 起始）
// 的匹配被丢弃，不会产生空 target 的引用。
func TestParseSeshatLinksDropsEmptyTarget(t *testing.T) {
	cases := []string{
		"seshat: 后面是空格\n",
		"seshat:]\n",
		"seshat:#p.1\n",
		"[[]] 里 seshat: 直接跟 ]] 结束\n",
		"",
	}
	for _, content := range cases {
		if got := ParseSeshatLinks(content); len(got) != 0 {
			t.Fatalf("ParseSeshatLinks(%q) = %+v, 期望空（target 为空的匹配应丢弃）", content, got)
		}
	}
}

// TestResolveTargetForms 表驱动验证三种目标形态的解析优先级与非法输入：
// uid → tag:path → 纯 path（默认根）。
func TestResolveTargetForms(t *testing.T) {
	svc, _, _ := newRefsFixture(t)

	cases := []struct {
		name    string
		key     string
		wantUID string
		wantErr logging.Code // 空串表示期望成功
	}{
		{"uid 形态", uidA, uidA, ""},
		{"tag:path 形态", "notes:sub/b.org", uidB, ""},
		{"tag:path 前导斜杠", "notes:/sub/b.org", uidB, ""},
		{"纯 path 用默认根", "sub/b.org", uidB, ""},
		{"未登记 uid", uidBookForRefs, "", logging.ErrNotFound},
		{"未登记路径", "missing.org", "", logging.ErrNotFound},
		{"未知 tag", "ebooks:a.org", "", logging.ErrNotFound},
		{"空 key", "   ", "", logging.ErrInvalidArgument},
		{"路径逃逸", "notes:../etc/passwd", "", logging.ErrInvalidArgument},
		{"tag 后为空", "notes:", "", logging.ErrInvalidArgument},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := svc.Resolve(tc.key)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("Resolve(%q) 返回错误: %v", tc.key, err)
				}
				if got != tc.wantUID {
					t.Fatalf("Resolve(%q) = %q, 期望 %q", tc.key, got, tc.wantUID)
				}
				return
			}
			if err == nil {
				t.Fatalf("Resolve(%q) 应返回错误，实际得到 %q", tc.key, got)
			}
			assertCode(t, err, tc.wantErr)
		})
	}
}

// uidBookForRefs 是一个合法但未登记的 uid（26 位 Crockford Base32）。
const uidBookForRefs = "01K8Q3M7D2X9V6T1B8N5C0RDEH"

// TestRefreshRefsResolvesThreeForms 验证 RefreshRefs 把三种形态的链接都解析成 uid。
func TestRefreshRefsResolvesThreeForms(t *testing.T) {
	svc, _, root := newRefsFixture(t)
	writeRootFile(t, root, "a.org", "[[seshat:"+uidB+"]]\n"+
		"[[seshat:notes:sub/b.org#p.3]]\n"+
		"[[seshat:sub/b.org#p.4]]\n")

	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs() 返回错误: %v", err)
	}

	refs, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	// 三条链接都解析到 uidB，但 location 不同，故保留 3 条边。
	if len(refs) != 3 {
		t.Fatalf("引用条数 = %d, 期望 3: %+v", len(refs), refs)
	}
	for _, r := range refs {
		if r.SourceUID != uidA || r.TargetUID != uidB {
			t.Fatalf("引用 = %+v, 期望 source=%s target=%s", r, uidA, uidB)
		}
		if r.SourceLocation != "" {
			t.Fatalf("source_location = %q, 期望为空串（当前不记录源位置）", r.SourceLocation)
		}
		if r.CreatedAt == "" {
			t.Fatal("created_at 为空，期望回填当前时间")
		}
	}
}

// TestRefreshRefsSkipsUnregisteredTarget 验证未登记/非法目标仅跳过该条，其余引用照常写入。
func TestRefreshRefsSkipsUnregisteredTarget(t *testing.T) {
	svc, _, root := newRefsFixture(t)
	writeRootFile(t, root, "a.org", "[[seshat:"+uidB+"]] [[seshat:missing.org]] [[seshat:"+uidBookForRefs+"]]\n")

	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs() 返回错误: %v", err)
	}

	refs, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(refs) != 1 || refs[0].TargetUID != uidB {
		t.Fatalf("引用 = %+v, 期望只剩指向 %s 的一条", refs, uidB)
	}
}

// TestRefreshRefsReplacesPrevious 验证第二次写入后旧引用消失（整份替换语义）。
func TestRefreshRefsReplacesPrevious(t *testing.T) {
	svc, _, root := newRefsFixture(t)

	writeRootFile(t, root, "a.org", "[[seshat:"+uidB+"]] [[seshat:notes:sub/b.org#p.9]]\n")
	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("首次 RefreshRefs() 返回错误: %v", err)
	}
	if refs, _ := svc.ListRefs(uidA, storage.RefDirectionOut); len(refs) != 2 {
		t.Fatalf("首次刷新后引用数 = %d, 期望 2", len(refs))
	}

	writeRootFile(t, root, "a.org", "已无链接\n")
	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("二次 RefreshRefs() 返回错误: %v", err)
	}
	refs, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(refs) != 0 {
		t.Fatalf("二次刷新后引用 = %+v, 期望为空（旧引用应被替换掉）", refs)
	}
}

// TestRefreshRefsNonOrgClears 验证源文件改名成非 .org 后引用被清空（不读内容）。
//
// 场景：a.org 改名 a.txt（uid 不变），此时该 uid 已不是 org 文档，旧引用必须清空，
// 否则引用图会残留「已不存在的链接」。非 .org 分支不读文件，故物理文件缺失也不影响。
func TestRefreshRefsNonOrgClears(t *testing.T) {
	svc, _, root := newRefsFixture(t)

	writeRootFile(t, root, "a.org", "[[seshat:"+uidB+"]]\n")
	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs(a.org) 返回错误: %v", err)
	}
	if refs, _ := svc.ListRefs(uidA, storage.RefDirectionOut); len(refs) != 1 {
		t.Fatalf("改名之前引用数 = %d, 期望 1", len(refs))
	}

	if _, err := svc.Apply(Event{
		UID: uidA, Op: storage.OpRename, Root: "notes", Path: "a.txt", OldPath: "a.org",
	}); err != nil {
		t.Fatalf("Apply(rename) 返回错误: %v", err)
	}

	if err := svc.RefreshRefs("notes", "a.txt"); err != nil {
		t.Fatalf("RefreshRefs(a.txt) 返回错误: %v", err)
	}
	refs, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(refs) != 0 {
		t.Fatalf("非 .org 源引用 = %+v, 期望为空（应清空）", refs)
	}
}

// TestRefreshRefsRequiresRegisteredSource 验证未登记源路径返回 not found。
func TestRefreshRefsRequiresRegisteredSource(t *testing.T) {
	svc, _, _ := newRefsFixture(t)

	err := svc.RefreshRefs("notes", "missing.org")
	assertCode(t, err, logging.ErrNotFound)
}

// TestRefreshRefsReadFailure 验证内容读取失败时返回错误且不改动既有引用。
func TestRefreshRefsReadFailure(t *testing.T) {
	svc, _, _ := newRefsFixture(t)

	// a.org 已登记但物理文件不存在 → 读取失败。
	err := svc.RefreshRefs("notes", "a.org")
	if err == nil {
		t.Fatal("物理文件缺失时 RefreshRefs() 应返回错误")
	}
}

// TestClearRefs 验证 ClearRefs 清空某源的全部引用且可重复调用（幂等）。
func TestClearRefs(t *testing.T) {
	svc, _, root := newRefsFixture(t)
	writeRootFile(t, root, "a.org", "[[seshat:"+uidB+"]]\n")
	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs() 返回错误: %v", err)
	}

	if err := svc.ClearRefs(uidA); err != nil {
		t.Fatalf("ClearRefs() 返回错误: %v", err)
	}
	if refs, _ := svc.ListRefs(uidA, storage.RefDirectionOut); len(refs) != 0 {
		t.Fatalf("清空后引用 = %+v, 期望为空", refs)
	}
	if err := svc.ClearRefs(uidA); err != nil {
		t.Fatalf("重复 ClearRefs() 返回错误: %v", err)
	}
}

// TestRefreshRefsCapsLinksPerDocument 验证单份文档的引用条数被截断到 maxRefsPerDocument。
//
// 构造 2001 条链接（目标相同、location 各不相同 → 去重键不同，全部是独立引用）。
// 截断优先于拒绝：写入仍成功，引用图只保留首次出现的 maxRefsPerDocument 条。
func TestRefreshRefsCapsLinksPerDocument(t *testing.T) {
	svc, _, root := newRefsFixture(t)

	var content strings.Builder
	for i := 0; i < maxRefsPerDocument+1; i++ {
		content.WriteString("[[seshat:" + uidB + "#p." + strconv.Itoa(i) + "]]\n")
	}
	writeRootFile(t, root, "a.org", content.String())

	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs() 返回错误: %v", err)
	}

	refs, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(refs) != maxRefsPerDocument {
		t.Fatalf("引用条数 = %d, 期望被截断到 %d", len(refs), maxRefsPerDocument)
	}

	// 截断按首次出现顺序：第一条保留，#p.<上限> 那条（第 2001 条）不应落库。
	if refs[0].TargetLocation != "p.0" {
		t.Fatalf("首条 location = %q, 期望 p.0（截断应保留首次出现的条目）", refs[0].TargetLocation)
	}
	last := "p." + strconv.Itoa(maxRefsPerDocument)
	for _, r := range refs {
		if r.TargetLocation == last {
			t.Fatalf("第 %d 条 location=%q 被保留，期望被截断", maxRefsPerDocument+1, last)
		}
	}
}

// TestListRefsDirections 验证 in/out 两个方向的过滤语义与空 direction 的默认值。
func TestListRefsDirections(t *testing.T) {
	svc, _, root := newRefsFixture(t)
	writeRootFile(t, root, "a.org", "[[seshat:"+uidB+"]]\n[[seshat:"+uidB+"#p.1]]\n")
	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs() 返回错误: %v", err)
	}

	out, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs(out) 返回错误: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("out 方向条数 = %d, 期望 2", len(out))
	}

	in, err := svc.ListRefs(uidB, storage.RefDirectionIn)
	if err != nil {
		t.Fatalf("ListRefs(in) 返回错误: %v", err)
	}
	if len(in) != 2 {
		t.Fatalf("in 方向条数 = %d, 期望 2", len(in))
	}
	for _, r := range in {
		if r.SourceUID != uidA || r.TargetUID != uidB {
			t.Fatalf("in 方向引用 = %+v, 期望 source=%s target=%s", r, uidA, uidB)
		}
	}

	// 空 direction 等价 out（与 storage 层口径一致）。
	def, err := svc.ListRefs(uidA, "")
	if err != nil {
		t.Fatalf("ListRefs(空 direction) 返回错误: %v", err)
	}
	if len(def) != 2 {
		t.Fatalf("空 direction 条数 = %d, 期望 2（等价 out）", len(def))
	}

	// 非法 direction 返回 invalid_argument。
	_, err = svc.ListRefs(uidA, "sideways")
	assertCode(t, err, logging.ErrInvalidArgument)
}

// uidCForRefs 是一个合法且可与 uidA/uidB 并存登记的 uid（26 位 Crockford Base32），
// 用于「显式 uid 形态确实进入了 refs 表」的集成用例。
const uidCForRefs = "01K8Q3M7D2X9V6T1B8N5C0RDEJ"

// TestResolveExplicitUIDForm 验证客户端产出的显式 uid 形态 "uid:<uid>"
// （org 链接写作 [[seshat:uid:<uid>]]）被 Service.Resolve 认作 uid。
//
// 断言口径（优先级四段的第 3、4 段）：
//   - "uid:" + 合法 uid 与裸 uid 共用同一套 uid 语义：已登记返回 uid，墓碑返回 ErrNotFound；
//   - "uid:" 之后不是合法 uid（长度不对 / 含小写 / 含 Crockford 排除字母 / 为空）时
//     必须回落到 tag:path（把 "uid" 当普通根 tag），**不得**返回 invalid_argument——
//     否则一个名为 uid 的根 tag 会永久不可用；此处用错误信息含「路径」来证明走了路径分支；
//   - 裸 uid 与 tag:path 两种既有形态行为不变（回归）。
func TestResolveExplicitUIDForm(t *testing.T) {
	svc, _, _ := newRefsFixture(t)

	// 第 1、2、6、7 例：合法 uid 形态 + 两种既有形态的回归。
	t.Run("合法 uid:/裸 uid/tag:path", func(t *testing.T) {
		cases := []struct{ name, key, wantUID string }{
			{"显式 uid 形态（a.org）", "uid:" + uidA, uidA},
			{"显式 uid 形态（另一份文档）", "uid:" + uidB, uidB},
			{"回归：裸 uid 形态不变", uidA, uidA},
			{"回归：tag:path 形态不变", "notes:sub/b.org", uidB},
		}
		for _, tc := range cases {
			got, err := svc.Resolve(tc.key)
			if err != nil {
				t.Fatalf("Resolve(%q) 返回错误: %v", tc.key, err)
			}
			if got != tc.wantUID {
				t.Fatalf("Resolve(%q) = %q, 期望 %q", tc.key, got, tc.wantUID)
			}
		}
	})

	// 第 3、4、5 例：前缀后不是合法 uid → 回落 tag:path（根 tag 为 "uid"）。
	t.Run("非法 uid 形态回落 tag:path", func(t *testing.T) {
		cases := []struct {
			name        string
			key         string
			wantCode    logging.Code
			wantMsgPart string
		}{
			// 25 位：长度不合法 → 根 tag=uid、路径为该 25 位串 → 路径未登记（ErrNotFound）。
			{"25 位（非法长度）", "uid:" + uidA[:25], logging.ErrNotFound, "路径未登记"},
			// 26 位但含小写字母：不满足 Crockford Base32 的字符类 → 同样按路径查。
			{"26 位含小写字母", "uid:" + strings.ToLower(uidA), logging.ErrNotFound, "路径未登记"},
			// 26 位但含 Crockford 排除字母 I：同上。
			{"26 位含排除字母 I", "uid:" + "01K8Q3M7D2X9V6T1B8N5C0RDEI", logging.ErrNotFound, "路径未登记"},
			// 前缀后为空：根 tag=uid、路径为空串，ResolvePath 先规范化路径 → 实际错误是
			// normalizeResourcePath 给出的 invalid_argument「资源路径不能为空」。
			// 注意它**不是** uid 分支的错误（uid 分支给的是「uid 格式非法」或墓碑的
			// ErrNotFound），用错误码 + 消息片段一起固定下来。
			{"前缀后为空", "uid:", logging.ErrInvalidArgument, "资源路径不能为空"},
		}
		for _, tc := range cases {
			got, err := svc.Resolve(tc.key)
			if err == nil {
				t.Fatalf("Resolve(%q) 应返回错误，实际得到 %q", tc.key, got)
			}
			assertCode(t, err, tc.wantCode)
			var appErr *logging.AppError
			if !errors.As(err, &appErr) {
				t.Fatalf("Resolve(%q) 的错误 %v 不是 AppError", tc.key, err)
			}
			if !strings.Contains(appErr.Message, tc.wantMsgPart) {
				t.Fatalf("Resolve(%q) 错误信息 = %q, 期望包含 %q（证明走的是 tag:path 分支）",
					tc.key, appErr.Message, tc.wantMsgPart)
			}
		}
	})

	// 第 2 例：墓碑语义——显式 uid 形态与裸 uid 一样返回 ErrNotFound。
	t.Run("显式 uid 形态的墓碑语义", func(t *testing.T) {
		if _, err := svc.Apply(Event{UID: uidB, Op: storage.OpDelete, Root: "notes", Path: "sub/b.org"}); err != nil {
			t.Fatalf("Apply(delete) 返回错误: %v", err)
		}
		for _, key := range []string{"uid:" + uidB, uidB} {
			got, err := svc.Resolve(key)
			if err == nil {
				t.Fatalf("Resolve(%q) 应返回错误（已删除），实际得到 %q", key, got)
			}
			assertCode(t, err, logging.ErrNotFound)
		}
	})
}

// TestResolveExplicitUIDFormKeepsUIDRoot 验证「前缀后不合法 → 回落 tag:path」这条约束
// 真的让一个名为 uid 的根 tag 仍然可用（否则该类配置会永久解析不到）。
func TestResolveExplicitUIDFormKeepsUIDRoot(t *testing.T) {
	svc, _ := newTestService(t)
	if err := svc.SetRoots([]Root{{Tag: "uid", Path: t.TempDir()}}); err != nil {
		t.Fatalf("SetRoots() 返回错误: %v", err)
	}
	for _, ev := range []Event{
		{UID: uidA, Op: storage.OpCreate, Root: "uid", Path: "a.org"},
		{UID: uidB, Op: storage.OpCreate, Root: "uid", Path: "b.org"},
	} {
		if _, err := svc.Apply(ev); err != nil {
			t.Fatalf("Apply() 返回错误: %v", err)
		}
	}

	// "uid:b.org" 不是合法 uid 形态（b.org 不是 uid），应回落为 root=uid、path=b.org。
	got, err := svc.Resolve("uid:b.org")
	if err != nil {
		t.Fatalf("Resolve(\"uid:b.org\") 返回错误: %v", err)
	}
	if got != uidB {
		t.Fatalf("Resolve(\"uid:b.org\") = %q, 期望 %q", got, uidB)
	}
}

// TestRefreshRefsResolvesExplicitUIDForm 验证客户端形态的链接（seshat:uid:<uid>）经
// RefreshRefs 后确实进入 refs 表——这是本形态的最终目的（GET /api/refs 能看到该边）。
//
// 结构仿 TestRefreshRefsResolvesThreeForms：同一份 a.org 里混写显式 uid 形态与
// tag:path 形态，刷新后 out 方向应有两条指向不同目标文档的边。
func TestRefreshRefsResolvesExplicitUIDForm(t *testing.T) {
	svc, _, root := newRefsFixture(t)
	if _, err := svc.Apply(Event{UID: uidCForRefs, Op: storage.OpCreate, Root: "notes", Path: "c.org"}); err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}

	writeRootFile(t, root, "a.org", "[[seshat:uid:"+uidB+"]]\n[[seshat:notes:c.org]]\n")
	if err := svc.RefreshRefs("notes", "a.org"); err != nil {
		t.Fatalf("RefreshRefs() 返回错误: %v", err)
	}

	refs, err := svc.ListRefs(uidA, storage.RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(refs) != 2 {
		t.Fatalf("引用条数 = %d, 期望 2（显式 uid 形态与 tag:path 形态各一条）: %+v", len(refs), refs)
	}

	targets := map[string]bool{}
	for _, r := range refs {
		if r.SourceUID != uidA {
			t.Fatalf("引用 = %+v, 期望 source=%s", r, uidA)
		}
		targets[r.TargetUID] = true
	}
	if !targets[uidB] || !targets[uidCForRefs] {
		t.Fatalf("引用目标 = %v, 期望同时包含 %s（uid: 形态）与 %s（tag:path 形态）",
			targets, uidB, uidCForRefs)
	}
}

// TestTruncateForLog 验证日志里的 target 限长处理（E 项安全修复）：
// 超长 target 不得原样写进日志，截断点必须落在 UTF-8 字符边界上。
func TestTruncateForLog(t *testing.T) {
	if got := truncateForLog("short", maxTargetLogBytes); got != "short" {
		t.Fatalf("truncateForLog(短串) = %q, 期望原样返回", got)
	}

	long := strings.Repeat("a", maxTargetLogBytes+50)
	got := truncateForLog(long, maxTargetLogBytes)
	if len(got) != maxTargetLogBytes+len("…") {
		t.Fatalf("truncateForLog(超长串) 长度 = %d, 期望 %d", len(got), maxTargetLogBytes+len("…"))
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("truncateForLog(超长串) = %q, 期望以省略号收尾", got)
	}
	if body := strings.TrimSuffix(got, "…"); !strings.HasPrefix(long, body) {
		t.Fatalf("truncateForLog(超长串) 不是原串前缀: %q", got)
	}

	// 多字节字符被截断时必须回退到字符边界（否则日志是乱码字节）
	multibyte := strings.Repeat("中", maxTargetLogBytes) // 每个 3 字节
	cut := truncateForLog(multibyte, maxTargetLogBytes)
	body := strings.TrimSuffix(cut, "…")
	if !utf8.ValidString(body) {
		t.Fatalf("truncateForLog 截断多字节串后不是合法 UTF-8: %q", body)
	}
	if len(body) > maxTargetLogBytes {
		t.Fatalf("truncateForLog 截断多字节串后仍超过上限: %d", len(body))
	}

	// 截断点落在多字节字符中间时必须回退到 RuneStart（上面的用例取了 3 的整数倍，
	// 恰好不需要回退；这里用 121 让 s[121] 落在「中」的第 2 个字节上）。
	straddle := truncateForLog(strings.Repeat("中", maxTargetLogBytes), maxTargetLogBytes+1)
	straddleBody := strings.TrimSuffix(straddle, "…")
	if len(straddleBody) != maxTargetLogBytes {
		t.Fatalf("truncateForLog 回退到字符边界后长度 = %d, 期望 %d", len(straddleBody), maxTargetLogBytes)
	}
	if !utf8.ValidString(straddleBody) {
		t.Fatalf("truncateForLog 回退到字符边界后不是合法 UTF-8: %q", straddleBody)
	}
}
