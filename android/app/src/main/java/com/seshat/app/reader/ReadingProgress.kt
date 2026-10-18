package com.seshat.app.reader

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 阅读进度：文档 + 当前章节序号 + 章节内滚动位置。 */
@Serializable
data class ReadingProgress(
    val documentId: String,
    val chapterIndex: Int = 0,
    val scrollY: Int = 0,
    val updatedAt: Long = 0L,
)

/**
 * 阅读进度持久化（SharedPreferences + JSON，key = documentId）。
 *
 * 构造器接受 [SharedPreferences] 而非 Context，保证纯逻辑（序列化/读写）可在 JVM 单测中验证。
 */
class ReadingProgressStore(
    private val prefs: SharedPreferences,
    private val json: Json = defaultJson(),
) {
    /** 应用内使用：进度独立于账号，故用独立 prefs 文件。 */
    constructor(context: Context) :
        this(context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE))

    /** 保存（覆盖）进度；`updatedAt` 为 0 时补当前时间戳。 */
    fun save(progress: ReadingProgress) {
        val value = if (progress.updatedAt > 0L) {
            progress
        } else {
            progress.copy(updatedAt = System.currentTimeMillis())
        }
        prefs.edit()
            .putString(progress.documentId, json.encodeToString(ReadingProgress.serializer(), value))
            .apply()
    }

    /** 读取进度；无记录或 JSON 损坏时返回 null。 */
    fun load(documentId: String): ReadingProgress? {
        val raw = prefs.getString(documentId, null) ?: return null
        return try {
            json.decodeFromString(ReadingProgress.serializer(), raw)
        } catch (_: Exception) {
            null
        }
    }

    /** 删除某文档进度。 */
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

    companion object {
        const val PREFS_NAME = "reading_progress"

        fun defaultJson(): Json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }
    }
}
