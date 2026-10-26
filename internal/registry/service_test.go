// 本文件测试 registry.Service 的事件应用与 key 解析。
//
// 断言口径：
//   - Apply 是「upsert 资源登记 + 追加变更事件」的单事务入口，op 语义边界明确：
//     create 已存在视为 update（幂等重放）、update 不存在先 create、
//     rename 保持 uid 不变且目标被占用报冲突、delete 写墓碑。
//   - Resolve 接受四种 key 形态，优先级：裸 uid > 显式 uid:<uid>（客户端形态）>
//     tag:path > 纯 path（默认根）；"uid:" 之后不是合法 uid 时回落到 tag:path 分支。
package registry

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"seshat/internal/logging"
	"seshat/internal/storage"
)

const (
	// uidA / uidB 是测试用的合法 uid（26 字符 Crockford Base32）。
	uidA = "01K8Q3M7D2X9V6T1B8N5C0RDEF"
	uidB = "01K8Q3M7D2X9V6T1B8N5C0RDEG"
)

// newTestService 在临时目录打开一个全新库并返回 Service 与其 DB（供直接断言）。
func newTestService(t *testing.T) (*Service, *storage.DB) {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("storage.Open() 返回错误: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return New(db, nil), db
}

// assertCode 断言 err 是带指定错误码的 AppError。
func assertCode(t *testing.T, err error, want logging.Code) {
	t.Helper()
	var appErr *logging.AppError
	if !errors.As(err, &appErr) {
		t.Fatalf("错误 %v 不是 AppError（期望错误码 %q）", err, want)
	}
	if appErr.Code != want {
		t.Fatalf("错误码 = %q, 期望 %q（err=%v）", appErr.Code, want, err)
	}
}

// createEvent 构造一条笔记根上的 create 事件。
func createEvent(uid, path string) Event {
	return Event{
		UID:   uid,
		Op:    storage.OpCreate,
		Root:  "notes",
		Path:  path,
		Blob:  "blob-" + uid,
		Rev:   "rev-1",
		Size:  10,
		Mtime: 1000,
	}
}

// lastChange 返回日志中最后一条事件；日志为空时终止测试。
func lastChange(t *testing.T, svc *Service) storage.Change {
	t.Helper()
	changes, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	if len(changes) == 0 {
		t.Fatal("变更日志为空")
	}
	return changes[len(changes)-1]
}

// TestApplyCreate 验证 create 写入登记与事件，seq 从 1 开始，At 空时自动填 RFC3339。
func TestApplyCreate(t *testing.T) {
	svc, _ := newTestService(t)

	seq, err := svc.Apply(createEvent(uidA, "a.org"))
	if err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}
	if seq != 1 {
		t.Fatalf("首个事件 seq = %d, 期望 1", seq)
	}

	saved, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}
	if saved.Path != "a.org" || saved.Size != 10 || saved.Mtime != 1000 ||
		saved.Blob != "blob-"+uidA || saved.Rev != "rev-1" {
		t.Fatalf("登记内容 = %+v, 与事件字段不一致", saved)
	}
	if saved.CreatedAt == "" || saved.UpdatedAt == "" {
		t.Fatalf("时间戳未填充: created_at=%q updated_at=%q", saved.CreatedAt, saved.UpdatedAt)
	}

	ch := lastChange(t, svc)
	if ch.Op != storage.OpCreate || ch.UID != uidA || ch.Path != "a.org" || ch.Seq != seq {
		t.Fatalf("变更事件 = %+v, 期望 op=create uid=%s path=a.org seq=%d", ch, uidA, seq)
	}
	if ch.ChangedAt == "" {
		t.Fatal("变更事件 changed_at 为空")
	}
}

// TestApplyCreateReplayIsUpdate 验证 create 重放（uid 已存在）按 update 处理：
// 字段被刷新、created_at 保留、事件 op 记为 update。
func TestApplyCreateReplayIsUpdate(t *testing.T) {
	svc, _ := newTestService(t)

	if _, err := svc.Apply(createEvent(uidA, "a.org")); err != nil {
		t.Fatalf("首次 Apply() 返回错误: %v", err)
	}
	first, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}

	replay := createEvent(uidA, "a.org")
	replay.Size, replay.Mtime = 20, 2000
	seq, err := svc.Apply(replay)
	if err != nil {
		t.Fatalf("重放 Apply() 返回错误: %v", err)
	}

	saved, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}
	if saved.Size != 20 || saved.Mtime != 2000 {
		t.Fatalf("重放后 size/mtime = %d/%d, 期望 20/2000", saved.Size, saved.Mtime)
	}
	if saved.CreatedAt != first.CreatedAt {
		t.Fatalf("重放后 created_at = %q, 期望保留 %q", saved.CreatedAt, first.CreatedAt)
	}

	ch := lastChange(t, svc)
	if ch.Op != storage.OpUpdate || ch.Seq != seq {
		t.Fatalf("重放事件 = %+v, 期望 op=update seq=%d", ch, seq)
	}
}

// TestApplyUpdateCreatesWhenMissing 验证 update 遇到未登记的 uid 时先 create。
func TestApplyUpdateCreatesWhenMissing(t *testing.T) {
	svc, _ := newTestService(t)

	ev := createEvent(uidA, "a.org")
	ev.Op = storage.OpUpdate
	if _, err := svc.Apply(ev); err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}

	if _, err := svc.Entry(uidA); err != nil {
		t.Fatalf("update 未创建登记: %v", err)
	}
	if ch := lastChange(t, svc); ch.Op != storage.OpCreate {
		t.Fatalf("事件 op = %q, 期望 create（uid 不存在时 update 先创建）", ch.Op)
	}
}

// TestApplyRenameKeepsUID 验证改名保留 uid、旧路径失效、事件记 old_path。
func TestApplyRenameKeepsUID(t *testing.T) {
	svc, _ := newTestService(t)

	if _, err := svc.Apply(createEvent(uidA, "old.org")); err != nil {
		t.Fatalf("Apply(create) 返回错误: %v", err)
	}
	before, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}

	seq, err := svc.Apply(Event{
		UID: uidA, Op: storage.OpRename, Root: "notes",
		Path: "sub/new.org", OldPath: "old.org",
	})
	if err != nil {
		t.Fatalf("Apply(rename) 返回错误: %v", err)
	}

	after, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("改名后 Entry() 返回错误: %v", err)
	}
	if after.UID != uidA || after.Path != "sub/new.org" {
		t.Fatalf("改名后登记 = %+v, 期望 uid 不变 path=sub/new.org", after)
	}
	if after.CreatedAt != before.CreatedAt {
		t.Fatalf("改名后 created_at = %q, 期望保留 %q", after.CreatedAt, before.CreatedAt)
	}
	if after.Size != before.Size || after.Blob != before.Blob {
		t.Fatalf("改名不应改内容字段: before=%+v after=%+v", before, after)
	}

	if _, err := svc.ResolvePath("notes", "old.org"); err == nil {
		t.Fatal("旧路径仍可解析，期望 not found")
	}

	ch := lastChange(t, svc)
	if ch.Op != storage.OpRename || ch.Seq != seq || ch.Path != "sub/new.org" || ch.OldPath != "old.org" {
		t.Fatalf("改名事件 = %+v, 期望 op=rename path=sub/new.org old_path=old.org", ch)
	}
}

// TestApplyRenameConflict 验证改名目标被其它 uid 占用时返回 ErrConflict 且不写事件。
func TestApplyRenameConflict(t *testing.T) {
	svc, _ := newTestService(t)

	for _, ev := range []Event{createEvent(uidA, "a.org"), createEvent(uidB, "b.org")} {
		if _, err := svc.Apply(ev); err != nil {
			t.Fatalf("Apply() 返回错误: %v", err)
		}
	}
	logged, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}

	_, err = svc.Apply(Event{
		UID: uidA, Op: storage.OpRename, Root: "notes", Path: "b.org", OldPath: "a.org",
	})
	assertCode(t, err, logging.ErrConflict)

	after, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	if len(after) != len(logged) {
		t.Fatalf("冲突后日志条数 = %d, 期望不变（%d）", len(after), len(logged))
	}
	saved, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}
	if saved.Path != "a.org" {
		t.Fatalf("冲突后 uidA 路径 = %q, 期望仍为 a.org", saved.Path)
	}
}

// TestApplyDeleteWritesTombstone 验证 delete 写墓碑（记录可查、Resolve 与 Entry 视为不存在）。
func TestApplyDeleteWritesTombstone(t *testing.T) {
	svc, db := newTestService(t)

	if _, err := svc.Apply(createEvent(uidA, "a.org")); err != nil {
		t.Fatalf("Apply(create) 返回错误: %v", err)
	}
	seq, err := svc.Apply(Event{UID: uidA, Op: storage.OpDelete, Root: "notes", Path: "a.org"})
	if err != nil {
		t.Fatalf("Apply(delete) 返回错误: %v", err)
	}

	raw, err := db.GetResourceByUID(uidA)
	if err != nil {
		t.Fatalf("墓碑记录不可读: %v", err)
	}
	if raw.DeletedAt == "" {
		t.Fatal("删除后 DeletedAt 为空，期望墓碑非空")
	}
	if raw.Path != "a.org" {
		t.Fatalf("墓碑记录 Path = %q, 期望保留删除前路径 a.org", raw.Path)
	}

	if _, err := svc.Entry(uidA); err == nil {
		t.Fatal("墓碑资源 Entry() 应返回 not found")
	} else {
		assertCode(t, err, logging.ErrNotFound)
	}
	if _, err := svc.ResolvePath("notes", "a.org"); err == nil {
		t.Fatal("墓碑路径 ResolvePath() 应返回 not found")
	}

	ch := lastChange(t, svc)
	if ch.Op != storage.OpDelete || ch.Seq != seq || ch.Path != "a.org" {
		t.Fatalf("删除事件 = %+v, 期望 op=delete path=a.org seq=%d", ch, seq)
	}
}

// TestApplyDeleteMissing 验证删除未登记的 uid 返回 ErrNotFound。
func TestApplyDeleteMissing(t *testing.T) {
	svc, _ := newTestService(t)

	_, err := svc.Apply(Event{UID: uidA, Op: storage.OpDelete, Root: "notes", Path: "a.org"})
	assertCode(t, err, logging.ErrNotFound)
}

// TestApplyValidatesEvent 验证非法 uid / op / root / path 均返回 ErrInvalidArgument。
func TestApplyValidatesEvent(t *testing.T) {
	svc, _ := newTestService(t)

	cases := []struct {
		name string
		ev   Event
	}{
		{"uid 位数不足", Event{UID: "ABC", Op: storage.OpCreate, Root: "notes", Path: "a.org"}},
		{"uid 含被排除字母 O", Event{UID: "01K8Q3M7D2X9V6T1B8N5C0RDEO", Op: storage.OpCreate, Root: "notes", Path: "a.org"}},
		{"op 非法", Event{UID: uidA, Op: "bogus", Root: "notes", Path: "a.org"}},
		{"root 为空", Event{UID: uidA, Op: storage.OpCreate, Path: "a.org"}},
		{"path 为空", Event{UID: uidA, Op: storage.OpCreate, Root: "notes"}},
		{"path 逃逸", Event{UID: uidA, Op: storage.OpCreate, Root: "notes", Path: "../etc/passwd"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := svc.Apply(tc.ev); err == nil {
				t.Fatal("Apply() 应返回错误，实际返回 nil")
			} else {
				assertCode(t, err, logging.ErrInvalidArgument)
			}
		})
	}
}

// TestApplySeqIncrements 验证连续事件的 seq 严格递增。
func TestApplySeqIncrements(t *testing.T) {
	svc, _ := newTestService(t)

	want := int64(1)
	for _, ev := range []Event{createEvent(uidA, "a.org"), createEvent(uidB, "b.org")} {
		seq, err := svc.Apply(ev)
		if err != nil {
			t.Fatalf("Apply() 返回错误: %v", err)
		}
		if seq != want {
			t.Fatalf("seq = %d, 期望 %d", seq, want)
		}
		want++
	}
}

// TestResolveByUID 验证 uid key 直接解析为自身。
func TestResolveByUID(t *testing.T) {
	svc, _ := newTestService(t)
	if _, err := svc.Apply(createEvent(uidA, "a.org")); err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}

	got, err := svc.Resolve(uidA)
	if err != nil {
		t.Fatalf("Resolve(%s) 返回错误: %v", uidA, err)
	}
	if got != uidA {
		t.Fatalf("Resolve(%s) = %q, 期望 %q", uidA, got, uidA)
	}
	if _, err := svc.Resolve(uidB); err == nil {
		t.Fatal("未登记的合法 uid 应返回错误")
	} else {
		assertCode(t, err, logging.ErrNotFound)
	}
}

// TestResolveByTagPath 验证 "tag:path" 形态，且路径前导斜杠被规范化。
func TestResolveByTagPath(t *testing.T) {
	svc, _ := newTestService(t)
	if _, err := svc.Apply(createEvent(uidA, "sub/a.org")); err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}

	for _, key := range []string{"notes:sub/a.org", "notes:/sub/a.org", "notes:sub//a.org"} {
		got, err := svc.Resolve(key)
		if err != nil {
			t.Fatalf("Resolve(%q) 返回错误: %v", key, err)
		}
		if got != uidA {
			t.Fatalf("Resolve(%q) = %q, 期望 %q", key, got, uidA)
		}
	}

	// 未知 tag：路径未登记 → not found。
	if _, err := svc.Resolve("ebooks:sub/a.org"); err == nil {
		t.Fatal("未知根的路径应返回 not found")
	} else {
		assertCode(t, err, logging.ErrNotFound)
	}
}

// TestResolveByPlainPathUsesDefaultRoot 验证纯 path 走 SetRoots 的首个根。
func TestResolveByPlainPathUsesDefaultRoot(t *testing.T) {
	svc, _ := newTestService(t)
	if err := svc.SetRoots([]Root{
		{Tag: "notes", Path: t.TempDir(), Mode: RootModeMirror},
		{Tag: "ebooks", Path: t.TempDir(), Mode: RootModeOnDemand},
	}); err != nil {
		t.Fatalf("SetRoots() 返回错误: %v", err)
	}
	if _, err := svc.Apply(createEvent(uidA, "a.org")); err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}

	got, err := svc.Resolve("a.org")
	if err != nil {
		t.Fatalf("Resolve() 返回错误: %v", err)
	}
	if got != uidA {
		t.Fatalf("Resolve(a.org) = %q, 期望 %q（默认根 notes）", got, uidA)
	}
}

// TestResolveWithoutDefaultRoot 验证未调用 SetRoots 时纯 path 解析给出明确错误。
func TestResolveWithoutDefaultRoot(t *testing.T) {
	svc, _ := newTestService(t)

	_, err := svc.Resolve("a.org")
	assertCode(t, err, logging.ErrInvalidArgument)
	if err == nil || !strings.Contains(err.Error(), "未设置默认根") {
		t.Fatalf("错误信息 = %v, 期望含「未设置默认根」", err)
	}
}

// TestResolvePathEscape 验证 ".." 逃逸与空路径被拒绝，未登记路径返回 not found。
func TestResolvePathEscape(t *testing.T) {
	svc, _ := newTestService(t)
	if _, err := svc.Apply(createEvent(uidA, "a.org")); err != nil {
		t.Fatalf("Apply() 返回错误: %v", err)
	}

	if _, err := svc.ResolvePath("notes", "../etc/passwd"); err == nil {
		t.Fatal("含 .. 的路径应被拒绝")
	} else {
		assertCode(t, err, logging.ErrInvalidArgument)
	}
	if _, err := svc.ResolvePath("", "a.org"); err == nil {
		t.Fatal("空 root 应被拒绝")
	} else {
		assertCode(t, err, logging.ErrInvalidArgument)
	}
	if _, err := svc.ResolvePath("notes", "missing.org"); err == nil {
		t.Fatal("未登记路径应返回 not found")
	} else {
		assertCode(t, err, logging.ErrNotFound)
	}

	// 前导斜杠与重复斜杠属于同一资源。
	got, err := svc.ResolvePath("notes", "/a.org")
	if err != nil {
		t.Fatalf("ResolvePath(/a.org) 返回错误: %v", err)
	}
	if got != uidA {
		t.Fatalf("ResolvePath(/a.org) = %q, 期望 %q", got, uidA)
	}
}

// TestSetRootsValidation 验证根清单校验（tag 唯一非空、不含 ':'、至少一项）。
func TestSetRootsValidation(t *testing.T) {
	cases := []struct {
		name  string
		roots []Root
	}{
		{"空清单", nil},
		{"tag 为空", []Root{{Tag: "", Path: "/tmp/a"}}},
		{"tag 含冒号", []Root{{Tag: "no:tes", Path: "/tmp/a"}}},
		{"tag 重复", []Root{{Tag: "notes", Path: "/tmp/a"}, {Tag: "notes", Path: "/tmp/b"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc, _ := newTestService(t)
			if err := svc.SetRoots(tc.roots); err == nil {
				t.Fatal("SetRoots() 应返回错误，实际返回 nil")
			} else {
				assertCode(t, err, logging.ErrInvalidArgument)
			}
		})
	}
}

// TestRootsReturnsCopy 验证 Roots() 返回副本（外部修改不影响内部默认根），
// 且未指定 Mode 时按位置归一（首根 mirror，其余 ondemand）。
func TestRootsReturnsCopy(t *testing.T) {
	svc, _ := newTestService(t)
	if err := svc.SetRoots([]Root{
		{Tag: "notes", Path: "/tmp/a"},
		{Tag: "ebooks", Path: "/tmp/b"},
	}); err != nil {
		t.Fatalf("SetRoots() 返回错误: %v", err)
	}

	got := svc.Roots()
	if len(got) != 2 {
		t.Fatalf("Roots() 长度 = %d, 期望 2", len(got))
	}
	if got[0].Mode != RootModeMirror || got[1].Mode != RootModeOnDemand {
		t.Fatalf("Mode 归一结果 = %q/%q, 期望 mirror/ondemand", got[0].Mode, got[1].Mode)
	}

	got[0].Tag = "mutated"
	if again := svc.Roots(); again[0].Tag != "notes" {
		t.Fatalf("Roots() 返回了内部切片（被外部修改为 %q）", again[0].Tag)
	}
}

// TestListChangesEntryDelegate 验证 List / Changes / Entry 的薄委托行为。
func TestListChangesEntryDelegate(t *testing.T) {
	svc, _ := newTestService(t)
	for _, ev := range []Event{createEvent(uidA, "a.org"), createEvent(uidB, "b.org")} {
		if _, err := svc.Apply(ev); err != nil {
			t.Fatalf("Apply() 返回错误: %v", err)
		}
	}

	items, err := svc.List(storage.ResourceFilter{Root: "notes"})
	if err != nil {
		t.Fatalf("List() 返回错误: %v", err)
	}
	if len(items) != 2 || items[0].Path != "a.org" || items[1].Path != "b.org" {
		t.Fatalf("List() = %+v, 期望按 (root, path) 升序返回两条", items)
	}

	changes, next, hasMore, err := svc.Changes(0, 1)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	if len(changes) != 1 || !hasMore || next != changes[0].Seq {
		t.Fatalf("Changes(0,1) = %+v next=%d hasMore=%v, 期望单条且还有更多", changes, next, hasMore)
	}

	if _, err := svc.Entry(uidB); err != nil {
		t.Fatalf("Entry(%s) 返回错误: %v", uidB, err)
	}
	if _, err := svc.Entry("bad-uid"); err == nil {
		t.Fatal("非法 uid 的 Entry() 应返回错误")
	}
}
