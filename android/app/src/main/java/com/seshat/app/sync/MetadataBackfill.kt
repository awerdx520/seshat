package com.seshat.app.sync

/** 回填所需的最小服务端能力（便于 fake）：`GET /api/resources` 单页拉取。 */
fun interface ResourcesApi {
    fun resources(root: String, sinceMtime: Long?, limit: Int): ResourcesPageDto
}

/** 一次回填的结果：[updated] 为回填（清脏）的条目数，[pages] 为实际发起的分页请求数。 */
data class BackfillResult(val updated: Int, val pages: Int)

/**
 * 把 `/api/resources` 的 `size`/`mtime`/`blob` 回填到本地索引的 dirty 条目。
 *
 * ## 分页机制
 * 服务端 `since` 是 **mtime 秒**（语义 `mtime >= since`），响应体**没有**游标：
 * - 首页 `since = null`（服务端按缺省 0 处理）；
 * - 后续页 `since = max(本页 mtime)`；
 * - **同秒边界**：若本页 `max(mtime) == 上一页的 since`（本轮没有任何时间前进，说明该秒的记录
 *   已在上一页全部返回）→ `since += 1` 继续，避免原地死循环；
 * - **空页（items 为空）→ 结束**，不再尝试取 `max(mtime)`；
 * - [maxPages] 触顶 → 停止并返回已回填数（防止服务端异常导致无穷请求）。
 *
 * ## 语义边界
 * **尽力而为 + 幂等**：本次漏掉的 dirty 条目保持 `dirty = true`，下次 sync 自然重试。
 * 因此回填保证「最终一致」，**不保证单次全量**。
 *
 * ## 异常
 * 本类不 catch 任何异常：网络/协议错误（如 `RestClient.ApiException`）直接向上抛给调用方
 * （装配方 `SyncCoordinator` 统一转成 `SyncOutcome.Failed`）。
 *
 * ## 线程
 * 无内部状态，可重入；调用方负责在后台线程执行（内部有阻塞网络调用）。
 *
 * [pages] 计入**每一次实际发起的分页请求**（包括返回空页的那次）。
 */
class MetadataBackfill(
    private val api: ResourcesApi,
    private val index: ResourceIndex,
    private val pageLimit: Int = 2000,
    private val maxPages: Int = 50,
) {

    /** 回填某根；返回本次更新的条目数与拉取页数。 */
    fun backfill(root: String): BackfillResult {
        var since: Long? = null
        var updated = 0
        var pages = 0
        while (true) {
            // 每页重新取：applyMetadata/markDeleted 会改变 dirty 状态
            val dirtyUids = index.dirtyEntries(root).mapTo(HashSet()) { it.uid }
            if (dirtyUids.isEmpty()) break
            val page = api.resources(root, since, pageLimit)
            pages++
            if (page.items.isEmpty()) break
            val updates = ArrayList<ResourceMetadataUpdate>()
            for (item in page.items) {
                if (item.deletedAt.isNotBlank()) {
                    // 服务端已墓碑：本地同步墓碑，不回填元数据
                    index.markDeleted(item.uid)
                } else if (item.uid in dirtyUids) {
                    updates += ResourceMetadataUpdate(item.uid, item.blob, item.size, item.mtime)
                }
            }
            index.applyMetadata(updates) // 每页一次：避免跨页累积
            updated += updates.size
            var nextSince = page.items.maxOf { it.mtime }
            if (nextSince == since) nextSince += 1 // 本秒已处理完 → 跳过该秒
            since = nextSince
            if (pages >= maxPages) break
            if (!page.hasMore) break
        }
        return BackfillResult(updated = updated, pages = pages)
    }
}
