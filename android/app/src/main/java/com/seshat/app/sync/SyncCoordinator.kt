package com.seshat.app.sync

import java.io.File
import java.util.concurrent.ExecutorService

/**
 * 同步所需的服务端能力聚合（便于 fake 测试；生产由 [RestSyncApis] 适配 [RestClient]）。
 *
 * 聚合为单一接口而非让编排层直接依赖 [RestClient]，是为了让 [SyncCoordinator] 可以在纯 JVM
 * 单测里用计数 fake 验证「未配置时零网络」「backfill 覆盖所有根」等行为，而无需 MockWebServer。
 */
interface SyncApis {
    /** 列出服务端根清单（`GET /api/roots`）。 */
    fun roots(): List<RootDto>

    /** 拉取变更日志（`GET /api/changes`）。 */
    fun changes(since: Long, limit: Int): ChangesPageDto

    /** 列资源（`GET /api/resources`，回填用）。 */
    fun resources(root: String, sinceMtime: Long?, limit: Int): ResourcesPageDto
}

/** 生产适配：把 [RestClient] 包成 [SyncApis]（只做转发，不含逻辑）。 */
class RestSyncApis(private val client: RestClient) : SyncApis {
    override fun roots(): List<RootDto> = client.roots()

    override fun changes(since: Long, limit: Int): ChangesPageDto = client.changes(since, limit)

    override fun resources(root: String, sinceMtime: Long?, limit: Int): ResourcesPageDto =
        client.resources(root = root, sinceMtime = sinceMtime, limit = limit)
}

/** 一次同步的结果。 */
sealed interface SyncOutcome {
    /** 服务端未配置（地址/令牌缺失）：零网络，不是错误。 */
    data object NotConfigured : SyncOutcome

    /** 成功：[applied] 应用的变更事件数、[backfilled] 回填的元数据条目数、[cursor] 结束游标。 */
    data class Ok(val applied: Int, val backfilled: Int, val cursor: Long) : SyncOutcome

    /** 失败：[message] 为异常消息（无消息时取异常类简单名）。 */
    data class Failed(val message: String) : SyncOutcome
}

/**
 * 同步编排：装配 [SyncEngine] + [MetadataBackfill]，在**单线程 executor** 上串行执行。
 *
 * ## 顺序
 * `changes` 增量同步（`cursor == 0` → [SyncEngine.bootstrap]，否则 [SyncEngine.pull]）
 * → 按 [roots] 逐个根回填 `size`/`mtime`/`blob`。回填在同步之后，保证新条目先进入索引再取元数据。
 *
 * ## 线程
 * [syncNow] 只负责提交任务后立即返回，所有网络与索引写入都在 [executor] 上**串行**发生——
 * 这是 [ResourceIndex] 单线程前提的装配层保证（同步、回填、书架扫描共用同一 executor 即安全）。
 * [SyncCoordinator] 自身的缓存字段用 `@Volatile`/`@Synchronized` 保护，可被任意线程调用。
 *
 * ## 未配置语义
 * [apis] 返回 null 表示服务端未配置（`SettingsStore.toConfig() == null`）→ 回 `NotConfigured`，
 * **不触发任何网络**（含 `roots()`）。`apis()` 自身抛异常（如解密失败）按 [SyncOutcome.Failed] 处理，
 * 因为那是配置读取故障而非「未配置」。
 *
 * @param index 本地资源索引（同步的唯一持久化状态）。
 * @param apis 服务端能力提供者；返回 null 表示未配置 → 全链跳过（零网络）。
 * @param executor 执行器（调用方持有；与其他后台任务共用时须保证单线程串行）。
 * @param pageLimit 回填分页大小（与服务端 `/api/resources` 上限 2000 一致）。
 * @param booksDir 本地书籍目录（`filesDir/books/`，扁平存储）；null 表示不做本地文件跟随
 *   （默认值即 null，保持既有纯 JVM 单测零改动）。
 * @param logger 日志回调（默认空实现）。**不能在此直接调 `android.util.Log`**：`SyncCoordinator`
 *   被纯 JVM 单测使用，`Log` 在 JVM 下会抛 `RuntimeException("Stub!")`；生产装配（`SyncHolder`）
 *   传入 `{ Log.w(TAG, it) }`。
 */
class SyncCoordinator(
    private val index: ResourceIndex,
    private val apis: () -> SyncApis?,
    private val executor: ExecutorService,
    private val pageLimit: Int = DEFAULT_PAGE_LIMIT,
    private val booksDir: File? = null,
    private val logger: (String) -> Unit = {},
) {
    /** 缓存的服务端根清单（含 mode），null 表示尚未拉取。 */
    @Volatile
    private var cachedRoots: List<RootDto>? = null

    /**
     * 拉取/复用根清单（含 `mode`，供上传前判断根是否可写）。
     *
     * 成功即缓存；**失败返回空表且不缓存**——下次调用会重试（网络抖动不会永久丢掉根清单）。
     * 未配置时同样返回空表（零网络）。`@Synchronized` 保证并发首访只请求一次。
     */
    @Synchronized
    fun roots(): List<RootDto> {
        cachedRoots?.let { return it }
        val loaded = runCatching { apis()?.roots() }.getOrNull() ?: return emptyList()
        cachedRoots = loaded
        return loaded
    }

    /** 使 roots 缓存失效（设置页保存服务端配置、或用户手动刷新时调用）。 */
    @Synchronized
    fun invalidateRoots() {
        cachedRoots = null
    }

    /**
     * 服务端配置变更后调用：清 roots 缓存。
     *
     * [apis] 函数与它内部的 [RestClient] 缓存由**调用方持有**，本类无法代为清理；
     * 调用方需同时丢弃自己那份客户端实例（例如置空 `restClient` 字段），否则旧令牌仍会被复用。
     */
    @Synchronized
    fun invalidateConfig() {
        cachedRoots = null
    }

    /**
     * 触发一次同步（异步）。
     *
     * 回调 [onDone] 在 **executor 线程**上执行（含未配置分支，保持线程语义一致），
     * 调用方需要更新 UI 时自行切主线程。返回 false 表示提交失败（executor 已关闭），
     * 此时 [onDone]**不会**被调用。
     */
    fun syncNow(onDone: (SyncOutcome) -> Unit): Boolean {
        val apiResult = runCatching { apis() }
        return runCatching {
            executor.execute {
                val api = apiResult.getOrNull()
                onDone(
                    if (api == null) {
                        apiResult.exceptionOrNull()
                            ?.let { SyncOutcome.Failed(it.message ?: it.javaClass.simpleName) }
                            ?: SyncOutcome.NotConfigured
                    } else {
                        runSync(api)
                    },
                )
            }
            true
        }.getOrElse { false } // RejectedExecutionException：executor 已关闭
    }

    /** 串行执行「同步 → 本地跟随 → 逐根回填」；任何异常（含网络、协议）折叠为 [SyncOutcome.Failed]。 */
    private fun runSync(api: SyncApis): SyncOutcome = runCatching {
        val engine = SyncEngine(SyncApi { since, limit -> api.changes(since, limit) }, index)
        val result = if (index.cursor() == 0L) engine.bootstrap() else engine.pull()
        // 先跟随本地文件（与回填顺序无关），再做元数据回填
        followRenames(result.renames)
        var backfilled = 0
        for (root in roots()) {
            val backfill = MetadataBackfill(
                ResourcesApi { r, since, limit -> api.resources(r, since, limit) },
                index,
                pageLimit,
            )
            backfilled += backfill.backfill(root.tag).updated
        }
        SyncOutcome.Ok(applied = result.applied, backfilled = backfilled, cursor = index.cursor())
    }.getOrElse { e -> SyncOutcome.Failed(e.message ?: e.javaClass.simpleName) }

    /**
     * 本地文件跟随：把服务端 `move`（`op = rename`）反映到 [booksDir]。
     *
     * ## 扁平存储的 best-effort 语义
     * [booksDir] 无目录层级，本地文件名 = `path.basename`，因此只按 basename 重命名：
     * - 旧文件不存在（该书未下载）→ 跳过；目标已存在（同名不同目录冲突）→ 跳过并记日志，
     *   **绝不覆盖、绝不删除**；
     * - 新旧 basename 相同（`a/x.epub` → `b/x.epub`）→ 本地无需动作，直接跳过；
     * - 失败只记日志，不中断同步（文件跟随是派生优化，不能拖垮索引同步）。
     */
    private fun followRenames(renames: List<RenameEvent>) {
        if (renames.isEmpty()) return
        val dir = booksDir ?: return
        for (event in renames) {
            val oldName = event.oldPath.substringAfterLast('/')
            val newName = event.newPath.substringAfterLast('/')
            if (oldName.isBlank() || newName.isBlank() || oldName == newName) continue
            val oldFile = File(dir, oldName)
            val newFile = File(dir, newName)
            if (!oldFile.isFile) continue // 本地没有该书 → 无需跟随
            if (newFile.exists()) {
                logger("move 跟随跳过（目标已存在）：$newName")
                continue
            }
            if (!oldFile.renameTo(newFile)) logger("move 跟随失败：$oldName -> $newName")
        }
    }

    companion object {
        /** 回填单页上限（与服务端 `/api/resources` 的 `limit` 夹紧上限一致）。 */
        const val DEFAULT_PAGE_LIMIT = 2000
    }
}
