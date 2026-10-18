package com.seshat.app.sync

import com.seshat.app.reader.AnnotationStore
import com.seshat.app.reader.BookAnnotation
import com.seshat.app.reader.FakeSharedPreferences
import com.seshat.app.reader.PdfProgress
import com.seshat.app.reader.ReadingProgress
import com.seshat.app.reader.ReadingProgressStore
import java.time.OffsetDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** [SyncManager] 的纯 JVM 单测：fake REST + 内存 store（复用 FakeSharedPreferences）。 */
class SyncManagerTest {

    /** 内存版服务端：记录进度与批注，模拟 M1.4 服务端的往返行为，并统计调用次数。 */
    private class FakeRestSyncApi : RestSyncApi {
        val progressByDoc = mutableMapOf<String, Progress>()
        val annotationsByDoc = mutableMapOf<String, MutableList<Annotation>>()
        var lastSetPosition: String? = null

        /** 最近一次 setProgress 收到的 uid（用于断言 uid 原样透传）。 */
        var lastSetUid: String? = null

        /** 最近一次 setProgress 收到的 updatedAt；null 表示未传（服务端填当前时间）。 */
        var lastSetUpdatedAt: String? = null

        /** 四个入口的调用计数：空白 uid 场景下必须全为 0（零网络请求）。 */
        var getProgressCalls = 0
        var setProgressCalls = 0
        var createAnnotationCalls = 0
        var listAnnotationsCalls = 0

        /** 四个入口的总调用次数。 */
        val totalCalls: Int
            get() = getProgressCalls + setProgressCalls + createAnnotationCalls + listAnnotationsCalls

        private var nextId = 1L

        override fun getProgress(uid: String): Progress? {
            getProgressCalls++
            return progressByDoc[uid]
        }

        override fun setProgress(uid: String, position: String, updatedAt: String?): Progress {
            setProgressCalls++
            lastSetUid = uid
            lastSetPosition = position
            lastSetUpdatedAt = updatedAt
            val saved = Progress(uid, position, "2026-10-11T10:00:00Z")
            progressByDoc[uid] = saved
            return saved
        }

        override fun createAnnotation(uid: String, location: String, text: String): Annotation {
            createAnnotationCalls++
            val annotation = Annotation(
                id = nextId++,
                uid = uid,
                location = location,
                text = text,
                createdAt = "2026-10-11T10:00:00Z",
                updatedAt = "2026-10-11T10:00:00Z",
            )
            annotationsByDoc.getOrPut(uid) { mutableListOf() }.add(annotation)
            return annotation
        }

        override fun listAnnotations(uid: String): List<Annotation> {
            listAnnotationsCalls++
            return annotationsByDoc[uid]?.toList() ?: emptyList()
        }
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

        fun seedLocalProgress(
            chapter: Int,
            scrollY: Int,
            uid: String = "doc-1",
            updatedAt: Long = 111L,
        ) {
            progressStore.save(
                ReadingProgress(uid, chapterIndex = chapter, scrollY = scrollY, updatedAt = updatedAt),
            )
        }

        fun seedLocalAnnotation(chapter: Int, note: String, uid: String = "doc-1") {
            annotationStore.add(
                BookAnnotation(documentId = uid, chapterIndex = chapter, selectedText = "选中", note = note),
            )
        }

        fun seedRemoteAnnotation(id: Long, location: String, text: String, uid: String = "doc-1") {
            rest.annotationsByDoc.getOrPut(uid) { mutableListOf() }
                .add(Annotation(id = id, uid = uid, location = location, text = text))
        }
    }

    /**
     * 直接返回固定进度的 store：用于构造真实 store 无法表达的边界值（如 `updatedAt = 0`，
     * [ReadingProgressStore] 会在 0 时补当前时间戳）。
     */
    private class FixedProgressStore(
        private val progress: ReadingProgress,
    ) : LocalSyncStore<ReadingProgress, BookAnnotation> {
        override fun loadProgress(uid: String): ReadingProgress = progress

        override fun saveProgress(uid: String, progress: ReadingProgress) = Unit

        override fun loadAnnotations(uid: String): List<BookAnnotation> = emptyList()

        override fun addAnnotation(uid: String, annotation: BookAnnotation) = Unit
    }

    private fun fixture(): Fixture = Fixture()

    private val oneHourMillis: Long =
        OffsetDateTime.parse("2026-10-11T10:00:00Z").toInstant().toEpochMilli()

    /** 26 位 Crockford Base32 形态的 uid（含大小写与数字），用于验证 uid 原样透传。 */
    private val crockfordUid = "01J8Z3K7QW9VX2M4N6P8R0T5YB"

    // ---- 进度 ----

    @Test
    fun pushProgressSendsEncodedPosition() {
        val f = fixture()
        f.seedLocalProgress(chapter = 3, scrollY = 42)

        val server = f.manager.pushProgress("doc-1")

        assertEquals("3:42", f.rest.lastSetPosition)
        assertEquals("3:42", server?.position)
        assertEquals("doc-1", server?.uid)
        assertEquals("3:42", f.rest.progressByDoc["doc-1"]?.position)
    }

    @Test
    fun pushProgressWithoutLocalReturnsNull() {
        val f = fixture()
        assertNull(f.manager.pushProgress("doc-1"))
        assertNull(f.rest.lastSetPosition)
    }

    @Test
    fun pushProgressPassesUpdatedAtRfc3339() {
        val f = fixture()
        // 刻意用毫秒非 0 的值：本地 updatedAt 来自 System.currentTimeMillis()，几乎从不整秒。
        // 若推送字符串带小数秒，服务端按 Go time.RFC3339 严格解析会判 invalid_argument（400）。
        val millis = 1_600_000_000_123L
        f.seedLocalProgress(chapter = 1, scrollY = 0, updatedAt = millis)

        f.manager.pushProgress("doc-1")

        val pushed = f.rest.lastSetUpdatedAt
        assertNotNull("本地 updatedAt 已知时必须透传，否则服务端无法做 409 冲突检测", pushed)
        // 「无小数秒」是硬约束（不是宽松的可解析性断言）：服务端只接受整秒 RFC 3339。
        assertFalse("推送的时间戳不得含小数秒：$pushed", pushed!!.contains('.'))
        assertTrue(
            "推送的时间戳必须是只到秒的 UTC RFC 3339：$pushed",
            Regex("""^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$""").matches(pushed),
        )
        // 秒精度往返：毫秒被截断，秒级值保持一致
        assertEquals(1_600_000_000_000L, OffsetDateTime.parse(pushed).toInstant().toEpochMilli())
    }

    @Test
    fun pushProgressSendsNullUpdatedAtWhenUnknown() {
        // epub 的 ReadingProgressStore 在 updatedAt=0 时会补当前时间戳，无法构造「未知」场景，
        // 故用固定值 store 直接注入 updatedAt=0 的进度（pdf 侧 store 亦原样保留 0）。
        val rest = FakeRestSyncApi()
        val manager = SyncManager(
            rest,
            FixedProgressStore(ReadingProgress("doc-1", chapterIndex = 1, updatedAt = 0L)),
            EpubSyncMapper(),
        )

        manager.pushProgress("doc-1")

        assertEquals("updatedAt 未知时仍应推送（仅跳过冲突检测）", 1, rest.setProgressCalls)
        assertNull("updatedAt=0 视为未知，必须传 null", rest.lastSetUpdatedAt)
    }

    @Test
    fun uidIsPassedThroughVerbatim() {
        val f = fixture()
        f.seedLocalProgress(chapter = 2, scrollY = 5, uid = crockfordUid)

        f.manager.pushProgress(crockfordUid)

        assertEquals("uid 必须原样透传，不得回退为本地旧 documentId", crockfordUid, f.rest.lastSetUid)
        assertNotNull(f.rest.progressByDoc[crockfordUid])
        assertNull("不得把请求挂到旧 documentId 键上", f.rest.progressByDoc["doc-1"])
    }

    @Test
    fun blankUidSendsNoRequests() {
        val f = fixture()
        f.seedLocalProgress(chapter = 1, scrollY = 1)
        f.seedLocalAnnotation(chapter = 1, note = "本地批注")

        for (blank in listOf("", "  ")) {
            assertNull(f.manager.pushProgress(blank))
            assertNull(f.manager.pullProgress(blank))
            assertTrue(f.manager.pushAnnotations(blank).isEmpty())
            assertTrue(f.manager.pullAnnotations(blank).isEmpty())
            assertEquals("空白 uid 意味着没有服务端身份，必须零网络请求", 0, f.rest.totalCalls)
            // 本地数据也不得被触碰（pull 分支不应写入）。
            assertEquals(1, f.progressStore.load("doc-1")?.chapterIndex)
            assertEquals(1, f.annotationStore.list("doc-1").size)
        }
    }

    @Test
    fun syncDocumentWithBlankUidReturnsEmptySummaryWithoutRequests() {
        val f = fixture()
        f.seedLocalProgress(chapter = 1, scrollY = 1)
        f.seedLocalAnnotation(chapter = 1, note = "本地批注")

        val summary = f.manager.syncDocument("  ")

        assertEquals("  ", summary.uid)
        assertNull(summary.pushedProgress)
        assertFalse(summary.pulledProgress)
        assertEquals(0, summary.pushedAnnotations)
        assertEquals(0, summary.pulledAnnotations)
        assertEquals(0, f.rest.totalCalls)
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
        assertEquals(listOf("doc-1", "doc-1"), remote.map { it.uid })
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

        assertEquals("doc-1", summary.uid)
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
    fun epubMapperReportsLocalUpdatedAt() {
        val mapper = EpubSyncMapper()
        assertEquals(123L, mapper.updatedAt(ReadingProgress("doc-1", 1, 2, 123L)))
        assertEquals("未知时间戳原样返回 0", 0L, mapper.updatedAt(ReadingProgress("doc-1", 0, 0, 0L)))
    }

    @Test
    fun pdfMapperReportsLocalUpdatedAt() {
        val mapper = PdfSyncMapper()
        assertEquals(456L, mapper.updatedAt(PdfProgress(page = 3, updatedAt = 456L)))
        assertEquals(0L, mapper.updatedAt(PdfProgress(page = 1, updatedAt = 0L)))
    }

    @Test
    fun pdfMapperEncodesPageAndMapsAnnotation() {
        val mapper = PdfSyncMapper()
        assertEquals("12", mapper.encodePosition(PdfProgress(page = 12, updatedAt = 5L)))
        val decoded = mapper.decodeProgress("doc-1", "12", "2026-10-11T10:00:00Z")
        assertEquals(12, decoded.page)
        assertEquals(oneHourMillis, decoded.updatedAt)

        val remote = Annotation(id = 7, uid = "doc-1", location = "page:3", text = "pdf 批注")
        val local = mapper.fromRemote(remote)
        assertEquals(7L, local.id)
        assertEquals("page:3", local.location)
        assertEquals("pdf 批注", local.text)
        assertEquals("page:3", mapper.location(local))
        assertEquals("pdf 批注", mapper.text(local))
    }
}
