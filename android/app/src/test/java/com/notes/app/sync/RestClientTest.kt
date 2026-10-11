package com.notes.app.sync

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
    private lateinit var config: NotesConfig
    private lateinit var client: RestClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        config = NotesConfig(serverUrl = server.url("/").toString(), token = "secret-token")
        client = RestClient(config, OkHttpClient())
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

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
                .setBody("""{"document_id":"book-1","position":"chapter-3:42","updated_at":"2026-10-11T10:00:00Z"}"""),
        )
        val progress = client.getProgress("book-1")
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/api/progress/book-1", request.path)
        assertEquals("Bearer secret-token", request.getHeader("Authorization"))
        assertEquals("book-1", progress?.documentId)
        assertEquals("chapter-3:42", progress?.position)
    }

    @Test
    fun getProgressReturnsNullOn304() {
        server.enqueue(MockResponse().setResponseCode(304))
        assertNull(client.getProgress("book-1"))
    }

    @Test
    fun createAnnotationPostsAndParses() {
        server.enqueue(
            MockResponse().setResponseCode(201)
                .setBody(
                    """{"id":1,"document_id":"book-1","location":"chapter-1:10","text":"第一条","created_at":"2026-10-11T10:00:00Z","updated_at":"2026-10-11T10:00:00Z"}""",
                ),
        )
        val ann = client.createAnnotation("book-1", "chapter-1:10", "第一条")
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/annotations", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("book-1", body["document_id"]?.jsonPrimitive?.content)
        assertEquals(1L, ann.id)
        assertEquals("第一条", ann.text)
    }

    @Test
    fun listAnnotationsParsesArrayWithQueryParam() {
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody(
                    """[{"id":1,"document_id":"book-1","location":"l1","text":"t1"},{"id":2,"document_id":"book-1","location":"l2","text":"t2"}]""",
                ),
        )
        val list = client.listAnnotations("book-1")
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/api/annotations?document_id=book-1", request.path)
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
        assertEquals("book-1", req.url.queryParameter("document_id"))
        assertEquals("Bearer secret-token", req.header("Authorization"))
    }
}
