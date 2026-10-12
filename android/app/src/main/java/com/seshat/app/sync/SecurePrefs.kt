package com.seshat.app.sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * 同步服务器配置的安全存储。
 *
 * 底层优先使用 [EncryptedSharedPreferences]：主密钥为 Android Keystore 中的
 * AES256_GCM 密钥，键用 AES256_SIV、值用 AES256_GCM 加密，因此 `auth_token`（服务端
 * `SESHAT_AUTH_TOKEN`，等同于账号密码）不再以明文落盘。
 *
 * 兼容与回退：
 * - 历史版本把配置明文写在 [LEGACY_PREFS]（普通 SharedPreferences）。首次读取时若加密
 *   存储缺该键而旧文件有值，会自动迁移到加密存储并清除明文旧值（见 [getString]）。
 * - 设备不支持硬件密钥库、密钥库损坏或文件解密失败时，[open] 回退到普通 SharedPreferences
 *   并记录告警，避免崩溃；此时 [isEncrypted] 为 `false`。
 *
 * 构造器接受 [SharedPreferences] 而非 [Context]，核心读写/迁移逻辑可在 JVM 单测中注入
 * 内存实现（[com.seshat.app.reader.FakeSharedPreferences]）验证。
 *
 * @property isEncrypted 底层是否真正使用了加密存储。
 */
class SecurePrefs internal constructor(
    private val prefs: SharedPreferences,
    private val legacy: SharedPreferences?,
    val isEncrypted: Boolean,
) {

    /**
     * 读取字符串值。
     *
     * 若加密存储中不存在 [key] 而旧明文存储中存在同名键，则把值迁移到加密存储、
     * 删除明文旧值，并返回该值；两者都没有时返回 [defValue]。
     */
    fun getString(key: String, defValue: String? = null): String? {
        val current = prefs.getString(key, null)
        if (current != null) return current

        val legacyValue = legacy?.getString(key, null) ?: return defValue
        // 迁移：写入加密存储后清除明文旧值，避免令牌以明文继续留存。
        prefs.edit().putString(key, legacyValue).apply()
        legacy.edit().remove(key).apply()
        return legacyValue
    }

    /** 写入字符串值到加密存储。 */
    fun putString(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    companion object {
        private const val TAG = "SecurePrefs"

        /** 加密 prefs 文件名（与旧明文文件区分）。 */
        const val ENCRYPTED_PREFS = "seshat_sync_secure"

        /** 旧版明文 prefs 文件名（迁移来源；新包名下无历史明文数据，仅保持命名一致）。 */
        const val LEGACY_PREFS = "seshat_sync"

        /** 服务端根地址键名。 */
        const val KEY_SERVER_URL = "server_url"

        /** 访问令牌键名（服务端 `SESHAT_AUTH_TOKEN`）。 */
        const val KEY_AUTH_TOKEN = "auth_token"

        /**
         * 打开同步配置存储。
         *
         * 优先创建 [EncryptedSharedPreferences]；初始化失败时回退到普通
         * [SharedPreferences]（[LEGACY_PREFS]）并告警，保证同步功能仍可用、历史明文配置仍可读。
         */
        fun open(context: Context): SecurePrefs {
            val legacy = context.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
            return try {
                val masterKey = MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                val encrypted = EncryptedSharedPreferences.create(
                    context,
                    ENCRYPTED_PREFS,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                )
                SecurePrefs(encrypted, legacy, isEncrypted = true)
            } catch (e: Exception) {
                // 设备不支持硬件密钥库 / 密钥库损坏 / 文件解密失败等。
                Log.w(TAG, "加密存储初始化失败，回退到普通 SharedPreferences", e)
                SecurePrefs(legacy, null, isEncrypted = false)
            }
        }
    }
}
