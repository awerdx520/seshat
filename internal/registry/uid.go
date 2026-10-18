// 本文件实现 uid 的生成与校验（M7 服务端地基：稳定文件身份）。
//
// 形态：crypto/rand 取 16 字节（128 位）随机量 → Crockford Base32 编码
// （字母表排除 I/L/O/U，避免与 1/0 手写混淆）→ 26 字符定长大写串。字符集与
// 校验正则严格一一对应：「生成的必然通过校验，非法字符必然被拒」是引用解析
// （seshat:<uid>）与同步游标成立的前提。
//
// 零新增依赖：只用标准库 crypto/rand 与 encoding/base32。
package registry

import (
	"crypto/rand"
	"encoding/base32"
	"regexp"

	"seshat/internal/logging"
)

// uidLength 是 uid 的固定字符长度（16 字节 = 128 位 → 26 个 Base32 字符）。
const uidLength = 26

// uidAlphabet 是 Crockford Base32 字母表（32 个字符，排除 I/L/O/U）。
const uidAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// uidEncoding 是无填充的 Crockford Base32 编码器。
var uidEncoding = base32.NewEncoding(uidAlphabet).WithPadding(base32.NoPadding)

// uidPattern 是 uid 校验正则，与计划约定完全一致（排除 I/L/O/U）。
var uidPattern = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{26}$`)

// NewUID 生成一个新的 uid（26 字符 Crockford Base32）。
//
// 随机源为 crypto/rand：uid 是全局唯一身份，不能退化为可预测值。熵不足时返回
// ErrInternal（此时生成 uid 的前提已不成立，调用方应中止而非重试静默降级）。
func NewUID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", logging.Wrap(err, logging.ErrInternal, "生成 uid 失败")
	}
	uid := uidEncoding.EncodeToString(buf)
	if len(uid) != uidLength {
		// 防御性断言：base32 对 16 字节必然产出 26 字符，此处不一致说明编码器被改动。
		return "", logging.NewAppError(logging.ErrInternal, "生成的 uid 长度异常")
	}
	return uid, nil
}

// IsUID 判断 s 是否为合法 uid（26 位 Crockford Base32 大写，排除 I/L/O/U）。
func IsUID(s string) bool {
	return uidPattern.MatchString(s)
}
