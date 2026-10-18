package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** ReadingProgressStore 读写单测（内存版 SharedPreferences，纯 JVM）。 */
class ReadingProgressStoreTest {

    private val prefs = FakeSharedPreferences()
    private val store = ReadingProgressStore(prefs)

    @Test
    fun saveAndLoadRoundTrip() {
        store.save(ReadingProgress(documentId = "doc-1", chapterIndex = 3, scrollY = 512))

        val loaded = store.load("doc-1")
        assertNotNull(loaded)
        assertEquals("doc-1", loaded!!.documentId)
        assertEquals(3, loaded.chapterIndex)
        assertEquals(512, loaded.scrollY)
        assertTrue(loaded.updatedAt > 0L)
    }

    @Test
    fun loadUnknownDocumentReturnsNull() {
        assertNull(store.load("missing"))
    }

    @Test
    fun saveOverwritesPreviousProgress() {
        store.save(ReadingProgress(documentId = "doc-1", chapterIndex = 1, scrollY = 10))
        store.save(ReadingProgress(documentId = "doc-1", chapterIndex = 5, scrollY = 99))

        assertEquals(5, store.load("doc-1")!!.chapterIndex)
        assertEquals(99, store.load("doc-1")!!.scrollY)
    }

    @Test
    fun progressIsIsolatedPerDocument() {
        store.save(ReadingProgress(documentId = "doc-1", chapterIndex = 1))
        store.save(ReadingProgress(documentId = "doc-2", chapterIndex = 7))

        assertEquals(1, store.load("doc-1")!!.chapterIndex)
        assertEquals(7, store.load("doc-2")!!.chapterIndex)
    }

    @Test
    fun explicitUpdatedAtIsPreserved() {
        store.save(ReadingProgress(documentId = "doc-1", chapterIndex = 0, updatedAt = 12345L))
        assertEquals(12345L, store.load("doc-1")!!.updatedAt)
    }

    @Test
    fun corruptedJsonReturnsNullInsteadOfThrowing() {
        prefs.putRaw("doc-1", "{not-json")
        assertNull(store.load("doc-1"))
    }

    @Test
    fun clearRemovesRecord() {
        store.save(ReadingProgress(documentId = "doc-1", chapterIndex = 2))
        store.clear("doc-1")
        assertNull(store.load("doc-1"))
    }

    @Test
    fun clearLegacyDeletesLegacyKeysAndKeepsUidKeys() {
        val hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
        val uid = "0123456789ABCDEFGHJKMNPQRS"
        val uri = "content://com.android.providers.downloads.documents/document/1"
        prefs.putRaw(hex, "{\"documentId\":\"$hex\"}")
        prefs.putRaw(uri, "{\"documentId\":\"$uri\"}")
        prefs.putRaw(uid, "{\"documentId\":\"$uid\"}")
        prefs.putRaw("doc-1", "{\"documentId\":\"doc-1\"}")
        prefs.edit().putBoolean(LegacyKeys.CLEARED_FLAG, true).apply()

        store.clearLegacy()

        assertFalse(prefs.contains(hex))
        assertFalse(prefs.contains(uri))
        assertTrue(prefs.contains(uid))
        // 普通键与 legacy_ 前缀标记键都不得被删
        assertTrue(prefs.contains("doc-1"))
        assertTrue(prefs.contains(LegacyKeys.CLEARED_FLAG))
    }

    @Test
    fun clearLegacyReturnsDeletedCount() {
        prefs.putRaw("a1b2c3d4e5f60718293a4b5c6d7e8f90", "{}")
        prefs.putRaw("file:///sdcard/a.pdf", "{}")
        prefs.putRaw("0123456789ABCDEFGHJKMNPQRS", "{}")

        assertEquals(2, store.clearLegacy())
        // 幂等：再跑一次删除 0 条
        assertEquals(0, store.clearLegacy())
    }
}
