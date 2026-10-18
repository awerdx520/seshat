package com.seshat.app.reader

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * PDF 设备本地批注。
 *
 * 字段与服务端批注模型（docs/api.md §4）对齐，便于后续 M3.4 REST 同步：
 * - [documentId] ↔ `document_id`
 * - [location]   ↔ `location`（PDF 侧取 `page:<n>`，1-based）
 * - [text]       ↔ `text`
 * - [createdAt] / [updatedAt] 为 epoch 毫秒（本地存储用；同步时由 M3.4 转为 RFC 3339）
 */
@Serializable
data class PdfAnnotation(
    val id: Long,
    val documentId: String,
    val location: String,
    val text: String,
    val createdAt: Long,
    val updatedAt: Long,
)

/**
 * PDF 批注持久化（设备本地，JSON 序列化）。
 *
 * 存储键为 `pdf_annotations_<docId>`，与 epub（M3.2）键空间隔离。
 * 通过注入读写函数避免直接依赖 `SharedPreferences`，核心逻辑可做 JVM 单测。
 *
 * @param read  读取键对应字符串（不存在返回 `null`）。
 * @param write 写入键值对。
 * @param json  JSON 编解码器（默认忽略未知字段，容忍未来字段扩展）。
 * @param keys  枚举该 prefs 文件的全部键（旧键清理用；默认空实现 → 清理为无操作）。
 * @param remove 删除单个键（旧键清理用；默认空实现 → 清理为无操作）。
 */
class PdfAnnotationStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
    private val json: Json = Json { ignoreUnknownKeys = true },
    private val keys: () -> Set<String> = { emptySet() },
    private val remove: (String) -> Unit = {},
) {
    /** 列出某文档的全部批注（按写入顺序）；无记录或 JSON 损坏时返回空列表。 */
    fun list(docId: String): List<PdfAnnotation> {
        val raw = read(key(docId)) ?: return emptyList()
        return runCatching { json.decodeFromString<List<PdfAnnotation>>(raw) }
            .getOrDefault(emptyList())
    }

    /** 追加一条批注。 */
    fun add(annotation: PdfAnnotation) {
        val next = list(annotation.documentId) + annotation
        write(key(annotation.documentId), json.encodeToString(next))
    }

    /** 某文档的批注条数。 */
    fun count(docId: String): Int = list(docId).size

    /** 生成下一个本地批注 id（单调递增，供 M3.4 同步前临时使用）。 */
    fun nextId(docId: String): Long = (list(docId).maxOfOrNull { it.id } ?: 0L) + 1L

    /**
     * 一次性清理本 store 前缀下的旧键（M7 之前以 pdf uri 作 docId）。
     *
     * 幂等纯清理：多次调用结果一致；是否只跑一次由调用方用 `legacy_cleared` 标记控制。
     * 旧数据**不迁移**（uid 映射需服务端 resolve，见 tech-debt）。
     *
     * @return 实际删除的键数量（未注入 [keys]/[remove] 时为 0）。
     */
    fun clearLegacy(): Int = LegacyKeys.clearByPrefix(PREFIX, keys, remove)

    companion object {
        /** 批注存储键前缀（PDF 命名空间，与 epub 隔离）。 */
        private const val PREFIX = "pdf_annotations_"

        /** 批注存储键。 */
        fun key(docId: String): String = "$PREFIX$docId"
    }
}
