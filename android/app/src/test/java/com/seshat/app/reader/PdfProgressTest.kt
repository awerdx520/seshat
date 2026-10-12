package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** [PdfProgress] / [PdfProgressStore] 的纯 JVM 单元测试。 */
class PdfProgressTest {

    /** 内存版读写，避免依赖 SharedPreferences（Android 框架）。 */
    private fun newStore(): Pair<PdfProgressStore, MutableMap<String, String>> {
        val map = mutableMapOf<String, String>()
        val store = PdfProgressStore(read = { map[it] }, write = { k, v -> map[k] = v })
        return store to map
    }

    @Test
    fun encodeDecodeRoundTrip() {
        val p = PdfProgress(page = 12, updatedAt = 1730000000000L)
        assertEquals("12:1730000000000", p.encode())
        assertEquals(p, PdfProgress.decode(p.encode()))
    }

    @Test
    fun decodeZeroPage() {
        assertEquals(PdfProgress(0, 1L), PdfProgress.decode("0:1"))
    }

    @Test
    fun decodeInvalidReturnsNull() {
        assertNull(PdfProgress.decode(null))
        assertNull(PdfProgress.decode(""))
        assertNull(PdfProgress.decode("   "))
        assertNull(PdfProgress.decode("abc"))
        assertNull(PdfProgress.decode("3:notanumber"))
        assertNull(PdfProgress.decode("-1:100"))
        assertNull(PdfProgress.decode("1:2:3"))
        assertNull(PdfProgress.decode(":5"))
    }

    @Test
    fun keyUsesPdfNamespace() {
        assertEquals("pdf_progress_doc1", PdfProgressStore.key("doc1"))
    }

    @Test
    fun loadWithoutRecordReturnsNull() {
        val (store, _) = newStore()
        assertNull(store.load("doc1"))
    }

    @Test
    fun saveThenLoad() {
        val (store, map) = newStore()
        store.save("doc1", PdfProgress(page = 3, updatedAt = 111L))
        assertEquals(PdfProgress(3, 111L), store.load("doc1"))
        assertEquals("3:111", map["pdf_progress_doc1"])
    }

    @Test
    fun saveIsPerDocument() {
        val (store, _) = newStore()
        store.save("docA", PdfProgress(1, 1L))
        store.save("docB", PdfProgress(9, 2L))
        assertEquals(PdfProgress(1, 1L), store.load("docA"))
        assertEquals(PdfProgress(9, 2L), store.load("docB"))
    }
}
