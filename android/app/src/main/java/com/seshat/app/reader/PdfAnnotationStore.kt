package com.seshat.app.reader

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * PDF 设备本地批注。
 *
 * 字段与服务端批注模型（keystone 仓 docs/api.md §4）对齐，便于后续 M3.4 REST 同步：
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
    /** 批注种类：`note` / `highlight` / `ink`（对齐服务端 v8 `kind`；旧 JSON 缺键按 `note`）。 */
    val kind: String = "note",
    /** 选中原文（对齐服务端 v8 `selected_text`；旧 JSON 缺键按空串）。 */
    val selectedText: String = "",
    /**
     * 服务端分配 id（`null` 表示尚未上传）。
     *
     * 本地 [id] 由 store 自行分配，**绝不复用**服务端 id，两者互不污染。
     */
    val serverId: Long? = null,
    /**
     * 新增或修改尚未上行。
     *
     * 仅表示「需要 push」；删除**不复用**该标记，走独立的待删队列（PendingDeletes）。
     */
    val dirty: Boolean = false,
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
    /** 列出某文档的全部批注（按写入顺序）；无记录或 JSON 损坏时返回空列表（副本）。 */
    @Synchronized
    fun list(docId: String): List<PdfAnnotation> {
        val raw = read(key(docId)) ?: return emptyList()
        return runCatching { json.decodeFromString<List<PdfAnnotation>>(raw) }
            .getOrDefault(emptyList())
    }

    /**
     * 追加一条批注，返回落库后的对象。
     *
     * `id <= 0` 时按 [nextId] 语义（当前最大 id + 1）分配本地 id——服务端拉取后入库的记录
     * 不再复用服务端 id（服务端 id 只写入 [PdfAnnotation.serverId]），否则 id 恒为 0。
     *
     * `@Synchronized`：写入有两条并发路径——阅读器主线程（读者新增/删除批注）与同步线程
     * （`SyncManager` 回填 serverId、pull 合并）。`add`/`update`/`remove` 都是「读整表 → 改 →
     * 整表回写」，无锁时后写覆盖先写（丢新增、丢 serverId → 重复上传 / 幽灵记录）。
     */
    @Synchronized
    fun add(annotation: PdfAnnotation): PdfAnnotation {
        val current = list(annotation.documentId)
        val stored = if (annotation.id <= 0L) {
            annotation.copy(id = (current.maxOfOrNull { it.id } ?: 0L) + 1L)
        } else {
            annotation
        }
        write(key(annotation.documentId), json.encodeToString(current + stored))
        return stored
    }

    /**
     * 按 [PdfAnnotation.id] 原地替换（保持列表顺序）。
     *
     * @return 是否命中既有记录；未命中不做任何写入（避免静默追加）。
     */
    @Synchronized
    fun update(annotation: PdfAnnotation): Boolean {
        val current = list(annotation.documentId)
        val index = current.indexOfFirst { it.id == annotation.id }
        if (index < 0) return false
        write(
            key(annotation.documentId),
            json.encodeToString(current.toMutableList().also { it[index] = annotation }),
        )
        return true
    }

    /**
     * 按 id 删除批注。
     *
     * 只做本地持久化移除；是否需要把 [PdfAnnotation.serverId] 加入待删队列由调用方判定
     * （`serverId == null` 表示从未上传，不发 DELETE、不入队）。
     *
     * @return 是否真的删除了记录。
     */
    @Synchronized
    fun remove(docId: String, id: Long): Boolean {
        val current = list(docId)
        val remaining = current.filterNot { it.id == id }
        if (remaining.size == current.size) return false
        write(key(docId), json.encodeToString(remaining))
        return true
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
    @Synchronized
    fun clearLegacy(): Int = LegacyKeys.clearByPrefix(PREFIX, keys, remove)

    companion object {
        /** 批注存储键前缀（PDF 命名空间，与 epub 隔离）。 */
        private const val PREFIX = "pdf_annotations_"

        /** 批注存储键。 */
        fun key(docId: String): String = "$PREFIX$docId"
    }
}
