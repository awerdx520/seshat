package com.seshat.app.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/**
 * [SettingsValidator] 的纯逻辑单测：地址规范化、https 强制与令牌规则。
 *
 * 断言的是 [UrlError] / [TokenError] 枚举而非文案，避免文案调整导致测试脆弱。
 */
class SettingsValidatorTest {

    /** 断言地址校验通过且规范化结果等于 [expected]。 */
    private fun assertUrlOk(expected: String, raw: String) {
        when (val result = SettingsValidator.validateServerUrl(raw)) {
            is UrlValidation.Ok -> assertEquals("输入：$raw", expected, result.normalized)
            is UrlValidation.Error -> fail("输入：$raw 期望通过，实际失败：${result.reason}")
            UrlValidation.Empty -> fail("输入：$raw 期望通过，实际为留空（Empty）")
        }
    }

    /** 断言地址校验失败且原因等于 [reason]。 */
    private fun assertUrlError(reason: UrlError, raw: String?) {
        when (val result = SettingsValidator.validateServerUrl(raw)) {
            is UrlValidation.Ok -> fail("输入：$raw 期望失败，实际通过：${result.normalized}")
            is UrlValidation.Error -> assertEquals("输入：$raw", reason, result.reason)
            UrlValidation.Empty -> fail("输入：$raw 期望失败，实际为留空（Empty）")
        }
    }

    /** 断言地址被视为「留空」（合法状态，非错误）。 */
    private fun assertUrlEmpty(raw: String?) {
        assertEquals("输入：$raw", UrlValidation.Empty, SettingsValidator.validateServerUrl(raw))
    }

    @Test
    fun blankUrlReturnsEmpty() {
        assertUrlEmpty("")
    }

    @Test
    fun whitespaceUrlReturnsEmpty() {
        assertUrlEmpty("   ")
    }

    @Test
    fun emptyStringIsAllowedAsEmpty() {
        // 服务端可选：空串与 null 都表示「未配置服务端」，属合法状态而非错误
        assertUrlEmpty("")
        assertUrlEmpty(null)
    }

    @Test
    fun blankStringIsAllowedAsEmpty() {
        // 含换行 / 制表符的纯空白同样视为留空
        assertUrlEmpty("\n\t ")
    }

    @Test
    fun missingSchemeGetsHttps() {
        assertUrlOk("https://seshat.example.com", "seshat.example.com")
    }

    @Test
    fun fullHttpsUrlKeptAsIs() {
        assertUrlOk("https://seshat.example.com", "https://seshat.example.com")
    }

    @Test
    fun trailingSlashRemoved() {
        assertUrlOk("https://seshat.example.com", "https://seshat.example.com/")
    }

    @Test
    fun httpRejected() {
        // 明文 http 会把访问令牌暴露在网络中，仅接受 https。
        assertUrlError(UrlError.UNSUPPORTED_SCHEME, "http://192.168.1.10:8080")
    }

    @Test
    fun ftpRejected() {
        assertUrlError(UrlError.UNSUPPORTED_SCHEME, "ftp://a.com")
    }

    @Test
    fun portKept() {
        assertUrlOk("https://a.com:8443", "https://a.com:8443")
    }

    @Test
    fun pathKept() {
        assertUrlOk("https://a.com/seshat", "https://a.com/seshat")
    }

    @Test
    fun pathTrailingSlashRemoved() {
        assertUrlOk("https://a.com/seshat", "https://a.com/seshat/")
    }

    @Test
    fun schemeCaseInsensitive() {
        // scheme 大小写不敏感可接受；normalized 保留用户输入原样（不重组 URL）
        assertUrlOk("HTTPS://a.com", "HTTPS://a.com")
    }

    @Test
    fun emptyHostReturnsMissingHost() {
        assertUrlError(UrlError.MISSING_HOST, "https://")
    }

    @Test
    fun pathWithoutHostReturnsMissingHost() {
        assertUrlError(UrlError.MISSING_HOST, "https:///path")
    }

    @Test
    fun userInfoRejected() {
        // https://real.com@evil.com 实际主机是 evil.com，用户极易误判目标。
        assertUrlError(UrlError.USER_INFO_NOT_ALLOWED, "https://real.com@evil.com")
    }

    @Test
    fun queryRejected() {
        assertUrlError(UrlError.QUERY_NOT_ALLOWED, "https://a.com?x=1")
    }

    @Test
    fun fragmentRejected() {
        assertUrlError(UrlError.QUERY_NOT_ALLOWED, "https://a.com#frag")
    }

    @Test
    fun tooLongRejected() {
        assertUrlError(UrlError.TOO_LONG, "https://a.com/" + "a".repeat(2100))
    }

    @Test
    fun malformedRejected() {
        // 空格在 URI 中非法
        assertUrlError(UrlError.MALFORMED, "https://a b.com")
    }

    @Test
    fun tokenReplaceWhenProvided() {
        val result = SettingsValidator.validateToken("  abc  ", hasExisting = true)
        when (result) {
            is TokenValidation.Replace -> assertEquals("abc", result.token)
            else -> fail("期望 Replace，实际：$result")
        }
    }

    @Test
    fun tokenUnchangedWhenBlankAndExisting() {
        val result = SettingsValidator.validateToken("  ", hasExisting = true)
        assertEquals(TokenValidation.Unchanged, result)
    }

    @Test
    fun tokenErrorWhenBlankAndMissing() {
        val result = SettingsValidator.validateToken(null, hasExisting = false)
        when (result) {
            is TokenValidation.Error -> assertEquals(TokenError.EMPTY, result.reason)
            else -> fail("期望 Error，实际：$result")
        }
    }

    @Test
    fun tokenWithNewlineRejected() {
        // 换行会让 OkHttp 构造 Authorization 头时抛 IllegalArgumentException（后台线程崩溃）
        val result = SettingsValidator.validateToken("abc\ndef", hasExisting = true)
        when (result) {
            is TokenValidation.Error -> assertEquals(TokenError.ILLEGAL_CHARS, result.reason)
            else -> fail("期望 Error(ILLEGAL_CHARS)，实际：$result")
        }
    }

    @Test
    fun tokenWithNonAsciiRejected() {
        // 非 ASCII 字符同样不满足 HTTP 头的可见 ASCII 约束
        val result = SettingsValidator.validateToken("中文令牌", hasExisting = false)
        when (result) {
            is TokenValidation.Error -> assertEquals(TokenError.ILLEGAL_CHARS, result.reason)
            else -> fail("期望 Error(ILLEGAL_CHARS)，实际：$result")
        }
    }
}
