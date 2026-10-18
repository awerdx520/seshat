package com.seshat.app.settings

import com.seshat.app.sync.SecurePrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** [SettingsStore] 的读写门面测试：用内存 map 注入读写函数，无需 Android 环境。 */
class SettingsStoreTest {

    private val storage = mutableMapOf<String, String>()

    /**
     * 构造指向内存 map 的 store。
     *
     * [writeSecret] 必填（无默认值）；默认实现写入 map 并返回 true，模拟加密存储可用。
     */
    private fun newStore(writeSecret: (String, String) -> Boolean = defaultWriteSecret): SettingsStore =
        SettingsStore(
            read = { key -> storage[key] },
            write = { key, value -> storage[key] = value },
            writeSecret = writeSecret,
        )

    /** 默认机密通道：写入内存 map 并报告成功（模拟加密存储可用）。 */
    private val defaultWriteSecret: (String, String) -> Boolean = { key, value ->
        storage[key] = value
        true
    }

    @Test
    fun emptyStoreReturnsNulls() {
        val store = newStore()
        assertNull(store.loadServerUrl())
        assertFalse(store.hasAuthToken())
        assertNull(store.toConfig())
    }

    @Test
    fun saveThenLoad() {
        val store = newStore()
        assertEquals(SaveResult.Ok, store.save("https://a.com", "tok"))
        assertEquals("https://a.com", store.loadServerUrl())
        assertTrue(store.hasAuthToken())
    }

    @Test
    fun saveWithoutTokenKeepsExisting() {
        val store = newStore()
        store.save("https://a.com", "tok")
        store.save("https://b.com", null)
        assertEquals("https://b.com", store.loadServerUrl())
        assertTrue(store.hasAuthToken())
    }

    @Test
    fun blankServerUrlReturnsNull() {
        storage[SecurePrefs.KEY_SERVER_URL] = "   "
        assertNull(newStore().loadServerUrl())
    }

    @Test
    fun toConfigRequiresBoth() {
        storage[SecurePrefs.KEY_SERVER_URL] = "https://a.com"
        assertNull(newStore().toConfig())
    }

    @Test
    fun toConfigBuildsConfig() {
        storage[SecurePrefs.KEY_SERVER_URL] = "https://a.com"
        storage[SecurePrefs.KEY_AUTH_TOKEN] = "tok"
        val config = newStore().toConfig()
        assertEquals("https://a.com", config?.serverUrl)
        assertEquals("tok", config?.token)
        assertEquals("/", config?.remoteDir)
    }

    @Test
    fun toConfigRequiresUrl() {
        storage[SecurePrefs.KEY_AUTH_TOKEN] = "tok"
        assertNull(newStore().toConfig())
    }

    @Test
    fun emptyTokenRejected() {
        val store = newStore()
        // 空串令牌语义不清：应拒绝，且不得写入地址（避免半配置）
        assertEquals(SaveResult.EmptyToken, store.save("https://a.com", ""))
        assertNull(store.loadServerUrl())
    }

    @Test
    fun secretWriteFailureAbortsUrlWrite() {
        // 加密存储不可用时 writeSecret 返回 false：地址与令牌都不得写入
        val store = newStore(writeSecret = { _, _ -> false })
        assertEquals(SaveResult.EncryptionUnavailable, store.save("https://a.com", "tok"))
        assertNull(store.loadServerUrl())
        assertFalse(store.hasAuthToken())
    }

    @Test
    fun saveTokenOnlyWritesToken() {
        val store = newStore()
        storage[SettingsStore.KEY_SERVER_URL] = "https://keep.example.com"

        // 只写令牌：地址必须保持原值不变
        assertTrue(store.saveTokenOnly("tok"))
        assertEquals("tok", storage[SettingsStore.KEY_AUTH_TOKEN])
        assertEquals("https://keep.example.com", storage[SettingsStore.KEY_SERVER_URL])
    }

    @Test
    fun saveTokenOnlyRejectedWhenSecretUnwritable() {
        // 加密存储不可用：拒绝写入，且不得落到任何通道
        val store = newStore(writeSecret = { _, _ -> false })

        assertFalse(store.saveTokenOnly("tok"))
        assertNull(storage[SettingsStore.KEY_AUTH_TOKEN])
    }

    @Test
    fun saveTokenOnlyRejectsEmpty() {
        // 空串令牌语义不清（清除请走 clearAuthToken），必须拒绝
        val store = newStore()

        assertFalse(store.saveTokenOnly(""))
        assertNull(storage[SettingsStore.KEY_AUTH_TOKEN])
    }

    @Test
    fun clearAuthTokenRemovesToken() {
        val store = newStore()
        store.save("https://a.com", "tok")
        assertTrue(store.hasAuthToken())

        store.clearAuthToken()

        assertFalse(store.hasAuthToken())
        // 地址保留
        assertEquals("https://a.com", store.loadServerUrl())
    }

    @Test
    fun clearAuthTokenReturnsTrueAndRemovesToken() {
        val store = newStore()
        store.save("https://a.com", "tok")
        assertTrue(store.hasAuthToken())

        // 加密通道可用：清除成功并返回 true
        assertTrue(store.clearAuthToken())
        assertFalse(store.hasAuthToken())
    }

    @Test
    fun clearAuthTokenFallsBackWhenSecretUnwritable() {
        // 加密存储不可用（writeSecret 恒 false），但本地已有令牌：退回普通通道写空串仍应清除成功
        storage[SettingsStore.KEY_AUTH_TOKEN] = "tok"
        val store = newStore(writeSecret = { _, _ -> false })
        assertTrue(store.hasAuthToken())

        assertTrue(store.clearAuthToken())
        assertFalse(store.hasAuthToken())
    }

    @Test
    fun keyConstantsMatchSecurePrefsValues() {
        // 键名与 SecurePrefs 必须一致，否则两处读写会错位
        assertEquals("server_url", SettingsStore.KEY_SERVER_URL)
        assertEquals("auth_token", SettingsStore.KEY_AUTH_TOKEN)
        assertEquals(SecurePrefs.KEY_SERVER_URL, SettingsStore.KEY_SERVER_URL)
        assertEquals(SecurePrefs.KEY_AUTH_TOKEN, SettingsStore.KEY_AUTH_TOKEN)
    }
}
