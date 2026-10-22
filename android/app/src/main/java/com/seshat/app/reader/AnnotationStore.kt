package com.seshat.app.reader

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** 本地批注：文档 + 章节 + 选中文本 + 批注内容。 */
@Serializable
data class BookAnnotation(
    val id: String = "",
    val documentId: String,
    val chapterIndex: Int,
    val selectedText: String,
    val note: String,
    val createdAt: Long = 0L,
    /**
     * 服务端 `location`（EPUB 定稿形态 `chapter:<spineIndex>@<start>-<end>`）。
     *
     * 旧记录无该键 → 空串，此时由 [chapterIndex] 派生 `chapter-<n>` 兼容旧行为。
     */
    val location: String = "",
    /** 批注种类：`note` / `highlight`（对齐服务端 v8 `kind`；旧记录缺键按 `note`）。 */
    val kind: String = KIND_NOTE,
    /** 服务端分配 id（`null` 表示尚未上传）；本地 [id]（UUID）绝不复用服务端 id。 */
    val serverId: Long? = null,
    /** 新增或修改尚未上行（删除不复用该标记，走独立待删队列）。 */
    val dirty: Boolean = false,
) {
    companion object {
        /** [kind] 取值：有备注的批注（服务端 `kind=note` 时 `text` 必填）。 */
        const val KIND_NOTE = "note"

        /** [kind] 取值：仅选中原文、无备注（服务端 v8 起 `text` 允许空串）。 */
        const val KIND_HIGHLIGHT = "highlight"
    }
}

/**
 * 批注持久化（MVP：SharedPreferences 存 JSON 数组，key = documentId）。
 *
 * 本地 id 用 UUID，M3.4 与服务端同步时以 `document_id + location` 做映射。
 * 构造器接受 [SharedPreferences]，便于 JVM 单测注入内存实现。
 */
class AnnotationStore(
    private val prefs: SharedPreferences,
    private val json: Json = defaultJson(),
) {
    constructor(context: Context) :
        this(context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE))

    /**
     * 新增批注；`id`/`createdAt` 为空时补齐，返回落库后的对象。
     *
     * `@Synchronized`：批注写入有两条并发路径——阅读器主线程（读者新增/删除）与同步线程
     * （`SyncManager` 回填 serverId、pull 合并）。`add`/`update`/`remove` 都是「读整表 → 改 →
     * 整表回写」，无锁时后写会覆盖先写（丢新增、丢 serverId → 重复上传 / 幽灵记录）。
     */
    @Synchronized
    fun add(annotation: BookAnnotation): BookAnnotation {
        val stored = annotation.copy(
            id = annotation.id.ifBlank { UUID.randomUUID().toString() },
            createdAt = if (annotation.createdAt > 0L) annotation.createdAt else System.currentTimeMillis(),
        )
        val list = list(annotation.documentId) + stored
        write(annotation.documentId, list)
        return stored
    }

    /**
     * 按 id 原地替换批注（同步层「服务端版本合并进本地」用），保留 [add] 的补齐语义：
     * `id` 为空补 UUID、`createdAt` 为 0 补当前时间。
     *
     * @return 是否命中既有记录；未命中不写入（避免静默追加重复条目）。
     */
    @Synchronized
    fun update(annotation: BookAnnotation): Boolean {
        val stored = annotation.copy(
            id = annotation.id.ifBlank { UUID.randomUUID().toString() },
            createdAt = if (annotation.createdAt > 0L) annotation.createdAt else System.currentTimeMillis(),
        )
        val list = list(annotation.documentId)
        val index = list.indexOfFirst { it.id == stored.id }
        if (index < 0) return false
        write(annotation.documentId, list.toMutableList().also { it[index] = stored })
        return true
    }

    /**
     * 列出某文档的批注（按写入顺序）。
     *
     * **返回副本**：每次调用都从 JSON 重新解码，调用方修改返回值不影响存储（与 [ResourceIndex]
     * 的约定一致）。`@Synchronized` 保证读到的是某一完整写入之后的快照。
     */
    @Synchronized
    fun list(documentId: String): List<BookAnnotation> {
        val raw = prefs.getString(documentId, null) ?: return emptyList()
        return try {
            json.decodeFromString(ListSerializer(BookAnnotation.serializer()), raw)
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** 按 id 删除批注；返回是否真的删除了记录。与 [add]/[update] 共用同一把锁。 */
    @Synchronized
    fun remove(documentId: String, id: String): Boolean {
        val list = list(documentId)
        val remaining = list.filterNot { it.id == id }
        if (remaining.size == list.size) return false
        write(documentId, remaining)
        return true
    }

    /** 清空某文档的全部批注。 */
    @Synchronized
    fun clear(documentId: String) {
        prefs.edit().remove(documentId).apply()
    }

    /**
     * 一次性清理旧键（M7 之前以 documentId 作键的记录）：32 位十六进制内容哈希或含 `:` 的 uri。
     *
     * 幂等纯清理：多次调用结果一致；是否只跑一次由调用方用 [LegacyKeys.CLEARED_FLAG] 标记控制。
     * 旧数据**不迁移**（uid 映射需服务端 resolve，见 tech-debt）。
     *
     * @return 实际删除的键数量。
     */
    @Synchronized
    fun clearLegacy(): Int {
        var removed = 0
        // getAll() 返回快照，遍历期间删除原 prefs 键安全
        for (key in prefs.all.keys.toList()) {
            if (key.startsWith(LegacyKeys.FLAG_PREFIX)) continue
            if (!LegacyKeys.isLegacyBase(key)) continue
            prefs.edit().remove(key).apply()
            removed++
        }
        return removed
    }

    private fun write(documentId: String, list: List<BookAnnotation>) {
        prefs.edit()
            .putString(documentId, json.encodeToString(ListSerializer(BookAnnotation.serializer()), list))
            .apply()
    }

    companion object {
        const val PREFS_NAME = "reader_annotations"

        fun defaultJson(): Json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }
    }
}
