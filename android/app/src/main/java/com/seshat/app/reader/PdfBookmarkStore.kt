package com.seshat.app.reader

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** 单本文档的书签集合（序列化载体）。 */
@Serializable
private data class PdfBookmarkDocument(
    val documentId: String,
    val bookmarks: List<PdfBookmark> = emptyList(),
)

/**
 * PDF 书签的本地持久化（SharedPreferences + JSON，M10.10）。
 *
 * 键为 `pdf_bookmark_<docId>`，与批注/进度/笔迹共用 `pdf_reader` prefs 文件但命名空间隔离。
 * JSON 配置沿用 [PdfInkStore.defaultJson] 的语义：忽略未知字段、序列化默认值、未知枚举回退。
 *
 * @param read 读取键对应字符串（不存在返回 `null`）。
 * @param write 写入键值对。
 * @param json JSON 编解码器（默认与笔迹/批注/进度一致）。
 * @param keys 枚举该 prefs 文件的全部键（旧键清理用；默认空实现 → 清理为无操作）。
 * @param remove 删除单个键（旧键清理用；默认空实现 → 清理为无操作）。
 */
class PdfBookmarkStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
    private val json: Json = PdfInkStore.defaultJson(),
    private val keys: () -> Set<String> = { emptySet() },
    private val remove: (String) -> Unit = {},
) {

    /** 该文档的全部书签（按页升序；无记录或 JSON 损坏返回空表）。 */
    fun list(docId: String): List<PdfBookmark> {
        val raw = read(key(docId)) ?: return emptyList()
        return runCatching { json.decodeFromString<PdfBookmarkDocument>(raw) }
            .getOrNull()
            ?.bookmarks
            ?.let(Bookmarks::sorted)
            .orEmpty()
    }

    /** 该页是否已有书签。 */
    fun has(docId: String, page: Int): Boolean = Bookmarks.has(list(docId), page)

    /** 添加书签；同页已存在返回 `false`（不重复写）。 */
    fun add(docId: String, bookmark: PdfBookmark): Boolean {
        val (updated, added) = Bookmarks.add(list(docId), bookmark)
        if (!added) return false
        persist(docId, updated)
        return true
    }

    /** 移除该页书签；该页无书签时不做写操作。 */
    fun remove(docId: String, page: Int) {
        val current = list(docId)
        val updated = Bookmarks.remove(current, page)
        // 无变化则不写，避免无意义的 prefs 写入
        if (updated.size == current.size) return
        persist(docId, updated)
    }

    /**
     * 一次性清理本 store 前缀下的旧键（与其它 store 一致，供 `clearLegacy()` 调用）。
     *
     * @return 实际删除的键数量（未注入 [keys]/[remove] 时为 0）。
     */
    fun clearLegacy(): Int = LegacyKeys.clearByPrefix(PREFIX, keys, remove)

    /** 写回该文档的书签集合。 */
    private fun persist(docId: String, bookmarks: List<PdfBookmark>) {
        write(key(docId), json.encodeToString(PdfBookmarkDocument(documentId = docId, bookmarks = bookmarks)))
    }

    companion object {
        /** 与批注/进度/笔迹共用同一 prefs 文件，键空间由前缀隔离。 */
        const val PREFS_NAME = "pdf_reader"

        /** 书签存储键前缀（PDF 命名空间）。 */
        private const val PREFIX = "pdf_bookmark_"

        /** 存储键：`pdf_bookmark_<docId>`。 */
        fun key(docId: String): String = "$PREFIX$docId"
    }
}
