package com.seshat.app.sync

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody

/** 阅读进度（服务端响应体）。 */
@Serializable
data class Progress(
    @SerialName("document_id") val documentId: String,
    @SerialName("position") val position: String,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/** 设置进度的请求体（`updated_at` 为空时由服务端填当前 UTC 时间）。 */
@Serializable
data class SetProgressRequest(
    @SerialName("position") val position: String,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/** 批注对象（创建/更新/列举响应的统一结构）。 */
@Serializable
data class Annotation(
    @SerialName("id") val id: Long = 0,
    @SerialName("document_id") val documentId: String,
    @SerialName("location") val location: String,
    @SerialName("text") val text: String,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/** 创建批注的请求体。 */
@Serializable
data class CreateAnnotationRequest(
    @SerialName("document_id") val documentId: String,
    @SerialName("location") val location: String,
    @SerialName("text") val text: String,
)

/** 更新批注的请求体（整体替换语义）。 */
@Serializable
data class UpdateAnnotationRequest(
    @SerialName("location") val location: String,
    @SerialName("text") val text: String,
)

/** REST 请求失败（非 2xx）；`code` 为服务端稳定错误码（若可解析）。 */
class ApiException(val statusCode: Int, val code: String?, message: String) : IOException(message)

/**
 * REST 状态同步客户端：阅读进度与批注 CRUD，`Authorization: Bearer <token>`，JSON 编解码。
 *
 * 端点严格对齐服务端 `internal/api`：
 * - `GET  /api/progress/{document_id}`（支持 If-Modified-Since，返回 null 表示 304）
 * - `PUT  /api/progress/{document_id}`
 * - `POST /api/annotations`（201）
 * - `GET  /api/annotations?document_id={id}`
 * - `PUT  /api/annotations/{id}`
 * - `DELETE /api/annotations/{id}`（204）
 */
class RestClient(
    private val config: SeshatConfig,
    private val client: OkHttpClient = defaultClient(),
    private val json: Json = defaultJson(),
) {
    companion object {
        const val IF_MODIFIED_SINCE = "If-Modified-Since"
        private val JSON = "application/json; charset=utf-8".toMediaType()

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()

        fun defaultJson(): Json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = false
        }
    }

    private fun bearer(): String = "Bearer ${config.token}"

    private fun apiUrl(vararg segments: String): HttpUrl {
        val builder = config.apiBase.toHttpUrl().newBuilder()
        segments.forEach { builder.addPathSegment(it) }
        return builder.build()
    }

    private fun <T> encode(serializer: kotlinx.serialization.KSerializer<T>, value: T) =
        json.encodeToString(serializer, value).toRequestBody(JSON)

    // ---- 请求构造（可单独用于单测断言） ----

    fun buildGetProgress(documentId: String, ifModifiedSince: String? = null): Request {
        val requestBuilder = Request.Builder()
            .url(apiUrl("progress", documentId))
            .get()
            .header("Authorization", bearer())
        if (ifModifiedSince != null) requestBuilder.header(IF_MODIFIED_SINCE, ifModifiedSince)
        return requestBuilder.build()
    }

    fun buildSetProgress(documentId: String, position: String, updatedAt: String? = null): Request =
        Request.Builder()
            .url(apiUrl("progress", documentId))
            .put(encode(SetProgressRequest.serializer(), SetProgressRequest(position, updatedAt)))
            .header("Authorization", bearer())
            .build()

    fun buildCreateAnnotation(documentId: String, location: String, text: String): Request =
        Request.Builder()
            .url(apiUrl("annotations"))
            .post(
                encode(
                    CreateAnnotationRequest.serializer(),
                    CreateAnnotationRequest(documentId, location, text),
                ),
            )
            .header("Authorization", bearer())
            .build()

    fun buildListAnnotations(documentId: String): Request =
        Request.Builder()
            .url(apiUrl("annotations").newBuilder().addQueryParameter("document_id", documentId).build())
            .get()
            .header("Authorization", bearer())
            .build()

    fun buildUpdateAnnotation(id: Long, location: String, text: String): Request =
        Request.Builder()
            .url(apiUrl("annotations", id.toString()))
            .put(encode(UpdateAnnotationRequest.serializer(), UpdateAnnotationRequest(location, text)))
            .header("Authorization", bearer())
            .build()

    fun buildDeleteAnnotation(id: Long): Request =
        Request.Builder()
            .url(apiUrl("annotations", id.toString()))
            .delete()
            .header("Authorization", bearer())
            .build()

    // ---- 执行方法 ----

    /** 获取阅读进度；服务端返回 304 时返回 null。 */
    fun getProgress(documentId: String, ifModifiedSince: String? = null): Progress? {
        client.newCall(buildGetProgress(documentId, ifModifiedSince)).execute().use { resp ->
            if (resp.code == 304) return null
            ensureSuccess(resp)
            return json.decodeFromString(Progress.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 设置（覆盖）阅读进度，返回服务端实际保存的记录。 */
    fun setProgress(documentId: String, position: String, updatedAt: String? = null): Progress {
        client.newCall(buildSetProgress(documentId, position, updatedAt)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(Progress.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 创建批注，返回含服务端分配 id 的完整对象。 */
    fun createAnnotation(documentId: String, location: String, text: String): Annotation {
        client.newCall(buildCreateAnnotation(documentId, location, text)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(Annotation.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 列出某文档的全部批注。 */
    fun listAnnotations(documentId: String): List<Annotation> {
        client.newCall(buildListAnnotations(documentId)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(
                ListSerializer(Annotation.serializer()),
                resp.body?.string().orEmpty(),
            )
        }
    }

    /** 更新批注，返回更新后的完整对象。 */
    fun updateAnnotation(id: Long, location: String, text: String): Annotation {
        client.newCall(buildUpdateAnnotation(id, location, text)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(Annotation.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 删除批注（服务端返回 204）。 */
    fun deleteAnnotation(id: Long) {
        client.newCall(buildDeleteAnnotation(id)).execute().use { resp ->
            ensureSuccess(resp)
        }
    }

    // ---- 内部工具 ----

    private fun ensureSuccess(resp: Response) {
        if (resp.isSuccessful) return
        val body = resp.body?.string().orEmpty()
        throw ApiException(resp.code, parseErrorCode(body), "REST ${resp.request.method} ${resp.request.url} 失败：HTTP ${resp.code} ${body.ifBlank { resp.message }}")
    }

    private fun parseErrorCode(body: String): String? = try {
        json.parseToJsonElement(body).jsonObject["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content
    } catch (_: Exception) {
        null
    }
}
