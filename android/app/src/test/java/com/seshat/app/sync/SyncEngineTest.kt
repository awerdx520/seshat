package com.seshat.app.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * [SyncEngine] 单测（纯 JVM，走 [SyncApi] fake + 内存 prefs fake，不触网）。
 *
 * 覆盖：bootstrap 单页/两页、pull 起点、create/update/rename/delete 事件语义、
 * 未知 op 忽略、幂等、先应用后存游标的崩溃语义、游标未前进防死循环、空批正常结束。
 */
class SyncEngineTest {

    /** 内存 prefs 容器：模拟 `getString(KEY_DOCUMENT, null)` 与 `putString`。 */
    private class Holder {
        var stored: String? = null
    }

    /** 构造索引 + 读取原始落盘字符串的持有者（用于跨实例 round-trip 断言）。 */
    private fun index(): Pair<ResourceIndex, () -> String?> {
        val holder = Holder()
        val index = ResourceIndex(read = { holder.stored }, write = { holder.stored = it })
        return index to { holder.stored }
    }

    /** 带写入计数的索引容器：用于断言批量写盘的实际落盘次数（F4）。 */
    private class CountingIndex {
        var stored: String? = null
        var writes = 0
        val index = ResourceIndex(
            read = { stored },
            write = {
                stored = it
                writes++
            },
        )
    }

    /** 按页返回预置响应的 fake，记录每次调用的 (since, limit)。 */
    private class FakeApi(private val pages: List<ChangesPageDto>) : SyncApi {
        val calls = mutableListOf<Pair<Long, Int>>()
        var index = 0
        override fun changes(since: Long, limit: Int): ChangesPageDto {
            calls += since to limit
            return pages[index++]
        }
    }

    /** 第一页正常返回、后续调用抛 [ApiException] 的 fake（模拟网络中断）。 */
    private class FailingApi(private val firstPage: ChangesPageDto) : SyncApi {
        val calls = mutableListOf<Pair<Long, Int>>()
        override fun changes(since: Long, limit: Int): ChangesPageDto {
            calls += since to limit
            if (calls.size == 1) return firstPage
            throw ApiException(500, "internal", "boom")
        }
    }

    /** 构造变更事件（默认字段可控）。 */
    private fun change(
        uid: String,
        op: String,
        root: String = "main",
        path: String = "$uid.md",
        oldPath: String? = null,
        blob: String = "blob-$uid",
        seq: Long = 1,
    ) = ChangeDto(
        seq = seq,
        uid = uid,
        op = op,
        root = root,
        path = path,
        oldPath = oldPath,
        blob = blob,
        rev = "rev-$uid",
        changedAt = "2026-10-18T00:00:00Z",
    )

    /** 构造分页响应。 */
    private fun page(
        changes: List<ChangeDto>,
        nextCursor: Long,
        hasMore: Boolean,
    ) = ChangesPageDto(changes = changes, nextCursor = nextCursor, hasMore = hasMore)

    /** 构造索引条目。 */
    private fun entry(
        uid: String,
        root: String = "main",
        path: String = "$uid.md",
        blob: String = "blob-$uid",
        size: Long = 11L,
        mtime: Long = 22L,
        deleted: Boolean = false,
        dirty: Boolean = false,
    ) = ResourceEntry(
        uid = uid,
        root = root,
        path = path,
        blob = blob,
        size = size,
        mtime = mtime,
        deleted = deleted,
        dirty = dirty,
    )

    // ---- 1. bootstrap 单页 ----

    @Test
    fun bootstrapSinglePageAppliesAndStoresCursor() {
        val (idx, _) = index()
        val api = FakeApi(
            listOf(
                page(listOf(change("u1", "create")), nextCursor = 5, hasMore = false),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.bootstrap()

        assertEquals(1, result.applied)
        assertEquals(5L, result.cursor)
        assertEquals(1, result.pages)
        assertEquals(5L, idx.cursor())
        assertEquals(1, api.calls.size)
        assertEquals(0L to SyncEngine.DEFAULT_LIMIT, api.calls[0])
    }

    // ---- 2. bootstrap 两页 ----

    @Test
    fun bootstrapTwoPagesFollowsNextCursor() {
        val (idx, _) = index()
        val api = FakeApi(
            listOf(
                page(listOf(change("u1", "create")), nextCursor = 10, hasMore = true),
                page(listOf(change("u2", "create")), nextCursor = 20, hasMore = false),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.bootstrap()

        assertEquals(2, result.applied)
        assertEquals(20L, result.cursor)
        assertEquals(2, result.pages)
        assertNotNull(idx.findByUid("u1"))
        assertNotNull(idx.findByUid("u2"))
        assertEquals(2, api.calls.size)
        assertEquals(0L to SyncEngine.DEFAULT_LIMIT, api.calls[0])
        assertEquals(10L to SyncEngine.DEFAULT_LIMIT, api.calls[1])
    }

    // ---- 3. pull 从 index.cursor() 起 ----

    @Test
    fun pullStartsFromStoredCursor() {
        val (idx, _) = index()
        idx.setCursor(42)
        val api = FakeApi(
            listOf(
                page(listOf(change("u1", "create")), nextCursor = 50, hasMore = false),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.pull()

        assertEquals(1, api.calls.size)
        assertEquals(42L to SyncEngine.DEFAULT_LIMIT, api.calls[0])
        assertEquals(1, result.applied)
        assertEquals(50L, result.cursor)
        assertEquals(50L, idx.cursor())
    }

    // ---- 4. create 事件 ----

    @Test
    fun createEventUpsertsFields() {
        val (idx, _) = index()
        val engine = SyncEngine(FakeApi(emptyList()), idx)

        val applied = engine.apply(
            listOf(change("u1", "create", root = "main", path = "a.md", blob = "b1")),
        )

        assertEquals(1, applied)
        val got = idx.findByUid("u1")
        assertNotNull(got)
        assertEquals("u1", got!!.uid)
        assertEquals("main", got.root)
        assertEquals("a.md", got.path)
        assertEquals("b1", got.blob)
        assertFalse(got.deleted)
        assertEquals(0L, got.size)
        assertEquals(0L, got.mtime)
        // /api/changes 不含 size/mtime，全新 create 的这两个字段未知 → 必须标 dirty = true，
        // 表示「待后续用 GET /api/resources 回填」，避免 B 批书架按 mtime = 0 排序踩坑。
        assertTrue("全新 create 的条目必须标 dirty = true（size/mtime 未知，待回填）", got.dirty)
    }

    // ---- 5. update 保留既有 size/mtime ----

    @Test
    fun updateEventKeepsExistingSizeAndMtime() {
        val (idx, _) = index()
        idx.upsert(entry("u1", path = "old.md", blob = "old", size = 1234L, mtime = 5678L))
        val engine = SyncEngine(FakeApi(emptyList()), idx)

        val applied = engine.apply(
            listOf(change("u1", "update", path = "new.md", blob = "new")),
        )

        assertEquals(1, applied)
        val got = idx.findByUid("u1")!!
        assertEquals(1234L, got.size)
        assertEquals(5678L, got.mtime)
        assertEquals("new.md", got.path)
        assertEquals("new", got.blob)
        assertEquals(1, idx.all().size)
    }

    // ---- 6. rename 事件 ----

    @Test
    fun renameEventChangesPathOnly() {
        val (idx, _) = index()
        idx.upsert(entry("u1", path = "old.md", blob = "b1", size = 5L, mtime = 6L, dirty = true))
        val engine = SyncEngine(FakeApi(emptyList()), idx)

        val applied = engine.apply(
            listOf(change("u1", "rename", path = "new.md", oldPath = "old.md")),
        )

        assertEquals(1, applied)
        val got = idx.findByUid("u1")!!
        assertEquals("u1", got.uid)
        assertEquals("new.md", got.path)
        assertEquals("b1", got.blob)
        assertEquals(5L, got.size)
        assertEquals(6L, got.mtime)
        assertTrue(got.dirty)
    }

    // ---- 7. delete 事件 ----

    @Test
    fun deleteEventMarksTombstoneKeepingIdentity() {
        val (idx, _) = index()
        idx.upsert(entry("u1", root = "main", path = "a.md", blob = "b1"))
        val engine = SyncEngine(FakeApi(emptyList()), idx)

        val applied = engine.apply(listOf(change("u1", "delete", root = "main", path = "a.md")))

        assertEquals(1, applied)
        val got = idx.findByUid("u1")!!
        assertTrue(got.deleted)
        assertEquals("u1", got.uid)
        assertEquals("main", got.root)
        assertEquals("a.md", got.path)
        assertEquals(0, idx.alive().size)
    }

    // ---- 8. 未知 op 忽略 ----

    @Test
    fun unknownOpIsIgnored() {
        val (idx, _) = index()
        idx.upsert(entry("u1", path = "a.md", blob = "b1", size = 5L, mtime = 6L))
        val engine = SyncEngine(FakeApi(emptyList()), idx)

        val applied = engine.apply(listOf(change("u1", "chmod", path = "a.md", blob = "b2")))

        assertEquals(0, applied)
        assertEquals(listOf(entry("u1", path = "a.md", blob = "b1", size = 5L, mtime = 6L)), idx.all())
    }

    // ---- 9. 幂等 ----

    @Test
    fun applyingSamePageTwiceIsIdempotent() {
        val (idx, _) = index()
        val engine = SyncEngine(FakeApi(emptyList()), idx)
        val batch = listOf(
            change("u1", "create", path = "a.md", blob = "b1"),
            change("u2", "create", path = "b.md", blob = "b2"),
        )

        assertEquals(2, engine.apply(batch))
        val once = idx.all()
        assertEquals(2, engine.apply(batch))
        val twice = idx.all()

        assertEquals(once, twice)
        assertEquals(2, twice.size)
    }

    // ---- 10. 先应用后存 cursor（第二页抛异常）----

    @Test
    fun firstPageStaysAppliedWhenNextPageFails() {
        val (idx, _) = index()
        val api = FailingApi(
            page(listOf(change("u1", "create")), nextCursor = 10, hasMore = true),
        )
        val engine = SyncEngine(api, idx)

        try {
            engine.bootstrap()
            fail("应向上抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(500, e.statusCode)
        }

        // 第一页事件与游标都已落盘，第二页失败不影响已提交部分
        assertNotNull(idx.findByUid("u1"))
        assertEquals(10L, idx.cursor())
        assertEquals(2, api.calls.size)
        assertEquals(10L to SyncEngine.DEFAULT_LIMIT, api.calls[1])
    }

    // ---- 11. hasMore=true 但游标未前进 ----

    @Test
    fun nonAdvancingCursorWithHasMoreThrows() {
        val (idx, _) = index()
        idx.setCursor(77)
        val api = FakeApi(
            listOf(page(listOf(change("u1", "create")), nextCursor = 77, hasMore = true)),
        )
        val engine = SyncEngine(api, idx)

        try {
            engine.pull()
            fail("游标未前进时必须抛 IllegalStateException")
        } catch (e: IllegalStateException) {
            val message = e.message.orEmpty()
            assertTrue(message, message.contains("77"))
        }

        // 事件仍然已应用（先应用后校验游标），不会丢数据
        assertNotNull(idx.findByUid("u1"))
        assertEquals(1, api.calls.size)
    }

    // ---- 12. 空批正常结束 ----

    @Test
    fun emptyPageWithSameCursorTerminatesNormally() {
        val (idx, _) = index()
        idx.setCursor(9)
        val api = FakeApi(listOf(page(emptyList(), nextCursor = 9, hasMore = false)))
        val engine = SyncEngine(api, idx)

        val result = engine.pull()

        assertEquals(0, result.applied)
        assertEquals(1, result.pages)
        assertEquals(9L, result.cursor)
        assertEquals(9L, idx.cursor())
        assertNull(idx.findByUid("u1"))
    }

    // ---- 13. F4：一批 create 只落盘一次 ----

    @Test
    fun batchOfCreatesWritesOnce() {
        val counting = CountingIndex()
        val engine = SyncEngine(FakeApi(emptyList()), counting.index)

        val applied = engine.apply((1..100).map { change("u$it", "create", path = "f$it.md") })

        assertEquals(100, applied)
        assertEquals(100, counting.index.all().size)
        // 逐条 upsert 会把全量 JSON 重写 100 次（O(N²) 写放大）；upsertAll 必须只写 1 次
        assertEquals(1, counting.writes)
    }

    // ---- 14. F4：混合批次按「段」落盘（create 段各一次 + rename 自身一次）----

    @Test
    fun mixedBatchWritesPerSegment() {
        val counting = CountingIndex()
        val engine = SyncEngine(FakeApi(emptyList()), counting.index)

        val applied = engine.apply(
            listOf(
                change("u1", "create", path = "a.md"),
                change("u2", "create", path = "b.md"),
                change("u1", "rename", path = "a-new.md", oldPath = "a.md"),
                change("u3", "create", path = "c.md"),
            ),
        )

        assertEquals(4, applied)
        // 写盘算式：rename 前 flush（第 1 次 upsertAll）+ rename 自身 persist（第 2 次）+ 末尾 flush（第 3 次）= 3
        assertEquals(3, counting.writes)
        assertEquals("a-new.md", counting.index.findByUid("u1")!!.path)
        assertEquals(3, counting.index.all().size)
    }

    // ---- 15. F4：同批内同 uid 两次 update → 单条 + 后者字段生效 + 既有 size/mtime 保留 ----

    @Test
    fun sameUidTwiceInBatchKeepsSingleEntryWithLatestFields() {
        val counting = CountingIndex()
        counting.index.upsert(entry("u1", path = "old.md", blob = "old", size = 1234L, mtime = 5678L))
        val engine = SyncEngine(FakeApi(emptyList()), counting.index)

        val applied = engine.apply(
            listOf(
                change("u1", "update", path = "first.md", blob = "b1"),
                change("u1", "update", path = "second.md", blob = "b2"),
            ),
        )

        assertEquals(2, applied)
        val all = counting.index.all()
        assertEquals("同 uid 不得产生重复条目", 1, all.size)
        val got = all.first()
        assertEquals("second.md", got.path)
        assertEquals("b2", got.blob)
        // size/mtime 只能来自索引里的既有值（changes 不含这两字段），不得被第一条未 flush 的条目吞掉
        assertEquals(1234L, got.size)
        assertEquals(5678L, got.mtime)
    }

    // ---- 16. F4：批量与逐条结果等价 ----

    @Test
    fun batchApplyMatchesSequentialApply() {
        val events = listOf(
            change("u1", "create", path = "a.md", blob = "b1"),
            change("u2", "create", path = "b.md", blob = "b2"),
            change("u1", "rename", path = "a-new.md", oldPath = "a.md"),
            change("u3", "create", path = "c.md", blob = "b3"),
            change("u2", "update", path = "b.md", blob = "b2-new"),
            change("u9", "delete", path = "x.md"),
            change("u3", "chmod", path = "c.md"),
        )

        val batched = CountingIndex()
        SyncEngine(FakeApi(emptyList()), batched.index).apply(events)

        val sequential = CountingIndex()
        val seqEngine = SyncEngine(FakeApi(emptyList()), sequential.index)
        events.forEach { seqEngine.apply(listOf(it)) }

        assertEquals(sequential.index.all(), batched.index.all())
        // 批量只写 3 次（create 段 + rename 段 + create/update 段）；逐条则每条一次
        assertEquals(3, batched.writes)
        assertEquals(5, sequential.writes)
    }

    // ---- 17. rename 事件被收集进 SyncResult（供本地文件跟随） ----

    @Test
    fun renameEventIsCollectedInSyncResult() {
        val (idx, _) = index()
        val api = FakeApi(
            listOf(
                page(
                    listOf(change("u1", "rename", path = "b/y.epub", oldPath = "a/x.epub")),
                    nextCursor = 5,
                    hasMore = false,
                ),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.bootstrap()

        assertEquals(
            listOf(RenameEvent("u1", "a/x.epub", "b/y.epub")),
            result.renames,
        )
    }

    // ---- 18. oldPath 为空的 rename 不产生 RenameEvent ----

    @Test
    fun renameWithoutOldPathProducesNoRenameEvent() {
        val (idx, _) = index()
        val api = FakeApi(
            listOf(
                page(
                    listOf(change("u1", "rename", path = "b/y.epub", oldPath = null)),
                    nextCursor = 5,
                    hasMore = false,
                ),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.bootstrap()

        assertTrue("oldPath 为 null 时无法定位本地旧文件", result.renames.isEmpty())
        // 索引侧的 rename 仍照常生效（与 renames 收集互不影响）
        assertEquals(1, result.applied)
    }

    // ---- 19. 多页的 rename 按出现顺序累计 ----

    @Test
    fun renamesAccumulateAcrossPagesInOrder() {
        val (idx, _) = index()
        val api = FakeApi(
            listOf(
                page(
                    listOf(
                        change("u1", "rename", path = "b/one.epub", oldPath = "a/one.epub"),
                        change("u2", "create", path = "a/two.epub"),
                    ),
                    nextCursor = 10,
                    hasMore = true,
                ),
                page(
                    listOf(change("u2", "rename", path = "b/two.epub", oldPath = "a/two.epub")),
                    nextCursor = 20,
                    hasMore = false,
                ),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.pull()

        assertEquals(2, result.pages)
        assertEquals(
            listOf(
                RenameEvent("u1", "a/one.epub", "b/one.epub"),
                RenameEvent("u2", "a/two.epub", "b/two.epub"),
            ),
            result.renames,
        )
    }

    // ---- 20. 非 rename 事件不产生 RenameEvent ----

    @Test
    fun nonRenameEventsProduceNoRenameEvent() {
        val (idx, _) = index()
        idx.upsert(entry("u2", path = "b.md", blob = "b2"))
        val api = FakeApi(
            listOf(
                page(
                    listOf(
                        change("u1", "create", path = "a.md"),
                        change("u2", "update", path = "b.md"),
                        change("u2", "delete", path = "b.md"),
                        change("u3", "chmod", path = "c.md"),
                    ),
                    nextCursor = 7,
                    hasMore = false,
                ),
            ),
        )
        val engine = SyncEngine(api, idx)

        val result = engine.pull()

        assertTrue("create/update/delete/未知 op 都不应产生 RenameEvent", result.renames.isEmpty())
        assertEquals(3, result.applied)
    }
}
