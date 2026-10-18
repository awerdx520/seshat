package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
