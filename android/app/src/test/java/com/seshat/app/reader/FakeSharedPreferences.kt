package com.seshat.app.reader

import android.content.SharedPreferences

/**
 * JVM 单测用的内存版 [SharedPreferences]。
 *
 * 不依赖 Robolectric：`android.content.SharedPreferences` 是纯接口，
 * 单测 classpath 上的 android.jar stub 可正常加载接口，实现类自行提供全部行为。
 *
 * **线程安全**：真实 Android 的 SharedPreferences 实现本身是线程安全的，这里必须同构——
 * 否则并发测试（`PendingDeletesTest` / `AnnotationStoreTest` 的多线程用例）暴露的会是本
 * 测试替身的 `HashMap` 竞态，而不是被测 store 的 read-modify-write 竞态。所有读写方法都走
 * `@Synchronized`（锁的是本实例，编辑器的 `apply()` 复用同一把锁）。
 */
class FakeSharedPreferences : SharedPreferences {

    private val values = LinkedHashMap<String, Any?>()

    @Synchronized
    override fun getAll(): MutableMap<String, Any?> = LinkedHashMap(values)

    @Synchronized
    override fun getString(key: String, defValue: String?): String? =
        values[key] as? String ?: defValue

    @Synchronized
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        @Suppress("UNCHECKED_CAST")
        (values[key] as? MutableSet<String>) ?: defValues

    @Synchronized
    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue

    @Synchronized
    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue

    @Synchronized
    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue

    @Synchronized
    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        values[key] as? Boolean ?: defValue

    @Synchronized
    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = FakeEditor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    /** 直写内存（测试直接塞入损坏 JSON 用）。 */
    @Synchronized
    fun putRaw(key: String, value: String?) {
        values[key] = value
    }

    /** 编辑器的写入落地：与读方法共用本实例的锁（模拟真实实现的线程安全落盘）。 */
    @Synchronized
    private fun commitPending(pending: Map<String, Any?>, clearRequested: Boolean) {
        if (clearRequested) values.clear()
        pending.forEach { (key, value) ->
            if (value === REMOVE) values.remove(key) else values[key] = value
        }
    }

    private inner class FakeEditor : SharedPreferences.Editor {

        private val pending = LinkedHashMap<String, Any?>()
        private var clearRequested = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor = apply {
            pending[key] = value
        }

        override fun putStringSet(
            key: String,
            values: MutableSet<String>?,
        ): SharedPreferences.Editor = apply { pending[key] = values }

        override fun putInt(key: String, value: Int): SharedPreferences.Editor = apply {
            pending[key] = value
        }

        override fun putLong(key: String, value: Long): SharedPreferences.Editor = apply {
            pending[key] = value
        }

        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = apply {
            pending[key] = value
        }

        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = apply {
            pending[key] = value
        }

        override fun remove(key: String): SharedPreferences.Editor = apply {
            pending.remove(key)
            pending[key] = REMOVE
        }

        override fun clear(): SharedPreferences.Editor = apply { clearRequested = true }

        override fun commit(): Boolean {
            apply()
            return true
        }

        override fun apply() {
            commitPending(pending, clearRequested)
        }
    }

    private companion object {
        /** remove 的哨兵值（避免与 null 值混淆）。 */
        val REMOVE = Any()
    }
}
