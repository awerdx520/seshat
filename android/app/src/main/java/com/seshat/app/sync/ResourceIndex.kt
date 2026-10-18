package com.seshat.app.sync

import android.content.Context
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * 本地资源索引中的单条资源（与远端 `/api/roots` 清单对齐 + 本地派生的 dirty/deleted 标记）。
 *
 * [uid] 是资源的稳定标识，**一旦分配不再改变**；[root] + [path] 是定位键。
 * 墓碑（[deleted] = true）保留 [uid]/[root]/[path] 原值，以支持「同路径重建复用 uid」。
 */
@Serializable
data class ResourceEntry(
    @SerialName("uid") val uid: String,
    @SerialName("root") val root: String = "",
    @SerialName("path") val path: String = "",
    @SerialName("blob") val blob: String = "",
    @SerialName("size") val size: Long = 0,
    @SerialName("mtime") val mtime: Long = 0,
    @SerialName("deleted") val deleted: Boolean = false,
    @SerialName("dirty") val dirty: Boolean = false,
)

/**
 * 索引文档：增量游标 + 全量条目列表，整体序列化成**单条 JSON** 存进一个 prefs 键。
 *
 * [cursor] 是远端清单的增量游标（服务端语义，可为任意 `Long`），与条目一起原子写入。
 */
@Serializable
data class ResourceIndexDocument(
    @SerialName("cursor") val cursor: Long = 0,
    @SerialName("entries") val entries: List<ResourceEntry> = emptyList(),
)

/**
 * 本地资源索引：缓存远端资源清单，供增量同步与阅读器 uid 解析使用。
 *
 * ## 定位
 * 这是**派生状态**，不是唯一真相：全部内容可随时丢弃（[clear]）并由一次全量 bootstrap 从远端重建。
 * 因此这里不做事务、不做迁移，读写失败也只影响下次全量同步的成本。
 *
 * ## 并发
 * A 批假定**单线程调用**（同步流程在单一协程/线程内串行）：内部用一个惰性 [cached] 文档做读写
 * 缓存，未加锁。跨线程使用前必须先补锁或改为事件串行。
 *
 * ## 容量边界
 * 单条 JSON 全量重写的设计面向**数千条资源 / 数百 KB 级**的索引；条目数量级明显超过此范围
 * （万级以上、或需要按 root/path 索引查询）时应评估迁移到 Room/SQLite，而非继续加大这个单文件。
 *
 * 读写函数注入（[read] / [write]）使核心逻辑可在纯 JVM 单测中验证，[open] 提供真实
 * SharedPreferences 实现。
 */
class ResourceIndex(
    private val read: () -> String?,
    private val write: (String) -> Unit,
) {

    /** 惰性解析后的文档缓存；null 表示尚未从 [read] 加载。 */
    private var cached: ResourceIndexDocument? = null

    // ---- 游标 ----

    /** 当前增量游标（空文档时为 0）。 */
    fun cursor(): Long = document().cursor

    /** 设置增量游标（只改 cursor，条目不变；接受任意 `Long`）。 */
    fun setCursor(value: Long) {
        persist(document().copy(cursor = value))
    }

    // ---- 查询 ----

    /** 全部条目（含墓碑），保持写入顺序。 */
    fun all(): List<ResourceEntry> = document().entries

    /** 存活条目（过滤 `deleted = true`），保持原顺序。 */
    fun alive(): List<ResourceEntry> = document().entries.filterNot { it.deleted }

    /** 按 uid 精确查找；未命中返回 null。 */
    fun findByUid(uid: String): ResourceEntry? = document().entries.firstOrNull { it.uid == uid }

    /** 按 root + path 精确查找（**不过滤墓碑**，由调用方检查 [ResourceEntry.deleted]）。 */
    fun findByPath(root: String, path: String): ResourceEntry? =
        document().entries.firstOrNull { it.root == root && it.path == path }

    /** 某根下的全部条目（**含墓碑**），保持原顺序。 */
    fun entriesInRoot(root: String): List<ResourceEntry> =
        document().entries.filter { it.root == root }

    // ---- 写入 ----

    /** 插入或更新：同 uid 已存在则**原位替换**（顺序不变、不产生重复），否则追加到末尾。 */
    fun upsert(entry: ResourceEntry) {
        val current = document()
        val position = current.entries.indexOfFirst { it.uid == entry.uid }
        val updated = if (position >= 0) {
            current.entries.toMutableList().also { it[position] = entry }
        } else {
            current.entries + entry
        }
        persist(current.copy(entries = updated))
    }

    /**
     * 批量 upsert：与逐条 [upsert] 语义完全相同（同 uid 原位替换、新 uid 追加），
     * 但**只序列化与落盘一次**（消除逐条全量重写的 O(N²) 写放大）。
     *
     * [entries] 为空时直接返回——不构造文档、不写盘（保持「从未落盘」的原状）。
     * 列表内同 uid 出现多次时，后者覆盖前者且位置以首次出现为准（与逐条 [upsert] 一致）。
     */
    fun upsertAll(entries: List<ResourceEntry>) {
        if (entries.isEmpty()) return
        val current = document()
        val updated = current.entries.toMutableList()
        for (entry in entries) {
            val position = updated.indexOfFirst { it.uid == entry.uid }
            if (position >= 0) {
                updated[position] = entry
            } else {
                updated += entry
            }
        }
        persist(current.copy(entries = updated))
    }

    /** 改路径：只替换该 uid 的 [ResourceEntry.path]，其它字段不变；uid 不存在时静默无操作。 */
    fun rename(uid: String, newPath: String) {
        val current = document()
        if (current.entries.none { it.uid == uid }) return
        persist(
            current.copy(
                entries = current.entries.map { if (it.uid == uid) it.copy(path = newPath) else it },
            ),
        )
    }

    /** 标记墓碑：置 `deleted = true` 并**保留 uid/root/path 原值**；uid 不存在时静默无操作。 */
    fun markDeleted(uid: String) {
        val current = document()
        if (current.entries.none { it.uid == uid }) return
        persist(
            current.copy(
                entries = current.entries.map { if (it.uid == uid) it.copy(deleted = true) else it },
            ),
        )
    }

    /** 清空索引：写回空文档（cursor = 0、entries 空），保留 prefs 键本身非空值。 */
    fun clear() {
        persist(ResourceIndexDocument())
    }

    // ---- 内部 ----

    /** 取缓存文档，未加载时惰性解析。 */
    private fun document(): ResourceIndexDocument =
        cached ?: load().also { cached = it }

    /** 从 [read] 解析文档；缺失、空白或损坏时兜底为空文档（不抛异常）。 */
    private fun load(): ResourceIndexDocument {
        val raw = read()
        if (raw.isNullOrBlank()) return ResourceIndexDocument()
        return runCatching { json.decodeFromString(ResourceIndexDocument.serializer(), raw) }
            .getOrElse { ResourceIndexDocument() }
    }

    /** 更新缓存 → 全量序列化 → 落盘（单文件 JSON 语义）。 */
    private fun persist(next: ResourceIndexDocument) {
        cached = next
        write(json.encodeToString(ResourceIndexDocument.serializer(), next))
    }

    companion object {
        /** 资源索引的 prefs 文件名（与偏好、机密的 `seshat_*` 分离）。 */
        const val PREFS_NAME = "seshat_resource_index"

        /** 索引文档所在的键。 */
        const val KEY_DOCUMENT = "index"

        /** `encodeDefaults = true` 保证默认值（`deleted`/`dirty` 等）也序列化，round-trip 语义不丢。 */
        private val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        /** 打开资源索引（普通 SharedPreferences，不加密：索引内容不含机密）。 */
        fun open(context: Context): ResourceIndex {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return ResourceIndex(
                read = { prefs.getString(KEY_DOCUMENT, null) },
                write = { prefs.edit().putString(KEY_DOCUMENT, it).apply() },
            )
        }
    }
}
