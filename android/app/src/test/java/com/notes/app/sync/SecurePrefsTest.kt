package com.notes.app.sync

import com.notes.app.reader.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SecurePrefs] 的键读写与明文→加密迁移逻辑单测（纯 JVM）。
 *
 * EncryptedSharedPreferences 依赖 Android Keystore，无法在 JVM 单测中实例化，
 * 因此这里以内存 [FakeSharedPreferences] 注入，验证封装层的读写与迁移语义
 * （加密本身由 androidx.security 库与设备验证覆盖）。
 */
class SecurePrefsTest {

    private val encrypted = FakeSharedPreferences()
    private val legacy = FakeSharedPreferences()

    @Test
    fun putThenGetReturnsValue() {
        val prefs = SecurePrefs(encrypted, legacy, isEncrypted = true)
        prefs.putString(SecurePrefs.KEY_AUTH_TOKEN, "secret-token")

        assertEquals("secret-token", prefs.getString(SecurePrefs.KEY_AUTH_TOKEN))
    }

    @Test
    fun getMissingReturnsDefault() {
        val prefs = SecurePrefs(encrypted, legacy, isEncrypted = true)

        assertNull(prefs.getString(SecurePrefs.KEY_SERVER_URL))
        assertEquals("fallback", prefs.getString(SecurePrefs.KEY_SERVER_URL, "fallback"))
    }

    @Test
    fun migratesLegacyValueAndClearsPlaintext() {
        legacy.putRaw(SecurePrefs.KEY_AUTH_TOKEN, "legacy-token")
        val prefs = SecurePrefs(encrypted, legacy, isEncrypted = true)

        val value = prefs.getString(SecurePrefs.KEY_AUTH_TOKEN)

        assertEquals("legacy-token", value)
        // 已迁移到加密存储
        assertEquals("legacy-token", encrypted.getString(SecurePrefs.KEY_AUTH_TOKEN, null))
        // 明文旧值已清除
        assertFalse(legacy.contains(SecurePrefs.KEY_AUTH_TOKEN))
    }

    @Test
    fun encryptedValueTakesPrecedenceOverLegacy() {
        encrypted.putRaw(SecurePrefs.KEY_SERVER_URL, "https://secure.example.com")
        legacy.putRaw(SecurePrefs.KEY_SERVER_URL, "https://plain.example.com")
        val prefs = SecurePrefs(encrypted, legacy, isEncrypted = true)

        assertEquals("https://secure.example.com", prefs.getString(SecurePrefs.KEY_SERVER_URL))
        // 未发生迁移，旧值保持原样
        assertEquals("https://plain.example.com", legacy.getString(SecurePrefs.KEY_SERVER_URL, null))
    }

    @Test
    fun migrationCoversServerUrlAndToken() {
        legacy.putRaw(SecurePrefs.KEY_SERVER_URL, "https://notes.example.com")
        legacy.putRaw(SecurePrefs.KEY_AUTH_TOKEN, "tok")
        val prefs = SecurePrefs(encrypted, legacy, isEncrypted = true)

        assertEquals("https://notes.example.com", prefs.getString(SecurePrefs.KEY_SERVER_URL))
        assertEquals("tok", prefs.getString(SecurePrefs.KEY_AUTH_TOKEN))
        assertTrue(legacy.getAll().isEmpty())
    }

    @Test
    fun fallbackInstanceHasNoLegacySource() {
        // 加密初始化失败的回退实例：legacy 为 null，直接读写普通 prefs。
        val fallback = FakeSharedPreferences()
        val prefs = SecurePrefs(fallback, null, isEncrypted = false)

        assertFalse(prefs.isEncrypted)
        prefs.putString(SecurePrefs.KEY_AUTH_TOKEN, "t")
        assertEquals("t", prefs.getString(SecurePrefs.KEY_AUTH_TOKEN))
    }
}
