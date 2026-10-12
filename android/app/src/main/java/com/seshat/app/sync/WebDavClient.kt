package com.seshat.app.sync

import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/** WebDAV 目录项（PROPFIND 单条 response 解析结果）。 */
data class DavEntry(
    val href: String,
    val isCollection: Boolean,
    val contentLength: Long,
    val lastModified: String?,
    val etag: String?,
)

/** WebDAV 请求失败（非 2xx）。 */
class WebDavException(val statusCode: Int, message: String) : IOException(message)

/**
 * WebDAV 客户端：PROPFIND / GET / PUT / DELETE，使用 Basic 认证
 * （凭据为 `base64(user:token)`，与服务端 `internal/auth` 一致）。
 *
 * `client` 可注入（单测传入 MockWebServer 指向的 OkHttpClient）。
 */
class WebDavClient(
    private val config: SeshatConfig,
    private val client: OkHttpClient = defaultClient(),
    private val username: String = DEFAULT_USER,
) {
    companion object {
        const val METHOD_PROPFIND = "PROPFIND"
        const val DEFAULT_USER = "seshat"
        private const val DAV_NS = "DAV:"
        private const val XML_CONTENT_TYPE = "application/xml; charset=utf-8"
        private const val OCTET_STREAM = "application/octet-stream"

        private val PROPFIND_BODY = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:">
              <d:prop>
                <d:resourcetype/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:getetag/>
              </d:prop>
            </d:propfind>
        """.trimIndent()

        /** 默认客户端：设置合理的连接/读写超时。 */
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    private fun authHeader(): String = Credentials.basic(username, config.token)

    // ---- 请求构造（可单独用于单测断言 URL/Method/Header/Body） ----

    fun buildPropfind(path: String = config.remoteDir, depth: Int = 1): Request =
        Request.Builder()
            .url(config.davUrl(path))
            .method(METHOD_PROPFIND, PROPFIND_BODY.toRequestBody(XML_CONTENT_TYPE.toMediaType()))
            .header("Depth", depth.toString())
            .header("Authorization", authHeader())
            .build()

    fun buildGet(path: String): Request =
        Request.Builder()
            .url(config.davUrl(path))
            .get()
            .header("Authorization", authHeader())
            .build()

    fun buildPut(path: String, content: ByteArray, contentType: String = OCTET_STREAM): Request =
        Request.Builder()
            .url(config.davUrl(path))
            .put(content.toRequestBody(contentType.toMediaType()))
            .header("Authorization", authHeader())
            .build()

    fun buildDelete(path: String): Request =
        Request.Builder()
            .url(config.davUrl(path))
            .delete()
            .header("Authorization", authHeader())
            .build()

    // ---- 执行方法 ----

    /** PROPFIND 列举目录：返回目录项列表（Depth=1 时含直接子项）。 */
    fun propfind(path: String = config.remoteDir, depth: Int = 1): List<DavEntry> {
        client.newCall(buildPropfind(path, depth)).execute().use { resp ->
            ensureSuccess(resp)
            val xml = resp.body?.string().orEmpty()
            return parseMultiStatus(xml)
        }
    }

    fun getBytes(path: String): ByteArray {
        client.newCall(buildGet(path)).execute().use { resp ->
            ensureSuccess(resp)
            return resp.body?.bytes() ?: ByteArray(0)
        }
    }

    fun getText(path: String): String = getBytes(path).toString(Charsets.UTF_8)

    /** PUT 上传内容，返回响应状态码。 */
    fun put(path: String, content: ByteArray, contentType: String = OCTET_STREAM): Int {
        client.newCall(buildPut(path, content, contentType)).execute().use { resp ->
            ensureSuccess(resp)
            return resp.code
        }
    }

    /** DELETE 删除资源，返回响应状态码。 */
    fun delete(path: String): Int {
        client.newCall(buildDelete(path)).execute().use { resp ->
            ensureSuccess(resp)
            return resp.code
        }
    }

    // ---- 内部工具 ----

    private fun ensureSuccess(resp: okhttp3.Response) {
        if (resp.isSuccessful) return
        val body = resp.body?.string().orEmpty()
        throw WebDavException(resp.code, "WebDAV ${resp.request.method} ${resp.request.url} 失败：HTTP ${resp.code} ${body.ifBlank { resp.message }}")
    }

    /** 解析 207 Multi-Status 响应体，抽取各 `<response>` 的资源属性。 */
    private fun parseMultiStatus(xml: String): List<DavEntry> {
        if (xml.isBlank()) return emptyList()
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            // 关闭外部实体解析，避免 XXE。
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        }
        val doc = factory.newDocumentBuilder().parse(xml.byteInputStream(Charsets.UTF_8))
        val responses = doc.getElementsByTagNameNS(DAV_NS, "response")
        val result = ArrayList<DavEntry>(responses.length)
        for (i in 0 until responses.length) {
            val response = responses.item(i) as? Element ?: continue
            val href = firstText(response, "href") ?: continue
            val prop = firstPropElement(response, "prop") ?: continue
            val isCollection = prop.getElementsByTagNameNS(DAV_NS, "collection").length > 0
            val length = firstText(prop, "getcontentlength")?.toLongOrNull() ?: 0L
            val lastModified = firstText(prop, "getlastmodified")
            val etag = firstText(prop, "getetag")
            result.add(DavEntry(href, isCollection, length, lastModified, etag))
        }
        return result
    }

    private fun firstText(parent: Element, localName: String): String? {
        val nodes = parent.getElementsByTagNameNS(DAV_NS, localName)
        if (nodes.length == 0) return null
        return nodes.item(0).textContent?.trim()?.ifBlank { null }
    }

    private fun firstPropElement(parent: Element, localName: String): Element? {
        val nodes = parent.getElementsByTagNameNS(DAV_NS, localName)
        return nodes.item(0) as? Element
    }
}
