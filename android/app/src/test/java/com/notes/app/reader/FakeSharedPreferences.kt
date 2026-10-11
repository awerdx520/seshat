package com.notes.app.reader

import android.content.SharedPreferences

/**
 * JVM 单测用的内存版 [SharedPreferences]。
 *
 * 不依赖 Robolectric：`android.content.SharedPreferences` 是纯接口，
 * 单测 classpath 上的 android.jar stub 可正常加载接口，实现类自行提供全部行为。
 */
class FakeSharedPreferences : SharedPreferences {

    private val values = LinkedHashMap<String, Any?>()

    override fun getAll(): MutableMap<String, Any?> = LinkedHashMap(values)

    override fun getString(key: String, defValue: String?): String? =
        values[key] as? String ?: defValue

    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        @Suppress("UNCHECKED_CAST")
        (values[key] as? MutableSet<String>) ?: defValues

    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue

    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue

    override fun getBoolean(key: String, defValue: Boolean): Boolean =
        values[key] as? Boolean ?: defValue

    override fun contains(key: String): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = FakeEditor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    /** 直写内存（测试直接塞入损坏 JSON 用）。 */
    fun putRaw(key: String, value: String?) {
        values[key] = value
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
            if (clearRequested) values.clear()
            pending.forEach { (key, value) ->
                if (value === REMOVE) values.remove(key) else values[key] = value
            }
        }
    }

    private companion object {
        /** remove 的哨兵值（避免与 null 值混淆）。 */
        val REMOVE = Any()
    }
}
