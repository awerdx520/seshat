package com.seshat.app.reader

/**
 * 旧键（M7 之前用 documentId 作键）判定。
 *
 * 旧键有两类形态：32 位十六进制（epub 内容哈希）与含 `:` 的 uri 字符串（pdf）。
 * 新键是服务端 uid（26 位 Crockford Base32，无 `:`、非 32 hex），两类判定都不会误命中。
 */
internal object LegacyKeys {
    /** 清理标记键的统一前缀：任何以此开头的键都不参与旧键清理（避免误删标记本身）。 */
    const val FLAG_PREFIX = "legacy_"

    /** 一次性清理的完成标记键（各 prefs 文件各自一份，语义互不干扰）。 */
    const val CLEARED_FLAG = FLAG_PREFIX + "cleared"

    /** 剥掉 store 前缀后的键体是否为旧键形态。 */
    fun isLegacyBase(base: String): Boolean =
        isSha256PrefixHex(base) || base.contains(':')

    /** 32 位十六进制（0-9a-fA-F，长度恰为 32）。 */
    fun isSha256PrefixHex(value: String): Boolean =
        value.length == 32 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }

    /** 26 位 Crockford Base32（服务端 uid 形态；仅用于防御性断言与测试）。 */
    fun isUid(value: String): Boolean {
        if (value.length != 26) return false
        return value.uppercase().all { it in '0'..'9' || (it in 'A'..'Z' && it !in "ILOU") }
    }

    /**
     * 通用「按 store 前缀剥壳 → 判旧键 → 删除」流程（注入式 Store 复用）。
     *
     * @param prefix 该 store 的键前缀（如 `pdf_progress_`）。
     * @param keys   枚举 prefs 全部键。
     * @param remove 删除单个键。
     * @return 实际删除的键数量。
     */
    fun clearByPrefix(prefix: String, keys: () -> Set<String>, remove: (String) -> Unit): Int {
        var removed = 0
        // keys() 返回快照（Set），遍历期间删除真实存储安全
        for (key in keys().toList()) {
            if (!key.startsWith(prefix)) continue
            if (!isLegacyBase(key.removePrefix(prefix))) continue
            remove(key)
            removed++
        }
        return removed
    }
}
