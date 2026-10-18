package com.seshat.app.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LegacyKeys] 的形态判定单测。
 *
 * 覆盖旧键两类形态（32 位十六进制 / 含 `:` 的 uri）与新键形态（26 位 Crockford Base32 uid）
 * 的边界，确保旧键清理不会误删 uid 键。
 */
class LegacyKeysTest {

    /** 合法的 26 位 Crockford Base32 串（无 I/L/O/U）。 */
    private val uid = "0123456789ABCDEFGHJKMNPQRS"

    @Test
    fun isSha256PrefixHexAcceptsExactly32HexChars() {
        assertTrue(LegacyKeys.isSha256PrefixHex("a1b2c3d4e5f60718293a4b5c6d7e8f90"))
        // 大小写混合仍算十六进制
        assertTrue(LegacyKeys.isSha256PrefixHex("A1B2C3D4E5F60718293A4B5C6D7E8F90"))
    }

    @Test
    fun isSha256PrefixHexRejectsWrongLengthOrNonHex() {
        // 31 位
        assertFalse(LegacyKeys.isSha256PrefixHex("a1b2c3d4e5f60718293a4b5c6d7e8f9"))
        // 33 位
        assertFalse(LegacyKeys.isSha256PrefixHex("a1b2c3d4e5f60718293a4b5c6d7e8f900"))
        // 长度正确但含非 hex 字符
        assertFalse(LegacyKeys.isSha256PrefixHex("g1b2c3d4e5f60718293a4b5c6d7e8f90"))
        // 空串
        assertFalse(LegacyKeys.isSha256PrefixHex(""))
    }

    @Test
    fun isLegacyBaseDetectsUriAndHexButNotUid() {
        assertTrue(LegacyKeys.isLegacyBase("content://com.android.providers/document/42"))
        assertTrue(LegacyKeys.isLegacyBase("file:///sdcard/book.pdf"))
        assertTrue(LegacyKeys.isLegacyBase("a1b2c3d4e5f60718293a4b5c6d7e8f90"))
        assertFalse(LegacyKeys.isLegacyBase(uid))
        assertFalse(LegacyKeys.isLegacyBase("doc-1"))
    }

    @Test
    fun isUidAccepts26CrockfordBase32() {
        assertTrue(LegacyKeys.isUid(uid))
        // 小写等价
        assertTrue(LegacyKeys.isUid(uid.lowercase()))
    }

    @Test
    fun isUidRejectsWrongLengthOrForbiddenChars() {
        assertEquals26(uid)
        // 25 / 27 位
        assertFalse(LegacyKeys.isUid(uid.dropLast(1)))
        assertFalse(LegacyKeys.isUid("${uid}0"))
        // 含被 Crockford Base32 排除的 I / L / O / U
        for (bad in listOf('I', 'L', 'O', 'U')) {
            val candidate = uid.dropLast(1) + bad
            assertFalse("应拒绝含 $bad 的串: $candidate", LegacyKeys.isUid(candidate))
        }
    }

    /** 断言基准串确实是 26 位（避免测试自身写错长度）。 */
    private fun assertEquals26(value: String) {
        org.junit.Assert.assertEquals(26, value.length)
    }
}
