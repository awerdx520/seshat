// 本文件测试 bootstrap / rescan：文件系统 → 登记表。
//
// 断言口径：
//   - 只登记普通文件；`.git` 与任何以 `.` 开头的目录整棵跳过（版本库与编辑器缓存
//     不是笔记内容）；符号链接与目录不登记。
//   - 幂等：未变更的文件计入 Unchanged，不产生多余事件（客户端游标不被无意义推进）。
//   - 内容或 mtime 变化计入 Updated，uid 保持不变。
//   - Rescan 在 bootstrap 之后比对「登记存活集」与「本次遍历集」，缺失者写 delete，
//     用以修复钩子漏记。
package registry

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"seshat/internal/gitver"
	"seshat/internal/logging"
	"seshat/internal/storage"
)

// writeFile 在 root 下写入文件（自动创建父目录）并返回完整路径。
func writeFile(t *testing.T, root, rel, content string) string {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("创建目录 %s 失败: %v", filepath.Dir(full), err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("写入 %s 失败: %v", rel, err)
	}
	return full
}

// buildTree 构造 bootstrap 的样例目录树：
//
//	a.org、sub/b.org（应登记）、.git/x、.hidden/y（应跳过）、empty/（目录不计）、
//	link.org（符号链接，应跳过）。
func buildTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeFile(t, root, "a.org", "aaa")
	writeFile(t, root, "sub/b.org", "bbb")
	writeFile(t, root, ".git/x", "git-internal")
	writeFile(t, root, ".hidden/y", "hidden")
	if err := os.MkdirAll(filepath.Join(root, "empty"), 0o755); err != nil {
		t.Fatalf("创建空目录失败: %v", err)
	}
	if err := os.Symlink(filepath.Join(root, "a.org"), filepath.Join(root, "link.org")); err != nil {
		t.Fatalf("创建符号链接失败: %v", err)
	}
	return root
}

// assertStats 逐字段断言统计值。
func assertStats(t *testing.T, got Stats, want Stats) {
	t.Helper()
	if got != want {
		t.Fatalf("Stats = %+v, 期望 %+v", got, want)
	}
}

// TestBootstrapCreates 验证首次扫描只登记普通文件，跳过 .git / 隐藏目录 / 符号链接 / 目录。
func TestBootstrapCreates(t *testing.T) {
	svc, _ := newTestService(t)
	root := buildTree(t)

	stats, err := svc.Bootstrap(context.Background(), []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}})
	if err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 2, Created: 2})

	items, err := svc.List(storage.ResourceFilter{Root: "notes"})
	if err != nil {
		t.Fatalf("List() 返回错误: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("登记条数 = %d, 期望 2（%+v）", len(items), items)
	}
	if items[0].Path != "a.org" || items[1].Path != "sub/b.org" {
		t.Fatalf("登记路径 = %q/%q, 期望 a.org/sub/b.org", items[0].Path, items[1].Path)
	}
	for _, it := range items {
		if !IsUID(it.UID) {
			t.Fatalf("登记 uid %q 非法", it.UID)
		}
	}

	// .git / 隐藏目录 / 符号链接都不得登记。
	//
	// 点路径在 normalizeResourcePath 层就被拒绝（invalid_argument，见 service.go），
	// 故这里只断言「无法解析」；「确实没进登记表」由上面的 len(items)==2 与路径断言
	// 直接证明（若被登记，items 会多出这些路径）。
	for _, p := range []string{".git/x", ".hidden/y", "link.org"} {
		if _, err := svc.ResolvePath("notes", p); err == nil {
			t.Fatalf("路径 %q 不应被登记", p)
		}
	}
}

// TestBootstrapIdempotent 验证二次扫描全部计入 Unchanged（无新增事件）。
func TestBootstrapIdempotent(t *testing.T) {
	svc, _ := newTestService(t)
	root := buildTree(t)
	roots := []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}

	if _, err := svc.Bootstrap(context.Background(), roots); err != nil {
		t.Fatalf("首次 Bootstrap() 返回错误: %v", err)
	}
	_, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}

	stats, err := svc.Bootstrap(context.Background(), roots)
	if err != nil {
		t.Fatalf("二次 Bootstrap() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 2, Unchanged: 2})

	changes, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	if len(changes) != 2 {
		t.Fatalf("变更事件条数 = %d, 期望仍为 2（幂等扫描不产生新事件）", len(changes))
	}
}

// TestBootstrapUpdates 验证内容与 mtime 变化计入 Updated，且 uid 不变。
func TestBootstrapUpdates(t *testing.T) {
	svc, _ := newTestService(t)
	root := buildTree(t)
	roots := []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}

	if _, err := svc.Bootstrap(context.Background(), roots); err != nil {
		t.Fatalf("首次 Bootstrap() 返回错误: %v", err)
	}
	uidBefore, err := svc.ResolvePath("notes", "a.org")
	if err != nil {
		t.Fatalf("ResolvePath() 返回错误: %v", err)
	}

	// 改写内容（长度不同）并显式推进 mtime，避免同秒写入被判定为未变更。
	full := writeFile(t, root, "a.org", "changed-content-longer")
	later := time.Now().Add(10 * time.Second)
	if err := os.Chtimes(full, later, later); err != nil {
		t.Fatalf("设置 mtime 失败: %v", err)
	}

	stats, err := svc.Bootstrap(context.Background(), roots)
	if err != nil {
		t.Fatalf("二次 Bootstrap() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 2, Updated: 1, Unchanged: 1})

	uidAfter, err := svc.ResolvePath("notes", "a.org")
	if err != nil {
		t.Fatalf("ResolvePath() 返回错误: %v", err)
	}
	if uidAfter != uidBefore {
		t.Fatalf("更新后 uid = %q, 期望保持不变 %q", uidAfter, uidBefore)
	}
	saved, err := svc.Entry(uidBefore)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}
	if saved.Size != int64(len("changed-content-longer")) || saved.Mtime != later.Unix() {
		t.Fatalf("登记 size/mtime = %d/%d, 期望 %d/%d",
			saved.Size, saved.Mtime, len("changed-content-longer"), later.Unix())
	}
}

// TestBootstrapMirrorBlob 验证 mirror 根记录 git blob hash，ondemand 根一律空串。
func TestBootstrapMirrorBlob(t *testing.T) {
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("storage.Open() 返回错误: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	mirrorRoot := t.TempDir()
	writeFile(t, mirrorRoot, "a.org", "aaa")
	repo, err := gitver.Open(mirrorRoot)
	if err != nil {
		t.Fatalf("gitver.Open() 返回错误: %v", err)
	}
	svc := New(db, repo)

	bookRoot := t.TempDir()
	writeFile(t, bookRoot, "book.epub", "binary-ish")

	stats, err := svc.Bootstrap(context.Background(), []Root{
		{Tag: "notes", Path: mirrorRoot, Mode: RootModeMirror},
		{Tag: "ebooks", Path: bookRoot, Mode: RootModeOnDemand},
	})
	if err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 2, Created: 2})

	uid, err := svc.ResolvePath("notes", "a.org")
	if err != nil {
		t.Fatalf("ResolvePath() 返回错误: %v", err)
	}
	note, err := svc.Entry(uid)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}
	if len(note.Blob) != 40 {
		t.Fatalf("mirror 根 blob = %q, 期望 40 位 git blob hash", note.Blob)
	}

	bookUID, err := svc.ResolvePath("ebooks", "book.epub")
	if err != nil {
		t.Fatalf("ResolvePath() 返回错误: %v", err)
	}
	book, err := svc.Entry(bookUID)
	if err != nil {
		t.Fatalf("Entry() 返回错误: %v", err)
	}
	if book.Blob != "" {
		t.Fatalf("ondemand 根 blob = %q, 期望空串（书库不在 git 仓库内）", book.Blob)
	}
}

// TestBootstrapMissingRoot 验证根目录不存在时返回错误而非静默成功。
func TestBootstrapMissingRoot(t *testing.T) {
	svc, _ := newTestService(t)

	missing := filepath.Join(t.TempDir(), "nope")
	if _, err := svc.Bootstrap(context.Background(), []Root{
		{Tag: "notes", Path: missing, Mode: RootModeMirror},
	}); err == nil {
		t.Fatal("根目录不存在时 Bootstrap() 应返回错误")
	}
}

// TestRescanDeletesMissing 验证 bootstrap 后手工删文件，Rescan 补齐 delete 事件与墓碑。
func TestRescanDeletesMissing(t *testing.T) {
	svc, _ := newTestService(t)
	root := buildTree(t)
	roots := []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}

	if _, err := svc.Bootstrap(context.Background(), roots); err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}
	goneUID, err := svc.ResolvePath("notes", "sub/b.org")
	if err != nil {
		t.Fatalf("ResolvePath() 返回错误: %v", err)
	}
	if err := os.Remove(filepath.Join(root, "sub", "b.org")); err != nil {
		t.Fatalf("删除文件失败: %v", err)
	}

	stats, err := svc.Rescan(context.Background(), roots)
	if err != nil {
		t.Fatalf("Rescan() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 1, Unchanged: 1, Deleted: 1})

	if _, err := svc.Entry(goneUID); err == nil {
		t.Fatal("被删除文件仍可 Entry()，期望 not found")
	} else {
		assertCode(t, err, logging.ErrNotFound)
	}

	changes, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	last := changes[len(changes)-1]
	if last.Op != storage.OpDelete || last.UID != goneUID || last.Path != "sub/b.org" {
		t.Fatalf("最后一条事件 = %+v, 期望 op=delete uid=%s path=sub/b.org", last, goneUID)
	}

	// 再跑一次 Rescan：已无缺失项，不得重复写 delete。
	again, err := svc.Rescan(context.Background(), roots)
	if err != nil {
		t.Fatalf("二次 Rescan() 返回错误: %v", err)
	}
	if again.Deleted != 0 {
		t.Fatalf("二次 Rescan Deleted = %d, 期望 0（墓碑不重复登记）", again.Deleted)
	}
}

// TestRescanDoesNotTombstoneOnApplyFailure 验证「文件仍在磁盘上、但本次 Apply 失败」时
// Rescan 不写墓碑。
//
// 故障注入用 Service.applyHook（见 service.go）：只让 a.org 的 update 失败，其余事件
// 走真实 Apply。修复缺失时 a.org 不会进入 seen，Rescan 的删除比对阶段会为它写墓碑 +
// delete 事件；修复后只要文件确认存在于磁盘就计入 seen，失败只计入 Stats.Failed。
func TestRescanDoesNotTombstoneOnApplyFailure(t *testing.T) {
	svc, db := newTestService(t)
	root := buildTree(t)
	roots := []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}

	if _, err := svc.Bootstrap(context.Background(), roots); err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}
	uidA, err := svc.ResolvePath("notes", "a.org")
	if err != nil {
		t.Fatalf("ResolvePath(a.org) 返回错误: %v", err)
	}

	// 改写 a.org（长度不同）并推进 mtime，使扫描走 update → Apply。
	full := writeFile(t, root, "a.org", "changed-content-longer")
	later := time.Now().Add(10 * time.Second)
	if err := os.Chtimes(full, later, later); err != nil {
		t.Fatalf("设置 mtime 失败: %v", err)
	}

	svc.applyHook = func(e Event) (int64, error) {
		if e.Path == "a.org" {
			return 0, logging.NewAppError(logging.ErrInternal, "注入的登记失败")
		}
		return svc.Apply(e)
	}

	stats, err := svc.Rescan(context.Background(), roots)
	if err != nil {
		t.Fatalf("Rescan() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 2, Failed: 1, Unchanged: 1})

	// 关键断言：a.org 不得被写墓碑，也不得产生 delete 事件。
	saved, err := db.GetResourceByUID(uidA)
	if err != nil {
		t.Fatalf("GetResourceByUID() 返回错误: %v", err)
	}
	if saved.DeletedAt != "" {
		t.Fatalf("a.org 被误写墓碑（deleted_at=%q），期望仍存活", saved.DeletedAt)
	}

	changes, _, _, err := db.ListChanges(0, 100)
	if err != nil {
		t.Fatalf("ListChanges() 返回错误: %v", err)
	}
	if len(changes) != 2 {
		t.Fatalf("变更事件条数 = %d, 期望 2（仅 bootstrap 的 create）: %+v", len(changes), changes)
	}
	for _, c := range changes {
		if c.Op == storage.OpDelete {
			t.Fatalf("出现 delete 事件 %+v，期望无删除（文件仍在磁盘上）", c)
		}
	}
}

// TestRescanDeletesOnlyTheMissingFile 是删除语义的回归测试：同一轮 Rescan 中，磁盘上
// 已删除的文件照常写墓碑并产生 delete 事件，而未变更的存活文件不受影响。
func TestRescanDeletesOnlyTheMissingFile(t *testing.T) {
	svc, _ := newTestService(t)
	root := buildTree(t)
	roots := []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}

	if _, err := svc.Bootstrap(context.Background(), roots); err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}
	uidA, err := svc.ResolvePath("notes", "a.org")
	if err != nil {
		t.Fatalf("ResolvePath(a.org) 返回错误: %v", err)
	}
	uidB, err := svc.ResolvePath("notes", "sub/b.org")
	if err != nil {
		t.Fatalf("ResolvePath(sub/b.org) 返回错误: %v", err)
	}
	if err := os.Remove(filepath.Join(root, "sub", "b.org")); err != nil {
		t.Fatalf("删除文件失败: %v", err)
	}

	stats, err := svc.Rescan(context.Background(), roots)
	if err != nil {
		t.Fatalf("Rescan() 返回错误: %v", err)
	}
	assertStats(t, stats, Stats{Scanned: 1, Unchanged: 1, Deleted: 1})

	// 存活文件不受牵连：无墓碑、无 delete 事件。
	alive, err := svc.Entry(uidA)
	if err != nil {
		t.Fatalf("Entry(a.org) 返回错误: %v", err)
	}
	if alive.DeletedAt != "" {
		t.Fatalf("a.org 被误写墓碑（deleted_at=%q）", alive.DeletedAt)
	}

	items, err := svc.List(storage.ResourceFilter{Root: "notes", IncludeDeleted: true})
	if err != nil {
		t.Fatalf("List() 返回错误: %v", err)
	}
	deleted := make(map[string]string, len(items))
	for _, it := range items {
		deleted[it.UID] = it.DeletedAt
	}
	if deleted[uidB] == "" {
		t.Fatalf("被删除的 sub/b.org 未写墓碑（条数 %d）", len(items))
	}
	if deleted[uidA] != "" {
		t.Fatalf("a.org 墓碑 = %q, 期望仍存活", deleted[uidA])
	}

	changes, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	deletes := 0
	for _, c := range changes {
		if c.Op != storage.OpDelete {
			continue
		}
		deletes++
		if c.UID != uidB || c.Path != "sub/b.org" {
			t.Fatalf("delete 事件 = %+v, 期望只针对 uid=%s path=sub/b.org", c, uidB)
		}
	}
	if deletes != 1 {
		t.Fatalf("delete 事件条数 = %d, 期望 1", deletes)
	}
}

// TestRescanRejectsRootWithoutPath 验证 SetRoots（Bootstrap/Rescan 的前置步骤）拒绝空物理
// 路径：空 Path 会让 filepath.Join("", rel) 退化为进程 CWD，使登记根静默变成部署目录。
func TestRescanRejectsRootWithoutPath(t *testing.T) {
	svc, _ := newTestService(t)

	_, err := svc.Rescan(context.Background(), []Root{{Tag: "notes", Path: "   "}})
	if err == nil {
		t.Fatal("空 Path 的根应被拒绝，实际返回 nil")
	}
	assertCode(t, err, logging.ErrInvalidArgument)
}

// TestApplyRejectsDotPaths 验证 Apply 拒绝点路径与 .git 段，与 bootstrap 的遍历口径
// 保持一致（bootstrap 不登记点目录）：否则会出现「登记表里有、扫描看不到」的条目。
func TestApplyRejectsDotPaths(t *testing.T) {
	svc, _ := newTestService(t)
	if err := svc.SetRoots([]Root{{Tag: "notes", Path: t.TempDir()}}); err != nil {
		t.Fatalf("SetRoots() 返回错误: %v", err)
	}

	for _, p := range []string{".hidden.org", "sub/.cache/x.org", ".git/config", "sub/.GIT/HEAD"} {
		_, err := svc.Apply(Event{UID: uidA, Op: storage.OpCreate, Root: "notes", Path: p})
		if err == nil {
			t.Fatalf("路径 %q 应被拒绝，实际登记成功", p)
		}
		assertCode(t, err, logging.ErrInvalidArgument)
	}

	// 正常路径仍然可用（拒绝只针对点段）。
	if _, err := svc.Apply(Event{
		UID: uidA, Op: storage.OpCreate, Root: "notes", Path: "sub/normal.org",
	}); err != nil {
		t.Fatalf("正常路径被误拒: %v", err)
	}
}

// TestRescanHonorsContext 验证 ctx 取消后提前返回错误。
func TestRescanHonorsContext(t *testing.T) {
	svc, _ := newTestService(t)
	root := buildTree(t)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := svc.Bootstrap(ctx, []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}); err == nil {
		t.Fatal("已取消的 ctx 应让 Bootstrap() 返回错误")
	}
}

// TestBootstrapSkipsDotFiles 验证根下的点文件（.gitignore 等）不被登记：
// 修复前它们会进入登记流程、被 normalizeResourcePath 拒绝，于是每轮扫描都产生一次
// Failed（「稳定噪音」）；修复后它们与点目录一样整项跳过，Failed 恒为 0。
func TestBootstrapSkipsDotFiles(t *testing.T) {
	svc, _ := newTestService(t)
	root := t.TempDir()
	writeFile(t, root, "a.org", "aaa")
	writeFile(t, root, "sub/b.org", "bbb")
	writeFile(t, root, ".gitignore", "*.tmp\n")
	writeFile(t, root, ".hidden-notes.org", "隐藏文件不登记")
	writeFile(t, root, ".git/config", "[core]")
	writeFile(t, root, "sub/.DS_Store", "cache")

	stats, err := svc.Bootstrap(context.Background(), []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}})
	if err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}
	// 关键断言：Failed == 0（点文件不再制造噪音），且只登记两个正常文件。
	assertStats(t, stats, Stats{Scanned: 2, Created: 2})

	items, err := svc.List(storage.ResourceFilter{Root: "notes"})
	if err != nil {
		t.Fatalf("List() 返回错误: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("登记条数 = %d, 期望 2（%+v）", len(items), items)
	}
	for _, it := range items {
		if it.Path != "a.org" && it.Path != "sub/b.org" {
			t.Fatalf("登记了非正常路径 %q，期望仅 a.org / sub/b.org", it.Path)
		}
	}

	// 点文件确实存在于磁盘上（不是被误删），只是不进入登记流程。
	for _, p := range []string{".gitignore", ".hidden-notes.org", "sub/.DS_Store"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(p))); err != nil {
			t.Fatalf("点文件 %q 应仍在磁盘上: %v", p, err)
		}
	}
}

// TestRescanTombstonesLegacyDotFileRow 验证历史遗留的点文件登记行被 Rescan 清理：
// 该文件仍在磁盘上，但点路径已不再被扫描接受，故登记行被写成墓碑并产生 delete 事件
// （行为变更，见 bootstrap.go 的 deleteMissing / tombstoneLegacy）。
func TestRescanTombstonesLegacyDotFileRow(t *testing.T) {
	svc, db := newTestService(t)
	root := t.TempDir()
	writeFile(t, root, "a.org", "aaa")
	writeFile(t, root, ".gitignore", "*.tmp\n")
	roots := []Root{{Tag: "notes", Path: root, Mode: RootModeMirror}}

	if _, err := svc.Bootstrap(context.Background(), roots); err != nil {
		t.Fatalf("Bootstrap() 返回错误: %v", err)
	}

	// 手工插入一条「修复前留下的」点文件登记行（模拟旧扫描/写钩子的产物）。
	legacyUID, err := NewUID()
	if err != nil {
		t.Fatalf("NewUID() 返回错误: %v", err)
	}
	if err := db.CreateResource(storage.Entry{
		UID:   legacyUID,
		Root:  "notes",
		Path:  ".gitignore",
		Size:  6,
		Mtime: 1,
	}); err != nil {
		t.Fatalf("CreateResource() 返回错误: %v", err)
	}
	if _, err := db.GetResourceByPath("notes", ".gitignore"); err != nil {
		t.Fatalf("预置的遗留行不可查: %v", err)
	}

	stats, err := svc.Rescan(context.Background(), roots)
	if err != nil {
		t.Fatalf("Rescan() 返回错误: %v", err)
	}
	// a.org 未变（Unchanged），遗留点文件行被清理（Deleted=1），且无失败。
	assertStats(t, stats, Stats{Scanned: 1, Unchanged: 1, Deleted: 1})

	// 文件仍在磁盘上，墓碑只是「不再登记」。
	if _, err := os.Stat(filepath.Join(root, ".gitignore")); err != nil {
		t.Fatalf(".gitignore 应仍在磁盘上: %v", err)
	}

	saved, err := db.GetResourceByUID(legacyUID)
	if err != nil {
		t.Fatalf("GetResourceByUID() 返回错误: %v", err)
	}
	if saved.DeletedAt == "" {
		t.Fatalf("遗留行未被写墓碑（deleted_at 为空），期望非空")
	}
	if saved.Path != ".gitignore" {
		t.Errorf("墓碑 path = %q, 期望保留删除前路径 .gitignore", saved.Path)
	}

	changes, _, _, err := svc.Changes(0, 100)
	if err != nil {
		t.Fatalf("Changes() 返回错误: %v", err)
	}
	last := changes[len(changes)-1]
	if last.Op != storage.OpDelete || last.UID != legacyUID || last.Path != ".gitignore" {
		t.Fatalf("最后一条事件 = %+v, 期望 op=delete uid=%s path=.gitignore", last, legacyUID)
	}

	// 再跑一次：墓碑已不在「存活集」，不得重复写 delete。
	again, err := svc.Rescan(context.Background(), roots)
	if err != nil {
		t.Fatalf("二次 Rescan() 返回错误: %v", err)
	}
	if again.Deleted != 0 || again.Failed != 0 {
		t.Fatalf("二次 Rescan Deleted/Failed = %d/%d, 期望 0/0", again.Deleted, again.Failed)
	}
}
