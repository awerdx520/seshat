package com.seshat.app.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * [ResourceIndex] 单测（纯 JVM，用内存 fake 代替 SharedPreferences）。
 *
 * 覆盖：空/缺失/损坏兜底、游标持久化（含超大 Long）、upsert 原位替换、
 * 查找、rename、墓碑、根过滤、clear、跨实例 round-trip。
 */
class ResourceIndexTest {

    /** 内存 fake prefs：单键单值，模拟 `getString(KEY_DOCUMENT, null)` 与 `putString`。 */
    private class FakePrefs {
        var stored: String? = null

        /** 落盘（`write`）调用次数：用于断言批量写盘没有写放大。 */
        var writes = 0

        fun index() = ResourceIndex(
            read = { stored },
            write = {
                stored = it
                writes++
            },
        )
    }

    /** 构造测试条目（默认字段可控）。 */
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

    // ---- 1. 空 / 缺失 / 空白 ----

    @Test
    fun emptyPrefsYieldsEmptyDocument() {
        val prefs = FakePrefs()
        val index = prefs.index()
        assertEquals(0L, index.cursor())
        assertTrue(index.all().isEmpty())
        assertTrue(index.alive().isEmpty())
        assertNull(index.findByUid("missing"))
    }

    @Test
    fun blankStoredValueYieldsEmptyDocument() {
        val prefs = FakePrefs()
        prefs.stored = "   "
        val index = prefs.index()
        assertEquals(0L, index.cursor())
        assertTrue(index.all().isEmpty())
    }

    // ---- 2. 游标 ----

    @Test
    fun setCursorPersistsIncludingHugeLong() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.setCursor(9007199254740993L)
        assertEquals(9007199254740993L, index.cursor())
        // 新实例（同一 stored）独立还原，证明真的落盘而非仅内存
        assertEquals(9007199254740993L, prefs.index().cursor())
        // 只改 cursor，不动 entries
        index.upsert(entry("a"))
        index.setCursor(7L)
        assertEquals(7L, index.cursor())
        assertEquals(1, index.all().size)
    }

    // ---- 3~5. upsert 与查找 ----

    @Test
    fun upsertAppendsNewEntryWithAllFields() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", root = "main", path = "a.md", blob = "b1", size = 123, mtime = 456))
        val all = index.all()
        assertEquals(1, all.size)
        val got = all.first()
        assertEquals("a", got.uid)
        assertEquals("main", got.root)
        assertEquals("a.md", got.path)
        assertEquals("b1", got.blob)
        assertEquals(123L, got.size)
        assertEquals(456L, got.mtime)
        assertFalse(got.deleted)
        assertFalse(got.dirty)
        // 默认值也写入（encodeDefaults = true），保证 round-trip 语义不丢
        val stored = prefs.stored!!
        assertTrue(stored.contains("\"deleted\""))
        assertTrue(stored.contains("\"dirty\""))
    }

    @Test
    fun upsertSameUidReplacesInPlaceWithoutDuplicates() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", path = "a.md", size = 1))
        index.upsert(entry("b", path = "b.md", size = 2))
        index.upsert(entry("c", path = "c.md", size = 3))
        // 原位替换 a（不是追加到末尾）
        index.upsert(entry("a", path = "a-new.md", blob = "blob-new", size = 99))

        val all = index.all()
        assertEquals(3, all.size)
        assertEquals(listOf("a", "b", "c"), all.map { it.uid })
        val got = index.findByUid("a")!!
        assertEquals("a-new.md", got.path)
        assertEquals("blob-new", got.blob)
        assertEquals(99L, got.size)
    }

    @Test
    fun findByUidReturnsNullWhenMissing() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a"))
        assertNull(index.findByUid("nope"))
        assertEquals("a", index.findByUid("a")!!.uid)
    }

    @Test
    fun findByPathMatchesRootAndPathTogether() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", root = "main", path = "same.md"))
        index.upsert(entry("b", root = "other", path = "same.md"))

        assertEquals("a", index.findByPath("main", "same.md")!!.uid)
        assertEquals("b", index.findByPath("other", "same.md")!!.uid)
        // 不同 root 同 path 不互相误命中
        assertNull(index.findByPath("third", "same.md"))
        // 同 root 不同 path 不命中
        assertNull(index.findByPath("main", "another.md"))
    }

    // ---- 7~8. rename ----

    @Test
    fun renameChangesOnlyPath() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", root = "main", path = "old.md", blob = "blob-a", size = 12, mtime = 34))
        index.rename("a", "sub/new.md")

        val got = index.findByUid("a")!!
        assertEquals("a", got.uid)
        assertEquals("main", got.root)
        assertEquals("sub/new.md", got.path)
        assertEquals("blob-a", got.blob)
        assertEquals(12L, got.size)
        assertEquals(34L, got.mtime)
        // 旧路径不再命中
        assertNull(index.findByPath("main", "old.md"))
        assertEquals("a", index.findByPath("main", "sub/new.md")!!.uid)
    }

    @Test
    fun renameUnknownUidIsSilentNoOp() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a"))
        val before = prefs.stored
        index.rename("ghost", "x.md") // 不抛
        assertEquals(1, index.all().size)
        assertEquals(before, prefs.stored) // 未发生写盘
        assertNull(index.findByUid("ghost"))
    }

    // ---- 9~10. 墓碑 ----

    @Test
    fun markDeletedKeepsUidRootAndPath() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", root = "main", path = "dir/a.md"))
        index.markDeleted("a")

        val got = index.findByUid("a")!!
        assertTrue(got.deleted)
        assertEquals("a", got.uid)
        assertEquals("main", got.root)
        assertEquals("dir/a.md", got.path)
        // 墓碑仍可被 findByPath 命中（B 批「同路径重建复用 uid」依赖）
        assertEquals("a", index.findByPath("main", "dir/a.md")!!.uid)
    }

    @Test
    fun markDeletedUnknownUidIsSilentNoOp() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a"))
        index.markDeleted("ghost") // 不抛
        assertEquals(1, index.all().size)
        assertFalse(index.findByUid("a")!!.deleted)
    }

    // ---- 11~12. 视图过滤 ----

    @Test
    fun aliveFiltersTombstonesKeepingOrder() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a"))
        index.upsert(entry("b"))
        index.upsert(entry("c"))
        index.markDeleted("b")

        assertEquals(listOf("a", "c"), index.alive().map { it.uid })
        assertEquals(listOf("a", "b", "c"), index.all().map { it.uid })
    }

    @Test
    fun entriesInRootReturnsAllEntriesIncludingTombstones() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", root = "main"))
        index.upsert(entry("b", root = "other"))
        index.upsert(entry("c", root = "main"))
        index.markDeleted("c")

        val main = index.entriesInRoot("main")
        assertEquals(listOf("a", "c"), main.map { it.uid })
        assertTrue(main.first { it.uid == "c" }.deleted)
        assertEquals(listOf("b"), index.entriesInRoot("other").map { it.uid })
        assertTrue(index.entriesInRoot("absent").isEmpty())
    }

    // ---- 13. clear ----

    @Test
    fun clearResetsDocumentAndWritesNonNullValue() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a"))
        index.setCursor(42L)

        index.clear()

        assertTrue(index.all().isEmpty())
        assertEquals(0L, index.cursor())
        assertNotNull(prefs.stored) // 不得 write(null)
        // 新实例同样看到空文档
        assertEquals(0L, prefs.index().cursor())
        assertTrue(prefs.index().all().isEmpty())
    }

    // ---- 14. 损坏 JSON 兜底 ----

    @Test
    fun corruptJsonFallsBackToEmptyDocumentAndStaysUsable() {
        val prefs = FakePrefs()
        prefs.stored = "{not json"
        val index = prefs.index()

        assertEquals(0L, index.cursor()) // 不抛异常
        assertTrue(index.all().isEmpty())

        // 之后仍能正常写入（覆盖为新文档）
        index.upsert(entry("a"))
        assertEquals(1, index.all().size)
        assertEquals(listOf("a"), prefs.index().all().map { it.uid })
    }

    // ---- 15. round-trip（跨实例，含超大 Long） ----

    @Test
    fun roundTripThroughNewInstancePreservesFieldsAndHugeLongs() {
        val prefs = FakePrefs()
        val first = prefs.index()
        first.setCursor(9007199254740993L)
        first.upsert(entry("a", root = "r1", path = "p/a.md", blob = "blob-1", size = 9007199254740995L, mtime = 9007199254740997L))
        first.upsert(entry("b", root = "r2", path = "p/b.md", blob = "blob-2", size = 3L, mtime = 4L, dirty = true))

        val second = prefs.index()
        assertEquals(9007199254740993L, second.cursor())
        val all = second.all()
        assertEquals(listOf("a", "b"), all.map { it.uid })

        val a = second.findByUid("a")!!
        assertEquals("r1", a.root)
        assertEquals("p/a.md", a.path)
        assertEquals("blob-1", a.blob)
        assertEquals(9007199254740995L, a.size)
        assertEquals(9007199254740997L, a.mtime)
        assertFalse(a.deleted)
        assertFalse(a.dirty)

        val b = second.findByUid("b")!!
        assertTrue(b.dirty)
        assertEquals(3L, b.size)
    }

    // ---- 16. upsertAll：空列表不写盘 ----

    @Test
    fun upsertAllWithEmptyListDoesNotWrite() {
        val prefs = FakePrefs()
        val index = prefs.index()

        index.upsertAll(emptyList())

        assertEquals(0, prefs.writes)
        assertTrue(index.all().isEmpty())
        assertNull(prefs.stored) // 连空文档都不写（保持「从未落盘」的原状）
    }

    // ---- 17. upsertAll：一次写盘 ----

    @Test
    fun upsertAllWritesOnceForWholeBatch() {
        val prefs = FakePrefs()
        val index = prefs.index()

        index.upsertAll((1..100).map { entry("u$it", path = "f$it.md") })

        // 逐条 upsert 会写 100 次；upsertAll 只写 1 次
        assertEquals(1, prefs.writes)
        assertEquals(100, index.all().size)
        assertEquals(100, prefs.index().all().size) // 真的落盘了
    }

    // ---- 18. upsertAll：语义与逐条 upsert 完全一致 ----

    @Test
    fun upsertAllMatchesSequentialUpsertSemantics() {
        val batchPrefs = FakePrefs()
        val batchIndex = batchPrefs.index()
        val batch = listOf(
            entry("a", path = "a.md", size = 1),
            entry("b", path = "b.md", size = 2),
            entry("a", path = "a-new.md", blob = "blob-new", size = 99), // 同 uid 原位替换
            entry("c", path = "c.md", size = 3),
            entry("b", path = "b-new.md", size = 22, dirty = true),
        )
        batchIndex.upsertAll(batch)

        val seqIndex = FakePrefs().index()
        batch.forEach { seqIndex.upsert(it) }

        // 顺序不变、无重复、同 uid 取最后一条
        assertEquals(seqIndex.all(), batchIndex.all())
        assertEquals(listOf("a", "b", "c"), batchIndex.all().map { it.uid })
        assertEquals("a-new.md", batchIndex.findByUid("a")!!.path)
        assertEquals(22L, batchIndex.findByUid("b")!!.size)
        assertTrue(batchIndex.findByUid("b")!!.dirty)
    }

    // ---- 19~20. dirtyEntries：回填候选（目标根 + dirty + 非墓碑） ----

    @Test
    fun dirtyEntriesReturnsOnlyTargetRootDirtyAliveEntries() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsertAll(
            listOf(
                entry("a", root = "main", dirty = true),
                entry("b", root = "main", dirty = false),
                entry("c", root = "main", dirty = true, deleted = true), // 墓碑不回填
                entry("d", root = "other", dirty = true),
            ),
        )

        val dirty = index.dirtyEntries("main")
        assertEquals(listOf("a"), dirty.map { it.uid })

        // 返回快照：改动返回的列表不影响索引
        @Suppress("UNCHECKED_CAST")
        (dirty as MutableList<ResourceEntry>).clear()
        assertEquals(listOf("a"), index.dirtyEntries("main").map { it.uid })
        assertEquals(4, index.all().size)
    }

    @Test
    fun dirtyEntriesExcludesOtherRoots() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsertAll(
            listOf(
                entry("a", root = "main", dirty = true),
                entry("d", root = "other", dirty = true),
                entry("e", root = "ebooks", dirty = true),
            ),
        )

        assertEquals(listOf("d"), index.dirtyEntries("other").map { it.uid })
        assertEquals(listOf("e"), index.dirtyEntries("ebooks").map { it.uid })
        assertTrue(index.dirtyEntries("absent").isEmpty())
    }

    // ---- 21~24. applyMetadata：批量回填 + 清 dirty ----

    @Test
    fun applyMetadataBackfillsFieldsAndClearsDirty() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", blob = "", size = 0, mtime = 0, dirty = true))

        index.applyMetadata(listOf(ResourceMetadataUpdate(uid = "a", blob = "b1", size = 111, mtime = 222)))

        val got = index.findByUid("a")!!
        assertEquals("b1", got.blob)
        assertEquals(111L, got.size)
        assertEquals(222L, got.mtime)
        assertFalse(got.dirty)
        assertFalse(got.deleted)
        // 真的落盘：新实例看到同样的结果
        val reread = prefs.index().findByUid("a")!!
        assertEquals("b1", reread.blob)
        assertEquals(111L, reread.size)
        assertFalse(reread.dirty)
    }

    @Test
    fun applyMetadataIgnoresUnknownUidSilently() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", size = 7, mtime = 8, dirty = true))
        index.upsert(entry("b", size = 9, mtime = 10))
        val storedBefore = prefs.stored

        // 全是未知 uid：不抛、不改、不写盘
        index.applyMetadata(
            listOf(
                ResourceMetadataUpdate("ghost", "bg", 1, 2),
                ResourceMetadataUpdate("phantom", "bp", 3, 4),
            ),
        )

        assertEquals(2, index.all().size)
        val a = index.findByUid("a")!!
        assertEquals(7L, a.size)
        assertTrue(a.dirty) // 未被误清
        assertEquals(9L, index.findByUid("b")!!.size)
        assertNull(index.findByUid("ghost"))
        assertEquals(storedBefore, prefs.stored)
    }

    @Test
    fun applyMetadataUpdatesTombstoneKeepingDeletedFlag() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", size = 1, mtime = 2, dirty = true))
        index.markDeleted("a")

        index.applyMetadata(listOf(ResourceMetadataUpdate("a", "b2", 33, 44)))

        val got = index.findByUid("a")!!
        assertTrue(got.deleted) // 墓碑保留
        assertFalse(got.dirty) // dirty 清掉
        assertEquals("b2", got.blob)
        assertEquals(33L, got.size)
        assertEquals(44L, got.mtime)
    }

    @Test
    fun applyMetadataWithEmptyListDoesNotWrite() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", size = 0, mtime = 0, dirty = true))
        val writesBefore = prefs.writes

        index.applyMetadata(emptyList())

        assertEquals(writesBefore, prefs.writes) // 不写盘
        val a = index.findByUid("a")!!
        assertTrue(a.dirty) // dirty 未被清
        assertEquals(0L, a.size)
    }

    @Test
    fun applyMetadataWritesOnceForWholeBatch() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsertAll((1..50).map { entry("u$it", size = 0, mtime = 0, dirty = true) })
        val writesBefore = prefs.writes

        index.applyMetadata((1..50).map { ResourceMetadataUpdate("u$it", "blob-$it", it.toLong(), it * 2L) })

        assertEquals(writesBefore + 1, prefs.writes) // 批量只写一次
        assertEquals(0, index.dirtyEntries("main").size)
        assertEquals(50L, index.findByUid("u50")!!.size)
    }

    // ---- 25. 读方法返回快照副本 ----

    @Test
    fun readMethodsReturnSnapshotCopies() {
        val prefs = FakePrefs()
        val index = prefs.index()
        index.upsert(entry("a", root = "main"))
        index.upsert(entry("b", root = "main"))

        @Suppress("UNCHECKED_CAST")
        (index.all() as MutableList<ResourceEntry>).clear()
        @Suppress("UNCHECKED_CAST")
        (index.alive() as MutableList<ResourceEntry>).clear()
        @Suppress("UNCHECKED_CAST")
        (index.entriesInRoot("main") as MutableList<ResourceEntry>).clear()
        @Suppress("UNCHECKED_CAST")
        (index.dirtyEntries("main") as MutableList<ResourceEntry>).add(entry("ghost"))

        // 索引内部未被外部改动污染
        assertEquals(listOf("a", "b"), index.all().map { it.uid })
        assertEquals(listOf("a", "b"), index.alive().map { it.uid })
        assertEquals(listOf("a", "b"), index.entriesInRoot("main").map { it.uid })
        assertTrue(index.dirtyEntries("main").isEmpty())
    }

    // ---- 26. 并发 upsert 不丢条目（验证 @Synchronized 有效） ----

    @Test(timeout = 10_000)
    fun concurrentUpsertsLoseNoEntries() {
        val prefs = FakePrefs()
        val index = prefs.index()
        val pool = Executors.newFixedThreadPool(2)
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        try {
            repeat(2) { thread ->
                pool.execute {
                    start.await() // 尽量让两个线程同时进入
                    for (i in 1..100) index.upsert(entry("t$thread-u$i"))
                    done.countDown()
                }
            }
            start.countDown()
            assertTrue("并发任务未在 8s 内完成", done.await(8, TimeUnit.SECONDS))
        } finally {
            pool.shutdown()
        }

        assertEquals(200, index.all().size)
        assertEquals(200, prefs.index().all().size) // 落盘结果也完整
    }
}
