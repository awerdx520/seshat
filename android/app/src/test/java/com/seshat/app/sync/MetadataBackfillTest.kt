package com.seshat.app.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [MetadataBackfill] 单测（纯 JVM，fake `ResourcesApi` + 内存 fake prefs）。
 *
 * 覆盖：单页回填、多页 since 推进、同秒边界（since+1）、空页结束、无 dirty 不请求、
 * `maxPages` 触顶、墓碑转 deleted、未知 uid 忽略、重复调用幂等、仅处理指定根。
 */
class MetadataBackfillTest {

    /** 内存 fake prefs：单键单值（与 [ResourceIndexTest] 保持一致的最小实现）。 */
    private class FakePrefs {
        var stored: String? = null
        fun index() = ResourceIndex(read = { stored }, write = { stored = it })
    }

    /**
     * 按调用次数依次返回预置页的 fake 服务端；越界后返回空页（模拟服务端无更多数据）。
     *
     * [sinceCalls] / [limitCalls] / [roots] 记录每次调用入参，供断言分页推进逻辑。
     */
    private class FakeApi(private val pages: List<ResourcesPageDto>) : ResourcesApi {
        val sinceCalls = ArrayList<Long?>()
        val limitCalls = ArrayList<Int>()
        val roots = ArrayList<String>()

        override fun resources(root: String, sinceMtime: Long?, limit: Int): ResourcesPageDto {
            roots += root
            sinceCalls += sinceMtime
            limitCalls += limit
            return pages.getOrElse(sinceCalls.size - 1) { ResourcesPageDto() }
        }
    }

    /** 构造本地索引条目（默认 dirty，便于作为回填候选）。 */
    private fun entry(
        uid: String,
        root: String = "main",
        path: String = "$uid.epub",
        dirty: Boolean = true,
        deleted: Boolean = false,
    ) = ResourceEntry(
        uid = uid,
        root = root,
        path = path,
        blob = "",
        size = 0,
        mtime = 0,
        deleted = deleted,
        dirty = dirty,
    )

    /** 构造服务端资源条目（只需回填用到的字段）。 */
    private fun dto(
        uid: String,
        size: Long = 10L,
        mtime: Long = 1L,
        blob: String = "blob-$uid",
        deletedAt: String = "",
        root: String = "main",
        path: String = "$uid.epub",
    ) = ResourceDto(
        uid = uid,
        root = root,
        path = path,
        blob = blob,
        size = size,
        mtime = mtime,
        deletedAt = deletedAt,
    )

    /** 构造单页响应。 */
    private fun page(items: List<ResourceDto>, hasMore: Boolean = false) =
        ResourcesPageDto(items = items, hasMore = hasMore)

    @Test
    fun `单页回填两条 dirty 条目并清脏`() {
        val index = FakePrefs().index()
        index.upsertAll(listOf(entry("a"), entry("b")))
        val api = FakeApi(
            listOf(
                page(
                    listOf(
                        dto("a", size = 100L, mtime = 50L, blob = "ba"),
                        dto("b", size = 200L, mtime = 60L, blob = "bb"),
                    ),
                ),
            ),
        )

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(2, result.updated)
        assertEquals(1, result.pages)
        // 首页 since 缺省 null；limit 用默认 2000；root 透传
        assertEquals(listOf<Long?>(null), api.sinceCalls)
        assertEquals(listOf(2000), api.limitCalls)
        assertEquals(listOf("main"), api.roots)
        assertTrue(index.dirtyEntries("main").isEmpty())
        val a = index.findByUid("a")
        assertNotNull(a)
        assertEquals(100L, a!!.size)
        assertEquals(50L, a.mtime)
        assertEquals("ba", a.blob)
        assertFalse(a.dirty)
        // root + path 不被服务端响应改写
        assertEquals("a.epub", a.path)
    }

    @Test
    fun `多页按本页最大 mtime 推进 since`() {
        val index = FakePrefs().index()
        index.upsertAll(listOf(entry("a"), entry("b")))
        val api = FakeApi(
            listOf(
                page(listOf(dto("a", mtime = 100L)), hasMore = true),
                page(listOf(dto("b", mtime = 150L)), hasMore = false),
            ),
        )

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(2, result.updated)
        assertEquals(2, result.pages)
        assertEquals(listOf<Long?>(null, 100L), api.sinceCalls)
    }

    @Test
    fun `同秒边界不死循环而是 since 加一推进`() {
        val index = FakePrefs().index()
        index.upsert(entry("c"))
        val api = FakeApi(
            listOf(
                // 首页：只有未知 uid，dirty 的 c 未被命中 → dirty 仍非空
                page(listOf(dto("x", mtime = 100L)), hasMore = true),
                // 第二页：最大 mtime 与上一页 since 相同且无新命中 → since 必须 +1
                page(listOf(dto("x", mtime = 100L)), hasMore = true),
                // 第三页：命中 c
                page(listOf(dto("c", mtime = 120L)), hasMore = false),
            ),
        )

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(listOf<Long?>(null, 100L, 101L), api.sinceCalls)
        assertEquals(1, result.updated)
        assertEquals(3, result.pages)
        val c = index.findByUid("c")
        assertNotNull(c)
        assertFalse(c!!.dirty)
        assertEquals(120L, c.mtime)
    }

    @Test
    fun `空页即结束且不再请求`() {
        val index = FakePrefs().index()
        index.upsert(entry("a"))
        val api = FakeApi(listOf(ResourcesPageDto()))

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(0, result.updated)
        assertEquals(1, result.pages)
        assertEquals(1, api.sinceCalls.size)
        // 未命中 → 保持 dirty，等下次 sync 重试
        assertEquals(listOf("a"), index.dirtyEntries("main").map { it.uid })
    }

    @Test
    fun `没有 dirty 条目时不发起任何请求`() {
        val index = FakePrefs().index()
        index.upsert(entry("a", dirty = false))
        val api = FakeApi(emptyList())

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(0, result.updated)
        assertEquals(0, result.pages)
        assertTrue(api.sinceCalls.isEmpty())
    }

    @Test
    fun `maxPages 触顶后停止并返回已拉取页数`() {
        val index = FakePrefs().index()
        index.upsert(entry("c"))
        // 60 页都 hasMore=true，且都是未知 uid（dirty 永不清空）
        val pages = (1..60).map { i ->
            page(listOf(dto("ghost-$i", mtime = i.toLong())), hasMore = true)
        }
        val api = FakeApi(pages)

        val result = MetadataBackfill(api, index, pageLimit = 10, maxPages = 50).backfill("main")

        assertEquals(0, result.updated)
        assertEquals(50, result.pages)
        assertEquals(50, api.sinceCalls.size)
        assertTrue(api.limitCalls.all { it == 10 })
        // 分页按 mtime 逐页推进
        assertEquals(49L, api.sinceCalls.last())
    }

    @Test
    fun `服务端墓碑条目标记本地删除而不回填`() {
        val index = FakePrefs().index()
        index.upsertAll(listOf(entry("a"), entry("d", dirty = false)))
        val api = FakeApi(
            listOf(page(listOf(dto("d", deletedAt = "2026-10-19T00:00:00Z")))),
        )

        MetadataBackfill(api, index).backfill("main")

        val d = index.findByUid("d")
        assertNotNull(d)
        assertTrue(d!!.deleted)
        assertTrue(index.alive().none { it.uid == "d" })
    }

    @Test
    fun `服务端未知 uid 忽略且不产生更新`() {
        val index = FakePrefs().index()
        index.upsert(entry("a"))
        val api = FakeApi(listOf(page(listOf(dto("ghost", size = 9L, mtime = 5L)))))

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(0, result.updated)
        assertEquals(1, index.all().size)
        assertEquals(listOf("a"), index.dirtyEntries("main").map { it.uid })
    }

    @Test
    fun `连续两次调用幂等第二次无更新`() {
        val index = FakePrefs().index()
        index.upsert(entry("a"))
        val api = FakeApi(listOf(page(listOf(dto("a", size = 7L, mtime = 3L)))))
        val backfill = MetadataBackfill(api, index)

        val first = backfill.backfill("main")
        val second = backfill.backfill("main")

        assertEquals(1, first.updated)
        assertEquals(1, first.pages)
        assertEquals(0, second.updated)
        assertEquals(0, second.pages)
        assertEquals(1, api.sinceCalls.size)
    }

    @Test
    fun `只回填指定根忽略其它根的 dirty 条目`() {
        val index = FakePrefs().index()
        index.upsertAll(listOf(entry("a"), entry("b", root = "other")))
        val api = FakeApi(
            listOf(
                page(listOf(dto("a"), dto("b", root = "other")), hasMore = false),
            ),
        )

        val result = MetadataBackfill(api, index).backfill("main")

        assertEquals(1, result.updated)
        assertEquals("main", api.roots.single())
        assertEquals(listOf("b"), index.dirtyEntries("other").map { it.uid })
        assertFalse(index.findByUid("a")!!.dirty)
    }
}
