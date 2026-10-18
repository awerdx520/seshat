// 本文件测试资源登记表（schema v6）的表级 CRUD。
//
// 断言口径：resources 是服务端权威的文件身份登记——uid 跨改名稳定；删除写墓碑
// （deleted_at 非空）而非物理删除，按 uid 仍可读到墓碑记录；列举默认隐藏墓碑，
// 需显式 IncludeDeleted 才返回。
package storage

import (
	"testing"
	"time"

	"seshat/internal/logging"
)

// baseEntry 返回一条字段齐全的资源登记（root 固定为 notes）。
func baseEntry(uid, path string) Entry {
	return Entry{
		UID:   uid,
		Root:  "notes",
		Path:  path,
		Blob:  "blob-" + uid,
		Rev:   "rev-1",
		Size:  10,
		Mtime: 1000,
	}
}

// mustCreateResource 创建一条资源登记，失败即终止测试。
func mustCreateResource(t *testing.T, db *DB, e Entry) {
	t.Helper()
	if err := db.CreateResource(e); err != nil {
		t.Fatalf("CreateResource(%s) 返回错误: %v", e.Path, err)
	}
}

// TestSchemaV6TablesExist 验证迁移后 user_version 为当前 schemaVersion，且身份三表
// 与索引均已建立（三表由 A1 的 v6 引入，故断言名沿用 V6）。
func TestSchemaV6TablesExist(t *testing.T) {
	db := openTestDB(t)

	var v int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("读取 user_version 失败: %v", err)
	}
	// 断言跟随 schemaVersion：A1 交付时为 6，B4 追加 v7（状态表按 uid 重建）后为 7。
	// v7 的精确断言（= 7 与状态表结构）在 state_v7_test.go 中，此处只守「迁移已推进到
	// 程序期望的版本」，避免每追加一条迁移都要改本行。
	if v != schemaVersion {
		t.Fatalf("user_version = %d, 期望 %d", v, schemaVersion)
	}

	for _, name := range []string{"resources", "changes", "refs"} {
		var got string
		err := db.db.QueryRow(
			`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, name).Scan(&got)
		if err != nil {
			t.Fatalf("表 %s 不存在: %v", name, err)
		}
	}
	for _, name := range []string{"idx_resources_blob", "idx_changes_uid", "idx_refs_target"} {
		var got string
		err := db.db.QueryRow(
			`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`, name).Scan(&got)
		if err != nil {
			t.Fatalf("索引 %s 不存在: %v", name, err)
		}
	}
}

// TestCreateResourceRoundTrip 验证按 uid 与按 (root, path) 都能读回同一记录，
// 时间戳被规范化为 UTC，Kind 默认为 file。
func TestCreateResourceRoundTrip(t *testing.T) {
	db := openTestDB(t)

	const uid = "01K8Q3M7D2X9V6T1B8N5C0RDEF"
	e := Entry{
		UID: uid, Root: "notes", Path: "a/b.org", Blob: "b1", Rev: "r1", Size: 42,
		Mtime:     1700000000,
		CreatedAt: "2026-10-18T10:00:00+08:00",
		UpdatedAt: "2026-10-18T10:00:00+08:00",
	}
	mustCreateResource(t, db, e)

	got, err := db.GetResourceByUID(uid)
	if err != nil {
		t.Fatalf("GetResourceByUID() 返回错误: %v", err)
	}
	if got.UID != uid || got.Root != "notes" || got.Path != "a/b.org" {
		t.Fatalf("读回身份字段不符: %+v", got)
	}
	if got.Blob != "b1" || got.Rev != "r1" || got.Size != 42 || got.Mtime != 1700000000 {
		t.Fatalf("读回内容字段不符: %+v", got)
	}
	if got.Kind != ResourceKindFile {
		t.Fatalf("Kind = %q, 期望 %q（默认 file）", got.Kind, ResourceKindFile)
	}
	if got.CreatedAt != "2026-10-18T02:00:00Z" || got.UpdatedAt != "2026-10-18T02:00:00Z" {
		t.Fatalf("时间戳未规范化为 UTC: created=%q updated=%q", got.CreatedAt, got.UpdatedAt)
	}
	if got.DeletedAt != "" {
		t.Fatalf("新登记记录 DeletedAt 应为空串，实际 %q", got.DeletedAt)
	}

	byPath, err := db.GetResourceByPath("notes", "a/b.org")
	if err != nil {
		t.Fatalf("GetResourceByPath() 返回错误: %v", err)
	}
	if byPath.UID != uid {
		t.Fatalf("按路径读回 uid = %q, 期望 %q", byPath.UID, uid)
	}
}

// TestCreateResourceTimestampBackfill 验证空时间戳回填为当前 UTC 时间。
func TestCreateResourceTimestampBackfill(t *testing.T) {
	db := openTestDB(t)

	e := baseEntry("uid-ts", "ts.org")
	mustCreateResource(t, db, e)

	got, err := db.GetResourceByUID("uid-ts")
	if err != nil {
		t.Fatalf("GetResourceByUID() 返回错误: %v", err)
	}
	for _, ts := range []string{got.CreatedAt, got.UpdatedAt} {
		parsed, err := time.Parse(time.RFC3339, ts)
		if err != nil {
			t.Fatalf("回填时间戳不是 RFC3339: %q", ts)
		}
		if delta := time.Since(parsed); delta < 0 || delta > time.Minute {
			t.Fatalf("回填时间戳偏差过大: %v", delta)
		}
	}
}

// TestGetResourceNotFound 验证按 uid 与按路径读不存在的记录均返回 not_found。
func TestGetResourceNotFound(t *testing.T) {
	db := openTestDB(t)

	if _, err := db.GetResourceByUID("missing-uid"); err != nil {
		assertCode(t, err, logging.ErrNotFound)
	} else {
		t.Fatal("GetResourceByUID(不存在的 uid) 应返回错误")
	}

	if _, err := db.GetResourceByPath("notes", "missing.org"); err != nil {
		assertCode(t, err, logging.ErrNotFound)
	} else {
		t.Fatal("GetResourceByPath(不存在的路径) 应返回错误")
	}
}

// TestResourceValidation 验证参数校验（空 uid / root / path 与非法时间戳）。
func TestResourceValidation(t *testing.T) {
	db := openTestDB(t)

	cases := []struct {
		name string
		fn   func() error
	}{
		{"CreateResource 空 uid", func() error {
			return db.CreateResource(Entry{Root: "notes", Path: "x.org"})
		}},
		{"CreateResource 空 root", func() error {
			return db.CreateResource(Entry{UID: "u1", Path: "x.org"})
		}},
		{"CreateResource 空 path", func() error {
			return db.CreateResource(Entry{UID: "u1", Root: "notes"})
		}},
		{"CreateResource 非法 created_at", func() error {
			return db.CreateResource(Entry{UID: "u1", Root: "notes", Path: "x.org", CreatedAt: "not-a-time"})
		}},
		{"UpsertResource 空 uid", func() error {
			return db.UpsertResource(Entry{Root: "notes", Path: "x.org"})
		}},
		{"TombstoneResource 空 uid", func() error {
			return db.TombstoneResource("  ", "")
		}},
		{"TombstoneResource 非法时间戳", func() error {
			mustCreateResource(t, db, baseEntry("u-tomb", "tomb.org"))
			return db.TombstoneResource("u-tomb", "not-a-time")
		}},
		{"RenameResource 空 path", func() error {
			return db.RenameResource("u1", "notes", "", "")
		}},
		{"GetResourceByUID 空 uid", func() error {
			_, err := db.GetResourceByUID("  ")
			return err
		}},
		{"GetResourceByPath 空 path", func() error {
			_, err := db.GetResourceByPath("notes", "")
			return err
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertCode(t, c.fn(), logging.ErrInvalidArgument)
		})
	}
}

// TestCreateResourceDuplicatePath 验证 UNIQUE(root, path) 生效：同路径不同 uid 被拒。
func TestCreateResourceDuplicatePath(t *testing.T) {
	db := openTestDB(t)
	mustCreateResource(t, db, baseEntry("uid-1", "dup.org"))

	err := db.CreateResource(baseEntry("uid-2", "dup.org"))
	assertCode(t, err, logging.ErrConflict)

	// 冲突不应留下第二条记录。
	n, err := db.CountResources()
	if err != nil {
		t.Fatalf("CountResources() 返回错误: %v", err)
	}
	if n != 1 {
		t.Fatalf("登记数 = %d, 期望 1", n)
	}

	// 不同 root 下同路径合法。
	other := baseEntry("uid-3", "dup.org")
	other.Root = "ebooks"
	mustCreateResource(t, db, other)
}

// TestUpsertResourceInsertThenUpdate 验证 UpsertResource 的插入与更新两条路径：
// 同 uid 再写为更新（内容字段刷新、created_at 保留、不新增行）。
func TestUpsertResourceInsertThenUpdate(t *testing.T) {
	db := openTestDB(t)

	e := baseEntry("uid-up", "up.org")
	e.CreatedAt = "2026-10-18T00:00:00Z"
	e.UpdatedAt = "2026-10-18T00:00:00Z"
	if err := db.UpsertResource(e); err != nil {
		t.Fatalf("UpsertResource() 插入失败: %v", err)
	}

	upd := baseEntry("uid-up", "up.org")
	upd.Blob = "blob-new"
	upd.Rev = "rev-2"
	upd.Size = 99
	upd.Mtime = 2000
	upd.CreatedAt = "2026-10-19T00:00:00Z"
	upd.UpdatedAt = "2026-10-19T00:00:00Z"
	if err := db.UpsertResource(upd); err != nil {
		t.Fatalf("UpsertResource() 更新失败: %v", err)
	}

	got, err := db.GetResourceByUID("uid-up")
	if err != nil {
		t.Fatalf("GetResourceByUID() 返回错误: %v", err)
	}
	if got.Blob != "blob-new" || got.Rev != "rev-2" || got.Size != 99 || got.Mtime != 2000 {
		t.Fatalf("更新未生效: %+v", got)
	}
	if got.CreatedAt != "2026-10-18T00:00:00Z" {
		t.Fatalf("created_at = %q, 期望保留首次登记时间", got.CreatedAt)
	}
	if got.UpdatedAt != "2026-10-19T00:00:00Z" {
		t.Fatalf("updated_at = %q, 期望 %q", got.UpdatedAt, "2026-10-19T00:00:00Z")
	}

	n, err := db.CountResources()
	if err != nil {
		t.Fatalf("CountResources() 返回错误: %v", err)
	}
	if n != 1 {
		t.Fatalf("更新后登记数 = %d, 期望 1（不新增行）", n)
	}
}

// TestTombstoneResource 验证墓碑语义：按 uid 仍可读到记录（含 DeletedAt），
// 默认列举隐藏墓碑、IncludeDeleted 时可返回。
func TestTombstoneResource(t *testing.T) {
	db := openTestDB(t)
	mustCreateResource(t, db, baseEntry("uid-alive", "alive.org"))
	mustCreateResource(t, db, baseEntry("uid-dead", "dead.org"))

	if err := db.TombstoneResource("uid-dead", "2026-10-18T03:00:00Z"); err != nil {
		t.Fatalf("TombstoneResource() 返回错误: %v", err)
	}

	got, err := db.GetResourceByUID("uid-dead")
	if err != nil {
		t.Fatalf("墓碑后按 uid 读取应成功，实际错误: %v", err)
	}
	if got.DeletedAt != "2026-10-18T03:00:00Z" {
		t.Fatalf("DeletedAt = %q, 期望 %q", got.DeletedAt, "2026-10-18T03:00:00Z")
	}
	if got.Path != "dead.org" {
		t.Fatalf("墓碑应保留删除前路径，实际 %q", got.Path)
	}

	alive, err := db.ListResources(ResourceFilter{})
	if err != nil {
		t.Fatalf("ListResources(默认) 返回错误: %v", err)
	}
	if len(alive) != 1 || alive[0].UID != "uid-alive" {
		t.Fatalf("默认列举应只含存活资源，实际 %+v", alive)
	}

	all, err := db.ListResources(ResourceFilter{IncludeDeleted: true})
	if err != nil {
		t.Fatalf("ListResources(IncludeDeleted) 返回错误: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("含墓碑列举数量 = %d, 期望 2", len(all))
	}

	// 统计只计存活资源。
	n, err := db.CountResources()
	if err != nil {
		t.Fatalf("CountResources() 返回错误: %v", err)
	}
	if n != 1 {
		t.Fatalf("CountResources() = %d, 期望 1（墓碑不计入）", n)
	}
}

// TestTombstoneResourceNotFound 验证墓碑不存在的 uid 返回 not_found。
func TestTombstoneResourceNotFound(t *testing.T) {
	db := openTestDB(t)
	assertCode(t, db.TombstoneResource("missing", ""), logging.ErrNotFound)
}

// TestRenameResource 验证改名后 uid 不变、路径变更，旧路径解析不到。
func TestRenameResource(t *testing.T) {
	db := openTestDB(t)
	mustCreateResource(t, db, baseEntry("uid-mv", "old.org"))

	if err := db.RenameResource("uid-mv", "notes", "dir/new.org", "2026-10-18T04:00:00Z"); err != nil {
		t.Fatalf("RenameResource() 返回错误: %v", err)
	}

	got, err := db.GetResourceByUID("uid-mv")
	if err != nil {
		t.Fatalf("GetResourceByUID() 返回错误: %v", err)
	}
	if got.UID != "uid-mv" {
		t.Fatalf("改名后 uid 变化: %q", got.UID)
	}
	if got.Path != "dir/new.org" {
		t.Fatalf("改名后 path = %q, 期望 %q", got.Path, "dir/new.org")
	}
	if got.UpdatedAt != "2026-10-18T04:00:00Z" {
		t.Fatalf("改名后 updated_at = %q, 期望 %q", got.UpdatedAt, "2026-10-18T04:00:00Z")
	}

	if _, err := db.GetResourceByPath("notes", "old.org"); err == nil {
		t.Fatal("旧路径应解析不到资源")
	} else {
		assertCode(t, err, logging.ErrNotFound)
	}
	if _, err := db.GetResourceByPath("notes", "dir/new.org"); err != nil {
		t.Fatalf("新路径应能解析到资源，实际错误: %v", err)
	}
}

// TestRenameResourceErrors 验证改名不存在的 uid 返回 not_found、改名到已占用路径返回 conflict。
func TestRenameResourceErrors(t *testing.T) {
	db := openTestDB(t)
	mustCreateResource(t, db, baseEntry("uid-a", "a.org"))
	mustCreateResource(t, db, baseEntry("uid-b", "b.org"))

	assertCode(t, db.RenameResource("missing", "notes", "x.org", ""), logging.ErrNotFound)
	assertCode(t, db.RenameResource("uid-a", "notes", "b.org", ""), logging.ErrConflict)
}

// TestListResourcesFilters 表驱动覆盖 root / include_deleted / since / limit 过滤。
func TestListResourcesFilters(t *testing.T) {
	db := openTestDB(t)

	a := baseEntry("uid-a", "a.org")
	a.Mtime = 100
	mustCreateResource(t, db, a)

	b := baseEntry("uid-b", "b.org")
	b.Mtime = 200
	mustCreateResource(t, db, b)

	c := baseEntry("uid-c", "c.org")
	c.Root = "ebooks"
	c.Mtime = 300
	mustCreateResource(t, db, c)

	dead := baseEntry("uid-d", "d.org")
	dead.Mtime = 400
	mustCreateResource(t, db, dead)
	if err := db.TombstoneResource("uid-d", "2026-10-18T05:00:00Z"); err != nil {
		t.Fatalf("TombstoneResource() 返回错误: %v", err)
	}

	// 期望顺序与实现一致：按 (root, path) 升序，故 ebooks 根（uid-c）排在 notes 根之前。
	cases := []struct {
		name string
		f    ResourceFilter
		want []string
	}{
		{"无过滤只返回存活（跨 root）", ResourceFilter{}, []string{"uid-c", "uid-a", "uid-b"}},
		{"按 root 过滤", ResourceFilter{Root: "ebooks"}, []string{"uid-c"}},
		{"IncludeDeleted 含墓碑", ResourceFilter{Root: "notes", IncludeDeleted: true}, []string{"uid-a", "uid-b", "uid-d"}},
		{"Since 按 mtime 过滤", ResourceFilter{Since: 250}, []string{"uid-c"}},
		{"Limit 截断", ResourceFilter{Limit: 2}, []string{"uid-c", "uid-a"}},
		{"复合条件", ResourceFilter{Root: "notes", Since: 150, Limit: 5}, []string{"uid-b"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := db.ListResources(c.f)
			if err != nil {
				t.Fatalf("ListResources() 返回错误: %v", err)
			}
			if len(got) != len(c.want) {
				t.Fatalf("数量 = %d, 期望 %d（实际 %+v）", len(got), len(c.want), got)
			}
			for i, want := range c.want {
				if got[i].UID != want {
					t.Fatalf("第 %d 条 uid = %q, 期望 %q", i, got[i].UID, want)
				}
			}
		})
	}
}

// TestListResourcesPrefixBoundary 验证 Prefix 过滤边界：`a` 匹配 `a` 与 `a/b`，
// 但不匹配 `ab`（前缀必须是路径段边界）。
func TestListResourcesPrefixBoundary(t *testing.T) {
	db := openTestDB(t)
	mustCreateResource(t, db, baseEntry("uid-a", "a"))
	mustCreateResource(t, db, baseEntry("uid-a-b", "a/b.org"))
	mustCreateResource(t, db, baseEntry("uid-ab", "ab.org"))

	got, err := db.ListResources(ResourceFilter{Prefix: "a"})
	if err != nil {
		t.Fatalf("ListResources() 返回错误: %v", err)
	}
	want := map[string]bool{"uid-a": true, "uid-a-b": true}
	if len(got) != len(want) {
		t.Fatalf("数量 = %d, 期望 %d（实际 %+v）", len(got), len(want), got)
	}
	for _, e := range got {
		if !want[e.UID] {
			t.Fatalf("Prefix=a 误匹配 %q（path=%q）", e.UID, e.Path)
		}
	}

	// 带尾斜杠的 prefix 归一化为去掉尾斜杠后匹配（等价于 Prefix="a"，即目录 a 自身的
	// 条目 + a 下的条目），避免 "a//%" 这种永不命中的模式。
	slash, err := db.ListResources(ResourceFilter{Prefix: "a/"})
	if err != nil {
		t.Fatalf("ListResources(Prefix=a/) 返回错误: %v", err)
	}
	if len(slash) != 2 {
		t.Fatalf("Prefix=a/ 结果数 = %d, 期望 2（等价于 Prefix=a）: %+v", len(slash), slash)
	}
	for _, e := range slash {
		if !want[e.UID] {
			t.Fatalf("Prefix=a/ 误匹配 %q（path=%q）", e.UID, e.Path)
		}
	}
}

// listPaths 按过滤条件列举并返回 path 集合（断言只看路径）。
func listPaths(t *testing.T, db *DB, f ResourceFilter) map[string]bool {
	t.Helper()
	items, err := db.ListResources(f)
	if err != nil {
		t.Fatalf("ListResources(%+v) 返回错误: %v", f, err)
	}
	out := make(map[string]bool, len(items))
	for _, e := range items {
		out[e.Path] = true
	}
	return out
}

// TestListResourcesPrefixExactAndCaseSensitive 验证 Prefix 是「精确字节前缀 + 路径段
// 边界」比较：大小写敏感，且 '%'、'_' 不带 LIKE 通配含义。
//
// 回归背景：早先用 path LIKE prefix || '/%'，LIKE 对 ASCII 大小写不敏感且未转义通配符
// ——prefix="a_b" 会命中 "aXb"、prefix="notes/A" 会命中 "notes/a"，目录删除（webdav
// applyDelete 按前缀召回整棵子树）因此可能误伤无关资源。
func TestListResourcesPrefixExactAndCaseSensitive(t *testing.T) {
	db := openTestDB(t)
	for uid, p := range map[string]string{
		"uid-a-underscore":     "a_b",
		"uid-a-underscore-sub": "a_b/c.org",
		"uid-a-x-b":            "aXb",
		"uid-a-x-b-sub":        "aXb/c.org",
		"uid-upper":            "notes/A",
		"uid-lower":            "notes/a",
		"uid-lower-sub":        "notes/a/sub.org",
		"uid-a":                "a",
		"uid-a-sub":            "a/b.org",
		"uid-pct":              "pct100%",
		"uid-pct-x":            "pct100x",
		"uid-pct-x-sub":        "pct100x/sub.org",
	} {
		mustCreateResource(t, db, baseEntry(uid, p))
	}

	cases := []struct {
		name    string
		prefix  string
		want    []string
		notWant []string
	}{
		{
			name:    "_ 不是通配符：a_b 不得命中 aXb 子树",
			prefix:  "a_b",
			want:    []string{"a_b", "a_b/c.org"},
			notWant: []string{"aXb", "aXb/c.org"},
		},
		{
			name:    "大小写敏感：notes/A 不得命中 notes/a 子树",
			prefix:  "notes/A",
			want:    []string{"notes/A"},
			notWant: []string{"notes/a", "notes/a/sub.org"},
		},
		{
			name:    "% 不是通配符：pct100% 不得命中 pct100x 子树",
			prefix:  "pct100%",
			want:    []string{"pct100%"},
			notWant: []string{"pct100x", "pct100x/sub.org"},
		},
		{
			name:    "原有边界不变：a 命中 a 与 a/b.org，不命中 ab 类",
			prefix:  "a",
			want:    []string{"a", "a/b.org"},
			notWant: []string{"a_b", "a_b/c.org", "aXb", "aXb/c.org"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := listPaths(t, db, ResourceFilter{Prefix: c.prefix})
			for _, p := range c.want {
				if !got[p] {
					t.Fatalf("Prefix=%q 未命中 %q（实际 %v）", c.prefix, p, got)
				}
			}
			for _, p := range c.notWant {
				if got[p] {
					t.Fatalf("Prefix=%q 误命中 %q", c.prefix, p)
				}
			}
		})
	}
}

// TestListResourcesNeverNil 验证空库列举返回非 nil 空切片（避免 JSON null）。
func TestListResourcesNeverNil(t *testing.T) {
	db := openTestDB(t)

	got, err := db.ListResources(ResourceFilter{})
	if err != nil {
		t.Fatalf("ListResources() 返回错误: %v", err)
	}
	if got == nil {
		t.Fatal("ListResources() 返回 nil，期望空切片")
	}
	if len(got) != 0 {
		t.Fatalf("空库数量 = %d, 期望 0", len(got))
	}

	// Limit 非正数应回落到默认上限而非报错或返回全部无限。
	if _, err := db.ListResources(ResourceFilter{Limit: -1}); err != nil {
		t.Fatalf("ListResources(Limit=-1) 返回错误: %v", err)
	}
}

// TestCountResourcesEmpty 验证空库计数为 0。
func TestCountResourcesEmpty(t *testing.T) {
	db := openTestDB(t)
	n, err := db.CountResources()
	if err != nil {
		t.Fatalf("CountResources() 返回错误: %v", err)
	}
	if n != 0 {
		t.Fatalf("空库 CountResources() = %d, 期望 0", n)
	}
}
