package com.seshat.app.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** RestClient 请求构造与执行（MockWebServer）单测。 */
class RestClientTest {

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
}
