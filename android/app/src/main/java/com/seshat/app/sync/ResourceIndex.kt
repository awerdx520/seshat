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
 * 元数据回填用的一次更新（来自 `/api/resources` 的 size/mtime/blob）。
 *
 * `/api/changes` 响应不含 `size`/`mtime`，因此增量同步产生的新条目 `dirty = true`，
 * 需由 [ResourceIndex.applyMetadata] 用这些字段回填并清脏。
 */
data class ResourceMetadataUpdate(
    val uid: String,
    val blob: String,
    val size: Long,
    val mtime: Long,
)

/**
 * 本地资源索引：缓存远端资源清单，供增量同步与阅读器 uid 解析使用。
 *
 * ## 定位
 * 这是**派生状态**，不是唯一真相：全部内容可随时丢弃（[clear]）并由一次全量 bootstrap 从远端重建。
 * 因此这里不做事务、不做迁移，读写失败也只影响下次全量同步的成本。
 *
 * ## 并发
 * **所有 public 方法均为 `@Synchronized`**（对象级锁）：同步流程与书架扫描即便落在不同线程也安全。
 * 索引操作是 O(n) 的内存遍历 + 一次全量序列化，锁粒度可接受；读方法（[all]/[alive]/
 * [entriesInRoot]/[dirtyEntries]）返回**快照副本**，调用方可在锁外自由遍历。
 *
 * 仍假定**单进程**：底层 `SharedPreferences` 不支持跨进程并发（多进程需换成 ContentProvider/Room
 * 或把索引下沉到单一进程服务）。
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
    @Synchronized
    fun cursor(): Long = document().cursor

    /** 设置增量游标（只改 cursor，条目不变；接受任意 `Long`）。 */
    @Synchronized
    fun setCursor(value: Long) {
        persist(document().copy(cursor = value))
    }

    // ---- 查询（均返回快照副本） ----

    /** 全部条目（含墓碑），保持写入顺序。**返回快照**：修改返回列表不影响索引。 */
    @Synchronized
    fun all(): List<ResourceEntry> = ArrayList(document().entries)

    /** 存活条目（过滤 `deleted = true`），保持原顺序。**返回快照**。 */
    @Synchronized
    fun alive(): List<ResourceEntry> =
        ArrayList(document().entries.filterNot { it.deleted })

    /** 按 uid 精确查找；未命中返回 null。 */
    @Synchronized
    fun findByUid(uid: String): ResourceEntry? =
        document().entries.firstOrNull { it.uid == uid }

    /** 按 root + path 精确查找（**不过滤墓碑**，由调用方检查 [ResourceEntry.deleted]）。 */
    @Synchronized
    fun findByPath(root: String, path: String): ResourceEntry? =
        document().entries.firstOrNull { it.root == root && it.path == path }

    /** 某根下的全部条目（**含墓碑**），保持原顺序。**返回快照**。 */
    @Synchronized
    fun entriesInRoot(root: String): List<ResourceEntry> =
        ArrayList(document().entries.filter { it.root == root })

    /**
     * 某根下 `dirty = true` 且**非墓碑**的条目（元数据回填候选），保持原顺序。
     *
     * **返回快照**：修改返回列表不影响索引。
     */
    @Synchronized
    fun dirtyEntries(root: String): List<ResourceEntry> =
        ArrayList(document().entries.filter { it.root == root && it.dirty && !it.deleted })

    // ---- 写入 ----

    /** 插入或更新：同 uid 已存在则**原位替换**（顺序不变、不产生重复），否则追加到末尾。 */
    @Synchronized
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
    @Synchronized
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
    @Synchronized
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
    @Synchronized
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
    @Synchronized
    fun clear() {
        persist(ResourceIndexDocument())
    }

    /**
     * 批量回填元数据（`blob`/`size`/`mtime`）并**清 dirty**，整批只落盘一次。
     *
     * - 只更新**仍存在**的 uid；未知 uid 静默忽略；
     * - 已墓碑的条目也回填（保留 `deleted = true`，只更新元数据并清 dirty）；
     * - [updates] 为空、或没有任何条目被命中时**不写盘**。
     */
    @Synchronized
    fun applyMetadata(updates: List<ResourceMetadataUpdate>) {
        if (updates.isEmpty()) return
        val current = document()
        if (current.entries.isEmpty()) return
        val byUid = updates.associateBy { it.uid }
        val updated = current.entries.map { existing ->
            val update = byUid[existing.uid] ?: return@map existing
            existing.copy(
                blob = update.blob,
                size = update.size,
                mtime = update.mtime,
                dirty = false,
            )
        }
        if (updated == current.entries) return // 全未命中：不做无意义写盘
        persist(current.copy(entries = updated))
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
