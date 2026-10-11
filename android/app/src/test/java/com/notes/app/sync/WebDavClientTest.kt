package com.notes.app.sync

import java.util.Base64
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** WebDavClient 请求构造与执行（MockWebServer）单测。 */
class WebDavClientTest {

    private lateinit var server: MockWebServer
    private lateinit var config: NotesConfig
    private lateinit var client: WebDavClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        config = NotesConfig(serverUrl = server.url("/").toString(), token = "secret-token")
        client = WebDavClient(config, OkHttpClient())
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun expectedBasic(): String =
        "Basic " + Base64.getEncoder().encodeToString("notes:secret-token".toByteArray(Charsets.UTF_8))

    @Test
    fun propfindSendsCorrectMethodHeadersAndParsesMultistatus() {
        val xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>/dav/</D:href>
                <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
              </D:response>
              <D:response>
                <D:href>/dav/notes/a.org</D:href>
                <D:propstat><D:prop>
                  <D:resourcetype/>
                  <D:getcontentlength>42</D:getcontentlength>
                  <D:getlastmodified>Sat, 11 Oct 2025 10:00:00 GMT</D:getlastmodified>
                  <D:getetag>"abc123"</D:getetag>
                </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
              </D:response>
            </D:multistatus>
        """.trimIndent()
        server.enqueue(MockResponse().setResponseCode(207).setBody(xml))

        val entries = client.propfind("/", 1)

        val request = server.takeRequest()
        assertEquals("PROPFIND", request.method)
        assertEquals("/dav", request.path)
        assertEquals("1", request.getHeader("Depth"))
        assertEquals(expectedBasic(), request.getHeader("Authorization"))
        assertTrue(request.body.readUtf8().contains("<d:propfind"))

        assertEquals(2, entries.size)
        val dir = entries[0]
        assertEquals("/dav/", dir.href)
        assertTrue(dir.isCollection)
        val file = entries[1]
        assertEquals("/dav/notes/a.org", file.href)
        assertFalse(file.isCollection)
        assertEquals(42L, file.contentLength)
        assertEquals("\"abc123\"", file.etag)
        assertNotNull(file.lastModified)
    }

    @Test
    fun getBytesReturnsBody() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("hello dav"))
        val text = client.getText("notes/a.org")
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/dav/notes/a.org", request.path)
        assertEquals(expectedBasic(), request.getHeader("Authorization"))
        assertEquals("hello dav", text)
    }

    @Test
    fun putSendsBodyAndContentType() {
        server.enqueue(MockResponse().setResponseCode(201))
        val code = client.put("notes/a.org", "* title\n".toByteArray(Charsets.UTF_8), "text/plain")
        val request = server.takeRequest()
        assertEquals("PUT", request.method)
        assertEquals("/dav/notes/a.org", request.path)
        assertTrue(request.getHeader("Content-Type")!!.startsWith("text/plain"))
        assertTrue(request.body.readUtf8().contains("* title"))
        assertEquals(201, code)
    }

    @Test
    fun buildPutUsesOctetStreamByDefault() {
        val req = client.buildPut("a.bin", byteArrayOf(1, 2, 3))
        assertEquals("PUT", req.method)
        assertEquals("http://${server.hostName}:${server.port}/dav/a.bin", req.url.toString())
        assertEquals("application/octet-stream", req.body?.contentType().toString())
    }

    @Test
    fun deleteReturnsStatus() {
        server.enqueue(MockResponse().setResponseCode(204))
        val code = client.delete("notes/a.org")
        val request = server.takeRequest()
        assertEquals("DELETE", request.method)
        assertEquals("/dav/notes/a.org", request.path)
        assertEquals(204, code)
    }
}
