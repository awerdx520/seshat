package com.seshat.app.settings

import com.seshat.app.sync.SeshatConfig

/** 保存结果。 */
sealed interface SaveResult {
    /** 保存成功。 */
    data object Ok : SaveResult

    /** 加密存储不可用：拒绝写入机密（令牌保持原值，地址也不写入，避免半配置）。 */
    data object EncryptionUnavailable : SaveResult

    /** 调用方传了空串令牌（语义不清，应改用 `null` 表示保留或 `clearAuthToken()` 表示清除）。 */
    data object EmptyToken : SaveResult
}

/**
 * 同步配置的读写门面。
 *
 * 构造接受读写函数而非 `SecurePrefs` 实例，使核心逻辑可在 JVM 单测中注入内存实现
 * （与 `PdfProgressStore(read, write)` 同风格）。生产环境由设置页注入
 * `SecurePrefs.getString` / `putString` / `putSecret`。
 *
 * 保存顺序为**先令牌后地址**：令牌写入失败时地址不会被改动，避免出现「新地址 + 旧令牌」
 * 把有效令牌发往错误主机的组合。
 *
 * 机密**只能**经 [writeSecret] 通道写入；[write] 仅用于非机密项（服务端地址、清除令牌的空串）。
 * [writeSecret] 为必填参数且无默认值：漏传会在编译期暴露，而不是在运行时静默写入明文
 * （M9.1 安全复审 N2 修复）。
 */
class SettingsStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
    /** 机密写入通道；由 `SecurePrefs.putSecret` 实现，加密不可用时必须返回 false。 */
    private val writeSecret: (String, String) -> Boolean,
) {

    /** 读取服务端地址；未配置或为空白时返回 `null`。 */
    fun loadServerUrl(): String? =
        read(KEY_SERVER_URL)?.trim()?.takeIf { it.isNotEmpty() }

    /** 本地是否已保存访问令牌（仅返回布尔，不暴露令牌本身）。 */
    fun hasAuthToken(): Boolean = !read(KEY_AUTH_TOKEN).isNullOrBlank()

    /**
     * 保存服务端地址，并可同时更新令牌。
     *
     * @param token 非 `null` 时覆盖令牌；`null` 表示保留原值。空串会被拒绝（见 [SaveResult.EmptyToken]）。
     */
    fun save(serverUrl: String, token: String?): SaveResult {
        if (token != null) {
            if (token.isEmpty()) return SaveResult.EmptyToken
            if (!writeSecret(KEY_AUTH_TOKEN, token)) return SaveResult.EncryptionUnavailable
        }
        write(KEY_SERVER_URL, serverUrl)
        return SaveResult.Ok
    }

    /**
     * 仅更新访问令牌（不写服务端地址）。
     *
     * 用于「服务端为可选」场景：用户只填令牌、地址留空。
     *
     * @return 是否写入成功（空串或加密不可用返回 `false`）。
     */
    fun saveTokenOnly(token: String): Boolean {
        if (token.isEmpty()) return false
        return writeSecret(KEY_AUTH_TOKEN, token)
    }

    /**
     * 移除本地保存的访问令牌（保留服务端地址）。
     *
     * 优先走机密通道（加密可用时）；加密不可用时退回普通通道清除（写入空串，不涉及机密内容）。
     *
     * @return 是否已确认清除成功（以清除后 [hasAuthToken] 为 false 为准）。
     */
    fun clearAuthToken(): Boolean {
        if (writeSecret(KEY_AUTH_TOKEN, "")) return true
        write(KEY_AUTH_TOKEN, "")
        return !hasAuthToken()
    }

    /** 组装同步配置；地址或令牌缺任一时返回 `null`。 */
    fun toConfig(): SeshatConfig? {
        val serverUrl = loadServerUrl() ?: return null
        val token = read(KEY_AUTH_TOKEN)?.trim().orEmpty()
        if (token.isEmpty()) return null
        return SeshatConfig(serverUrl = serverUrl, token = token)
    }

    companion object {
        /** 服务端地址键名；值必须与 `SecurePrefs.KEY_SERVER_URL` 一致（由单测断言）。 */
        const val KEY_SERVER_URL = "server_url"

        /** 访问令牌键名；值必须与 `SecurePrefs.KEY_AUTH_TOKEN` 一致（由单测断言）。 */
        const val KEY_AUTH_TOKEN = "auth_token"
    }
}
