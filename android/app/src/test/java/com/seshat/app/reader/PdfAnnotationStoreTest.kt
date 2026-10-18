package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
