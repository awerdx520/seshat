package com.seshat.app.settings

import java.net.URI
import java.net.URISyntaxException

/** 服务端地址校验失败的原因（文案由 UI 层映射到 `strings.xml`）。 */
enum class UrlError {
    TOO_LONG,
    MALFORMED,
    UNSUPPORTED_SCHEME,
    MISSING_HOST,
    USER_INFO_NOT_ALLOWED,
    QUERY_NOT_ALLOWED,
}

/** 访问令牌校验失败的原因。 */
enum class TokenError {
    EMPTY,

    /** 令牌含非法字符（换行 / NUL / 空格 / 非 ASCII 等）。 */
    ILLEGAL_CHARS,
}

/** 服务端地址校验结果。 */
sealed interface UrlValidation {
    /** 校验通过，[normalized] 为可直接保存的规范化地址。 */
    data class Ok(val normalized: String) : UrlValidation

    /** 服务端为可选配置：用户留空（合法，表示仅本地使用）。 */
    data object Empty : UrlValidation

    /** 校验失败。 */
    data class Error(val reason: UrlError) : UrlValidation
}

/** 访问令牌校验结果。 */
sealed interface TokenValidation {
    /** 留空且本地已有令牌：保持原值不变。 */
    data object Unchanged : TokenValidation

    /** 使用新令牌（已去首尾空白）。 */
    data class Replace(val token: String) : TokenValidation

    /** 校验失败。 */
    data class Error(val reason: TokenError) : TokenValidation
}

/**
 * 设置页的输入校验（纯逻辑，无 Android 依赖，可在 JVM 单测中验证）。
 *
 * 安全约束（M9.1 安全加固）：
 * - **默认仅接受 https**——明文 http 会把 Bearer / Basic 凭据暴露在网络中，与本项目
 *   「传输层由反向代理终止 TLS」的威胁模型冲突。仅 debug 构建传 `allowHttp = true`
 *   放行 http（本机 adb reverse 真机联调），release 恒为 https-only。
 * - **拒绝 userinfo**（`https://real.com@evil.com` 会让用户误判目标主机）。
 * - **拒绝查询参数与锚点**——配置项是服务端根地址，携带参数会污染后续 API 路径拼接。
 * - 只做最小规范化（补 scheme、去末尾斜杠），**不重组 URL**。
 *
 * 服务端为**可选**配置：地址留空是合法状态（[UrlValidation.Empty]），表示仅本地使用、
 * 不做增量同步；因此「留空」与「格式非法」必须区分，后者才拦截保存。
 */
object SettingsValidator {

    /** 地址长度上限，防止超长值写入 prefs 并拼进请求。 */
    private const val MAX_URL_LENGTH = 2048

    /** 访问令牌允许的字符集（RFC 6750 b64token 的近似：可见 ASCII，不含空格）。 */
    private val TOKEN_CHARS = Regex("^[\\u0021-\\u007E]+$")

    /**
     * 校验服务端地址。
     *
     * @param raw 用户输入（可为 `null`）。
     * @param allowHttp 是否允许明文 http（**仅 debug 构建**为 true，用于本机 adb reverse 联调）；
     *   默认 false → https-only（与既有语义、单测一致）。
     *   注意：本开关只放宽 scheme，主机名白名单由 debug 的 `network_security_config.xml` 负责。
     */
    fun validateServerUrl(raw: String?, allowHttp: Boolean = false): UrlValidation {
        val trimmed = raw?.trim().orEmpty()
        // 地址留空是合法状态（服务端可选，表示仅本地使用），与「格式非法」区分开
        if (trimmed.isEmpty()) return UrlValidation.Empty
        if (trimmed.length > MAX_URL_LENGTH) return UrlValidation.Error(UrlError.TOO_LONG)

        val withScheme = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        // 先判 scheme：明文 http 会把访问令牌暴露在网络中，与「传输层由反代终止 TLS」冲突；
        // 仅 debug 构建传 allowHttp=true 放行 http，其它 scheme 一律拒绝
        val scheme = withScheme.substringBefore("://").lowercase()
        if (scheme != "https" && !(allowHttp && scheme == "http")) {
            return UrlValidation.Error(UrlError.UNSUPPORTED_SCHEME)
        }

        val uri = try {
            URI(withScheme)
        } catch (e: URISyntaxException) {
            // "https://" 这类空 authority 在 java.net.URI 中属语法错误，语义上归为「缺少主机名」
            val reason = if (withScheme.substringAfter("://").isEmpty()) {
                UrlError.MISSING_HOST
            } else {
                UrlError.MALFORMED
            }
            return UrlValidation.Error(reason)
        }

        if (uri.host.isNullOrEmpty()) return UrlValidation.Error(UrlError.MISSING_HOST)
        if (!uri.userInfo.isNullOrEmpty()) return UrlValidation.Error(UrlError.USER_INFO_NOT_ALLOWED)
        if (uri.rawQuery != null || uri.rawFragment != null) {
            return UrlValidation.Error(UrlError.QUERY_NOT_ALLOWED)
        }
        if (uri.port !in -1..65535) return UrlValidation.Error(UrlError.MALFORMED)

        return UrlValidation.Ok(withScheme.trimEnd('/'))
    }

    /**
     * 校验访问令牌。
     *
     * @param raw 用户输入（可为 `null`）。
     * @param hasExisting 本地是否已保存过令牌。
     */
    fun validateToken(raw: String?, hasExisting: Boolean): TokenValidation {
        val trimmed = raw?.trim().orEmpty()
        // 先判字符集：OkHttp 构造请求头时遇到换行 / NUL / 非 ASCII 会抛 IllegalArgumentException
        if (trimmed.isNotEmpty() && !TOKEN_CHARS.matches(trimmed)) {
            return TokenValidation.Error(TokenError.ILLEGAL_CHARS)
        }
        return when {
            trimmed.isNotEmpty() -> TokenValidation.Replace(trimmed)
            hasExisting -> TokenValidation.Unchanged
            else -> TokenValidation.Error(TokenError.EMPTY)
        }
    }
}
