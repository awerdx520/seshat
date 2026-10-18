// 本文件测试 uid 的生成与校验。
//
// 断言口径：uid 是服务端权威的文本身份，形态固定为 26 字符 Crockford Base32
// （字母表排除 I/L/O/U，避免与 1/0 手写混淆）；校验正则必须与之一致，
// 否则「能生成但不能解析」或「接受非法字符」都会破坏引用与同步的基础假设。
package registry

import (
	"regexp"
	"testing"
)

// uidCharset 是合法 uid 字符集（Crockford Base32 大写字母表）。
const uidCharset = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// TestNewUIDFormat 验证生成的 uid 长度 26 且字符全部落在合法字符集内。
func TestNewUIDFormat(t *testing.T) {
	uid, err := NewUID()
	if err != nil {
		t.Fatalf("NewUID() 返回错误: %v", err)
	}
	if len(uid) != 26 {
		t.Fatalf("uid 长度 = %d, 期望 26（uid=%q）", len(uid), uid)
	}
	allowed := make(map[rune]bool, len(uidCharset))
	for _, r := range uidCharset {
		allowed[r] = true
	}
	for _, r := range uid {
		if !allowed[r] {
			t.Fatalf("uid %q 含非法字符 %q（须为 Crockford Base32 大写）", uid, r)
		}
	}
	if !IsUID(uid) {
		t.Fatalf("IsUID(%q) = false, 生成的 uid 必须能通过校验", uid)
	}
}

// TestNewUIDUnique 验证 1000 次生成无重复（crypto/rand 提供 128 位随机量）。
func TestNewUIDUnique(t *testing.T) {
	const n = 1000
	seen := make(map[string]bool, n)
	for i := 0; i < n; i++ {
		uid, err := NewUID()
		if err != nil {
			t.Fatalf("第 %d 次 NewUID() 返回错误: %v", i, err)
		}
		if seen[uid] {
			t.Fatalf("第 %d 次生成重复 uid %q", i, uid)
		}
		seen[uid] = true
	}
	if len(seen) != n {
		t.Fatalf("去重后数量 = %d, 期望 %d", len(seen), n)
	}
}

// TestIsUIDTable 表驱动验证 IsUID 的正负例：长度、大小写、被排除的字母都须拒绝。
func TestIsUIDTable(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want bool
	}{
		{"合法 26 位大写", "01K8Q3M7D2X9V6T1B8N5C0RDEF", true},
		{"全数字", "01234567890123456789012345", true},
		{"25 位（短一位）", "01K8Q3M7D2X9V6T1B8N5C0RDE", false},
		{"27 位（长一位）", "01K8Q3M7D2X9V6T1B8N5C0RDEFG", false},
		{"小写", "01k8q3m7d2x9v6t1b8n5c0rdef", false},
		{"含 I", "01K8Q3M7D2X9V6T1B8N5C0RDEI", false},
		{"含 L", "01K8Q3M7D2X9V6T1B8N5C0RDEL", false},
		{"含 O", "01K8Q3M7D2X9V6T1B8N5C0RDEO", false},
		{"含 U", "01K8Q3M7D2X9V6T1B8N5C0RDEU", false},
		{"空串", "", false},
		{"含连字符", "01K8Q3M7-D2X9V6T1B8N5C0RD", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsUID(tc.in); got != tc.want {
				t.Fatalf("IsUID(%q) = %v, 期望 %v", tc.in, got, tc.want)
			}
		})
	}
}

// TestIsUIDMatchesPlanPattern 验证 IsUID 与计划给定的正则完全一致。
func TestIsUIDMatchesPlanPattern(t *testing.T) {
	const pattern = `^[0-9A-HJKMNP-TV-Z]{26}$`
	plan := regexp.MustCompile(pattern)

	samples := []string{
		"01K8Q3M7D2X9V6T1B8N5C0RDEF",
		"01234567890123456789012345",
		"01k8q3m7d2x9v6t1b8n5c0rdef",
		"01K8Q3M7D2X9V6T1B8N5C0RDEI",
		"01K8Q3M7D2X9V6T1B8N5C0RDEO",
		"",
		"01K8Q3M7D2X9V6T1B8N5C0RDE",
	}
	for _, s := range samples {
		if got, want := IsUID(s), plan.MatchString(s); got != want {
			t.Fatalf("IsUID(%q) = %v, 计划正则 = %v", s, got, want)
		}
	}
}
