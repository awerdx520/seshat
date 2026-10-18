package com.seshat.app.reader

/**
 * PDF 阅读进度值对象。
 *
 * @property page      当前页码（0-based，与 [android.graphics.pdf.PdfRenderer] 页索引一致）。
 * @property updatedAt 最近更新时间（epoch 毫秒），供后续 M3.4 REST 同步做冲突检测。
 *
 * 序列化格式固定为 `<page>:<updatedAtMillis>`（如 `12:1730000000000`），
 * 便于持久化与纯 JVM 单测（不依赖 Android 框架）。
 */
data class PdfProgress(
    val page: Int,
    val updatedAt: Long,
) {
    /** 编码为单行字符串。 */
    fun encode(): String = "$page:$updatedAt"

    companion object {
        /** 解析 [encode] 产物；非法输入返回 `null`。 */
        fun decode(raw: String?): PdfProgress? {
            if (raw.isNullOrBlank()) return null
            val parts = raw.split(':')
            if (parts.size != 2) return null
            val page = parts[0].toIntOrNull() ?: return null
            val updatedAt = parts[1].toLongOrNull() ?: return null
            if (page < 0) return null
            return PdfProgress(page = page, updatedAt = updatedAt)
        }
    }
}

/**
 * PDF 阅读进度持久化。
 *
 * 存储键为 `pdf_progress_<docId>`，与 epub（M3.2）的键空间隔离，
 * 避免并行开发时的键冲突。通过注入读写函数而非直接依赖
 * `SharedPreferences`，使核心逻辑可脱离 Android 框架做 JVM 单测。
 *
 * @param read  读取键对应字符串（不存在返回 `null`）。
 * @param write 写入键值对。
 * @param keys  枚举该 prefs 文件的全部键（旧键清理用；默认空实现 → 清理为无操作）。
 * @param remove 删除单个键（旧键清理用；默认空实现 → 清理为无操作）。
 */
class PdfProgressStore(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
    private val keys: () -> Set<String> = { emptySet() },
    private val remove: (String) -> Unit = {},
) {
    /** 读取指定文档的进度，无记录或记录损坏时返回 `null`。 */
    fun load(docId: String): PdfProgress? = PdfProgress.decode(read(key(docId)))

    /** 覆盖写入指定文档的进度。 */
    fun save(docId: String, progress: PdfProgress) {
        write(key(docId), progress.encode())
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

    companion object {
        /** 进度存储键前缀（PDF 命名空间，与 epub 隔离）。 */
        private const val PREFIX = "pdf_progress_"

        /** 进度存储键。 */
        fun key(docId: String): String = "$PREFIX$docId"
    }
}
