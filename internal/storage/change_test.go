// 本文件测试变更日志表（schema v6）的追加与增量读取。
//
// 断言口径：changes.seq 由 SQLite AUTOINCREMENT 提供，全局单调递增且不复用；
// 客户端以「最后消费的 seq」为游标，ListChanges 返回 seq > since 的一批记录，
// 并通过 hasMore / nextCursor 支撑分页。
package storage

import (
	"testing"
	"time"

	"seshat/internal/logging"
)

// sampleChange 返回一条字段齐全的变更事件。
func sampleChange(uid, op, path string) Change {
	return Change{
		UID:  uid,
		Op:   op,
		Root: "notes",
		Path: path,
		Blob: "blob-" + uid,
		Rev:  "rev-1",
	}
}

// TestAppendChangeSeqMonotonic 验证 seq 单调递增，且空 ChangedAt 回填当前 UTC 时间。
func TestAppendChangeSeqMonotonic(t *testing.T) {
	db := openTestDB(t)

	var seqs []int64
	for _, op := range []string{OpCreate, OpUpdate, OpRename, OpDelete} {
		seq, err := db.AppendChange(sampleChange("uid-x", op, "x.org"))
		if err != nil {
			t.Fatalf("AppendChange(%s) 返回错误: %v", op, err)
		}
		seqs = append(seqs, seq)
	}

	if len(seqs) != 4 {
		t.Fatalf("seq 数量 = %d, 期望 4", len(seqs))
	}
	for i := 1; i < len(seqs); i++ {
		if seqs[i] <= seqs[i-1] {
			t.Fatalf("seq 非单调递增: %v", seqs)
		}
	}

	items, _, _, err := db.ListChanges(0, 10)
	if err != nil {
		t.Fatalf("ListChanges() 返回错误: %v", err)
	}
	if len(items) != 4 {
		t.Fatalf("变更条数 = %d, 期望 4", len(items))
	}
	if items[0].Op != OpCreate || items[1].Op != OpUpdate || items[2].Op != OpRename || items[3].Op != OpDelete {
		t.Fatalf("按 seq 升序返回的 op 序列不符: %+v", items)
	}
	for _, it := range items {
		parsed, err := time.Parse(time.RFC3339, it.ChangedAt)
		if err != nil {
			t.Fatalf("ChangedAt 未回填为 RFC3339: %q", it.ChangedAt)
		}
		if delta := time.Since(parsed); delta < 0 || delta > time.Minute {
			t.Fatalf("ChangedAt 偏差过大: %v", delta)
		}
	}
}

// TestAppendChangePreservesFields 验证事件字段（含 old_path）按原样存取，
// 且显式 ChangedAt 被规范化为 UTC。
func TestAppendChangePreservesFields(t *testing.T) {
	db := openTestDB(t)

	c := Change{
		UID: "uid-mv", Op: OpRename, Root: "notes", Path: "new.org", OldPath: "old.org",
		Blob: "b1", Rev: "r1", ChangedAt: "2026-10-18T10:00:00+08:00",
	}
	seq, err := db.AppendChange(c)
	if err != nil {
		t.Fatalf("AppendChange() 返回错误: %v", err)
	}

	items, _, _, err := db.ListChanges(0, 10)
	if err != nil {
		t.Fatalf("ListChanges() 返回错误: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("变更条数 = %d, 期望 1", len(items))
	}
	got := items[0]
	if got.Seq != seq || got.UID != "uid-mv" || got.Op != OpRename || got.Root != "notes" {
		t.Fatalf("读回字段不符: %+v", got)
	}
	if got.Path != "new.org" || got.OldPath != "old.org" || got.Blob != "b1" || got.Rev != "r1" {
		t.Fatalf("读回路径/内容字段不符: %+v", got)
	}
	if got.ChangedAt != "2026-10-18T02:00:00Z" {
		t.Fatalf("ChangedAt = %q, 期望规范化为 UTC", got.ChangedAt)
	}
}

// TestAppendChangeValidation 验证必填字段与 op 取值校验。
func TestAppendChangeValidation(t *testing.T) {
	db := openTestDB(t)

	cases := []struct {
		name string
		c    Change
	}{
		{"空 uid", Change{Op: OpCreate, Root: "notes", Path: "x.org"}},
		{"空 op", Change{UID: "u1", Root: "notes", Path: "x.org"}},
		{"非法 op", Change{UID: "u1", Op: "move", Root: "notes", Path: "x.org"}},
		{"空 root", Change{UID: "u1", Op: OpCreate, Path: "x.org"}},
		{"空 path", Change{UID: "u1", Op: OpCreate, Root: "notes"}},
		{"非法 changed_at", Change{UID: "u1", Op: OpCreate, Root: "notes", Path: "x.org", ChangedAt: "nope"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := db.AppendChange(c.c)
			assertCode(t, err, logging.ErrInvalidArgument)
		})
	}
}

// TestListChangesPagination 验证分页：limit=2 逐页前推，hasMore 与 nextCursor 正确。
func TestListChangesPagination(t *testing.T) {
	db := openTestDB(t)

	var seqs []int64
	for i := 0; i < 5; i++ {
		seq, err := db.AppendChange(sampleChange("uid-p", OpUpdate, "p.org"))
		if err != nil {
			t.Fatalf("AppendChange() 返回错误: %v", err)
		}
		seqs = append(seqs, seq)
	}

	cursor := int64(0)
	page := 0
	for {
		items, next, hasMore, err := db.ListChanges(cursor, 2)
		if err != nil {
			t.Fatalf("ListChanges(cursor=%d) 返回错误: %v", cursor, err)
		}
		page++
		switch page {
		case 1:
			if len(items) != 2 || !hasMore || next != seqs[1] {
				t.Fatalf("第 1 页不符: len=%d hasMore=%v next=%d", len(items), hasMore, next)
			}
		case 2:
			if len(items) != 2 || !hasMore || next != seqs[3] {
				t.Fatalf("第 2 页不符: len=%d hasMore=%v next=%d", len(items), hasMore, next)
			}
		case 3:
			if len(items) != 1 || hasMore || next != seqs[4] {
				t.Fatalf("第 3 页不符: len=%d hasMore=%v next=%d", len(items), hasMore, next)
			}
			return
		default:
			t.Fatalf("分页轮次异常: page=%d", page)
		}
		cursor = next
	}
}

// TestListChangesSinceBeyondMax 验证 since 大于最大 seq 时返回空批次，
// nextCursor 回传 since、hasMore 为 false（游标不倒退）。
func TestListChangesSinceBeyondMax(t *testing.T) {
	db := openTestDB(t)

	if _, err := db.AppendChange(sampleChange("uid-s", OpCreate, "s.org")); err != nil {
		t.Fatalf("AppendChange() 返回错误: %v", err)
	}

	items, next, hasMore, err := db.ListChanges(999, 10)
	if err != nil {
		t.Fatalf("ListChanges() 返回错误: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("条数 = %d, 期望 0", len(items))
	}
	if items == nil {
		t.Fatal("items 为 nil，期望空切片")
	}
	if next != 999 {
		t.Fatalf("nextCursor = %d, 期望回传 since=999", next)
	}
	if hasMore {
		t.Fatal("hasMore 应为 false")
	}
}

// TestListChangesLimitClamp 验证 limit 被夹紧到 [1, 2000]：0/负数走默认值，
// 超大值不报错且不返回超额记录。
func TestListChangesLimitClamp(t *testing.T) {
	db := openTestDB(t)

	for i := 0; i < 3; i++ {
		if _, err := db.AppendChange(sampleChange("uid-c", OpCreate, "c.org")); err != nil {
			t.Fatalf("AppendChange() 返回错误: %v", err)
		}
	}

	for _, limit := range []int{0, -5, 1, 5, 2000, 999999} {
		items, _, hasMore, err := db.ListChanges(0, limit)
		if err != nil {
			t.Fatalf("ListChanges(limit=%d) 返回错误: %v", limit, err)
		}
		if limit <= 0 || limit >= 3 {
			if len(items) != 3 || hasMore {
				t.Fatalf("ListChanges(limit=%d): len=%d hasMore=%v, 期望 3/false", limit, len(items), hasMore)
			}
			continue
		}
		if len(items) != limit {
			t.Fatalf("ListChanges(limit=%d): len=%d", limit, len(items))
		}
	}
}

// TestLatestChangeSeq 验证空库返回 0、有记录时返回最大 seq。
func TestLatestChangeSeq(t *testing.T) {
	db := openTestDB(t)

	seq, err := db.LatestChangeSeq()
	if err != nil {
		t.Fatalf("LatestChangeSeq() 返回错误: %v", err)
	}
	if seq != 0 {
		t.Fatalf("空库 LatestChangeSeq() = %d, 期望 0", seq)
	}

	last := int64(0)
	for i := 0; i < 3; i++ {
		got, err := db.AppendChange(sampleChange("uid-l", OpCreate, "l.org"))
		if err != nil {
			t.Fatalf("AppendChange() 返回错误: %v", err)
		}
		last = got
	}

	seq, err = db.LatestChangeSeq()
	if err != nil {
		t.Fatalf("LatestChangeSeq() 返回错误: %v", err)
	}
	if seq != last {
		t.Fatalf("LatestChangeSeq() = %d, 期望 %d", seq, last)
	}
}
