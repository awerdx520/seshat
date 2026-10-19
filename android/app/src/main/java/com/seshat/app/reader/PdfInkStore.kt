package com.seshat.app.reader

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * 手写笔迹的本地持久化（SharedPreferences + JSON）。
 *
 * 键为 `pdf_ink_<docId>`，与 [PdfAnnotationStore]（`pdf_annotations_*`）和
 * [PdfProgressStore]（`pdf_progress_*`）共用 `pdf_reader` prefs 文件但命名空间隔离。
 *
 * @param read 读取键对应字符串（不存在返回 `null`）。
 * @param write 写入键值对。
 * @param json JSON 编解码器（默认忽略未知字段，容忍未来字段扩展）。
 * @param keys 枚举该 prefs 文件的全部键（旧键清理用；默认空实现 → 清理为无操作）。
 * @param remove 删除单个键（旧键清理用；默认空实现 → 清理为无操作）。
 */
class PdfInkStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
    private val json: Json = defaultJson(),
    private val keys: () -> Set<String> = { emptySet() },
    private val remove: (String) -> Unit = {},
) {

    /** 读取整份文档（无记录或 JSON 损坏时返回空文档）。 */
    fun document(docId: String): PdfInkDocument {
        val raw = read(key(docId)) ?: return PdfInkDocument(documentId = docId)
        return runCatching { json.decodeFromString<PdfInkDocument>(raw) }
            .getOrDefault(PdfInkDocument(documentId = docId))
    }

    /** 某页的全部笔迹（按追加顺序）。 */
    fun strokes(docId: String, page: Int): List<InkStroke> =
        document(docId).pages.firstOrNull { it.page == page }?.strokes.orEmpty()

    /** 某页是否已有笔迹。 */
    fun hasInk(docId: String, page: Int): Boolean = strokes(docId, page).isNotEmpty()

    /** 文档的总笔迹数（跨页）。 */
    fun count(docId: String): Int = document(docId).pages.sumOf { it.strokes.size }

    /** 追加一笔到指定页。 */
    fun appendStroke(docId: String, page: Int, stroke: InkStroke) {
        val document = document(docId)
        val pages = document.pages.toMutableList()
        val index = pages.indexOfFirst { it.page == page }
        if (index >= 0) {
            pages[index] = pages[index].copy(strokes = pages[index].strokes + stroke)
        } else {
            pages.add(PdfInkPage(page = page, strokes = listOf(stroke)))
        }
        persist(docId, pages)
    }

    /** 撤销该页最后一笔；无笔迹时返回 `false`。 */
    fun undoLast(docId: String, page: Int): Boolean {
        val document = document(docId)
        val index = document.pages.indexOfFirst { it.page == page }
        if (index < 0) return false
        val strokes = document.pages[index].strokes
        if (strokes.isEmpty()) return false
        val pages = document.pages.toMutableList()
        val remaining = strokes.dropLast(1)
        // 撤销最后一笔后该页无笔迹 → 直接移除页条目，避免留下空页占位
        if (remaining.isEmpty()) pages.removeAt(index) else pages[index] = document.pages[index].copy(strokes = remaining)
        persist(docId, pages)
        return true
    }

    /** 清除该页全部笔迹。 */
    fun clearPage(docId: String, page: Int) {
        val document = document(docId)
        if (document.pages.none { it.page == page }) return
        persist(docId, document.pages.filterNot { it.page == page })
    }

    /**
     * 一次性清理本 store 前缀下的旧键（M7 之前以 pdf uri 作 docId）。
     *
     * 幂等纯清理：多次调用结果一致；是否只跑一次由调用方用 `legacy_cleared` 标记控制。
     * 旧数据**不迁移**（uid 映射需服务端 resolve，见 tech-debt）。
     *
     * @return 实际删除的键数量（未注入 [keys]/[remove] 时为 0）。
     */
    fun clearLegacy(): Int = LegacyKeys.clearByPrefix(PREFIX, keys, remove)

    /** 写回整份文档并刷新 [PdfInkDocument.updatedAt]。 */
    private fun persist(docId: String, pages: List<PdfInkPage>) {
        val updated = PdfInkDocument(
            documentId = docId,
            pages = pages,
            updatedAt = System.currentTimeMillis(),
        )
        write(key(docId), json.encodeToString(updated))
    }

    companion object {
        /** 与批注/进度共用同一 prefs 文件，键空间由前缀隔离。 */
        const val PREFS_NAME = "pdf_reader"

        /** 笔迹存储键前缀（PDF 命名空间，与 epub 隔离）。 */
        private const val PREFIX = "pdf_ink_"

        /** 存储键：`pdf_ink_<docId>`。 */
        fun key(docId: String): String = "$PREFIX$docId"

        /**
         * 默认 JSON 配置：
         * - `ignoreUnknownKeys`：容忍未来字段扩展；
         * - `encodeDefaults`：默认值（含 `style = PEN`）也写入，便于其它端读取；
         * - `coerceInputValues`：未知枚举值（如未来新增笔型被旧版读到）回退到字段默认值，不抛异常。
         */
        fun defaultJson(): Json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            coerceInputValues = true
        }
    }
}
