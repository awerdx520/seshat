// 本文件测试 ApplyResourceChange：把「资源登记」与「变更事件」写在同一事务内。
//
// 断言口径：两个写入要么同时可见、要么同时不可见——变更事件插入失败时资源登记
// 也不得残留，否则登记表与变更日志会永久不一致（客户端据此增量同步会漏掉变更）。
package storage

import (
	"testing"

	"seshat/internal/logging"
)

// changeFor 构造与 Entry 对应的变更事件（默认 create）。
func changeFor(e Entry, op string) Change {
	return Change{UID: e.UID, Op: op, Root: e.Root, Path: e.Path, Blob: e.Blob, Rev: e.Rev}
}

// TestApplyResourceChangeCommitsBoth 验证资源登记与变更事件同时落库，且返回的 seq
// 与日志中的记录一致。
func TestApplyResourceChangeCommitsBoth(t *testing.T) {
	db := openTestDB(t)
	e := baseEntry("01K8Q3M7D2X9V6T1B8N5C0RDEF", "a.org")

	seq, err := db.ApplyResourceChange(e, changeFor(e, OpCreate))
	if err != nil {
		t.Fatalf("ApplyResourceChange() 返回错误: %v", err)
	}
	if seq <= 0 {
		t.Fatalf("seq = %d, 期望正整数", seq)
	}

	got, err := db.GetResourceByUID(e.UID)
	if err != nil {
		t.Fatalf("资源未落库: %v", err)
	}
	if got.Path != "a.org" || got.Size != e.Size || got.Mtime != e.Mtime {
		t.Fatalf("资源登记 = %+v, 期望 path=a.org size=%d mtime=%d", got, e.Size, e.Mtime)
	}

	changes, _, _, err := db.ListChanges(0, 10)
	if err != nil {
		t.Fatalf("ListChanges() 返回错误: %v", err)
	}
	if len(changes) != 1 {
		t.Fatalf("变更日志条数 = %d, 期望 1", len(changes))
	}
	if changes[0].Seq != seq || changes[0].Op != OpCreate || changes[0].Path != "a.org" {
		t.Fatalf("变更事件 = %+v, 期望 seq=%d op=create path=a.org", changes[0], seq)
	}
}

// TestApplyResourceChangeRollsBack 验证事务内任一步失败时整体回滚：
// 变更事件非法（op / uid / 时间戳）或路径冲突时，资源登记都不得残留。
func TestApplyResourceChangeRollsBack(t *testing.T) {
	db := openTestDB(t)

	// 先占位一条记录，供「路径冲突」用例制造 UNIQUE 冲突。
	occupied := baseEntry("01K8Q3M7D2X9V6T1B8N5C0RDEH", "occupied.org")
	if err := db.CreateResource(occupied); err != nil {
		t.Fatalf("CreateResource() 返回错误: %v", err)
	}

	cases := []struct {
		name string
		uid  string
		path string
		ch   func(e Entry) Change
		code logging.Code
	}{
		{
			name: "非法 op",
			uid:  "01K8Q3M7D2X9V6T1B8N5C0RDEF",
			path: "a.org",
			ch:   func(e Entry) Change { return changeFor(e, "bogus") },
			code: logging.ErrInvalidArgument,
		},
		{
			name: "变更 uid 为空",
			uid:  "01K8Q3M7D2X9V6T1B8N5C0RDEF",
			path: "a.org",
			ch: func(e Entry) Change {
				c := changeFor(e, OpCreate)
				c.UID = ""
				return c
			},
			code: logging.ErrInvalidArgument,
		},
		{
			name: "变更时间戳非法",
			uid:  "01K8Q3M7D2X9V6T1B8N5C0RDEF",
			path: "a.org",
			ch: func(e Entry) Change {
				c := changeFor(e, OpCreate)
				c.ChangedAt = "not-a-time"
				return c
			},
			code: logging.ErrInvalidArgument,
		},
		{
			name: "路径被其它 uid 占用",
			uid:  "01K8Q3M7D2X9V6T1B8N5C0RDEF",
			path: "occupied.org",
			ch:   func(e Entry) Change { return changeFor(e, OpCreate) },
			code: logging.ErrConflict,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := baseEntry(tc.uid, tc.path)
			if _, err := db.ApplyResourceChange(e, tc.ch(e)); err == nil {
				t.Fatal("ApplyResourceChange() 应返回错误，实际返回 nil")
			} else {
				assertCode(t, err, tc.code)
			}

			// 资源未落库（占位记录除外，它由前置步骤写入）。
			if _, err := db.GetResourceByUID(tc.uid); err == nil {
				t.Fatalf("回滚后 uid %s 仍可读到资源登记", tc.uid)
			}
			// 变更日志也没有新增（只有前置步骤之外没有事件）。
			changes, _, _, err := db.ListChanges(0, 10)
			if err != nil {
				t.Fatalf("ListChanges() 返回错误: %v", err)
			}
			if len(changes) != 0 {
				t.Fatalf("回滚后变更日志条数 = %d, 期望 0", len(changes))
			}
		})
	}
}

// TestApplyResourceChangeSeqIncrements 验证连续两次事务写入的 seq 严格递增。
func TestApplyResourceChangeSeqIncrements(t *testing.T) {
	db := openTestDB(t)

	first := baseEntry("01K8Q3M7D2X9V6T1B8N5C0RDEF", "a.org")
	seq1, err := db.ApplyResourceChange(first, changeFor(first, OpCreate))
	if err != nil {
		t.Fatalf("第一次 ApplyResourceChange() 返回错误: %v", err)
	}

	second := baseEntry("01K8Q3M7D2X9V6T1B8N5C0RDEG", "b.org")
	seq2, err := db.ApplyResourceChange(second, changeFor(second, OpCreate))
	if err != nil {
		t.Fatalf("第二次 ApplyResourceChange() 返回错误: %v", err)
	}

	if seq2 != seq1+1 {
		t.Fatalf("seq2 = %d, 期望 %d（严格递增且无空洞）", seq2, seq1+1)
	}
}

// TestApplyResourceChangeTombstone 验证 DeletedAt 非空时写墓碑（不物理删除），
// 且日志记录 delete 事件。
func TestApplyResourceChangeTombstone(t *testing.T) {
	db := openTestDB(t)
	e := baseEntry("01K8Q3M7D2X9V6T1B8N5C0RDEF", "a.org")
	if err := db.CreateResource(e); err != nil {
		t.Fatalf("CreateResource() 返回错误: %v", err)
	}

	tomb := e
	tomb.DeletedAt = "2026-10-18T10:00:00Z"
	tomb.UpdatedAt = tomb.DeletedAt
	if _, err := db.ApplyResourceChange(tomb, changeFor(tomb, OpDelete)); err != nil {
		t.Fatalf("ApplyResourceChange() 返回错误: %v", err)
	}

	got, err := db.GetResourceByUID(e.UID)
	if err != nil {
		t.Fatalf("墓碑记录不可读: %v", err)
	}
	if got.DeletedAt == "" {
		t.Fatal("墓碑记录 DeletedAt 为空，期望非空")
	}
	if got.Path != "a.org" {
		t.Fatalf("墓碑记录 Path = %q, 期望保留删除前路径 a.org", got.Path)
	}

	changes, _, _, err := db.ListChanges(0, 10)
	if err != nil {
		t.Fatalf("ListChanges() 返回错误: %v", err)
	}
	if len(changes) != 1 || changes[0].Op != OpDelete {
		t.Fatalf("变更日志 = %+v, 期望一条 delete 事件", changes)
	}
}

// TestApplyResourceChangeTombstoneMissing 验证对未登记的 uid 写墓碑返回 ErrNotFound。
func TestApplyResourceChangeTombstoneMissing(t *testing.T) {
	db := openTestDB(t)
	e := baseEntry("01K8Q3M7D2X9V6T1B8N5C0RDEF", "a.org")
	e.DeletedAt = "2026-10-18T10:00:00Z"

	_, err := db.ApplyResourceChange(e, changeFor(e, OpDelete))
	assertCode(t, err, logging.ErrNotFound)
}
