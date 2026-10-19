package com.seshat.app.sync

import java.io.File
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
    @SerialName("uid") val uid: String,
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
    @SerialName("uid") val uid: String,
    @SerialName("location") val location: String,
    @SerialName("text") val text: String,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/** 创建批注的请求体。 */
@Serializable
data class CreateAnnotationRequest(
    @SerialName("uid") val uid: String,
    @SerialName("location") val location: String,
    @SerialName("text") val text: String,
)

/** 更新批注的请求体（整体替换语义）。 */
@Serializable
data class UpdateAnnotationRequest(
    @SerialName("location") val location: String,
    @SerialName("text") val text: String,
)

/** 仓库根（M7 `GET /api/roots` 的条目）。 */
@Serializable
data class RootDto(
    @SerialName("tag") val tag: String,
    @SerialName("mode") val mode: String,
    // default 是 Kotlin 关键字，属性名改为 isDefault，序列化名保持服务端字段
    @SerialName("default") val isDefault: Boolean = false,
)

/** `GET /api/roots` 的外层包装（服务端返回 `{"roots":[...]}`）。 */
@Serializable
data class RootsResponse(@SerialName("roots") val roots: List<RootDto> = emptyList())

/** 资源条目（M7 只读端点）。`size`/`mtime` 为 int64，必须用 Long。 */
@Serializable
data class ResourceDto(
    @SerialName("uid") val uid: String,
    @SerialName("root") val root: String = "",
    @SerialName("path") val path: String = "",
    @SerialName("kind") val kind: String = "",
    @SerialName("blob") val blob: String = "",
    @SerialName("rev") val rev: String = "",
    @SerialName("size") val size: Long = 0,
    @SerialName("mtime") val mtime: Long = 0,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
    @SerialName("deleted_at") val deletedAt: String = "",
)

/** `GET /api/resources` 的分页响应。 */
@Serializable
data class ResourcesPageDto(
    @SerialName("items") val items: List<ResourceDto> = emptyList(),
    @SerialName("has_more") val hasMore: Boolean = false,
)

/** `GET /api/resolve` 的响应（root + path → uid）。 */
@Serializable
data class ResolveResponse(
    @SerialName("uid") val uid: String,
    @SerialName("root") val root: String = "",
    @SerialName("path") val path: String = "",
)

/** 变更日志条目（M7 `GET /api/changes`）；`seq` 为 int64。 */
@Serializable
data class ChangeDto(
    @SerialName("seq") val seq: Long = 0,
    @SerialName("uid") val uid: String = "",
    @SerialName("op") val op: String = "",
    @SerialName("root") val root: String = "",
    @SerialName("path") val path: String = "",
    @SerialName("old_path") val oldPath: String? = null,
    @SerialName("blob") val blob: String = "",
    @SerialName("rev") val rev: String = "",
    @SerialName("changed_at") val changedAt: String = "",
)

/** `GET /api/changes` 的分页响应；`next_cursor` 为 int64。 */
@Serializable
data class ChangesPageDto(
    @SerialName("changes") val changes: List<ChangeDto> = emptyList(),
    @SerialName("next_cursor") val nextCursor: Long = 0,
    @SerialName("has_more") val hasMore: Boolean = false,
)

/** `PUT /api/files/{path...}` 的响应（写入后的资源快照；`created` 表示是否新建）。 */
@Serializable
data class FileWriteResponse(
    @SerialName("uid") val uid: String = "",
    @SerialName("root") val root: String = "",
    @SerialName("path") val path: String = "",
    @SerialName("blob") val blob: String = "",
    @SerialName("etag") val etag: String = "",
    @SerialName("rev") val rev: String = "",
    @SerialName("seq") val seq: Long = 0,
    @SerialName("created") val created: Boolean = false,
)

/** `DELETE /api/files/{path...}` 的响应（软删；目录会返回多个 uid）。 */
@Serializable
data class FileDeleteResponse(
    @SerialName("uid") val uid: String = "",
    @SerialName("uids") val uids: List<String> = emptyList(),
    @SerialName("root") val root: String = "",
    @SerialName("path") val path: String = "",
    @SerialName("seq") val seq: Long = 0,
)

/** `POST /api/resources/{uid}/move` 的响应。 */
@Serializable
data class MoveResponse(
    @SerialName("uid") val uid: String = "",
    @SerialName("root") val root: String = "",
    @SerialName("from") val from: String = "",
    @SerialName("to") val to: String = "",
    @SerialName("seq") val seq: Long = 0,
)

/** `POST /api/resources/{uid}/move` 的请求体：`to` 为根内目标路径。 */
@Serializable
data class MoveRequest(@SerialName("to") val to: String)

/** REST 请求失败（非 2xx）；`code` 为服务端稳定错误码（若可解析）。 */
class ApiException(val statusCode: Int, val code: String?, message: String) : IOException(message)

/**
 * REST 状态同步客户端：阅读进度与批注 CRUD + M7 只读状态端点，`Authorization: Bearer <token>`，JSON 编解码。
 *
 * 端点严格对齐服务端 `internal/api`（M7 起状态标识统一为资源 uid，旧称 document_id）：
 * - `GET  /api/progress/{uid}`（支持 If-Modified-Since，返回 null 表示 304）
 * - `PUT  /api/progress/{uid}`
 * - `POST /api/annotations`（201）
 * - `GET  /api/annotations?uid={id}`
 * - `PUT  /api/annotations/{id}`
 * - `DELETE /api/annotations/{id}`（204）
 * - `GET  /api/roots`（外层 `{"roots":[...]}`）
 * - `GET  /api/resources?root=&prefix=&since=&include_deleted=&limit=`（`since` 为 mtime 秒级）
 * - `GET  /api/resolve?root=&path=`
 * - `GET  /api/changes?since=&limit=`
 * - `GET  /api/files/{path...}?root=`（原始字节；支持 `Range`、`If-None-Match`）
 * - `PUT  /api/files/{path...}?root=`（原始字节，≤32 MiB；支持 `If-Match`/`If-None-Match`）
 * - `DELETE /api/files/{path...}?root=`（软删，返回受影响 uid 列表）
 * - `POST /api/resources/{uid}/move`（根内改名，仅 mirror 根可写）
 */
class RestClient(
    private val config: SeshatConfig,
    private val client: OkHttpClient = defaultClient(),
    private val json: Json = defaultJson(),
) {
    companion object {
        const val IF_MODIFIED_SINCE = "If-Modified-Since"

        /** 上传体积上限：与服务端 `maxFileBytes = 32 << 20` 保持一致（超限前置拒绝，不发请求）。 */
        const val MAX_UPLOAD_BYTES = 32L * 1024 * 1024

        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val OCTET_STREAM = "application/octet-stream".toMediaType()

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

    fun buildGetProgress(uid: String, ifModifiedSince: String? = null): Request {
        val requestBuilder = Request.Builder()
            .url(apiUrl("progress", uid))
            .get()
            .header("Authorization", bearer())
        if (ifModifiedSince != null) requestBuilder.header(IF_MODIFIED_SINCE, ifModifiedSince)
        return requestBuilder.build()
    }

    fun buildSetProgress(uid: String, position: String, updatedAt: String? = null): Request =
        Request.Builder()
            .url(apiUrl("progress", uid))
            .put(encode(SetProgressRequest.serializer(), SetProgressRequest(position, updatedAt)))
            .header("Authorization", bearer())
            .build()

    fun buildCreateAnnotation(uid: String, location: String, text: String): Request =
        Request.Builder()
            .url(apiUrl("annotations"))
            .post(
                encode(
                    CreateAnnotationRequest.serializer(),
                    CreateAnnotationRequest(uid, location, text),
                ),
            )
            .header("Authorization", bearer())
            .build()

    fun buildListAnnotations(uid: String): Request =
        Request.Builder()
            .url(apiUrl("annotations").newBuilder().addQueryParameter("uid", uid).build())
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

    /** `GET /api/roots`：无参数。 */
    fun buildRoots(): Request = Request.Builder()
        .url(apiUrl("roots"))
        .get()
        .header("Authorization", bearer())
        .build()

    /**
     * `GET /api/resources`：可空过滤参数为 null 时不加入 URL（保持 URL 干净），
     * `include_deleted` 仅在 true 时加入，`limit` 恒加入（服务端再夹紧到 [1,2000]）。
     */
    fun buildResources(
        root: String? = null,
        prefix: String? = null,
        sinceMtime: Long? = null,
        includeDeleted: Boolean = false,
        limit: Int = 500,
    ): Request {
        val urlBuilder = apiUrl("resources").newBuilder()
        if (root != null) urlBuilder.addQueryParameter("root", root)
        if (prefix != null) urlBuilder.addQueryParameter("prefix", prefix)
        if (sinceMtime != null) urlBuilder.addQueryParameter("since", sinceMtime.toString())
        if (includeDeleted) urlBuilder.addQueryParameter("include_deleted", "true")
        urlBuilder.addQueryParameter("limit", limit.toString())
        return Request.Builder()
            .url(urlBuilder.build())
            .get()
            .header("Authorization", bearer())
            .build()
    }

    /** `GET /api/resolve`：`root` 与 `path` 必须同时提供。 */
    fun buildResolve(root: String, path: String): Request = Request.Builder()
        .url(
            apiUrl("resolve").newBuilder()
                .addQueryParameter("root", root)
                .addQueryParameter("path", path)
                .build(),
        )
        .get()
        .header("Authorization", bearer())
        .build()

    /** `GET /api/changes`：`since` 为游标（int64），`limit` 由服务端夹紧到 [1,2000]。 */
    fun buildChanges(since: Long, limit: Int = 2000): Request = Request.Builder()
        .url(
            apiUrl("changes").newBuilder()
                .addQueryParameter("since", since.toString())
                .addQueryParameter("limit", limit.toString())
                .build(),
        )
        .get()
        .header("Authorization", bearer())
        .build()

    /**
     * 文件端点的 URL：`/api/files/<path 逐段编码>?root=<tag>`。
     *
     * `path` 可含 `/`、中文与空格：按 `/` 切段后逐段 [HttpUrl.Builder.addPathSegment]，
     * 保证每段独立百分号编码（不得对整串一次性编码，否则 `/` 会被转成 `%2F`）。
     */
    private fun fileUrl(root: String, path: String): HttpUrl {
        val builder = config.apiBase.toHttpUrl().newBuilder()
        builder.addPathSegment("files")
        path.trim('/').split('/').filter { it.isNotEmpty() }.forEach { builder.addPathSegment(it) }
        builder.addQueryParameter("root", root)
        return builder.build()
    }

    /**
     * `GET /api/files/{path...}?root=`：原始字节下载。
     *
     * `rangeStart != null` → `Range: bytes=<start>-`（服务端返回 206/416）；
     * `ifNoneMatch` → `If-None-Match`（命中返回 304）。
     */
    fun buildGetFile(
        root: String,
        path: String,
        ifNoneMatch: String? = null,
        rangeStart: Long? = null,
    ): Request {
        val requestBuilder = Request.Builder()
            .url(fileUrl(root, path))
            .get()
            .header("Authorization", bearer())
        if (ifNoneMatch != null) requestBuilder.header("If-None-Match", ifNoneMatch)
        if (rangeStart != null) requestBuilder.header("Range", "bytes=$rangeStart-")
        return requestBuilder.build()
    }

    /** `PUT /api/files/{path...}?root=`：请求体为原始字节（`application/octet-stream`）。 */
    fun buildPutFile(
        root: String,
        path: String,
        bytes: ByteArray,
        ifMatch: String? = null,
        ifNoneMatch: String? = null,
    ): Request {
        val requestBuilder = Request.Builder()
            .url(fileUrl(root, path))
            .put(bytes.toRequestBody(OCTET_STREAM))
            .header("Authorization", bearer())
        if (ifMatch != null) requestBuilder.header("If-Match", ifMatch)
        if (ifNoneMatch != null) requestBuilder.header("If-None-Match", ifNoneMatch)
        return requestBuilder.build()
    }

    /** `DELETE /api/files/{path...}?root=`：服务端软删（路径未登记存活资源 → 404）。 */
    fun buildDeleteFile(root: String, path: String): Request = Request.Builder()
        .url(fileUrl(root, path))
        .delete()
        .header("Authorization", bearer())
        .build()

    /** `POST /api/resources/{uid}/move`：请求体 `{"to":"<根内路径>"}`。 */
    fun buildMoveResource(uid: String, to: String): Request = Request.Builder()
        .url(apiUrl("resources", uid, "move"))
        .post(encode(MoveRequest.serializer(), MoveRequest(to)))
        .header("Authorization", bearer())
        .build()

    // ---- 执行方法 ----

    /** 获取阅读进度；服务端返回 304 时返回 null。 */
    fun getProgress(uid: String, ifModifiedSince: String? = null): Progress? {
        client.newCall(buildGetProgress(uid, ifModifiedSince)).execute().use { resp ->
            if (resp.code == 304) return null
            ensureSuccess(resp)
            return json.decodeFromString(Progress.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 设置（覆盖）阅读进度，返回服务端实际保存的记录。 */
    fun setProgress(uid: String, position: String, updatedAt: String? = null): Progress {
        client.newCall(buildSetProgress(uid, position, updatedAt)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(Progress.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 创建批注，返回含服务端分配 id 的完整对象。 */
    fun createAnnotation(uid: String, location: String, text: String): Annotation {
        client.newCall(buildCreateAnnotation(uid, location, text)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(Annotation.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 列出某个 uid 的全部批注。 */
    fun listAnnotations(uid: String): List<Annotation> {
        client.newCall(buildListAnnotations(uid)).execute().use { resp ->
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

    /** 列出仓库根（解包服务端 `{"roots":[...]}` 外层）。 */
    fun roots(): List<RootDto> {
        client.newCall(buildRoots()).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(RootsResponse.serializer(), resp.body?.string().orEmpty()).roots
        }
    }

    /** 列资源（只读）。 */
    fun resources(
        root: String? = null,
        prefix: String? = null,
        sinceMtime: Long? = null,
        includeDeleted: Boolean = false,
        limit: Int = 500,
    ): ResourcesPageDto {
        client.newCall(buildResources(root, prefix, sinceMtime, includeDeleted, limit)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(ResourcesPageDto.serializer(), resp.body?.string().orEmpty())
        }
    }

    /**
     * `root` + `path` → uid。
     *
     * 404（uid 未登记）返回 `null`，作为「该路径尚无资源记录」的正常信号；
     * 其余非 2xx（如 400 invalid_argument）由 [ensureSuccess] 抛 [ApiException]。
     */
    fun resolve(root: String, path: String): String? {
        client.newCall(buildResolve(root, path)).execute().use { resp ->
            if (resp.code == 404) return null
            ensureSuccess(resp)
            return json.decodeFromString(ResolveResponse.serializer(), resp.body?.string().orEmpty()).uid
        }
    }

    /** 拉取变更日志（只读）。 */
    fun changes(since: Long, limit: Int = 2000): ChangesPageDto {
        client.newCall(buildChanges(since, limit)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(ChangesPageDto.serializer(), resp.body?.string().orEmpty())
        }
    }

    /**
     * 下载文件到 [target]：先写 `<target>.part`，**输出流关闭之后**再 rename 到目标名。
     *
     * 服务端 304 → 返回 null（不触碰本地文件）。任何失败路径（网络异常 / 非 2xx / 空响应体 /
     * rename 失败）都会删除 `.part`，避免残留半截文件。
     *
     * 本方法与同类执行方法均为**阻塞调用**，必须在后台 executor 中调用（与既有方法一致）。
     */
    fun downloadFile(root: String, path: String, target: File, ifNoneMatch: String? = null): File? {
        val part = File(target.parentFile, target.name + ".part")
        try {
            client.newCall(buildGetFile(root, path, ifNoneMatch)).execute().use { resp ->
                if (resp.code == 304) return null
                ensureSuccess(resp)
                val body = resp.body ?: throw ApiException(resp.code, null, "响应体为空")
                part.outputStream().use { out -> body.byteStream().copyTo(out) }
            }
            if (!part.renameTo(target)) throw IOException("重命名失败：$part -> $target")
            return target
        } catch (e: Exception) {
            part.delete()
            throw e
        }
    }

    /**
     * 上传文件（原始字节）。
     *
     * 超过 [MAX_UPLOAD_BYTES] 时**前置抛 [IllegalArgumentException]** 且不发请求
     * （服务端硬上限同为 32 MiB，超限只会得到 400，故提前拒绝）。
     */
    fun uploadFile(
        root: String,
        path: String,
        bytes: ByteArray,
        ifNoneMatch: String? = null,
    ): FileWriteResponse {
        if (bytes.size > MAX_UPLOAD_BYTES) {
            throw IllegalArgumentException("文件超过 32 MiB 上限：${bytes.size}")
        }
        client.newCall(buildPutFile(root, path, bytes, ifNoneMatch = ifNoneMatch)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(FileWriteResponse.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 删除文件（服务端软删；目录路径会收集子树）。 */
    fun deleteFile(root: String, path: String): FileDeleteResponse {
        client.newCall(buildDeleteFile(root, path)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(FileDeleteResponse.serializer(), resp.body?.string().orEmpty())
        }
    }

    /** 根内改名（仅 mirror 根可写；目标被占 → 409）。 */
    fun moveResource(uid: String, to: String): MoveResponse {
        client.newCall(buildMoveResource(uid, to)).execute().use { resp ->
            ensureSuccess(resp)
            return json.decodeFromString(MoveResponse.serializer(), resp.body?.string().orEmpty())
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
