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
)

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

    /** 新增批注；`id`/`createdAt` 为空时补齐，返回落库后的对象。 */
    fun add(annotation: BookAnnotation): BookAnnotation {
        val stored = annotation.copy(
            id = annotation.id.ifBlank { UUID.randomUUID().toString() },
            createdAt = if (annotation.createdAt > 0L) annotation.createdAt else System.currentTimeMillis(),
        )
        val list = list(annotation.documentId) + stored
        write(annotation.documentId, list)
        return stored
    }

    /** 列出某文档的批注（按写入顺序）。 */
    fun list(documentId: String): List<BookAnnotation> {
        val raw = prefs.getString(documentId, null) ?: return emptyList()
        return try {
            json.decodeFromString(ListSerializer(BookAnnotation.serializer()), raw)
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** 按 id 删除批注；返回是否真的删除了记录。 */
    fun remove(documentId: String, id: String): Boolean {
        val list = list(documentId)
        val remaining = list.filterNot { it.id == id }
        if (remaining.size == list.size) return false
        write(documentId, remaining)
        return true
    }

    /** 清空某文档的全部批注。 */
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
