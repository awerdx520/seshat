package com.notes.app.reader

import org.junit.Assert.assertEquals
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
}
