// 本文件测试引用图表（schema v6）的替换写入与双向查询。
//
// 断言口径：ReplaceRefs 是「整份替换」语义（单事务内先删该 source 的全部引用再插入），
// 因此重复调用幂等；空 refs 表示清空。ListRefs 的 direction 为 in 时按 target_uid
// 查「谁引用了我」，为 out 时按 source_uid 查「我引用了谁」，空方向按 out 处理。
package storage

import (
	"testing"

	"seshat/internal/logging"
)

// refTarget 构造一条 source→target 的引用。
func refTarget(source, target string) Ref {
	return Ref{
		SourceUID:      source,
		SourceLocation: "loc-" + source,
		TargetUID:      target,
		TargetLocation: "loc-" + target,
	}
}

// TestReplaceRefsAndListRefs 验证写入后按 out（我引用了谁）与 in（谁引用了我）双向查询。
func TestReplaceRefsAndListRefs(t *testing.T) {
	db := openTestDB(t)

	refs := []Ref{refTarget("uid-a", "uid-b"), refTarget("uid-a", "uid-c")}
	if err := db.ReplaceRefs("uid-a", refs); err != nil {
		t.Fatalf("ReplaceRefs() 返回错误: %v", err)
	}

	out, err := db.ListRefs("uid-a", RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs(out) 返回错误: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("out 引用数 = %d, 期望 2（实际 %+v）", len(out), out)
	}
	targets := map[string]bool{}
	for _, r := range out {
		targets[r.TargetUID] = true
		if r.SourceUID != "uid-a" {
			t.Fatalf("out 结果的 source_uid = %q, 期望 uid-a", r.SourceUID)
		}
		if r.CreatedAt == "" {
			t.Fatal("CreatedAt 未回填")
		}
	}
	if !targets["uid-b"] || !targets["uid-c"] {
		t.Fatalf("out 结果缺失目标: %+v", out)
	}

	in, err := db.ListRefs("uid-b", RefDirectionIn)
	if err != nil {
		t.Fatalf("ListRefs(in) 返回错误: %v", err)
	}
	if len(in) != 1 || in[0].SourceUID != "uid-a" || in[0].TargetUID != "uid-b" {
		t.Fatalf("in 结果不符: %+v", in)
	}

	// 空方向按 out 处理。
	def, err := db.ListRefs("uid-a", "")
	if err != nil {
		t.Fatalf("ListRefs(空方向) 返回错误: %v", err)
	}
	if len(def) != len(out) {
		t.Fatalf("空方向结果数 = %d, 期望与 out 一致 %d", len(def), len(out))
	}
}

// TestListRefsEmpty 验证无引用时返回非 nil 空切片。
func TestListRefsEmpty(t *testing.T) {
	db := openTestDB(t)

	got, err := db.ListRefs("uid-none", RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if got == nil {
		t.Fatal("ListRefs() 返回 nil，期望空切片")
	}
	if len(got) != 0 {
		t.Fatalf("引用数 = %d, 期望 0", len(got))
	}
}

// TestReplaceRefsIdempotent 验证重复调用结果一致（先删后插，不产生重复行）。
func TestReplaceRefsIdempotent(t *testing.T) {
	db := openTestDB(t)

	refs := []Ref{refTarget("uid-a", "uid-b"), refTarget("uid-a", "uid-c")}
	for i := 0; i < 3; i++ {
		if err := db.ReplaceRefs("uid-a", refs); err != nil {
			t.Fatalf("第 %d 次 ReplaceRefs() 返回错误: %v", i+1, err)
		}
		got, err := db.ListRefs("uid-a", RefDirectionOut)
		if err != nil {
			t.Fatalf("ListRefs() 返回错误: %v", err)
		}
		if len(got) != 2 {
			t.Fatalf("第 %d 次调用后引用数 = %d, 期望 2", i+1, len(got))
		}
	}
}

// TestReplaceRefsReplacesAndClears 验证整份替换语义与空 refs 清空。
func TestReplaceRefsReplacesAndClears(t *testing.T) {
	db := openTestDB(t)

	if err := db.ReplaceRefs("uid-a", []Ref{refTarget("uid-a", "uid-b")}); err != nil {
		t.Fatalf("首次 ReplaceRefs() 返回错误: %v", err)
	}
	// 整份替换：旧目标消失、新目标出现。
	if err := db.ReplaceRefs("uid-a", []Ref{refTarget("uid-a", "uid-c")}); err != nil {
		t.Fatalf("替换 ReplaceRefs() 返回错误: %v", err)
	}
	got, err := db.ListRefs("uid-a", RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(got) != 1 || got[0].TargetUID != "uid-c" {
		t.Fatalf("整份替换结果不符: %+v", got)
	}

	// 空 refs 清空该 source 的全部引用，且不影响其它 source。
	if err := db.ReplaceRefs("uid-z", []Ref{refTarget("uid-z", "uid-a")}); err != nil {
		t.Fatalf("写入 uid-z 引用失败: %v", err)
	}
	if err := db.ReplaceRefs("uid-a", nil); err != nil {
		t.Fatalf("清空 ReplaceRefs() 返回错误: %v", err)
	}
	cleared, err := db.ListRefs("uid-a", RefDirectionOut)
	if err != nil {
		t.Fatalf("ListRefs() 返回错误: %v", err)
	}
	if len(cleared) != 0 {
		t.Fatalf("清空后引用数 = %d, 期望 0", len(cleared))
	}
	if in, err := db.ListRefs("uid-a", RefDirectionIn); err != nil || len(in) != 1 {
		t.Fatalf("其它 source 的引用不应被清空: in=%+v err=%v", in, err)
	}
}

// TestReplaceRefsValidation 验证空 sourceUID / 空 targetUID / 非法方向 / 空方向 uid 校验。
func TestReplaceRefsValidation(t *testing.T) {
	db := openTestDB(t)

	assertCode(t, db.ReplaceRefs("  ", []Ref{refTarget("uid-a", "uid-b")}), logging.ErrInvalidArgument)
	assertCode(t, db.ReplaceRefs("uid-a", []Ref{{SourceUID: "uid-a", TargetUID: " "}}), logging.ErrInvalidArgument)

	_, err := db.ListRefs("uid-a", "sideways")
	assertCode(t, err, logging.ErrInvalidArgument)

	_, err = db.ListRefs("  ", RefDirectionOut)
	assertCode(t, err, logging.ErrInvalidArgument)
}
