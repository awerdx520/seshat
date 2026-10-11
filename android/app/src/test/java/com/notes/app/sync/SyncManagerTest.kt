package com.notes.app.sync

import com.notes.app.reader.AnnotationStore
import com.notes.app.reader.BookAnnotation
import com.notes.app.reader.FakeSharedPreferences
import com.notes.app.reader.ReadingProgress
import com.notes.app.reader.ReadingProgressStore
import java.time.OffsetDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** [SyncManager] 的纯 JVM 单测：fake REST + 内存 store（复用 FakeSharedPreferences）。 */
class SyncManagerTest {

    /** 内存版服务端：记录进度与批注，模拟 M1.4 服务端的往返行为。 */
    private class FakeRestSyncApi : RestSyncApi {
        val progressByDoc = mutableMapOf<String, Progress>()
        val annotationsByDoc = mutableMapOf<String, MutableList<Annotation>>()
        var lastSetPosition: String? = null
        private var nextId = 1L

        override fun getProgress(documentId: String): Progress? = progressByDoc[documentId]

        override fun setProgress(documentId: String, position: String): Progress {
            lastSetPosition = position
            val saved = Progress(documentId, position, "2026-10-11T10:00:00Z")
            progressByDoc[documentId] = saved
            return saved
        }

        override fun createAnnotation(documentId: String, location: String, text: String): Annotation {
            val annotation = Annotation(
                id = nextId++,
                documentId = documentId,
                location = location,
                text = text,
                createdAt = "2026-10-11T10:00:00Z",
                updatedAt = "2026-10-11T10:00:00Z",
            )
            annotationsByDoc.getOrPut(documentId) { mutableListOf() }.add(annotation)
            return annotation
        }

        override fun listAnnotations(documentId: String): List<Annotation> =
            annotationsByDoc[documentId]?.toList() ?: emptyList()
    }

    /** 组装 epub 侧的一套依赖（store 分别用独立 prefs，模拟真实文件中不同 prefs 名）。 */
    private class Fixture {
        val rest = FakeRestSyncApi()
        val progressStore = ReadingProgressStore(FakeSharedPreferences())
        val annotationStore = AnnotationStore(FakeSharedPreferences())
        val manager: SyncManager<ReadingProgress, BookAnnotation> = SyncManager(
            rest,
            EpubLocalSyncStore(progressStore, annotationStore),
            EpubSyncMapper(),
        )

        fun seedLocalProgress(chapter: Int, scrollY: Int) {
            progressStore.save(
                ReadingProgress("doc-1", chapterIndex = chapter, scrollY = scrollY, updatedAt = 111L),
            )
        }

        fun seedLocalAnnotation(chapter: Int, note: String) {
            annotationStore.add(
                BookAnnotation(documentId = "doc-1", chapterIndex = chapter, selectedText = "选中", note = note),
            )
        }

        fun seedRemoteAnnotation(id: Long, location: String, text: String) {
            rest.annotationsByDoc.getOrPut("doc-1") { mutableListOf() }
                .add(Annotation(id = id, documentId = "doc-1", location = location, text = text))
        }
    }

    private fun fixture(): Fixture = Fixture()

    private val oneHourMillis: Long =
        OffsetDateTime.parse("2026-10-11T10:00:00Z").toInstant().toEpochMilli()

    // ---- 进度 ----

    @Test
    fun pushProgressSendsEncodedPosition() {
        val f = fixture()
        f.seedLocalProgress(chapter = 3, scrollY = 42)

        val server = f.manager.pushProgress("doc-1")

        assertEquals("3:42", f.rest.lastSetPosition)
        assertEquals("3:42", server?.position)
        assertEquals("doc-1", server?.documentId)
        assertEquals("3:42", f.rest.progressByDoc["doc-1"]?.position)
    }

    @Test
    fun pushProgressWithoutLocalReturnsNull() {
        val f = fixture()
        assertNull(f.manager.pushProgress("doc-1"))
        assertNull(f.rest.lastSetPosition)
    }

    @Test
    fun pullProgressWritesRemoteIntoLocalStore() {
        val f = fixture()
        f.rest.progressByDoc["doc-1"] = Progress("doc-1", "5:100", "2026-10-11T10:00:00Z")

        val local = f.manager.pullProgress("doc-1")

        assertEquals(ReadingProgress("doc-1", 5, 100, oneHourMillis), local)
        assertEquals(5, f.progressStore.load("doc-1")?.chapterIndex)
        assertEquals(100, f.progressStore.load("doc-1")?.scrollY)
    }

    @Test
    fun pullProgressReturnsNullWhenServerHasNoRecord() {
        val f = fixture()
        assertNull(f.manager.pullProgress("doc-1"))
        assertNull(f.progressStore.load("doc-1"))
    }

    // ---- 批注 ----

    @Test
    fun pushAnnotationsCreatesOnServerWithMappedFields() {
        val f = fixture()
        f.seedLocalAnnotation(chapter = 1, note = "第一条")
        f.seedLocalAnnotation(chapter = 2, note = "第二条")

        val created = f.manager.pushAnnotations("doc-1")

        assertEquals(2, created.size)
        val remote = f.rest.listAnnotations("doc-1")
        assertEquals(listOf("chapter-1", "chapter-2"), remote.map { it.location })
        assertEquals(listOf("第一条", "第二条"), remote.map { it.text })
        assertEquals(listOf("doc-1", "doc-1"), remote.map { it.documentId })
    }

    @Test
    fun pushAnnotationsSkipsAlreadyOnServer() {
        val f = fixture()
        f.seedLocalAnnotation(chapter = 1, note = "第一条")

        val first = f.manager.pushAnnotations("doc-1")
        val second = f.manager.pushAnnotations("doc-1")

        assertEquals(1, first.size)
        assertTrue(second.isEmpty())
        assertEquals(1, f.rest.listAnnotations("doc-1").size)
    }

    @Test
    fun pullAnnotationsMergesRemoteIntoLocalStore() {
        val f = fixture()
        f.seedRemoteAnnotation(id = 1, location = "chapter-1", text = "远端一")
        f.seedRemoteAnnotation(id = 2, location = "chapter-2", text = "远端二")

        val added = f.manager.pullAnnotations("doc-1")

        assertEquals(2, added.size)
        val local = f.annotationStore.list("doc-1")
        assertEquals(2, local.size)
        assertEquals("远端一", local[0].note)
        assertEquals(1, local[0].chapterIndex)
        assertEquals("1", local[0].id)
        assertEquals("2", local[1].id)
    }

    @Test
    fun pullAnnotationsIsIdempotent() {
        val f = fixture()
        f.seedRemoteAnnotation(id = 1, location = "chapter-1", text = "远端一")

        val first = f.manager.pullAnnotations("doc-1")
        val second = f.manager.pullAnnotations("doc-1")

        assertEquals(1, first.size)
        assertTrue(second.isEmpty())
        assertEquals(1, f.annotationStore.list("doc-1").size)
    }

    @Test
    fun pushThenPullAnnotationsRoundTrips() {
        val f = fixture()
        f.seedLocalAnnotation(chapter = 1, note = "本地批注")

        f.manager.pushAnnotations("doc-1")
        // 清空本地后从服务端拉回，验证内容一致。
        f.annotationStore.clear("doc-1")
        val pulled = f.manager.pullAnnotations("doc-1")

        assertEquals(1, pulled.size)
        assertEquals("本地批注", f.annotationStore.list("doc-1").single().note)
        assertEquals(1, f.annotationStore.list("doc-1").single().chapterIndex)
    }

    // ---- 完整流程 ----

    @Test
    fun syncDocumentCompletesFullRoundTrip() {
        val f = fixture()
        f.seedLocalProgress(chapter = 2, scrollY = 10)
        f.seedLocalAnnotation(chapter = 1, note = "本地批注")
        // 服务端预置一条本地没有的批注，验证 pull 分支。
        f.seedRemoteAnnotation(id = 9, location = "chapter-9", text = "远端批注")
        f.rest.progressByDoc["doc-1"] = Progress("doc-1", "7:70", "2026-10-11T09:00:00Z")

        val summary = f.manager.syncDocument("doc-1")

        assertEquals("doc-1", summary.docId)
        assertEquals("2:10", summary.pushedProgress?.position)
        assertTrue(summary.pulledProgress)
        assertEquals(1, summary.pushedAnnotations)
        assertEquals(1, summary.pulledAnnotations)

        // 本地 → 服务端
        assertTrue(f.rest.listAnnotations("doc-1").any { it.text == "本地批注" })
        // 服务端 → 本地
        assertTrue(f.annotationStore.list("doc-1").any { it.note == "远端批注" })
        // 进度：本地推送后又被服务端回读覆盖为本地值（幂等一致）
        assertEquals("2:10", f.rest.progressByDoc["doc-1"]?.position)
        assertEquals(2, f.progressStore.load("doc-1")?.chapterIndex)
    }

    @Test
    fun syncDocumentSecondRunIsNoOpForAnnotations() {
        val f = fixture()
        f.seedLocalAnnotation(chapter = 1, note = "本地批注")

        val first = f.manager.syncDocument("doc-1")
        val second = f.manager.syncDocument("doc-1")

        assertEquals(1, first.pushedAnnotations)
        assertEquals(0, second.pushedAnnotations)
        assertEquals(0, second.pulledAnnotations)
        assertEquals(1, f.annotationStore.list("doc-1").size)
        assertEquals(1, f.rest.listAnnotations("doc-1").size)
        assertFalse(f.rest.listAnnotations("doc-1").isEmpty())
    }

    // ---- 字段映射（mapper 单元行为） ----

    @Test
    fun epubMapperEncodesAndDecodesPosition() {
        val mapper = EpubSyncMapper()
        assertEquals("3:42", mapper.encodePosition(ReadingProgress("doc-1", 3, 42, 0L)))
        assertEquals(
            ReadingProgress("doc-1", 5, 100, oneHourMillis),
            mapper.decodeProgress("doc-1", "5:100", "2026-10-11T10:00:00Z"),
        )
        // 非法 position 容错为 0。
        assertEquals(ReadingProgress("doc-1", 0, 0, 0L), mapper.decodeProgress("doc-1", "bad", null))
    }

    @Test
    fun pdfMapperEncodesPageAndMapsAnnotation() {
        val mapper = PdfSyncMapper()
        assertEquals("12", mapper.encodePosition(com.notes.app.reader.PdfProgress(page = 12, updatedAt = 5L)))
        val decoded = mapper.decodeProgress("doc-1", "12", "2026-10-11T10:00:00Z")
        assertEquals(12, decoded.page)
        assertEquals(oneHourMillis, decoded.updatedAt)

        val remote = Annotation(id = 7, documentId = "doc-1", location = "page:3", text = "pdf 批注")
        val local = mapper.fromRemote(remote)
        assertEquals(7L, local.id)
        assertEquals("page:3", local.location)
        assertEquals("pdf 批注", local.text)
        assertEquals("page:3", mapper.location(local))
        assertEquals("pdf 批注", mapper.text(local))
    }
}
