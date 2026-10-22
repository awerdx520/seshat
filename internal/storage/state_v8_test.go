// 本文件覆盖 M10.3 T1 的 v8 迁移与批注契约扩展：annotations 增 kind 与
// selected_text 两列（纯 ADD COLUMN）、Create/List/Update 的列补齐、
// 按 kind 分支放宽 text 校验、以及 (uid, kind, location, text) 幂等去重。
//
// 安全约束：涉及 v7 → v8 升级的用例都在 t.TempDir() 的一次性库上运行，绝不触碰
// 真实数据库（沿用 state_v7_test.go 的约定）。
package storage

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"sync"
	"testing"

	"seshat/internal/logging"
)

// v7MigrationCount 是 v8 之前的迁移脚本条数，同时是 v7 库的 user_version。
const v7MigrationCount = 7

// 批注 kind 的契约取值（服务端不做枚举校验，此处仅作测试数据）。
const (
	kindNote      = "note"
	kindHighlight = "highlight"
	kindInk       = "ink"
)

// buildV7DB 在 path 上构造一个 user_version = 7 的库：逐条执行 v1–v7 脚本后写入
// 版本号，从而复现「状态表已按 uid 重建、尚未升 v8」的存量库——此时 annotations
// 表还没有 kind / selected_text 两列。返回的 *sql.DB 由调用方写入旧数据后自行关闭。
func buildV7DB(t *testing.T, path string) *sql.DB {
	t.Helper()

	raw, err := sql.Open(driverName(), buildDSN(path, ""))
	if err != nil {
		t.Fatalf("打开 v7 测试库失败: %v", err)
	}
	// 用例提前失败时兜底释放；Close 可重复调用。
	t.Cleanup(func() { _ = raw.Close() })

	for i := 0; i < v7MigrationCount; i++ {
		if _, err := raw.Exec(migrations[i]); err != nil {
			t.Fatalf("执行 v%d 迁移脚本失败: %v", i+1, err)
		}
	}
	// PRAGMA 不支持占位符；v7MigrationCount 为包内常量，拼接安全。
	if _, err := raw.Exec(fmt.Sprintf("PRAGMA user_version = %d", v7MigrationCount)); err != nil {
		t.Fatalf("写入 user_version=%d 失败: %v", v7MigrationCount, err)
	}
	return raw
}

// annotationRowCount 返回 annotations 表的行数，用于断言幂等去重不新增行。
func annotationRowCount(t *testing.T, db *DB) int {
	t.Helper()

	var n int
	if err := db.db.QueryRow(`SELECT COUNT(*) FROM annotations`).Scan(&n); err != nil {
		t.Fatalf("统计批注行数失败: %v", err)
	}
	return n
}

// TestSchemaV8AddsAnnotationColumnsWithDefaults 验证 v7 → v8 升级：user_version 到
// 8（与 schemaVersion 自洽），存量批注的 kind 回填 note、selected_text 回填空串。
func TestSchemaV8AddsAnnotationColumnsWithDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "seshat.db")

	raw := buildV7DB(t, path)
	const createdAt = "2026-10-22T10:00:00Z"
	if _, err := raw.Exec(
		`INSERT INTO annotations(uid, location, text, created_at, updated_at)
		 VALUES(?, ?, ?, ?, ?)`,
		testUID1, "chapter-1:10", "存量批注", createdAt, createdAt); err != nil {
		t.Fatalf("写入 v7 存量批注失败: %v", err)
	}
	// 前提校验：v7 结构确实没有 kind 列，否则本用例没有覆盖到「升级」路径。
	if _, err := raw.Exec(`SELECT kind FROM annotations`); err == nil {
		t.Fatalf("v7 库不应存在 annotations.kind 列")
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("关闭 v7 测试库失败: %v", err)
	}

	db, err := Open(path, "")
	if err != nil {
		t.Fatalf("v7 库升级到 v8 失败: %v", err)
	}
	defer func() { _ = db.Close() }()

	var v int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		t.Fatalf("读取 user_version 失败: %v", err)
	}
	if want := 8; v != want || schemaVersion != want {
		t.Fatalf("user_version = %d, 期望 8（schemaVersion = %d）", v, schemaVersion)
	}

	// 存量行按列默认值回填，其它字段不变。
	var kind, selected, text, gotCreated string
	if err := db.db.QueryRow(
		`SELECT kind, selected_text, text, created_at FROM annotations WHERE uid = ?`,
		testUID1).Scan(&kind, &selected, &text, &gotCreated); err != nil {
		t.Fatalf("读取存量批注失败: %v", err)
	}
	if kind != kindNote {
		t.Fatalf("存量批注 kind = %q, 期望 %q", kind, kindNote)
	}
	if selected != "" {
		t.Fatalf("存量批注 selected_text = %q, 期望空串", selected)
	}
	if text != "存量批注" || gotCreated != createdAt {
		t.Fatalf("存量批注其它字段被改动: text=%q created_at=%q", text, gotCreated)
	}

	// 两列均为 NOT NULL：显式写 NULL 必须被拒绝（DEFAULT 只在省略列时生效）。
	if _, err := db.db.Exec(
		`INSERT INTO annotations(uid, location, kind, text, created_at, updated_at)
		 VALUES(?, ?, NULL, ?, ?, ?)`,
		testUID1, "loc", "文本", createdAt, createdAt); err == nil {
		t.Fatalf("kind 为 NOT NULL 列，写入 NULL 应失败")
	}

	// 数据面可用：存储层读取路径已补齐新列。
	items, err := db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("v8 库 ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 || items[0].Kind != kindNote || items[0].SelectedText != "" {
		t.Fatalf("v8 库读回存量批注不符: %+v", items)
	}
}

// TestSchemaV8HasNoPreMigrationCheck 验证 v8 是纯 ADD COLUMN 的可逆迁移：
// 不登记 preMigrationChecks（登记了就说明实现者误加了破坏性前置校验）。
func TestSchemaV8HasNoPreMigrationCheck(t *testing.T) {
	if check := preMigrationChecks[8]; check != nil {
		t.Fatalf("v8 为可逆迁移，不应登记 preMigrationChecks")
	}
	if len(migrations) != schemaVersion {
		t.Fatalf("len(migrations) = %d, schemaVersion = %d，二者必须相等", len(migrations), schemaVersion)
	}
}

// TestCreateAnnotationKindDefaultsToNote 验证 kind 缺省在 storage 层兜底为 note
// （显式 INSERT 带 kind 列，SQL 的 DEFAULT 'note' 不会生效）。
func TestCreateAnnotationKindDefaultsToNote(t *testing.T) {
	db := openTestDB(t)

	created, isNew, err := db.CreateAnnotation(testUID1, "loc", "", "备注正文", "选中原文")
	if err != nil {
		t.Fatalf("CreateAnnotation() 返回错误: %v", err)
	}
	if !isNew {
		t.Fatalf("首次创建应返回 isNew = true")
	}
	if created.Kind != kindNote {
		t.Fatalf("缺省 kind = %q, 期望 %q", created.Kind, kindNote)
	}
	if created.SelectedText != "选中原文" {
		t.Fatalf("selected_text = %q, 期望 %q", created.SelectedText, "选中原文")
	}

	// 落库值同样为 note（不只看返回值）。
	items, err := db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 || items[0].Kind != kindNote {
		t.Fatalf("落库 kind 不符: %+v", items)
	}
}

// TestCreateAnnotationNonNoteAllowsEmptyText 验证 highlight / ink 以及未知 kind 都
// 允许空 text：服务端不对 kind 做枚举校验，只有 note 要求 text 非空。
func TestCreateAnnotationNonNoteAllowsEmptyText(t *testing.T) {
	db := openTestDB(t)

	cases := []struct {
		kind         string
		location     string
		selectedText string
	}{
		{kindHighlight, "chapter:0@1-9", "选中的原文"},
		{kindInk, "page:3;ink:pen,1.50,10,20", ""},
		{"bookmark", "page:1", ""}, // 未知 kind：服务端不校验枚举
	}
	for _, tc := range cases {
		created, isNew, err := db.CreateAnnotation(testUID1, tc.location, tc.kind, "", tc.selectedText)
		if err != nil {
			t.Fatalf("kind=%q 空 text 应创建成功，实际: %v", tc.kind, err)
		}
		if !isNew || created.Kind != tc.kind || created.Text != "" {
			t.Fatalf("kind=%q 创建结果不符: %+v (isNew=%v)", tc.kind, created, isNew)
		}
		if created.SelectedText != tc.selectedText {
			t.Fatalf("kind=%q selected_text = %q, 期望 %q", tc.kind, created.SelectedText, tc.selectedText)
		}
	}
	if n := annotationRowCount(t, db); n != len(cases) {
		t.Fatalf("批注行数 = %d, 期望 %d", n, len(cases))
	}
}

// TestCreateAnnotationNoteRejectsEmptyText 验证 kind=note（含缺省）时 text 仍必填。
func TestCreateAnnotationNoteRejectsEmptyText(t *testing.T) {
	db := openTestDB(t)

	_, _, err := db.CreateAnnotation(testUID1, "loc", kindNote, "", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	// 缺省 kind 同样落到 note，故空 text 也应被拒绝。
	_, _, err = db.CreateAnnotation(testUID1, "loc", "", "", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	if n := annotationRowCount(t, db); n != 0 {
		t.Fatalf("校验失败不应写入任何行, 实际 %d 行", n)
	}
}

// TestCreateAnnotationIdempotentOnSameContent 验证幂等去重：同
// (uid, kind, location, text) 第二次创建直接返回既有记录（isNew=false），
// 不插新行、不刷新 updated_at；selected_text 不参与去重键。
func TestCreateAnnotationIdempotentOnSameContent(t *testing.T) {
	db := openTestDB(t)

	first, isNew, err := db.CreateAnnotation(testUID1, "loc", kindHighlight, "", "第一次选中")
	if err != nil {
		t.Fatalf("首次 CreateAnnotation() 返回错误: %v", err)
	}
	if !isNew {
		t.Fatalf("首次创建应返回 isNew = true")
	}

	second, isNew, err := db.CreateAnnotation(testUID1, "loc", kindHighlight, "", "第二次选中")
	if err != nil {
		t.Fatalf("重复 CreateAnnotation() 返回错误: %v", err)
	}
	if isNew {
		t.Fatalf("命中既有记录时应返回 isNew = false")
	}
	if second.ID != first.ID {
		t.Fatalf("命中记录 id = %d, 期望既有 id %d", second.ID, first.ID)
	}
	if second.UpdatedAt != first.UpdatedAt || second.CreatedAt != first.CreatedAt {
		t.Fatalf("命中记录不应改动时间戳: %q → %q", first.UpdatedAt, second.UpdatedAt)
	}
	if second.SelectedText != first.SelectedText {
		t.Fatalf("命中记录应原样返回既有 selected_text=%q, 实际 %q", first.SelectedText, second.SelectedText)
	}
	if n := annotationRowCount(t, db); n != 1 {
		t.Fatalf("批注行数 = %d, 期望 1（幂等不应插新行）", n)
	}
}

// TestCreateAnnotationSameLocationDifferentKind 验证同 location、不同 kind 是两条
// 独立批注（去重键含 kind）。
func TestCreateAnnotationSameLocationDifferentKind(t *testing.T) {
	db := openTestDB(t)

	const loc = "page:3"
	if _, isNew, err := db.CreateAnnotation(testUID1, loc, kindHighlight, "", "选中"); err != nil || !isNew {
		t.Fatalf("highlight 创建失败: err=%v isNew=%v", err, isNew)
	}
	if _, isNew, err := db.CreateAnnotation(testUID1, loc, kindInk, "", ""); err != nil || !isNew {
		t.Fatalf("ink 创建失败: err=%v isNew=%v", err, isNew)
	}

	if n := annotationRowCount(t, db); n != 2 {
		t.Fatalf("批注行数 = %d, 期望 2（同 location 不同 kind 不去重）", n)
	}
	items, err := db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("ListAnnotations() 返回错误: %v", err)
	}
	got := make(map[string]bool, len(items))
	for _, a := range items {
		got[a.Kind] = true
	}
	if !got[kindHighlight] || !got[kindInk] {
		t.Fatalf("两类批注未各存一条: %+v", items)
	}
}

// TestAnnotationKindSelectedTextRoundTrip 验证 Create → List → Update → List 四步
// 都能带出 kind 与 selected_text（覆盖各 SQL 的补列与列顺序一致性）。
func TestAnnotationKindSelectedTextRoundTrip(t *testing.T) {
	db := openTestDB(t)

	created, _, err := db.CreateAnnotation(testUID1, "chapter:2@10-20", kindHighlight, "", "选中原文")
	if err != nil {
		t.Fatalf("CreateAnnotation() 返回错误: %v", err)
	}

	items, err := db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("批注条数 = %d, 期望 1", len(items))
	}
	if items[0].Kind != kindHighlight || items[0].SelectedText != "选中原文" || items[0].Text != "" {
		t.Fatalf("列表读回的 kind/selected_text/text 不符: %+v", items[0])
	}
	if items[0].ID != created.ID {
		t.Fatalf("列表 id = %d, 期望 %d", items[0].ID, created.ID)
	}

	updated, err := db.UpdateAnnotation(created.ID, "chapter:2@10-20", kindNote, "补的备注", "选中原文")
	if err != nil {
		t.Fatalf("UpdateAnnotation() 返回错误: %v", err)
	}
	if updated.Kind != kindNote || updated.Text != "补的备注" || updated.SelectedText != "选中原文" {
		t.Fatalf("更新返回的字段不符: %+v", updated)
	}

	items, err = db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("二次 ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 || items[0].Kind != kindNote || items[0].Text != "补的备注" {
		t.Fatalf("更新后列表读回不符: %+v", items)
	}
	if items[0].CreatedAt != created.CreatedAt {
		t.Fatalf("created_at 不应变化: %q → %q", created.CreatedAt, items[0].CreatedAt)
	}
}

// TestUpdateAnnotationAtKindTransition 验证更新时 kind 与 text 一起生效：
// note（有 text）可改为 highlight（空 text），反之 highlight 也可补回 note。
func TestUpdateAnnotationAtKindTransition(t *testing.T) {
	db := openTestDB(t)

	created, _, err := db.CreateAnnotation(testUID1, "page:2", kindNote, "原始备注", "")
	if err != nil {
		t.Fatalf("CreateAnnotation() 返回错误: %v", err)
	}

	// note → highlight：text 置空 + selected_text 写入，必须成功。
	highlight, err := db.UpdateAnnotationAt(created.ID, "page:2", kindHighlight, "", "选中的句子", "")
	if err != nil {
		t.Fatalf("note → highlight 更新失败: %v", err)
	}
	if highlight.Kind != kindHighlight || highlight.Text != "" || highlight.SelectedText != "选中的句子" {
		t.Fatalf("note → highlight 结果不符: %+v", highlight)
	}
	if highlight.CreatedAt != created.CreatedAt {
		t.Fatalf("created_at 不应变化: %q → %q", created.CreatedAt, highlight.CreatedAt)
	}

	// highlight → note 但 text 仍为空：note 要求 text 非空，必须拒绝且不改记录。
	_, err = db.UpdateAnnotationAt(created.ID, "page:2", kindNote, "", "", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	items, err := db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 || items[0].Kind != kindHighlight || items[0].SelectedText != "选中的句子" {
		t.Fatalf("校验失败的更新不应改动记录: %+v", items)
	}

	// 更新时 kind 缺省同样兜底为 note，并因此要求 text 非空。
	updated, err := db.UpdateAnnotationAt(created.ID, "page:2", "", "补回备注", "", "")
	if err != nil {
		t.Fatalf("kind 缺省更新失败: %v", err)
	}
	if updated.Kind != kindNote || updated.Text != "补回备注" || updated.SelectedText != "" {
		t.Fatalf("kind 缺省更新结果不符: %+v", updated)
	}
}

// TestCreateAnnotationConcurrentSameContent 验证并发重放同一幂等键时只落一行。
//
// 该用例守护「find → insert」的原子性：CreateAnnotation 先查后插、两步各取一次
// 连接，SetMaxOpenConns(1) 只串行化单条语句，不保证两步之间不被其它 goroutine
// 插入——若不串行化该临界区，多个 goroutine 会同时查不到然后各插一行，服务端
// 因而出现重复批注，违反 (uid, kind, location, text) 唯一 + 命中返回 200 的契约。
//
// 库用 openTestDB（t.TempDir() 下的文件型库）而非 :memory:：内存库按连接隔离，
// 并发场景下多条连接会看到不同的库，测不出真实语义。
func TestCreateAnnotationConcurrentSameContent(t *testing.T) {
	db := openTestDB(t)

	const (
		workers = 8
		loc     = "page:5:concurrent"
		text    = "并发补登的同一批注"
	)

	type outcome struct {
		id    int64
		isNew bool
		err   error
	}

	results := make([]outcome, workers)
	// 用闭路 channel 作起跑线，尽量让 8 个 goroutine 同时进入临界区（提高复现率）。
	start := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func(i int) {
			defer wg.Done()
			<-start
			a, isNew, err := db.CreateAnnotation(testUID1, loc, kindNote, text, "")
			if err != nil {
				results[i] = outcome{err: err}
				return
			}
			results[i] = outcome{id: a.ID, isNew: isNew}
		}(i)
	}
	close(start)
	wg.Wait()

	// ① 所有调用都必须成功（含命中既有记录的分支）。
	createdCount := 0
	wantID := results[0].id
	for i, r := range results {
		if r.err != nil {
			t.Fatalf("第 %d 个 goroutine 返回错误: %v", i, r.err)
		}
		if r.isNew {
			createdCount++
		}
		// ④ 所有返回记录的 id 必须一致。
		if r.id != wantID {
			t.Fatalf("第 %d 个 goroutine 返回 id = %d, 期望与首个一致为 %d", i, r.id, wantID)
		}
	}

	// ② 恰好 1 个 goroutine 真正新建，其余全部命中既有记录。
	if createdCount != 1 {
		t.Fatalf("isNew=true 的次数 = %d, 期望恰好 1（并发去重失效，出现重复批注）", createdCount)
	}

	// ③ 库中该幂等键只允许一行。
	if n := annotationRowCount(t, db); n != 1 {
		t.Fatalf("批注行数 = %d, 期望 1（并发下不得插入重复行）", n)
	}
}

// TestCreateAnnotationTrimsKind 验证 kind 两端空白被归一化后再做分支判定：
// " note " 与 "note" 等价（因而 text 必填），全空白仍兜底为 note。
//
// 修复前 kind 只在「全空白」时兜底为 note，随后用 kind == "note" 精确比较，
// 于是 " note " 既不命中兜底、也不命中 text 必填分支，可绕过校验写入空 text
// 的 note 批注。
func TestCreateAnnotationTrimsKind(t *testing.T) {
	db := openTestDB(t)

	// " note " 等价 note → 空 text 必须被拒绝（修复前会绕过校验插行）。
	_, _, err := db.CreateAnnotation(testUID1, "loc:padded", " note ", "", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	// 全空白 kind 兜底为 note 后同样要求 text 非空。
	_, _, err = db.CreateAnnotation(testUID1, "loc:blank", "  ", "", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	if n := annotationRowCount(t, db); n != 0 {
		t.Fatalf("校验失败不应写入任何行, 实际 %d 行", n)
	}

	// 有 text 时带空白的 note 落库为归一化后的 "note"（去重键也随之归一）。
	created, isNew, err := db.CreateAnnotation(testUID1, "loc:trim", " note ", "备注正文", "")
	if err != nil {
		t.Fatalf("kind=%q 且 text 非空应创建成功: %v", " note ", err)
	}
	if !isNew || created.Kind != kindNote {
		t.Fatalf("kind=%q 创建结果不符: %+v (isNew=%v)", " note ", created, isNew)
	}

	// 带空白的高亮 kind 同样归一化，且仍允许空 text（非 note 契约不变）。
	created, isNew, err = db.CreateAnnotation(testUID1, "loc:hl", " highlight ", "", "选中原文")
	if err != nil {
		t.Fatalf("kind=%q 且空 text 应创建成功: %v", " highlight ", err)
	}
	if !isNew || created.Kind != kindHighlight {
		t.Fatalf("kind=%q 创建结果不符: %+v (isNew=%v)", " highlight ", created, isNew)
	}

	if n := annotationRowCount(t, db); n != 2 {
		t.Fatalf("批注行数 = %d, 期望 2", n)
	}
}

// TestUpdateAnnotationTrimsKind 验证 Update 路径与 Create 同口径：kind 两端空白
// 归一化后再判定 text 是否必填，不允许用 " note " 绕过校验。
func TestUpdateAnnotationTrimsKind(t *testing.T) {
	db := openTestDB(t)

	created, _, err := db.CreateAnnotation(testUID1, "page:9", kindHighlight, "", "选中原文")
	if err != nil {
		t.Fatalf("CreateAnnotation() 返回错误: %v", err)
	}

	// " note " 等价 note → 空 text 必须被拒绝，且不得改动既有记录。
	_, err = db.UpdateAnnotationAt(created.ID, "page:9", " note ", "", "选中原文", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	// 全空白 kind 兜底为 note 后同样被拒绝。
	_, err = db.UpdateAnnotationAt(created.ID, "page:9", "  ", "", "选中原文", "")
	assertCode(t, err, logging.ErrInvalidArgument)

	items, err := db.ListAnnotations(testUID1)
	if err != nil {
		t.Fatalf("ListAnnotations() 返回错误: %v", err)
	}
	if len(items) != 1 || items[0].Kind != kindHighlight || items[0].SelectedText != "选中原文" {
		t.Fatalf("校验失败的更新不应改动记录: %+v", items)
	}

	// 带空白的 note + 非空 text：更新成功且落库 kind 归一化为 "note"。
	updated, err := db.UpdateAnnotation(created.ID, "page:9", " note ", "补的备注", "")
	if err != nil {
		t.Fatalf("kind=%q 且 text 非空应更新成功: %v", " note ", err)
	}
	if updated.Kind != kindNote || updated.Text != "补的备注" {
		t.Fatalf("kind=%q 更新结果不符（kind 未归一化）: %+v", " note ", updated)
	}
}
