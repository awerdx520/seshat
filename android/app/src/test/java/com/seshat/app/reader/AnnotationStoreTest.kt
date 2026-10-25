package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** AnnotationStore 读写单测（内存版 SharedPreferences，纯 JVM）。 */
class AnnotationStoreTest {

    private val prefs = FakeSharedPreferences()
    private val store = AnnotationStore(prefs)

    @Test
    fun addAssignsIdAndCreatedAtThenPersists() {
        val saved = store.add(
            BookAnnotation(documentId = "doc-1", chapterIndex = 2, selectedText = "选中文本", note = "我的批注"),
        )

        assertTrue(saved.id.isNotBlank())
        assertTrue(saved.createdAt > 0L)

        val list = store.list("doc-1")
        assertEquals(1, list.size)
        assertEquals(saved.id, list[0].id)
        assertEquals(2, list[0].chapterIndex)
        assertEquals("选中文本", list[0].selectedText)
        assertEquals("我的批注", list[0].note)
    }

    @Test
    fun listKeepsInsertionOrder() {
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 0, selectedText = "a", note = "n1"))
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 1, selectedText = "b", note = "n2"))

        assertEquals(listOf("a", "b"), store.list("doc-1").map { it.selectedText })
        assertEquals(listOf("n1", "n2"), store.list("doc-1").map { it.note })
    }

    @Test
    fun annotationsAreIsolatedPerDocument() {
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 0, selectedText = "x", note = "n"))
        store.add(BookAnnotation(documentId = "doc-2", chapterIndex = 0, selectedText = "y", note = "m"))

        assertEquals(1, store.list("doc-1").size)
        assertEquals(1, store.list("doc-2").size)
        assertEquals("y", store.list("doc-2")[0].selectedText)
    }

    @Test
    fun listUnknownDocumentReturnsEmpty() {
        assertTrue(store.list("missing").isEmpty())
    }

    @Test
    fun removeDeletesOnlyMatchingId() {
        val first = store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 0, selectedText = "a", note = ""))
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 1, selectedText = "b", note = ""))

        assertTrue(store.remove("doc-1", first.id))
        assertEquals(listOf("b"), store.list("doc-1").map { it.selectedText })
        assertFalse(store.remove("doc-1", "not-exists"))
    }

    @Test
    fun clearRemovesAllAnnotationsOfDocument() {
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 0, selectedText = "a", note = ""))
        store.clear("doc-1")
        assertTrue(store.list("doc-1").isEmpty())
    }

    @Test
    fun corruptedJsonReturnsEmptyListInsteadOfThrowing() {
        prefs.putRaw("doc-1", "[{\"broken\":")
        assertTrue(store.list("doc-1").isEmpty())
    }

    @Test
    fun explicitIdIsKept() {
        val saved = store.add(
            BookAnnotation(
                id = "fixed-id",
                documentId = "doc-1",
                chapterIndex = 0,
                selectedText = "a",
                note = "",
                createdAt = 42L,
            ),
        )
        assertEquals("fixed-id", saved.id)
        assertEquals(42L, saved.createdAt)
    }

    // ---- M10.3 T3：模型新字段 / update ----

    /** 旧 JSON（缺 location/kind/serverId/dirty 四键）反序列化后取默认值，保证向后兼容。 */
    @Test
    fun legacyJsonWithoutNewKeysDecodesToDefaults() {
        prefs.putRaw(
            "doc-1",
            """[{"id":"a","documentId":"doc-1","chapterIndex":2,"selectedText":"旧选中","note":"旧备注","createdAt":7}]""",
        )

        val loaded = store.list("doc-1").single()

        assertEquals("", loaded.location)
        assertEquals("note", loaded.kind)
        assertNull(loaded.serverId)
        assertFalse(loaded.dirty)
        assertEquals("旧备注", loaded.note)
    }

    /** 新字段随 JSON 往返（写 → 读）。 */
    @Test
    fun newFieldsSurviveJsonRoundTrip() {
        store.add(
            BookAnnotation(
                documentId = "doc-1",
                chapterIndex = 3,
                selectedText = "选中",
                note = "",
                location = "chapter:3@10-20",
                kind = "highlight",
                serverId = 88L,
                dirty = true,
            ),
        )

        val loaded = store.list("doc-1").single()

        assertEquals("chapter:3@10-20", loaded.location)
        assertEquals("highlight", loaded.kind)
        assertEquals(88L, loaded.serverId)
        assertTrue(loaded.dirty)
    }

    @Test
    fun updateReplacesMatchingIdAndKeepsCreatedAt() {
        val saved = store.add(
            BookAnnotation(
                documentId = "doc-1",
                chapterIndex = 0,
                selectedText = "a",
                note = "旧",
                createdAt = 100L,
            ),
        )

        val ok = store.update(
            BookAnnotation(
                id = saved.id,
                documentId = "doc-1",
                chapterIndex = 5,
                selectedText = "新选中",
                note = "新备注",
                createdAt = 100L,
            ),
        )

        assertTrue(ok)
        val list = store.list("doc-1")
        assertEquals(1, list.size)
        assertEquals("新备注", list[0].note)
        assertEquals(5, list[0].chapterIndex)
        assertEquals(100L, list[0].createdAt)
    }

    /** update 保留 add 的补齐语义：createdAt=0 补当前时间，id 为空串补 UUID。 */
    @Test
    fun updateFillsZeroCreatedAt() {
        val saved = store.add(
            BookAnnotation(
                documentId = "doc-1",
                chapterIndex = 0,
                selectedText = "a",
                note = "旧",
                createdAt = 100L,
            ),
        )

        assertTrue(
            store.update(
                BookAnnotation(
                    id = saved.id,
                    documentId = "doc-1",
                    chapterIndex = 0,
                    selectedText = "a",
                    note = "新",
                    createdAt = 0L,
                ),
            ),
        )

        val loaded = store.list("doc-1").single()
        assertEquals("新", loaded.note)
        assertTrue(loaded.createdAt > 100L)
    }

    @Test
    fun updateMissingIdReturnsFalseAndLeavesListUntouched() {
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 0, selectedText = "a", note = "旧"))

        assertFalse(
            store.update(
                BookAnnotation(
                    id = "not-exists",
                    documentId = "doc-1",
                    chapterIndex = 0,
                    selectedText = "a",
                    note = "幽灵",
                ),
            ),
        )
        assertEquals(listOf("旧"), store.list("doc-1").map { it.note })
    }

    /** 空 id 会补 UUID，故必然未命中已有记录 → false（避免误覆盖）。 */
    @Test
    fun updateWithBlankIdNeverMatches() {
        store.add(BookAnnotation(documentId = "doc-1", chapterIndex = 0, selectedText = "a", note = "旧"))

        assertFalse(
            store.update(
                BookAnnotation(id = "", documentId = "doc-1", chapterIndex = 0, selectedText = "a", note = "新"),
            ),
        )
        assertEquals(listOf("旧"), store.list("doc-1").map { it.note })
    }

    /**
     * 编辑备注只替换 `text`：`kind` 必须保持原值。
     *
     * 这是「kind 只表类型、有无备注由 text 表达」在存储层的落点——EPUB 侧编辑备注不再把
     * `highlight` 升级成 `note`（与 PDF 侧一致），靠的就是 `copy(note = …)` 不碰 kind。
     */
    @Test
    fun updatingNoteKeepsKindUnchanged() {
        val saved = store.add(
            BookAnnotation(
                documentId = "doc-1",
                chapterIndex = 0,
                selectedText = "选中的原文",
                note = "",
                kind = BookAnnotation.KIND_HIGHLIGHT,
            ),
        )
        assertEquals(BookAnnotation.KIND_HIGHLIGHT, store.list("doc-1").single().kind)

        assertTrue(store.update(saved.copy(note = "后来补的备注")))

        val loaded = store.list("doc-1").single()
        assertEquals("加备注不能改 kind", BookAnnotation.KIND_HIGHLIGHT, loaded.kind)
        assertEquals("后来补的备注", loaded.note)
    }

    @Test
    fun clearLegacyDeletesLegacyKeysAndKeepsUidKeys() {
        val hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
        val uid = "0123456789ABCDEFGHJKMNPQRS"
        val uri = "content://com.android.providers.downloads.documents/document/1"
        prefs.putRaw(hex, "[]")
        prefs.putRaw(uri, "[]")
        prefs.putRaw(uid, "[]")
        prefs.putRaw("legacy_other", "[]")

        store.clearLegacy()

        assertFalse(prefs.contains(hex))
        assertFalse(prefs.contains(uri))
        assertTrue(prefs.contains(uid))
        // 任何 legacy_ 前缀键都保留（含清理标记本身）
        assertTrue(prefs.contains("legacy_other"))
    }

    @Test
    fun clearLegacyReturnsDeletedCount() {
        prefs.putRaw("a1b2c3d4e5f60718293a4b5c6d7e8f90", "[]")
        prefs.putRaw("file:///sdcard/a.pdf", "[]")
        prefs.putRaw("0123456789ABCDEFGHJKMNPQRS", "[]")

        assertEquals(2, store.clearLegacy())
        assertEquals(0, store.clearLegacy())
    }

    /**
     * 并发 `add`（R1 blocking 回归）：主线程新增批注与同步线程回填/合并并发写同一 documentId，
     * `add` 是「读整表 → 追加 → 整表回写」，无 `@Synchronized` 时后写覆盖先写、条目凭空消失。
     */
    @Test
    fun concurrentAddsLoseNoAnnotations() {
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
                            store.add(
                                BookAnnotation(
                                    documentId = "doc-1",
                                    chapterIndex = index,
                                    selectedText = "s",
                                    note = "n-$index-$offset",
                                ),
                            )
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

        val notes = store.list("doc-1").map { it.note }.toSet()
        assertEquals("并发 add 丢批注", threads * perThread, notes.size)
        assertTrue(notes.contains("n-3-99"))
    }
}
