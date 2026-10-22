package com.seshat.app.sync

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** RestClient 请求构造与执行（MockWebServer）单测。 */
class RestClientTest {

    /** 下载落盘用例需要真实目录（[TemporaryFolder]）。 */
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var config: SeshatConfig
    private lateinit var client: RestClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        config = SeshatConfig(serverUrl = server.url("/").toString(), token = "secret-token")
        client = RestClient(config, OkHttpClient())
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    // ---- 进度 ----

    @Test
    fun buildGetProgressUsesPathAndBearer() {
        val req = client.buildGetProgress("book-1", "Sat, 11 Oct 2025 10:00:00 GMT")
        assertEquals("GET", req.method)
        assertEquals("http://${server.hostName}:${server.port}/api/progress/book-1", req.url.toString())
        assertEquals("Bearer secret-token", req.header("Authorization"))
        assertEquals("Sat, 11 Oct 2025 10:00:00 GMT", req.header(RestClient.IF_MODIFIED_SINCE))
    }

    @Test
    fun buildSetProgressSerializesBody() {
        val req = client.buildSetProgress("book-1", "chapter-3:42", "2026-10-11T10:00:00Z")
        assertEquals("PUT", req.method)
        assertEquals("/api/progress/book-1", req.url.encodedPath)
        val body = req.body?.let { okio.Buffer().also { b -> it.writeTo(b) }.readUtf8() }.orEmpty()
        val obj = Json.parseToJsonElement(body).jsonObject
        assertEquals("chapter-3:42", obj["position"]?.jsonPrimitive?.content)
        assertEquals("2026-10-11T10:00:00Z", obj["updated_at"]?.jsonPrimitive?.content)
    }

    @Test
    fun getProgressParsesResponse() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"uid":"book-1","position":"chapter-3:42","updated_at":"2026-10-11T10:00:00Z"}"""),
        )
        val progress = client.getProgress("book-1")
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/api/progress/book-1", request.path)
        assertEquals("Bearer secret-token", request.getHeader("Authorization"))
        assertEquals("book-1", progress?.uid)
        assertEquals("chapter-3:42", progress?.position)
    }

    @Test
    fun getProgressReturnsNullOn304() {
        server.enqueue(MockResponse().setResponseCode(304))
        assertNull(client.getProgress("book-1"))
    }

    // ---- 批注 ----

    @Test
    fun createAnnotationPostsAndParses() {
        server.enqueue(
            MockResponse().setResponseCode(201)
                .setBody(
                    """{"id":1,"uid":"book-1","location":"chapter-1:10","text":"第一条","created_at":"2026-10-11T10:00:00Z","updated_at":"2026-10-11T10:00:00Z"}""",
                ),
        )
        val ann = client.createAnnotation("book-1", "chapter-1:10", "第一条")
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/annotations", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("book-1", body["uid"]?.jsonPrimitive?.content)
        assertEquals(1L, ann.id)
        assertEquals("第一条", ann.text)
    }

    @Test
    fun listAnnotationsParsesArrayWithQueryParam() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody(
                    """[{"id":1,"uid":"book-1","location":"l1","text":"t1"},{"id":2,"uid":"book-1","location":"l2","text":"t2"}]""",
                ),
        )
        val list = client.listAnnotations("book-1")
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/api/annotations?uid=book-1", request.path)
        assertEquals(2, list.size)
        assertEquals(2L, list[1].id)
    }

    @Test
    fun deleteAnnotationAccepts204() {
        server.enqueue(MockResponse().setResponseCode(204))
        client.deleteAnnotation(7L)
        val request = server.takeRequest()
        assertEquals("DELETE", request.method)
        assertEquals("/api/annotations/7", request.path)
    }

    @Test
    fun nonSuccessThrowsApiExceptionWithCode() {
        server.enqueue(
            MockResponse().setResponseCode(404)
                .setBody("""{"error":{"code":"not_found","message":"阅读进度不存在"}}"""),
        )
        try {
            client.getProgress("missing")
            fail("应抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(404, e.statusCode)
            assertEquals("not_found", e.code)
        }
    }

    @Test
    fun buildListAnnotationsHasQueryParameter() {
        val req = client.buildListAnnotations("book-1")
        assertEquals("GET", req.method)
        assertEquals("book-1", req.url.queryParameter("uid"))
        assertEquals("Bearer secret-token", req.header("Authorization"))
    }

    /** 服务端 400 + `invalid_uid` 错误码须原样暴露给调用方（M9.2 断言）。 */
    @Test
    fun invalidUidCodeIsExposed() {
        server.enqueue(
            MockResponse().setResponseCode(400)
                .setBody("""{"error":{"code":"invalid_uid","message":"uid 形态非法"}}"""),
        )
        try {
            client.getProgress("bad uid")
            fail("应抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(400, e.statusCode)
            assertEquals("invalid_uid", e.code)
        }
    }

    // ---- M7 新增只读端点：roots ----

    @Test
    fun rootsParsesWrappedResponse() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody("""{"roots":[{"tag":"notes","mode":"mirror","default":true},{"tag":"docs","mode":"ro"}]}"""),
        )
        val roots = client.roots()
        assertEquals(2, roots.size)
        assertEquals("notes", roots[0].tag)
        assertEquals("mirror", roots[0].mode)
        assertTrue(roots[0].isDefault)
        assertEquals("docs", roots[1].tag)
        assertEquals(false, roots[1].isDefault)
    }

    @Test
    fun rootsUsesBearerAndPath() {
        val req = client.buildRoots()
        assertEquals("GET", req.method)
        assertEquals("/api/roots", req.url.encodedPath)
        assertEquals("Bearer secret-token", req.header("Authorization"))
    }

    // ---- M7 新增只读端点：resources ----

    @Test
    fun resourcesBuildsQueryWithAllParams() {
        val req = client.buildResources(
            root = "notes",
            prefix = "books/",
            sinceMtime = 1700000000123L,
            includeDeleted = true,
            limit = 200,
        )
        assertEquals("GET", req.method)
        assertEquals("/api/resources", req.url.encodedPath)
        assertEquals("notes", req.url.queryParameter("root"))
        assertEquals("books/", req.url.queryParameter("prefix"))
        assertEquals("1700000000123", req.url.queryParameter("since"))
        assertEquals("true", req.url.queryParameter("include_deleted"))
        assertEquals("200", req.url.queryParameter("limit"))
        assertEquals("Bearer secret-token", req.header("Authorization"))
    }

    /** 三个可空过滤参数为 null 时不得出现在 URL 中；`limit` 恒添加。 */
    @Test
    fun resourcesOmitsNullParams() {
        val req = client.buildResources()
        assertEquals("/api/resources", req.url.encodedPath)
        assertNull(req.url.queryParameter("root"))
        assertNull(req.url.queryParameter("prefix"))
        assertNull(req.url.queryParameter("since"))
        assertNull(req.url.queryParameter("include_deleted"))
        assertEquals("500", req.url.queryParameter("limit"))
    }

    @Test
    fun resourcesParsesItemsAndHasMore() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody(
                    """{"items":[{"uid":"u1","root":"notes","path":"a.md","mtime":1700000000},{"uid":"u2","root":"notes","path":"b.md"}],"has_more":true}""",
                ),
        )
        val page = client.resources(root = "notes")
        val request = server.takeRequest()
        assertEquals("/api/resources?root=notes&limit=500", request.path)
        assertEquals(2, page.items.size)
        assertEquals("u1", page.items[0].uid)
        assertEquals("a.md", page.items[0].path)
        assertTrue(page.hasMore)
    }

    /** `size`/`mtime` 为 int64：超过 Int 范围的值必须无损解码为 Long。 */
    @Test
    fun resourcesParsesInt64Fields() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody(
                    """{"items":[{"uid":"u1","size":9007199254740993,"mtime":9007199254740994}],"has_more":false}""",
                ),
        )
        val page = client.resources()
        assertEquals(1, page.items.size)
        assertEquals(9007199254740993L, page.items[0].size)
        assertEquals(9007199254740994L, page.items[0].mtime)
        assertEquals(false, page.hasMore)
    }

    // ---- M7 新增只读端点：resolve ----

    @Test
    fun resolveReturnsUidOn200() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody("""{"uid":"u-42","root":"notes","path":"books/a.epub"}"""),
        )
        val uid = client.resolve("notes", "books/a.epub")
        val request = server.takeRequest()
        assertEquals("/api/resolve", request.requestUrl?.encodedPath)
        assertEquals("notes", request.requestUrl?.queryParameter("root"))
        assertEquals("books/a.epub", request.requestUrl?.queryParameter("path"))
        assertEquals("Bearer secret-token", request.getHeader("Authorization"))
        assertEquals("u-42", uid)
    }

    @Test
    fun resolveReturnsNullOn404() {
        server.enqueue(
            MockResponse().setResponseCode(404)
                .setBody("""{"error":{"code":"unknown_uid","message":"未登记"}}"""),
        )
        assertNull(client.resolve("notes", "missing.epub"))
    }

    @Test
    fun resolveThrowsApiExceptionOn400() {
        server.enqueue(
            MockResponse().setResponseCode(400)
                .setBody("""{"error":{"code":"invalid_argument","message":"root 与 path 必须同时提供"}}"""),
        )
        try {
            client.resolve("notes", "")
            fail("应抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(400, e.statusCode)
            assertEquals("invalid_argument", e.code)
        }
    }

    // ---- M7 新增只读端点：changes ----

    @Test
    fun changesParsesChangesAndNextCursor() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody(
                    """{"changes":[{"seq":7,"uid":"u1","op":"rename","root":"notes","path":"new.md","old_path":"old.md","changed_at":"2026-10-11T10:00:00Z"}],"next_cursor":9007199254740993,"has_more":false}""",
                ),
        )
        val page = client.changes(0)
        val request = server.takeRequest()
        assertEquals("/api/changes?since=0&limit=2000", request.path)
        assertEquals(1, page.changes.size)
        val change = page.changes[0]
        assertEquals(7L, change.seq)
        assertEquals("u1", change.uid)
        assertEquals("rename", change.op)
        assertEquals("old.md", change.oldPath)
        assertEquals("2026-10-11T10:00:00Z", change.changedAt)
        assertEquals(9007199254740993L, page.nextCursor)
        assertEquals(false, page.hasMore)
    }

    @Test
    fun changesPassesSinceAndLimit() {
        val req = client.buildChanges(since = 1234L, limit = 100)
        assertEquals("/api/changes", req.url.encodedPath)
        assertEquals("1234", req.url.queryParameter("since"))
        assertEquals("100", req.url.queryParameter("limit"))
        assertEquals("Bearer secret-token", req.header("Authorization"))
    }

    // ---- M9.2 B 批：文件通道（/api/files + move） ----

    /** 路径按 `/` 逐段编码，`root` 走 query。 */
    @Test
    fun buildGetFileEncodesPathSegmentsAndRoot() {
        val req = client.buildGetFile("notes", "/a/b.org")
        assertEquals("GET", req.method)
        assertEquals("/api/files/a/b.org", req.url.encodedPath)
        assertEquals("notes", req.url.queryParameter("root"))
        assertEquals(listOf("api", "files", "a", "b.org"), req.url.pathSegments)
        assertEquals("Bearer secret-token", req.header("Authorization"))
    }

    /** 中文与空格必须百分号编码，且解码回来后仍等于原始路径段（不得出现裸空格）。 */
    @Test
    fun buildGetFileEncodesChineseAndSpace() {
        val req = client.buildGetFile("notes", "中文 书/第一章 a.org")
        assertTrue(req.url.encodedPath.contains("%E4%B8%AD%E6%96%87%20%E4%B9%A6"))
        assertFalse(req.url.encodedPath.contains(" "))
        assertEquals(listOf("api", "files", "中文 书", "第一章 a.org"), req.url.pathSegments)
    }

    @Test
    fun buildGetFileAddsIfNoneMatchHeader() {
        val req = client.buildGetFile("notes", "a.org", ifNoneMatch = "\"etag-1\"")
        assertEquals("\"etag-1\"", req.header("If-None-Match"))
        assertNull(req.header("Range"))
    }

    /** `rangeStart` → `Range: bytes=<start>-`（服务端按 `http.ServeContent` 语法解析）。 */
    @Test
    fun buildGetFileAddsRangeHeader() {
        val req = client.buildGetFile("notes", "a.org", rangeStart = 100L)
        assertEquals("bytes=100-", req.header("Range"))
        assertNull(req.header("If-None-Match"))
    }

    @Test
    fun buildPutFileUsesOctetStreamAndBody() {
        val bytes = byteArrayOf(0, 1, 2, 65, 66)
        val req = client.buildPutFile("notes", "a/b.org", bytes)
        assertEquals("PUT", req.method)
        assertEquals("/api/files/a/b.org", req.url.encodedPath)
        assertEquals("notes", req.url.queryParameter("root"))
        assertTrue(req.body!!.contentType().toString().startsWith("application/octet-stream"))
        val buffer = okio.Buffer()
        req.body!!.writeTo(buffer)
        assertArrayEquals(bytes, buffer.readByteArray())
    }

    @Test
    fun buildPutFileAddsConditionalHeaders() {
        val req = client.buildPutFile("notes", "a.org", byteArrayOf(1), ifMatch = "\"e1\"", ifNoneMatch = "*")
        assertEquals("\"e1\"", req.header("If-Match"))
        assertEquals("*", req.header("If-None-Match"))
    }

    @Test
    fun buildDeleteFileUsesDeleteMethod() {
        val req = client.buildDeleteFile("notes", "dir/a.org")
        assertEquals("DELETE", req.method)
        assertEquals("/api/files/dir/a.org", req.url.encodedPath)
        assertEquals("notes", req.url.queryParameter("root"))
    }

    @Test
    fun buildMoveResourcePostsToBody() {
        val req = client.buildMoveResource("u-1", "x/y.org")
        assertEquals("POST", req.method)
        assertEquals("/api/resources/u-1/move", req.url.encodedPath)
        val body = okio.Buffer().also { req.body!!.writeTo(it) }.readUtf8()
        assertEquals("x/y.org", Json.parseToJsonElement(body).jsonObject["to"]?.jsonPrimitive?.content)
    }

    /** 200 → 内容落盘；`.part` 临时文件必须已被 rename 掉。 */
    @Test
    fun downloadFileWritesTargetAndLeavesNoPart() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("hello-file-bytes"))
        val dir = tmp.newFolder()
        val target = File(dir, "b.org")
        val result = client.downloadFile("notes", "a/b.org", target)
        val request = server.takeRequest()
        assertEquals("/api/files/a/b.org?root=notes", request.path)
        assertEquals(target, result)
        assertEquals("hello-file-bytes", target.readText())
        assertFalse(File(dir, "b.org.part").exists())
    }

    /** 304 → 返回 null，且不得创建（或截断）本地文件。 */
    @Test
    fun downloadFileReturnsNullOn304() {
        server.enqueue(MockResponse().setResponseCode(304))
        val dir = tmp.newFolder()
        val target = File(dir, "b.org")
        assertNull(client.downloadFile("notes", "b.org", target, ifNoneMatch = "\"etag-1\""))
        assertEquals("\"etag-1\"", server.takeRequest().getHeader("If-None-Match"))
        assertFalse(target.exists())
        assertFalse(File(dir, "b.org.part").exists())
    }

    /** 非 2xx → 抛 ApiException，且残留的 `.part` 必须被清理。 */
    @Test
    fun downloadFileCleansPartOnError() {
        server.enqueue(
            MockResponse().setResponseCode(500)
                .setBody("""{"error":{"code":"internal","message":"读取失败"}}"""),
        )
        val dir = tmp.newFolder()
        val target = File(dir, "b.org")
        try {
            client.downloadFile("notes", "b.org", target)
            fail("应抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(500, e.statusCode)
            assertEquals("internal", e.code)
        }
        assertFalse(File(dir, "b.org.part").exists())
        assertFalse(target.exists())
    }

    /** 超 32 MiB 前置拦截：不得发出任何请求。 */
    @Test
    fun uploadFileRejectsOversizeBeforeRequest() {
        val tooBig = ByteArray((RestClient.MAX_UPLOAD_BYTES + 1).toInt())
        try {
            client.uploadFile("notes", "big.epub", tooBig)
            fail("应抛出 IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message.orEmpty().contains("32 MiB"))
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun uploadFileParsesWriteResponse() {
        server.enqueue(
            MockResponse().setResponseCode(201)
                .setBody(
                    """{"uid":"u-1","root":"notes","path":"books/a.epub","blob":"blob-1","etag":"\"e-1\"","rev":"r-1","seq":9007199254740993,"created":true}""",
                ),
        )
        val resp = client.uploadFile("notes", "books/a.epub", byteArrayOf(1, 2, 3), ifNoneMatch = "*")
        val request = server.takeRequest()
        assertEquals("PUT", request.method)
        assertEquals("/api/files/books/a.epub?root=notes", request.path)
        assertEquals("*", request.getHeader("If-None-Match"))
        assertEquals("u-1", resp.uid)
        assertEquals("books/a.epub", resp.path)
        assertEquals("blob-1", resp.blob)
        assertEquals("\"e-1\"", resp.etag)
        assertEquals("r-1", resp.rev)
        assertEquals(9007199254740993L, resp.seq)
        assertTrue(resp.created)
    }

    @Test
    fun deleteFileParsesUids() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody("""{"uid":"u-1","uids":["u-1","u-2"],"root":"notes","path":"dir/a.org","seq":7}"""),
        )
        val resp = client.deleteFile("notes", "dir/a.org")
        val request = server.takeRequest()
        assertEquals("DELETE", request.method)
        assertEquals("/api/files/dir/a.org?root=notes", request.path)
        assertEquals(listOf("u-1", "u-2"), resp.uids)
        assertEquals("dir/a.org", resp.path)
        assertEquals(7L, resp.seq)
    }

    @Test
    fun moveResourceParsesFromAndTo() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody("""{"uid":"u-1","root":"notes","from":"a.org","to":"x/y.org","seq":9}"""),
        )
        val resp = client.moveResource("u-1", "x/y.org")
        val request = server.takeRequest()
        assertEquals("/api/resources/u-1/move", request.requestUrl?.encodedPath)
        assertEquals("x/y.org", Json.parseToJsonElement(request.body.readUtf8()).jsonObject["to"]?.jsonPrimitive?.content)
        assertEquals("u-1", resp.uid)
        assertEquals("a.org", resp.from)
        assertEquals("x/y.org", resp.to)
        assertEquals(9L, resp.seq)
    }

    // ---- M10.3 T3：批注 kind / selected_text / updated_at / 409 / 404 ----

    /** 请求体 JSON 解析（`buildXxx` 与 MockWebServer 记录的请求共用）。 */
    private fun bodyOf(req: okhttp3.Request): kotlinx.serialization.json.JsonObject =
        Json.parseToJsonElement(
            okio.Buffer().also { req.body!!.writeTo(it) }.readUtf8(),
        ).jsonObject

    /** 创建请求体带 `kind` 与 `selected_text`（非默认值才会被 `encodeDefaults=false` 序列化）。 */
    @Test
    fun buildCreateAnnotationSerializesKindAndSelectedText() {
        val req = client.buildCreateAnnotation(
            "book-1",
            "chapter:3@10-20",
            "",
            kind = "highlight",
            selectedText = "选中原文",
        )
        val body = bodyOf(req)
        assertEquals("POST", req.method)
        assertEquals("highlight", body["kind"]?.jsonPrimitive?.content)
        assertEquals("选中原文", body["selected_text"]?.jsonPrimitive?.content)
        assertEquals("", body["text"]?.jsonPrimitive?.content)
        assertEquals("book-1", body["uid"]?.jsonPrimitive?.content)
    }

    /**
     * 缺省值被 `encodeDefaults=false` 省略：服务端对缺键按 `kind="note"` / `selected_text=""` 兜底，
     * 与显式传默认值等价（保持既有调用方的请求体形状不变）。
     */
    @Test
    fun buildCreateAnnotationOmitsDefaultKindAndSelectedText() {
        val body = bodyOf(client.buildCreateAnnotation("book-1", "page:1", "备注"))
        assertNull(body["kind"])
        assertNull(body["selected_text"])
        assertEquals("备注", body["text"]?.jsonPrimitive?.content)
    }

    @Test
    fun createAnnotationPostsKindAndSelectedText() {
        server.enqueue(
            MockResponse().setResponseCode(201)
                .setBody(
                    """{"id":3,"uid":"book-1","location":"chapter:1@0-5","text":"","kind":"highlight","selected_text":"选中","created_at":"2026-10-11T10:00:00Z","updated_at":"2026-10-11T10:00:00Z"}""",
                ),
        )
        val ann = client.createAnnotation("book-1", "chapter:1@0-5", "", kind = "highlight", selectedText = "选中")
        val sent = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("highlight", sent["kind"]?.jsonPrimitive?.content)
        assertEquals("选中", sent["selected_text"]?.jsonPrimitive?.content)
        assertEquals("highlight", ann.kind)
        assertEquals("选中", ann.selectedText)
    }

    /** `updatedAt` 非空 → 请求体带 `updated_at`。 */
    @Test
    fun buildUpdateAnnotationIncludesUpdatedAtWhenPresent() {
        val req = client.buildUpdateAnnotation(
            id = 7L,
            location = "page:2",
            text = "改后备注",
            kind = "note",
            selectedText = "选中",
            updatedAt = "2026-10-22T10:00:00Z",
        )
        val body = bodyOf(req)
        assertEquals("PUT", req.method)
        assertEquals("/api/annotations/7", req.url.encodedPath)
        assertEquals("2026-10-22T10:00:00Z", body["updated_at"]?.jsonPrimitive?.content)
        assertEquals("选中", body["selected_text"]?.jsonPrimitive?.content)
        assertEquals("改后备注", body["text"]?.jsonPrimitive?.content)
    }

    /** `updatedAt` 为空 → 请求体不含 `updated_at`（服务端自行填当前时间，不做冲突检测）。 */
    @Test
    fun buildUpdateAnnotationOmitsUpdatedAtWhenAbsent() {
        val body = bodyOf(client.buildUpdateAnnotation(7L, "page:2", "改后备注"))
        assertNull(body["updated_at"])
        assertNull(body["kind"])
        assertNull(body["selected_text"])
    }

    @Test
    fun updateAnnotationReturnsOkOn200() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody(
                    """{"id":7,"uid":"book-1","location":"page:2","text":"改后","kind":"note","selected_text":"","updated_at":"2026-10-22T11:00:00Z"}""",
                ),
        )
        val result = client.updateAnnotation(7L, "page:2", "改后", updatedAt = "2026-10-22T10:00:00Z")
        val request = server.takeRequest()
        assertEquals("PUT", request.method)
        assertEquals("/api/annotations/7", request.path)
        val ok = result as UpdateAnnotationResult.Ok
        assertEquals(7L, ok.annotation.id)
        assertEquals("2026-10-22T11:00:00Z", ok.annotation.updatedAt)
    }

    /** 409 → 可判别的 `Conflict`（不抛异常，交由同步层按「服务端版本为准」合并）。 */
    @Test
    fun updateAnnotationReturnsConflictOn409() {
        server.enqueue(
            MockResponse().setResponseCode(409)
                .setBody("""{"error":{"code":"conflict","message":"批注已被他人修改"}}"""),
        )
        val result = client.updateAnnotation(7L, "page:2", "改后", updatedAt = "2026-10-22T09:00:00Z")
        assertEquals(UpdateAnnotationResult.Conflict, result)
    }

    /** 其它非 2xx 仍按统一约定抛 [ApiException]（只有 409 被特判）。 */
    @Test
    fun updateAnnotationThrowsOnOtherErrors() {
        server.enqueue(
            MockResponse().setResponseCode(500)
                .setBody("""{"error":{"code":"internal","message":"写入失败"}}"""),
        )
        try {
            client.updateAnnotation(7L, "page:2", "改后")
            fail("应抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(500, e.statusCode)
            assertEquals("internal", e.code)
        }
    }

    /** DELETE 404 视为成功（服务端批注已不存在 = 删除目标已达成）。 */
    @Test
    fun deleteAnnotationTreats404AsSuccess() {
        server.enqueue(
            MockResponse().setResponseCode(404)
                .setBody("""{"error":{"code":"not_found","message":"批注不存在"}}"""),
        )
        client.deleteAnnotation(7L)
        assertEquals("DELETE", server.takeRequest().method)
    }

    @Test
    fun deleteAnnotationThrowsOnOtherErrors() {
        server.enqueue(
            MockResponse().setResponseCode(500)
                .setBody("""{"error":{"code":"internal","message":"删除失败"}}"""),
        )
        try {
            client.deleteAnnotation(7L)
            fail("应抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(500, e.statusCode)
        }
    }
}
