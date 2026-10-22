package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** [PdfAnnotation] / [PdfAnnotationStore] 的纯 JVM 单元测试。 */
class PdfAnnotationStoreTest {

    private fun newStore(): Pair<PdfAnnotationStore, MutableMap<String, String>> {
        val map = mutableMapOf<String, String>()
        val store = PdfAnnotationStore(read = { map[it] }, write = { k, v -> map[k] = v })
        return store to map
    }

    private fun sample(id: Long, docId: String, location: String = "page:1", text: String = "备注") =
        PdfAnnotation(
            id = id,
            documentId = docId,
            location = location,
            text = text,
            createdAt = 100L,
            updatedAt = 100L,
        )

    @Test
    fun keyUsesPdfNamespace() {
        assertEquals("pdf_annotations_book", PdfAnnotationStore.key("book"))
    }

    @Test
    fun emptyByDefault() {
        val (store, _) = newStore()
        assertTrue(store.list("doc1").isEmpty())
        assertEquals(0, store.count("doc1"))
    }

    @Test
    fun addPersistsJsonAndLists() {
        val (store, map) = newStore()
        val a = sample(1, "doc1")
        store.add(a)
        assertEquals(listOf(a), store.list("doc1"))
        assertEquals(1, store.count("doc1"))
        assertTrue(map.containsKey("pdf_annotations_doc1"))
    }

    @Test
    fun addAppendsInOrder() {
        val (store, _) = newStore()
        store.add(sample(1, "doc1", text = "first"))
        store.add(sample(2, "doc1", text = "second"))
        assertEquals(listOf("first", "second"), store.list("doc1").map { it.text })
    }

    @Test
    fun nextIdStartsAtOneAndIncrements() {
        val (store, _) = newStore()
        assertEquals(1L, store.nextId("doc1"))
        store.add(sample(1, "doc1"))
        assertEquals(2L, store.nextId("doc1"))
        store.add(sample(2, "doc1"))
        assertEquals(3L, store.nextId("doc1"))
    }

    // ---- M10.3 T3：模型新字段 / add 自动分配 id / update / remove ----

    /** 旧 JSON（缺 kind/selectedText/serverId/dirty 四键）反序列化后取默认值，保证向后兼容。 */
    @Test
    fun legacyJsonWithoutNewKeysDecodesToDefaults() {
        val map = mutableMapOf(
            PdfAnnotationStore.key("doc1") to
                """[{"id":1,"documentId":"doc1","location":"page:1","text":"旧批注","createdAt":10,"updatedAt":20}]""",
        )
        val store = PdfAnnotationStore(read = { map[it] }, write = { k, v -> map[k] = v })

        val loaded = store.list("doc1").single()

        assertEquals("note", loaded.kind)
        assertEquals("", loaded.selectedText)
        assertNull(loaded.serverId)
        assertFalse(loaded.dirty)
        assertEquals("旧批注", loaded.text)
    }

    /** 新字段随 JSON 往返（写 → 读）。 */
    @Test
    fun newFieldsSurviveJsonRoundTrip() {
        val (store, _) = newStore()
        store.add(
            sample(1, "doc1").copy(
                kind = "highlight",
                selectedText = "选中原文",
                serverId = 42L,
                dirty = true,
            ),
        )

        val loaded = store.list("doc1").single()

        assertEquals("highlight", loaded.kind)
        assertEquals("选中原文", loaded.selectedText)
        assertEquals(42L, loaded.serverId)
        assertTrue(loaded.dirty)
    }

    /** `id <= 0` 时按 store 现有最大 id + 1 分配，连续两次递增（拉取后入库不再恒为 0）。 */
    @Test
    fun addGeneratesNextIdWhenIdIsNonPositive() {
        val (store, _) = newStore()

        val first = store.add(sample(0, "doc1"))
        val second = store.add(sample(-5, "doc1"))

        assertEquals(1L, first.id)
        assertEquals(2L, second.id)
        assertEquals(listOf(1L, 2L), store.list("doc1").map { it.id })
    }

    /** 已有记录不受影响：显式正 id 原样保留。 */
    @Test
    fun addKeepsPositiveId() {
        val (store, _) = newStore()
        val saved = store.add(sample(7, "doc1"))
        assertEquals(7L, saved.id)
    }

    @Test
    fun updateReplacesMatchingIdInPlace() {
        val (store, _) = newStore()
        store.add(sample(1, "doc1", text = "first"))
        store.add(sample(2, "doc1", text = "second"))

        assertTrue(store.update(sample(2, "doc1", text = "second-改")))

        assertEquals(listOf("first", "second-改"), store.list("doc1").map { it.text })
        assertEquals(listOf(1L, 2L), store.list("doc1").map { it.id })
    }

    @Test
    fun updateMissingIdReturnsFalseWithoutWriting() {
        val (store, map) = newStore()
        store.add(sample(1, "doc1", text = "only"))
        val before = map[PdfAnnotationStore.key("doc1")]

        assertFalse(store.update(sample(9, "doc1", text = "幽灵")))

        assertEquals(before, map[PdfAnnotationStore.key("doc1")])
        assertEquals(listOf("only"), store.list("doc1").map { it.text })
    }

    /** update 不得跨文档误命中。 */
    @Test
    fun updateTargetsGivenDocumentOnly() {
        val (store, _) = newStore()
        store.add(sample(1, "docA", text = "a"))
        store.add(sample(1, "docB", text = "b"))

        assertTrue(store.update(sample(1, "docA", text = "a-改")))

        assertEquals("a-改", store.list("docA").single().text)
        assertEquals("b", store.list("docB").single().text)
    }

    @Test
    fun removeDeletesOnlyMatchingIdAndReportsResult() {
        val (store, _) = newStore()
        store.add(sample(1, "doc1", text = "keep"))
        store.add(sample(2, "doc1", text = "drop"))

        assertTrue(store.remove("doc1", 2L))
        assertFalse(store.remove("doc1", 2L))
        assertFalse(store.remove("doc1", 99L))
        assertEquals(listOf("keep"), store.list("doc1").map { it.text })
    }

    @Test
    fun documentsAreIsolated() {
        val (store, _) = newStore()
        store.add(sample(1, "docA"))
        assertTrue(store.list("docB").isEmpty())
    }

    @Test
    fun corruptJsonReturnsEmpty() {
        val map = mutableMapOf(PdfAnnotationStore.key("doc1") to "{not valid json")
        val store = PdfAnnotationStore(read = { map[it] }, write = { k, v -> map[k] = v })
        assertTrue(store.list("doc1").isEmpty())
    }

    @Test
    fun clearLegacyStripsPrefixBeforeJudging() {
        val hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
        val uid = "0123456789ABCDEFGHJKMNPQRS"
        val uri = "content://media/external/document/7"
        val map = mutableMapOf(
            PdfAnnotationStore.key(hex) to "[]",
            PdfAnnotationStore.key(uri) to "[]",
            PdfAnnotationStore.key(uid) to "[]",
            PdfAnnotationStore.key("doc1") to "[]",
            // 其它 store 前缀的旧键不归本 store 管
            PdfInkStore.key(hex) to "{}",
        )
        val store = PdfAnnotationStore(
            read = { map[it] },
            write = { k, v -> map[k] = v },
            keys = { map.keys.toSet() },
            remove = { map.remove(it) },
        )

        assertEquals(2, store.clearLegacy())

        assertFalse(map.containsKey(PdfAnnotationStore.key(hex)))
        assertFalse(map.containsKey(PdfAnnotationStore.key(uri)))
        assertTrue(map.containsKey(PdfAnnotationStore.key(uid)))
        assertTrue(map.containsKey(PdfAnnotationStore.key("doc1")))
        assertTrue(map.containsKey(PdfInkStore.key(hex)))
    }

    /**
     * 并发 `add`（R1 blocking 回归）：主线程落笔/删除与同步线程回填 serverId 并发写同一 docId，
     * `add` 是「读整表 → 追加 → 整表回写」，无 `@Synchronized` 时后写覆盖先写、记录消失。
     *
     * 存储用 [ConcurrentHashMap]：被测点是 store 层的 read-modify-write 竞态，不是 map 自身。
     */
    @Test
    fun concurrentAddsLoseNoAnnotations() {
        val map = ConcurrentHashMap<String, String>()
        val store = PdfAnnotationStore(read = { map[it] }, write = { k, v -> map[k] = v })
        val threads = 4
        val perThread = 100
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val pool = Executors.newFixedThreadPool(threads)
        try {
            repeat(threads) { index ->
                pool.execute {
                    start.await()
                    try {
                        repeat(perThread) { offset ->
                            store.add(sample(id = 0L, docId = "doc1", text = "n-$index-$offset"))
                        }
                    } finally {
                        done.countDown()
                    }
                }
            }
            start.countDown()
            assertTrue("并发 add 未在 30 秒内完成（疑似死锁）", done.await(30, TimeUnit.SECONDS))
        } finally {
            pool.shutdown()
        }

        val stored = store.list("doc1")
        assertEquals("并发 add 丢批注", threads * perThread, stored.size)
        // 本地 id 必须唯一：id 分配与写入必须同处一把锁内，否则会出现重复 id
        assertEquals(threads * perThread, stored.map { it.id }.toSet().size)
    }
}
