package com.seshat.app.reader

import java.io.File

/** 下载所需的最小能力（便于 fake）。 */
fun interface FileDownloadApi {
    /** 下载到 [target]；失败抛异常；304 可返回 null。 */
    fun download(root: String, path: String, target: File): File?
}

/** 生产适配：包 RestClient。 */
class RestFileDownloadApi(private val client: com.seshat.app.sync.RestClient) : FileDownloadApi {
    override fun download(root: String, path: String, target: File): File? =
        client.downloadFile(root, path, target)
}

sealed interface DownloadResult {
    data class Ready(val file: File) : DownloadResult

    /** 服务端未配置。 */
    data object NotConfigured : DownloadResult

    data class Failed(val message: String) : DownloadResult
}

/**
 * 按需下载：把远端书籍落到本地 [booksDir]。
 *
 * 判定顺序：
 * 1. 本地已有同名且长度匹配的文件（见 [RemoteBookSource.localFileOf]）→ 直接 [DownloadResult.Ready]，**不联网**
 * 2. [apiFactory] 返回 `null`（服务端未配置）→ [DownloadResult.NotConfigured]，零网络、零文件改动
 * 3. 否则下载到 `booksDir/<book.name>`
 *
 * 临时文件 `.part` 由 [com.seshat.app.sync.RestClient.downloadFile] 内部管理（close 后 rename、
 * 任何异常路径删除），本类**不重复处理**；因此「本类不接受 `.part` 参与扫描的假设」——
 * 下载产物只有 `<name>`，`.part` 仅在同一时刻的下载过程中短暂存在。
 *
 * 本类不抛异常：所有失败都折成 [DownloadResult.Failed]，调用方按 UI 提示处理。
 * 内部为阻塞调用，调用方负责放到后台线程（单线程 executor）。
 *
 * @param booksDir    本地书库目录（扁平存储，本地文件名 = 远端 `path` 的 basename）
 * @param apiFactory  每次调用时解析下载能力；返回 `null` 表示服务端未配置
 */
class BookDownloader(
    private val booksDir: File,
    private val apiFactory: () -> FileDownloadApi?,
) {

    /** 确保 [book] 已落盘；本地命中时不下载。阻塞调用（调用方负责后台线程）。 */
    fun ensureLocal(book: RemoteBook): DownloadResult {
        if (!booksDir.exists() && !booksDir.mkdirs()) {
            return DownloadResult.Failed("无法创建书库目录")
        }
        RemoteBookSource.localFileOf(booksDir, book)?.let { return DownloadResult.Ready(it) }
        val api = apiFactory() ?: return DownloadResult.NotConfigured
        val target = File(booksDir, book.name)
        return runCatching { api.download(book.root, book.path, target) }.fold(
            onSuccess = { downloaded ->
                when {
                    downloaded != null -> DownloadResult.Ready(downloaded)
                    // 304（Not Modified）但本地没有可用文件：无从阅读
                    target.isFile -> DownloadResult.Ready(target)
                    else -> DownloadResult.Failed("服务端返回 304 但本地文件不存在")
                }
            },
            onFailure = { e -> DownloadResult.Failed(e.message ?: e.javaClass.simpleName) },
        )
    }
}
