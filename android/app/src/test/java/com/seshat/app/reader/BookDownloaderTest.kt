package com.seshat.app.reader

import java.io.File
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [BookDownloader] 单测：本地命中跳过、长度不匹配重下、服务端未配置、下载失败、
 * 304 且本地不存在、书库目录自动创建。
 *
 * 下载能力用 [FakeApi] 注入，不触碰网络（[RestFileDownloadApi] 仅做生产包装）。
 */
class BookDownloaderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 记录调用次数与落点的 fake；[behavior] 决定每次调用对 [File] 做什么。 */
    private class FakeApi(private val behavior: (File) -> File?) : FileDownloadApi {
        var calls = 0
        var lastTarget: File? = null
        override fun download(root: String, path: String, target: File): File? {
            calls++
            lastTarget = target
            return behavior(target)
        }
    }

    /** 写一个指定长度的文件（内容无意义，仅用于长度判定）。 */
    private fun writeSize(file: File, size: Long): File {
        file.writeBytes(ByteArray(size.toInt()))
        return file
    }

    private fun book(
        name: String = "a.epub",
        size: Long = 100,
        path: String = name,
    ) = RemoteBook(uid = "uid-$path", root = "main", path = path, name = name, size = size, mtime = 2_000)

    private fun downloader(apiFactory: () -> FileDownloadApi?) =
        BookDownloader(booksDir = tmp.root, apiFactory = apiFactory)

    @Test
    fun existingFileWithMatchingLengthSkipsDownload() {
        val local = writeSize(File(tmp.root, "a.epub"), 100)
        val api = FakeApi { writeSize(it, 100) }

        val result = downloader { api }.ensureLocal(book())

        assertEquals(DownloadResult.Ready(local), result)
        assertEquals("本地命中时不应调用下载", 0, api.calls)
    }

    @Test
    fun lengthMismatchDownloadsAgain() {
        writeSize(File(tmp.root, "a.epub"), 50)
        val api = FakeApi { writeSize(it, 100) }

        val result = downloader { api }.ensureLocal(book(size = 100))

        assertEquals(1, api.calls)
        assertEquals(DownloadResult.Ready(File(tmp.root, "a.epub")), result)
        assertEquals(100, File(tmp.root, "a.epub").length())
    }

    @Test
    fun missingServiceReturnsNotConfigured() {
        val result = downloader { null }.ensureLocal(book())

        assertEquals(DownloadResult.NotConfigured, result)
        assertFalse("未配置时不应留下任何文件", File(tmp.root, "a.epub").exists())
    }

    @Test
    fun downloadFailureReturnsFailedWithMessage() {
        val api = FakeApi { throw IOException("boom") }

        val result = downloader { api }.ensureLocal(book())

        assertTrue(result is DownloadResult.Failed)
        assertTrue("失败信息应含原因", (result as DownloadResult.Failed).message.contains("boom"))
    }

    @Test
    fun notModifiedWithoutLocalFileReturnsFailed() {
        // 304（api 返回 null）但本地文件不存在 → 无法阅读，报失败
        val api = FakeApi { null }

        val result = downloader { api }.ensureLocal(book())

        assertTrue(result is DownloadResult.Failed)
        assertFalse(File(tmp.root, "a.epub").exists())
    }

    @Test
    fun notModifiedWithLocalFileReturnsReady() {
        // 长度不匹配 → 走下载；服务端回 304（null）但本地已有同名文件 → 用本地
        val local = writeSize(File(tmp.root, "a.epub"), 50)
        val api = FakeApi { null }

        val result = downloader { api }.ensureLocal(book(size = 100))

        assertEquals(1, api.calls)
        assertEquals(DownloadResult.Ready(local), result)
    }

    @Test
    fun unknownSizeTreatsExistingFileAsReady() {
        // size <= 0（元数据未回填）→ 只判存在，不下载
        val local = writeSize(File(tmp.root, "a.epub"), 100)
        val api = FakeApi { writeSize(it, 100) }

        val result = downloader { api }.ensureLocal(book(size = 0))

        assertEquals(DownloadResult.Ready(local), result)
        assertEquals(0, api.calls)
    }

    @Test
    fun createsBooksDirWhenMissing() {
        val missing = File(tmp.root, "books")
        assertFalse("前置条件：目录不存在", missing.exists())
        val api = FakeApi { writeSize(it, 100) }

        val result = BookDownloader(booksDir = missing, apiFactory = { api }).ensureLocal(book())

        assertTrue(missing.isDirectory)
        assertEquals(DownloadResult.Ready(File(missing, "a.epub")), result)
    }

    @Test
    fun usesFileReturnedByApi() {
        // api 返回的文件与 target 不同时，以返回值为准（例如实现内部换了落点）
        val other = writeSize(File(tmp.root, "a.epub.alt"), 100)
        val api = FakeApi { other }

        val result = downloader { api }.ensureLocal(book(name = "b.epub", path = "b.epub"))

        assertEquals(DownloadResult.Ready(other), result)
        assertEquals("按约定落点仍为 booksDir/<name>", File(tmp.root, "b.epub"), api.lastTarget)
    }
}
