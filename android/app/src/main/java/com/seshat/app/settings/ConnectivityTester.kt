package com.seshat.app.settings

import com.seshat.app.sync.SeshatConfig
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/** 连通性测试结果。 */
sealed interface ConnectivityResult {
    /** 服务端可达且令牌有效。 */
    data object Ok : ConnectivityResult

    /** 令牌无效或权限不足（401/403）。 */
    data object Unauthorized : ConnectivityResult

    /** 服务端返回了其它非 2xx 状态。 */
    data class ServerError(val code: Int) : ConnectivityResult

    /** 网络不可达或超时。 */
    data class Unreachable(val message: String) : ConnectivityResult
}

/**
 * 服务端连通性探测。
 *
 * 用 `GET /api/annotations?document_id=__connectivity_probe__` 探测：该端点对不存在的文档
 * 返回 200 + 空列表、不写任何数据，因此可安全地作为「地址 + 令牌」的探针。
 *
 * 构造函数接受 [OkHttpClient] 以便在 JVM 单测中注入 MockWebServer。
 */
class ConnectivityTester(
    private val config: SeshatConfig,
    private val client: OkHttpClient = defaultClient(),
    /** 是否强制要求 https；仅单元测试（MockWebServer 为明文 http）允许传 false。 */
    private val requireHttps: Boolean = true,
) {

    /** 执行一次探测。 */
    fun test(): ConnectivityResult {
        val url = "${config.apiBase}/annotations"
            .toHttpUrlOrNull()
            ?.newBuilder()
            ?.addQueryParameter("document_id", PROBE_DOCUMENT_ID)
            ?.build()
            ?: return ConnectivityResult.Unreachable("地址无法解析")

        // 明文 http 会把 Bearer 令牌暴露在网络中：与本项目「传输层由反代终止 TLS」的
        // 威胁模型一致地在这里再拦一次（调用方虽已用 SettingsValidator 校验，但不依赖它）。
        if (requireHttps && !url.isHttps) {
            return ConnectivityResult.Unreachable("仅支持 https 地址")
        }

        return try {
            val request = Request.Builder()
                .url(url)
                .header("Authorization", "Bearer ${config.token}")
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                when {
                    response.isSuccessful -> ConnectivityResult.Ok
                    response.code == 401 || response.code == 403 -> ConnectivityResult.Unauthorized
                    else -> ConnectivityResult.ServerError(response.code)
                }
            }
        } catch (e: IllegalArgumentException) {
            // 令牌含非法字符（换行/NUL/非 ASCII）时 OkHttp 会在此抛出，不能让它逃出后台线程
            ConnectivityResult.Unreachable("令牌包含非法字符")
        } catch (e: IOException) {
            ConnectivityResult.Unreachable(e.message ?: e.javaClass.simpleName)
        }
    }

    companion object {
        /** 探测用文档标识（不会写入服务端）。 */
        const val PROBE_DOCUMENT_ID = "__connectivity_probe__"

        /** 默认客户端：连接/读取超时各 10s。 */
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }
}
