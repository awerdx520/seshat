package com.seshat.app.sync

/**
 * 服务端连接配置。
 *
 * @property serverUrl 服务端根地址，如 `https://seshat.example.com`（结尾斜杠可有可无）。
 * @property token     访问令牌，即服务端 `SESHAT_AUTH_TOKEN`：
 *                     REST 用作 `Authorization: Bearer <token>`；WebDAV 用作 Basic 密码。
 * @property remoteDir WebDAV 根下笔记目录的相对路径，默认根目录 `/`。
 */
data class SeshatConfig(
    val serverUrl: String,
    val token: String,
    val remoteDir: String = "/",
) {
    /** 去掉结尾斜杠的服务端地址，便于拼接路径。 */
    val baseUrl: String
        get() = serverUrl.trimEnd('/')

    /** REST API 基地址（服务端挂载在 `/api`）。 */
    val apiBase: String
        get() = "$baseUrl/api"

    /** WebDAV 基地址（服务端挂载在 `/dav`）。 */
    val davBase: String
        get() = "$baseUrl/dav"

    /**
     * 拼接 WebDAV 绝对 URL：`path` 为相对笔记目录的路径（可带前导 `/`）。
     * 空路径 / 根路径返回 WebDAV 基地址本身。
     */
    fun davUrl(path: String): String {
        val p = path.trimStart('/')
        return if (p.isEmpty()) davBase else "$davBase/$p"
    }
}
