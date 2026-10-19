package com.seshat.app.sync

/**
 * 增量事件源（生产实现为 [RestClient.changes]；用 fun interface 便于 lambda 适配与 fake）。
 *
 * 生产环境适配示例（**不属于 A 批接线范围**，仅示意）：
 * ```
 * val api = SyncApi { since, limit -> restClient.changes(since, limit) }
 * ```
 */
fun interface SyncApi {
    /** 拉取 `since` 之后的一页变更事件；`limit` 为单页上限。失败抛 [ApiException] 等 IO 异常。 */
    fun changes(since: Long, limit: Int): ChangesPageDto
}

/** 一次同步中发生的重命名（用于本地文件跟随）。 */
data class RenameEvent(val uid: String, val oldPath: String, val newPath: String)

/**
 * 一次同步的结果：应用事件总数、结束游标、拉取页数。
 *
 * 计划中的 `BootstrapResult` / `PullResult` 结构完全相同，已合并为本类型。
 */
data class SyncResult(
    val applied: Int,
    val cursor: Long,
    val pages: Int,
    /** 本次同步中 op=rename 且 oldPath 非空的事件（按出现顺序）。 */
    val renames: List<RenameEvent> = emptyList(),
)

/**
 * 增量同步引擎：把服务端 `/api/changes` 的变更事件折叠进本地 [ResourceIndex]。
 *
 * ## 语义与不变量
 * 1. **索引是派生状态**：内容全部可丢弃，[ResourceIndex.clear] 后一次 [bootstrap] 即可从远端重建；
 *    索引里的 `cursor` 与条目一起原子落盘，是唯一需要持久化的同步位置。
 * 2. **崩溃语义（先应用、后存游标）**：每页先 [apply] 事件、再 `index.setCursor(page.nextCursor)`。
 *    若两者之间崩溃，重启后会**重新拉取并重复应用同一页**——[apply] 幂等，所以最多多花一次网络，
 *    绝不会丢事件；反之若先存游标再应用，崩溃就会永久跳过整页事件。
 * 3. **事件字段的缺失**：`/api/changes` 不含 `size` / `mtime`，因此 create/update 在 upsert 时
 *    **保留索引里已有的 `size` / `mtime` / `dirty`**（写 0 会把已知大小清零，书架排序与展示会坏）；
 *    全新 create 的这两个字段无从得知，此时 `size` / `mtime` 为 0 且 **`dirty = true`** 表示
 *    「待后续用 `GET /api/resources` 回填」；要拿到真实 size/mtime 需另外查询 `/api/resources`，记入 tech-debt。
 * 4. **`rev` 被丢弃**：本地的 [ResourceEntry] 没有 `rev` 字段（`uid + cursor` 已足够表达同步位置），
 *    需要服务端版本号的场景（如条件更新）须另行扩展索引，记入 tech-debt。
 * 5. **rename 的 `oldPath` 只用于本地跟随**：索引侧仍只用 `path`（uid 才是稳定键），
 *    `oldPath` 仅被收集进 [SyncResult.renames]，供 `SyncCoordinator` 重命名本地文件。
 * 6. **未知 `op` 忽略**：不抛异常、不改索引、不计入 [SyncResult.applied]，以便服务端新增操作类型时
 *    旧客户端仍能同步其余事件。
 * 7. **A 批不接线**：本类当前**没有任何调用点**（`SeshatApp` / Activity / [SyncManager] 均未使用），
 *    由 T4/T5 负责接入；A 批假定单线程串行调用，与 [ResourceIndex] 的并发前提一致。
 *
 * ## 循环协议
 * `since` 初值为 0（[bootstrap]）或 `index.cursor()`（[pull]），每轮拉一页，直到 `hasMore == false`。
 * 若服务端返回 `hasMore == true` 却没有推进游标，立即抛 [IllegalStateException] 防死循环
 * （这是服务端/协议错误，不应静默重试）；空批 + `hasMore == false` + 游标未前进属正常情况。
 */
class SyncEngine(
    private val api: SyncApi,
    private val index: ResourceIndex,
) {

    /**
     * 本次同步中收集到的重命名事件（`op = rename` 且 `oldPath` 非空）。
     *
     * ## 生命周期
     * [sync] 开头 [MutableList.clear]、结尾做快照塞进 [SyncResult.renames]；[apply] 只追加。
     * [apply] 是 public 且被测试直接调用，因此**单次 [apply] 之间不清空**——直接调用方不读这个字段，
     * 下一次 [sync] 会先清空，所以不会有副作用。
     */
    private val pendingRenames = mutableListOf<RenameEvent>()

    /** 全量重建：从 `since = 0` 循环到 `hasMore == false`；每页先应用事件、再存下一页游标。 */
    fun bootstrap(): SyncResult = sync(startSince = 0L)

    /** 增量拉取：从 [ResourceIndex.cursor] 起，循环与崩溃语义同 [bootstrap]。 */
    fun pull(): SyncResult = sync(startSince = index.cursor())

    /**
     * 应用一批变更事件（按列表顺序逐条应用）；返回**已识别并处理**的条数。
     *
     * 幂等：同一批事件重复应用后索引内容一致（create/update 覆盖、rename 同值、delete 置位）。
     * 未知 `op` 忽略且不计入返回值；uid 在索引中不存在的 rename/delete 仍计入（事件已处理，
     * [ResourceIndex] 侧静默无操作）。
     *
     * ## 分段批量写盘
     * create/update 先累积到内存 [pending]，遇到 rename/delete 或批次结束才一次性
     * [ResourceIndex.upsertAll] 落盘——把「N 条事件 N 次全量重写」压成「每段一次」。
     * 顺序语义不变：rename/delete 前必须先 flush，否则它们会作用在旧文档上而丢掉同段内的
     * create/update（rename 只改 path、markDeleted 只置位，都不会带上未落盘的新条目）。
     */
    fun apply(changes: List<ChangeDto>): Int {
        var applied = 0
        val pending = mutableListOf<ResourceEntry>()

        fun flush() {
            if (pending.isNotEmpty()) {
                index.upsertAll(pending)
                pending.clear()
            }
        }

        for (change in changes) {
            when (change.op) {
                OP_CREATE, OP_UPDATE -> {
                    // 既有值先查未落盘的 pending，再查索引：同批内同 uid 连续 update 时
                    // size/mtime/dirty 才能从上一条传递，不会因「尚未 flush」而丢成默认值
                    pending += buildEntry(change, existingOf(change.uid, pending))
                    applied++
                }
                OP_RENAME -> {
                    flush()
                    index.rename(change.uid, change.path)
                    // oldPath 非空才能定位本地旧文件；仅收集、不影响索引侧语义
                    change.oldPath?.takeIf { it.isNotBlank() }?.let {
                        pendingRenames += RenameEvent(change.uid, it, change.path)
                    }
                    applied++
                }
                OP_DELETE -> {
                    flush()
                    index.markDeleted(change.uid)
                    applied++
                }
                // 未知 op：忽略（不抛、不改索引、不计入 applied）
                else -> Unit
            }
        }
        flush()
        return applied
    }

    /**
     * 构造 create/update 事件对应的条目。
     *
     * `/api/changes` 不含 `size` / `mtime`，因此这两个字段只能继承既有值（没有则写 0）；
     * 全新 create 时它们无从得知，故把 `dirty` 置为 `true`，表示
     * 「需后续用 `GET /api/resources` 回填」——避免 B 批书架按 `mtime = 0` 排序踩坑。
     */
    private fun buildEntry(change: ChangeDto, existing: ResourceEntry?): ResourceEntry =
        ResourceEntry(
            uid = change.uid,
            root = change.root,
            path = change.path,
            blob = change.blob,
            // changes 不含 size/mtime：保留既有值，避免把已知大小清零
            size = existing?.size ?: 0L,
            mtime = existing?.mtime ?: 0L,
            deleted = false,
            // 已有条目保留其 dirty（可能已被 /api/resources 回填过）；全新条目未知 → true
            dirty = existing?.dirty ?: true,
        )

    /** 既有值查找：同批内尚未落盘的 [pending] 优先（同 uid 连续事件传递），再查 [index]。 */
    private fun existingOf(uid: String, pending: List<ResourceEntry>): ResourceEntry? =
        pending.lastOrNull { it.uid == uid } ?: index.findByUid(uid)

    /** 拉取循环：`startSince` → `hasMore == false`。异常向上抛，已提交页的数据与游标保留。 */
    private fun sync(startSince: Long): SyncResult {
        pendingRenames.clear() // 每次同步独立收集：上一次（含异常中断）的残留不得泄漏进本次结果
        var since = startSince
        var applied = 0
        var pages = 0
        while (true) {
            val page = api.changes(since, DEFAULT_LIMIT)
            // 先应用事件，再存游标：崩溃时最多重复处理一页（apply 幂等），绝不丢事件
            applied += apply(page.changes)
            if (page.hasMore && page.nextCursor == since) {
                throw IllegalStateException(
                    "增量游标未前进：since=$since, nextCursor=${page.nextCursor}（hasMore=true）" +
                        "，拒绝无限重试同一页",
                )
            }
            index.setCursor(page.nextCursor)
            since = page.nextCursor
            pages++
            if (!page.hasMore) break
        }
        return SyncResult(
            applied = applied,
            cursor = index.cursor(),
            pages = pages,
            renames = pendingRenames.toList(),
        )
    }

    companion object {
        /** 单页拉取上限（与服务端 `limit` 默认值一致）。 */
        const val DEFAULT_LIMIT = 2000

        private const val OP_CREATE = "create"
        private const val OP_UPDATE = "update"
        private const val OP_RENAME = "rename"
        private const val OP_DELETE = "delete"
    }
}
