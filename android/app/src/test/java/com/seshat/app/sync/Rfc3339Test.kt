package com.seshat.app.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [formatRfc3339Millis] / [parseRfc3339Millis] 的纯 JVM 单测。
 *
 * 核心约束：**输出必须只到秒、不含小数秒**。keystone 仓 `internal/storage/state.go` 用
 * `time.RFC3339` 布局严格解析 `updated_at`，带小数秒会被判 `invalid_argument`（HTTP 400），
 * 因此这里对格式做逐字符级别的硬断言，而不只是「能被解析」的宽松断言。
 */
class Rfc3339Test {

    /** 只到秒的 RFC 3339 UTC 形态（无小数秒、无偏移量变体）。 */
    private val secondPrecisionPattern = Regex("""^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$""")

    @Test
    fun formatDropsMillisecondFraction() {
        // 毫秒非 0 的输入：必须截断，禁止输出 "2020-09-13T12:26:40.123Z"
        assertEquals("2020-09-13T12:26:40Z", formatRfc3339Millis(1_600_000_000_123L))
    }

    @Test
    fun formatMatchesSecondPrecisionPattern() {
        val out = formatRfc3339Millis(1_700_000_000_999L)
        assertTrue("输出必须匹配「只到秒」的正则：$out", secondPrecisionPattern.matches(out))
        assertFalse("输出不得含小数秒：$out", out.contains('.'))
    }

    @Test
    fun formatOfWholeSecondIsUnchanged() {
        // 整秒输入本就不带小数部分，截断后必须与改造前完全一致
        val out = formatRfc3339Millis(1_600_000_000_000L)
        assertEquals("2020-09-13T12:26:40Z", out)
    }

    @Test
    fun formatThenParseRoundTripsToTruncatedSecond() {
        // 往返后应得到「去掉毫秒」的值，证明截断是幂等且可逆的（就秒精度而言）
        val millis = 1_600_000_000_123L
        val truncated = 1_600_000_000_000L
        assertEquals(truncated, parseRfc3339Millis(formatRfc3339Millis(millis)))

        val another = 1_700_000_000_999L
        assertEquals(1_700_000_000_000L, parseRfc3339Millis(formatRfc3339Millis(another)))
    }
}
