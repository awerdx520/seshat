package com.seshat.app.sync

import com.seshat.app.reader.AnnotationStore
import com.seshat.app.reader.BookAnnotation
import com.seshat.app.reader.FakeSharedPreferences
import com.seshat.app.reader.PdfAnnotation
import com.seshat.app.reader.PdfProgress
import com.seshat.app.reader.PendingDeletes
import com.seshat.app.reader.ReadingProgress
import com.seshat.app.reader.ReadingProgressStore
import java.time.OffsetDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** [SyncManager] 的纯 JVM 单测：fake REST + 内存 store（复用 FakeSharedPreferences）。 */
class SyncManagerTest {

    /** 一条 `PUT /api/annotations/{id}` 请求的参数快照。 */
    private data class UpdateCall(
        val id: Long,
        val location: String,
        val text: String,
        val kind: String,
        val selectedText: String,
        val updatedAt: String?,
    )

    /** 内存版服务端：记录进度与批注，模拟 M1.4 服务端的往返行为，并统计调用次数。 */
    private class FakeRestSyncApi : RestSyncApi {
        val progressByDoc = mutableMapOf<String, Progress>()
        val annotationsByDoc = mutableMapOf<String, MutableList<Annotation>>()
        var lastSetPosition: String? = null

        /** 最近一次 setProgress 收到的 uid（用于断言 uid 原样透传）。 */
        var lastSetUid: String? = null

        /** 最近一次 setProgress 收到的 updatedAt；null 表示未传（服务端填当前时间）。 */
        var lastSetUpdatedAt: String? = null

        /** 各入口的调用计数：空白 uid 场景下必须全为 0（零网络请求）。 */
        var getProgressCalls = 0
        var setProgressCalls = 0
        var createAnnotationCalls = 0
        var listAnnotationsCalls = 0
        var updateAnnotationCalls = 0
        var deleteAnnotationCalls = 0

        /** 六个入口的总调用次数。 */
        val totalCalls: Int
            get() = getProgressCalls + setProgressCalls + createAnnotationCalls +
                listAnnotationsCalls + updateAnnotationCalls + deleteAnnotationCalls

        /** 每次 POST 收到的 `(kind, selectedText)`（v8 字段往返断言用）。 */
        val createdFields = mutableListOf<Pair<String, String>>()

        /** 每次 PUT 的参数（断言 kind/selectedText 上行与 updatedAt 取值）。 */
        val updateCalls = mutableListOf<UpdateCall>()

        /** 每次 DELETE 收到的 serverId（按调用顺序）。 */
        val deleteCalls = mutableListOf<Long>()

        /** 这些 serverId 的 PUT 返回 409（模拟服务端冲突检测命中）。 */
        val conflictIds = mutableSetOf<Long>()

        /**
         * 模拟服务端**进度**的 409 冲突检测：请求的 `updatedAt` **不晚于**库内 `updated_at` →
         * 抛 `ApiException(409)`。
         *
         * 比真实服务端更严格：服务端是 `existing > incoming` 才冲突（keystone 仓 `internal/storage/state.go`
         * 的 `assertNotStale`），此处把「相等」也算冲突，让「本地毫秒较新但上行时间戳被截断到秒、
         * 与服务端同秒」这一防御分支（`SyncManager` 的「本地较新 → 带新时间戳重发」）可被测试覆盖。
         * 默认关闭：既有进度用例不关心冲突，保持原行为。
         */
        var progressConflictDetection = false

        /** 无条件对 `setProgress` 抛 409（模拟「重发仍冲突」）。 */
        var progressAlwaysConflict = false

        /** 非 null 时 `setProgress` 抛该状态码的 `ApiException`（校验「非 409 行为不变」）。 */
        var progressErrorCode: Int? = null

        private var nextId = 1L

        /** 服务端写入时使用的自增时间戳（`2026-10-11T10:00:0N Z`），便于断言「服务端版本更新」。 */
        private var clock = 0

        fun addRemote(
            uid: String,
            id: Long,
            location: String,
            text: String,
            kind: String = "note",
            selectedText: String = "",
        ) {
            annotationsByDoc.getOrPut(uid) { mutableListOf() }.add(
                Annotation(
                    id = id,
                    uid = uid,
                    location = location,
                    text = text,
                    kind = kind,
                    selectedText = selectedText,
                    createdAt = "2026-10-11T10:00:00Z",
                    updatedAt = "2026-10-11T10:00:00Z",
                ),
            )
        }

        override fun getProgress(uid: String): Progress? {
            getProgressCalls++
            return progressByDoc[uid]
        }

        override fun setProgress(uid: String, position: String, updatedAt: String?): Progress {
            setProgressCalls++
            lastSetUid = uid
            lastSetPosition = position
            lastSetUpdatedAt = updatedAt
            progressErrorCode?.let { code ->
                throw ApiException(code, "error", "setProgress 失败（模拟非 409）：$code")
            }
            if (progressAlwaysConflict) throw ApiException(409, "conflict", "进度冲突（模拟：重发仍冲突）")
            val existing = progressByDoc[uid]
            if (progressConflictDetection && updatedAt != null && existing != null &&
                parseRfc3339Millis(updatedAt) <= parseRfc3339Millis(existing.updatedAt)
            ) {
                throw ApiException(409, "conflict", "进度冲突（模拟：请求 updated_at 不晚于库内值）")
            }
            // 冲突检测开启时按请求值落库（便于断言「重发时间戳」），否则保持既有用例依赖的固定值
            val storedUpdatedAt =
                if (progressConflictDetection) updatedAt ?: "2026-10-11T10:00:00Z" else "2026-10-11T10:00:00Z"
            val saved = Progress(uid = uid, position = position, updatedAt = storedUpdatedAt)
            progressByDoc[uid] = saved
            return saved
        }

        override fun createAnnotation(
            uid: String,
            location: String,
            text: String,
            kind: String,
            selectedText: String,
        ): Annotation {
            createAnnotationCalls++
            createdFields += kind to selectedText
            val annotation = Annotation(
                id = nextId++,
                uid = uid,
                location = location,
                text = text,
                kind = kind,
                selectedText = selectedText,
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

        override fun updateAnnotation(
            id: Long,
            location: String,
            text: String,
            kind: String,
            selectedText: String,
            updatedAt: String?,
        ): UpdateAnnotationResult {
            updateAnnotationCalls++
            updateCalls += UpdateCall(id, location, text, kind, selectedText, updatedAt)
            if (id in conflictIds) return UpdateAnnotationResult.Conflict
            val list = annotationsByDoc.values.firstOrNull { items -> items.any { it.id == id } }
                ?: throw ApiException(404, "not_found", "批注不存在：$id")
            val index = list.indexOfFirst { it.id == id }
            val stored = list[index].copy(
                location = location,
                text = text,
                kind = kind,
                selectedText = selectedText,
                updatedAt = "2026-10-11T11:00:0${clock++ % 10}Z",
            )
            list[index] = stored
            return UpdateAnnotationResult.Ok(stored)
        }

        override fun deleteAnnotation(id: Long) {
            deleteAnnotationCalls++
            deleteCalls += id
            // 与 RestClient 一致：不存在即「目标已达成」，不抛错。
            annotationsByDoc.values.forEach { items -> items.removeAll { it.id == id } }
        }
    }

    /** 组装 epub 侧的一套依赖（store 分别用独立 prefs，模拟真实文件中不同 prefs 名）。 */
    private class Fixture {
        val rest = FakeRestSyncApi()
        val progressStore = ReadingProgressStore(FakeSharedPreferences())
        val annotationStore = AnnotationStore(FakeSharedPreferences())
        val pendingPrefs = FakeSharedPreferences()
        val pendingDeletes = PendingDeletes(pendingPrefs)
        val manager: SyncManager<ReadingProgress, BookAnnotation> = SyncManager(
            rest,
            EpubLocalSyncStore(progressStore, annotationStore),
            EpubSyncMapper(),
            pendingDeletes,
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

        /** 落库一条字段完全可控的本地批注，返回落库后的对象（含 store 分配的 UUID）。 */
        fun seedLocal(
            note: String,
            location: String = "",
            kind: String = "note",
            selectedText: String = "",
            serverId: Long? = null,
            dirty: Boolean = false,
            chapter: Int = 1,
            uid: String = "doc-1",
        ): BookAnnotation = annotationStore.add(
            BookAnnotation(
                documentId = uid,
                chapterIndex = chapter,
                selectedText = selectedText,
                note = note,
                location = location,
                kind = kind,
                serverId = serverId,
                dirty = dirty,
            ),
        )

        fun local(uid: String = "doc-1"): List<BookAnnotation> = annotationStore.list(uid)

        fun seedRemoteAnnotation(id: Long, location: String, text: String, uid: String = "doc-1") {
            rest.addRemote(uid = uid, id = id, location = location, text = text)
        }

        fun queueDelete(serverId: Long, uid: String = "doc-1") = pendingDeletes.add(uid, serverId)
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

        override fun updateAnnotation(uid: String, annotation: BookAnnotation): Boolean = false

        override fun removeAnnotation(uid: String, annotation: BookAnnotation): Boolean = false
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

    // ---- 进度 409 冲突合并（R7 / 计划 T3 遗留） ----

    /** ISO 时间戳 → epoch 毫秒（构造「本地/服务端哪个更新」的场景）。 */
    private fun millisOf(iso: String): Long = OffsetDateTime.parse(iso).toInstant().toEpochMilli()

    /** ① 409 且**服务端较新** → 用服务端值覆盖本地、视为成功，不重发。 */
    @Test
    fun progressConflictWithNewerServerOverwritesLocal() {
        val f = fixture()
        f.seedLocalProgress(chapter = 1, scrollY = 0, updatedAt = millisOf("2026-10-11T09:00:00Z"))
        f.rest.progressByDoc["doc-1"] = Progress("doc-1", "9:120", "2026-10-11T12:00:00Z")
        f.rest.progressConflictDetection = true

        val result = f.manager.pushProgressDetailed("doc-1")

        assertTrue("服务端较新时应返回 Merged，实际 $result", result is ProgressPushResult.Merged)
        assertEquals("9:120", (result as ProgressPushResult.Merged).progress.position)
        assertEquals("只发首 PUT + 一次重拉，不重发", 1, f.rest.setProgressCalls)
        assertEquals("必须重拉服务端进度", 1, f.rest.getProgressCalls)
        val local = f.progressStore.load("doc-1")
        assertEquals("本地章号被服务端值覆盖", 9, local?.chapterIndex)
        assertEquals("本地滚动位置被服务端值覆盖", 120, local?.scrollY)
    }

    /** ② 409 且**本地较新** → 用严格更大的时间戳重发一次并成功。 */
    @Test
    fun progressConflictWithNewerLocalRetriesWithGreaterTimestamp() {
        val f = fixture()
        val serverMillis = millisOf("2026-10-11T13:00:00Z")
        // 本地毫秒比服务端大 900ms，但上行时间戳被截断到秒 → 与库内值同秒（fake 判 409）
        val localMillis = serverMillis + 900L
        f.seedLocalProgress(chapter = 2, scrollY = 7, updatedAt = localMillis)
        f.rest.progressByDoc["doc-1"] = Progress("doc-1", "9:120", "2026-10-11T13:00:00Z")
        f.rest.progressConflictDetection = true

        val result = f.manager.pushProgressDetailed("doc-1")

        assertTrue("本地较新且重发成功，应为 Pushed，实际 $result", result is ProgressPushResult.Pushed)
        assertEquals("首 PUT(409) + 重发 = 2 次", 2, f.rest.setProgressCalls)
        assertEquals(1, f.rest.getProgressCalls)
        val retried = requireNotNull(f.rest.lastSetUpdatedAt) { "重发必须带时间戳" }
        val retriedMillis = parseRfc3339Millis(retried)
        assertTrue(
            "重发时间戳必须严格大于服务端 updated_at（$retried vs 2026-10-11T13:00:00Z）",
            retriedMillis > serverMillis,
        )
        assertTrue("重发时间戳不得倒退本地更晚的值（$retried）", retriedMillis >= localMillis)
        assertEquals("服务端最终保存本地位置", "2:7", f.rest.progressByDoc["doc-1"]?.position)
    }

    /** ③ 重发仍 409 → 返回可判别失败（Rejected），并在整轮同步摘要里显式记录，不静默吞掉。 */
    @Test
    fun progressConflictRejectedAfterRetryIsNotSwallowed() {
        val f = fixture()
        f.seedLocalProgress(chapter = 2, scrollY = 7, updatedAt = millisOf("2026-10-11T13:00:00Z"))
        f.rest.progressByDoc["doc-1"] = Progress("doc-1", "9:120", "2026-10-11T12:00:00Z")
        f.rest.progressConflictDetection = true
        f.rest.progressAlwaysConflict = true

        val result = f.manager.pushProgressDetailed("doc-1")

        assertTrue("重发仍 409 必须返回 Rejected，实际 $result", result is ProgressPushResult.Rejected)
        assertEquals("Rejected 需带上服务端版本供提示", "9:120", (result as ProgressPushResult.Rejected).remote?.position)
        assertEquals("首 PUT + 一次重发，不再重试", 2, f.rest.setProgressCalls)
        assertEquals("失败不得覆盖本地数据", 2, f.progressStore.load("doc-1")?.chapterIndex)

        // 兼容入口返回 null；但 syncDocument 会把该结局显式记入摘要（不再只是「已忽略」）
        assertNull(f.manager.pushProgress("doc-1"))
        assertTrue("整轮同步必须标记进度推送失败", f.manager.syncDocument("doc-1").progressRejected)
    }

    /** ④ 非 409 错误 → 行为不变：原样上抛、不重拉、不重发。 */
    @Test
    fun progressNonConflictErrorPropagatesUnchanged() {
        val f = fixture()
        f.seedLocalProgress(chapter = 1, scrollY = 0)
        f.rest.progressErrorCode = 500

        try {
            f.manager.pushProgressDetailed("doc-1")
            fail("非 409 的进度推送失败必须原样上抛")
        } catch (expected: ApiException) {
            assertEquals(500, expected.statusCode)
        }
        assertEquals("非 409 不重拉服务端进度", 0, f.rest.getProgressCalls)
        assertEquals("非 409 不重发", 1, f.rest.setProgressCalls)
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
        f.queueDelete(7L)

        for (blank in listOf("", "  ")) {
            assertNull(f.manager.pushProgress(blank))
            assertNull(f.manager.pullProgress(blank))
            assertTrue(f.manager.pushAnnotations(blank).isEmpty())
            assertTrue(f.manager.pullAnnotations(blank).isEmpty())
            assertEquals("空白 uid 时待删队列也不得处理", 0, f.manager.pushDeletes(blank))
            assertEquals("空白 uid 意味着没有服务端身份，必须零网络请求", 0, f.rest.totalCalls)
            // 本地数据也不得被触碰（pull 分支不应写入；待删队列保持原样）。
            assertEquals(1, f.progressStore.load("doc-1")?.chapterIndex)
            assertEquals(1, f.annotationStore.list("doc-1").size)
            assertEquals(listOf(7L), f.pendingDeletes.list("doc-1"))
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
        assertEquals(0, summary.updatedAnnotations)
        assertEquals(0, summary.deletedAnnotations)
        assertEquals(0, summary.conflictAnnotations)
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

    // ---- 批注：推送 ----

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

    /** ⑧ 新建路径：POST 成功后把 `serverId` 下行、`dirty` 复位（本地 id 不变）。 */
    @Test
    fun pushBackfillsServerIdAndClearsDirtyAfterCreate() {
        val f = fixture()
        val local = f.seedLocal(note = "本地批注", location = "chapter:1@0-4")

        f.manager.pushAnnotations("doc-1")

        val stored = f.local().single()
        assertEquals("本地 id 必须保持稳定（由 store 分配，不因同步而变）", local.id, stored.id)
        assertEquals("服务端 id 必须回填到 serverId", 1L, stored.serverId)
        assertFalse("上行成功后 dirty 必须复位", stored.dirty)
        assertEquals("chapter:1@0-4", stored.location)
    }

    /** ⑧ 更新路径：PUT 成功后清 dirty，并用服务端返回的字段覆盖本地。 */
    @Test
    fun pushUpdateBackfillsServerFieldsAndClearsDirty() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 5, location = "chapter:2@0-9", text = "服务端旧内容")
        f.seedLocal(note = "本地改后", location = "chapter:2@0-9", serverId = 5L, dirty = true)

        val result = f.manager.pushAnnotationsDetailed("doc-1")

        assertEquals("有 serverId 且 dirty 时必须走 PUT 而非 POST", 1, result.updated)
        assertEquals(0, result.created)
        assertEquals(1, f.rest.updateAnnotationCalls)
        assertEquals(0, f.rest.createAnnotationCalls)
        val stored = f.local().single()
        assertEquals(5L, stored.serverId)
        assertFalse(stored.dirty)
        // PUT 是整体替换：服务端返回的就是本次请求内容，本地回填后应与之保持一致。
        assertEquals("本地改后", stored.note)
    }

    @Test
    fun pushSkipsCleanUploadedAnnotationsWithoutRequests() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 3, location = "chapter:1@0-4", text = "已同步")
        f.seedLocal(note = "已同步", location = "chapter:1@0-4", serverId = 3L, dirty = false)

        val result = f.manager.pushAnnotationsDetailed("doc-1")

        assertTrue(result.pushed.isEmpty())
        assertEquals(0, f.rest.updateAnnotationCalls)
        assertEquals(0, f.rest.createAnnotationCalls)
    }

    /** ⑤ 同一 `(kind, location, text)` 第二次推送不再 POST（第一次已回填 serverId）。 */
    @Test
    fun pushSameContentTwicePostsOnce() {
        val f = fixture()
        f.seedLocal(note = "同一条", location = "chapter:1@0-4")

        f.manager.pushAnnotations("doc-1")
        f.manager.pushAnnotations("doc-1")
        f.manager.pushAnnotations("doc-1")

        assertEquals("重复推送不得重复创建", 1, f.rest.createAnnotationCalls)
        assertEquals(1, f.rest.listAnnotations("doc-1").size)
        assertEquals(1, f.local().size)
    }

    /** ⑤ 补偿路径：上次 POST 成功但本地未回填（serverId 为空）→ 认领服务端记录，不重复 POST。 */
    @Test
    fun pushAdoptsExistingServerRecordWithoutSecondPost() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 88, location = "chapter:1@0-4", text = "同一条")
        val local = f.seedLocal(note = "同一条", location = "chapter:1@0-4")

        val result = f.manager.pushAnnotationsDetailed("doc-1")

        assertTrue(result.pushed.isEmpty())
        assertEquals(0, f.rest.createAnnotationCalls)
        val stored = f.local().single()
        assertEquals(local.id, stored.id)
        assertEquals("认领后必须回填服务端 id", 88L, stored.serverId)
        assertFalse(stored.dirty)
    }

    /** ⑥ 同 location、不同 kind（同一章上的 highlight 与 note）不得互相去重。 */
    @Test
    fun sameLocationDifferentKindIsNotDeduplicated() {
        val f = fixture()
        f.seedLocal(note = "我的备注", location = "chapter:1@0-9", kind = "note")
        f.seedLocal(note = "", location = "chapter:1@0-9", kind = "highlight", selectedText = "选中原文")

        val result = f.manager.pushAnnotationsDetailed("doc-1")

        assertEquals(2, result.created)
        assertEquals(2, f.rest.createAnnotationCalls)
        assertEquals(
            listOf("note" to "", "highlight" to "选中原文"),
            f.rest.createdFields,
        )
        assertEquals(
            "服务端必须收到两条同 location、不同 kind 的批注",
            2,
            f.rest.listAnnotations("doc-1").size,
        )
    }

    /** ④ PUT 409 → 重拉 + 以服务端版本为准覆盖本地，冲突快照返回调用方（不静默丢弃）。 */
    @Test
    fun pushConflictResolvesWithServerVersionAndReportsIt() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 5, location = "chapter:2@0-9", text = "服务端版本")
        f.seedLocal(note = "本地改动", location = "chapter:2@0-9", serverId = 5L, dirty = true)
        f.rest.conflictIds += 5L

        val result = f.manager.pushAnnotationsDetailed("doc-1")

        assertEquals("409 不算上行成功", 0, result.updated)
        assertEquals(1, result.conflicts.size)
        assertEquals("本地改动", result.conflicts.single().note)
        val stored = f.local().single()
        assertEquals("服务端版本为准", "服务端版本", stored.note)
        assertFalse("冲突解决后本地不应再标记 dirty", stored.dirty)
        assertEquals(5L, stored.serverId)
    }

    @Test
    fun syncDocumentReportsConflictCount() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 5, location = "chapter:2@0-9", text = "服务端版本")
        f.seedLocal(note = "本地改动", location = "chapter:2@0-9", serverId = 5L, dirty = true)
        f.rest.conflictIds += 5L

        val summary = f.manager.syncDocument("doc-1")

        assertEquals(1, summary.conflictAnnotations)
        assertEquals(0, summary.updatedAnnotations)
    }

    /** 冲突时服务端记录已被别端删除 → 本地记录一并移除（否则永远推不上去的幽灵条目）。 */
    @Test
    fun pushConflictWithVanishedServerRecordRemovesLocalGhost() {
        val f = fixture()
        f.seedLocal(note = "本地改动", location = "chapter:2@0-9", serverId = 5L, dirty = true)
        f.rest.conflictIds += 5L

        val result = f.manager.pushAnnotationsDetailed("doc-1")

        assertEquals(1, result.conflicts.size)
        assertTrue("服务端已无该记录时本地不得留幽灵条目", f.local().isEmpty())
    }

    // ---- 批注：拉取（三路匹配） ----

    /** ⑦ 路径 ①：本地 `serverId` 命中 → 覆盖内容。 */
    @Test
    fun pullUpdatesLocalByServerId() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 42, location = "chapter:1@0-4", text = "服务端新内容")
        val local = f.seedLocal(note = "本地旧内容", location = "chapter:1@0-4", serverId = 42L)

        val touched = f.manager.pullAnnotations("doc-1")

        assertEquals(1, touched.size)
        val stored = f.local().single()
        assertEquals(local.id, stored.id)
        assertEquals("服务端新内容", stored.note)
        assertEquals(42L, stored.serverId)
    }

    /** 本地有未上行改动（dirty）时 pull 不得覆盖：离线改的备注不能被打开书籍时的拉取静默丢掉。 */
    @Test
    fun pullDoesNotOverwriteDirtyLocalEdit() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 42, location = "chapter:1@0-4", text = "服务端版本")
        f.seedLocal(note = "离线改的", location = "chapter:1@0-4", serverId = 42L, dirty = true)

        val touched = f.manager.pullAnnotations("doc-1")

        assertTrue("dirty 记录必须留给 push 上行，pull 不得写库", touched.isEmpty())
        val stored = f.local().single()
        assertEquals("离线改的", stored.note)
        assertTrue("dirty 标记必须保留到 push 成功", stored.dirty)
    }

    /** ⑦ 路径 ②：`serverId` 未命中 → `(kind, location, text)` 兜底命中 → update 并回填 serverId。 */
    @Test
    fun pullAdoptsLocalByContentKeyAndBackfillsServerId() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 42, location = "chapter:1@0-4", text = "备注")
        val local = f.seedLocal(note = "备注", location = "chapter:1@0-4", selectedText = "本地选中")

        val touched = f.manager.pullAnnotations("doc-1")

        assertEquals(1, touched.size)
        val stored = f.local().single()
        assertEquals("必须原地更新而非新增", local.id, stored.id)
        assertEquals(42L, stored.serverId)
        assertEquals("服务端 selected_text 覆盖本地", "", stored.selectedText)
        assertEquals(1, f.local().size)
    }

    /** ⑦ 路径 ③：两路都未命中 → add（本地 id 由 store 分配，不复用服务端 id）。 */
    @Test
    fun pullAddsWhenNeitherPathMatches() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 77, location = "chapter:2@0-3", text = "远端内容")
        f.seedLocal(note = "本地内容", location = "chapter:1@0-4")

        val touched = f.manager.pullAnnotations("doc-1")

        assertEquals(1, touched.size)
        assertEquals(2, f.local().size)
        val added = f.local().first { it.serverId == 77L }
        assertNotEquals("本地 id 不得复用服务端 id", "77", added.id)
        assertTrue("本地 id 必须是 store 分配的 UUID", added.id.isNotBlank())
        assertEquals("chapter:2@0-3", added.location)
        assertEquals(2, added.chapterIndex)
        assertFalse(added.dirty)
    }

    @Test
    fun pullAnnotationsMergesRemoteIntoLocalStore() {
        val f = fixture()
        f.seedRemoteAnnotation(id = 1, location = "chapter-1", text = "远端一")
        f.seedRemoteAnnotation(id = 2, location = "chapter-2", text = "远端二")

        val added = f.manager.pullAnnotations("doc-1")

        assertEquals(2, added.size)
        val local = f.local()
        assertEquals(2, local.size)
        assertEquals("远端一", local[0].note)
        assertEquals(1, local[0].chapterIndex)
        assertEquals("服务端 id 只写 serverId", 1L, local[0].serverId)
        assertNotEquals("本地 id 不得复用服务端 id", "1", local[0].id)
        assertEquals(2L, local[1].serverId)
    }

    @Test
    fun pullAnnotationsIsIdempotent() {
        val f = fixture()
        f.seedRemoteAnnotation(id = 1, location = "chapter-1", text = "远端一")

        val first = f.manager.pullAnnotations("doc-1")
        val second = f.manager.pullAnnotations("doc-1")

        assertEquals(1, first.size)
        assertTrue("内容已一致时不得重复写库", second.isEmpty())
        assertEquals(1, f.local().size)
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
        assertEquals("本地批注", f.local().single().note)
        assertEquals(1, f.local().single().chapterIndex)
    }

    /** v8 字段往返：建 → 列 → 改 → 拉，`kind` / `selected_text` 全程不丢。 */
    @Test
    fun kindAndSelectedTextRoundTripThroughCreateUpdateAndPull() {
        val f = fixture()
        val local = f.seedLocal(
            note = "",
            location = "chapter:3@10-20",
            kind = "highlight",
            selectedText = "选中原文",
        )

        f.manager.pushAnnotations("doc-1")
        val created = f.rest.listAnnotations("doc-1").single()
        assertEquals("highlight", created.kind)
        assertEquals("选中原文", created.selectedText)

        // 改：dirty 置位后推送（kind/selectedText 必须原样上行）
        f.annotationStore.update(f.local().single().copy(note = "备注补一句", dirty = true))
        f.manager.pushAnnotations("doc-1")
        val updateCall = f.rest.updateCalls.single()
        assertEquals("highlight", updateCall.kind)
        assertEquals("选中原文", updateCall.selectedText)
        assertEquals(local.location, updateCall.location)

        // 拉：服务端版本回填本地
        f.annotationStore.clear("doc-1")
        f.manager.pullAnnotations("doc-1")
        val pulled = f.local().single()
        assertEquals("highlight", pulled.kind)
        assertEquals("选中原文", pulled.selectedText)
    }

    // ---- 批注：删除传播 ----

    /** ① 已上传批注删除 → 入队 → pushDeletes 发 DELETE 并清空队列。 */
    @Test
    fun deleteUploadedAnnotationIsPropagatedAndQueueCleared() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 7, location = "chapter:1@0-4", text = "要删的")
        val local = f.seedLocal(note = "要删的", location = "chapter:1@0-4", serverId = 7L, dirty = false)

        assertTrue(f.manager.deleteAnnotation("doc-1", local))
        assertEquals("已上传记录删除后必须入队", listOf(7L), f.pendingDeletes.list("doc-1"))
        assertTrue("本地记录已立即移除", f.local().isEmpty())

        val deleted = f.manager.pushDeletes("doc-1")

        assertEquals(1, deleted)
        assertEquals(listOf(7L), f.rest.deleteCalls)
        assertTrue("成功后必须出队", f.pendingDeletes.list("doc-1").isEmpty())
        assertTrue("服务端记录已删除", f.rest.listAnnotations("doc-1").isEmpty())
    }

    /** ② 未上传批注删除 → 仅本地移除，零请求、不入队。 */
    @Test
    fun deleteNeverUploadedAnnotationSendsNoRequest() {
        val f = fixture()
        val local = f.seedLocal(note = "从未上传", location = "chapter:1@0-4")

        assertTrue(f.manager.deleteAnnotation("doc-1", local))

        assertTrue(f.local().isEmpty())
        assertTrue("serverId 为空时不得入队", f.pendingDeletes.list("doc-1").isEmpty())
        assertEquals(0, f.manager.pushDeletes("doc-1"))
        assertEquals("未上传的删除不得产生任何网络请求", 0, f.rest.totalCalls)
    }

    /** ③ DELETE 404（服务端已无该 id）记为成功并出队。 */
    @Test
    fun deletePropagationTreatsMissingServerRecordAsSuccess() {
        val f = fixture()
        // 服务端本就没有 99 号记录（模拟别端已删 / 上次 DELETE 成功但未出队）
        f.queueDelete(99L)

        val deleted = f.manager.pushDeletes("doc-1")

        assertEquals(1, deleted)
        assertEquals(listOf(99L), f.rest.deleteCalls)
        assertTrue(f.pendingDeletes.list("doc-1").isEmpty())
    }

    /** 删除必须早于拉取：否则刚删掉的服务端记录会在 pull 阶段被重新写回本地。 */
    @Test
    fun syncDocumentDeletesBeforePulling() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 9, location = "chapter-9@0-3", text = "已删")
        f.queueDelete(9L)

        val summary = f.manager.syncDocument("doc-1")

        assertEquals(1, summary.deletedAnnotations)
        assertEquals(0, summary.pulledAnnotations)
        assertTrue("已删除的记录不得被 pull 复活", f.local().isEmpty())
        assertTrue(f.rest.listAnnotations("doc-1").isEmpty())
    }

    @Test
    fun pushDeletesWithoutQueueIsNoOp() {
        val rest = FakeRestSyncApi()
        val manager = SyncManager(
            rest,
            EpubLocalSyncStore(ReadingProgressStore(FakeSharedPreferences()), AnnotationStore(FakeSharedPreferences())),
            EpubSyncMapper(),
        )

        assertEquals("未装配待删队列时 pushDeletes 必须零请求", 0, manager.pushDeletes("doc-1"))
        assertEquals(0, rest.totalCalls)
    }

    /** 残留清理：本地仍有同 serverId 的记录时，DELETE 成功后一并清掉（删除流程中途被杀的兜底）。 */
    @Test
    fun pushDeletesDropsResidualLocalRecord() {
        val f = fixture()
        f.rest.addRemote(uid = "doc-1", id = 7, location = "chapter:1@0-4", text = "要删的")
        f.seedLocal(note = "要删的", location = "chapter:1@0-4", serverId = 7L)
        f.queueDelete(7L)

        assertEquals(1, f.manager.pushDeletes("doc-1"))

        assertTrue("同 serverId 的本地残留必须清理", f.local().isEmpty())
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
        assertTrue(f.local().any { it.note == "远端批注" })
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
        assertEquals(0, second.updatedAnnotations)
        assertEquals(0, second.pulledAnnotations)
        assertEquals(1, f.local().size)
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
        assertEquals("本地 id 不得复用服务端 id（由 store 分配 nextId）", 0L, local.id)
        assertEquals("服务端 id 只写 serverId", 7L, local.serverId)
        assertEquals("page:3", local.location)
        assertEquals("pdf 批注", local.text)
        assertEquals("page:3", mapper.location(local))
        assertEquals("pdf 批注", mapper.text(local))
    }

    /** ⑨ `location()` 优先新格式、旧记录（location 为空）按 chapterIndex 兜底。 */
    @Test
    fun epubMapperPrefersNewLocationAndFallsBackToChapterIndex() {
        val mapper = EpubSyncMapper()
        assertEquals(
            "chapter:3@10-20",
            mapper.location(
                BookAnnotation(
                    id = "a",
                    documentId = "doc-1",
                    chapterIndex = 3,
                    selectedText = "",
                    note = "n",
                    location = "chapter:3@10-20",
                ),
            ),
        )
        assertEquals(
            "旧记录 location 为空时按 chapterIndex 派生",
            "chapter-4",
            mapper.location(
                BookAnnotation(id = "b", documentId = "doc-1", chapterIndex = 4, selectedText = "", note = "n"),
            ),
        )
    }

    /** ⑨ `fromRemote` 对新旧两种 location 都回填 chapterIndex（不得归零）。 */
    @Test
    fun epubMapperParsesChapterIndexFromNewAndLegacyLocations() {
        val mapper = EpubSyncMapper()
        assertEquals(
            3,
            mapper.fromRemote(Annotation(id = 1, uid = "doc-1", location = "chapter:3@10-20", text = "新")).chapterIndex,
        )
        assertEquals(
            "旧形态 chapter-<n> 仍须解析出章节号",
            7,
            mapper.fromRemote(Annotation(id = 2, uid = "doc-1", location = "chapter-7", text = "旧")).chapterIndex,
        )
        assertEquals(
            "无法识别时容忍为 0",
            0,
            mapper.fromRemote(Annotation(id = 3, uid = "doc-1", location = "page:2", text = "脏")).chapterIndex,
        )
    }

    /** ⑩ epub 从服务端回填：本地 id 为空串、服务端 id 落 serverId、v8 字段透传。 */
    @Test
    fun epubMapperFromRemoteKeepsLocalIdEmptyAndFillsServerId() {
        val mapper = EpubSyncMapper()
        val local = mapper.fromRemote(
            Annotation(
                id = 7,
                uid = "doc-1",
                location = "chapter:3@10-20",
                text = "备注",
                kind = "highlight",
                selectedText = "选中原文",
            ),
        )

        assertEquals("", local.id)
        assertEquals(7L, local.serverId)
        assertEquals(3, local.chapterIndex)
        assertEquals("chapter:3@10-20", local.location)
        assertEquals("highlight", local.kind)
        assertEquals("选中原文", local.selectedText)
        assertEquals("备注", local.note)
        assertFalse(local.dirty)
    }

    /** ⑩ pdf 从服务端回填：本地 id 为 0、服务端 id 落 serverId、v8 字段透传。 */
    @Test
    fun pdfMapperFromRemoteKeepsLocalIdZeroAndFillsServerId() {
        val mapper = PdfSyncMapper()
        val local = mapper.fromRemote(
            Annotation(
                id = 12,
                uid = "doc-1",
                location = "page:5",
                text = "",
                kind = "ink",
                selectedText = "",
            ),
        )

        assertEquals(0L, local.id)
        assertEquals(12L, local.serverId)
        assertEquals("ink", local.kind)
        assertEquals("page:5", local.location)
        assertFalse(local.dirty)
    }

    /** `kind()` / `selectedText()` 在两个模型上都可取到值（三个 kind 各覆盖一次编码方向）。 */
    @Test
    fun mappersEncodeKindAndSelectedTextForBothModels() {
        val epub = EpubSyncMapper()
        val note = BookAnnotation(id = "a", documentId = "doc-1", chapterIndex = 1, selectedText = "原文", note = "备注")
        assertEquals("note", epub.kind(note))
        assertEquals("原文", epub.selectedText(note))
        assertEquals("highlight", epub.kind(note.copy(kind = "highlight")))
        assertEquals("旧记录缺 kind 时按 note", "note", epub.kind(note.copy(kind = "")))

        val pdf = PdfSyncMapper()
        val pageNote = PdfAnnotation(
            id = 1L,
            documentId = "doc-1",
            location = "page:1",
            text = "备注",
            createdAt = 0L,
            updatedAt = 0L,
            selectedText = "原文",
        )
        assertEquals("note", pdf.kind(pageNote))
        assertEquals("原文", pdf.selectedText(pageNote))
        assertEquals("ink", pdf.kind(pageNote.copy(kind = "ink")))
        assertEquals("note", pdf.kind(pageNote.copy(kind = "")))
    }
}
