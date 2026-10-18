package com.seshat.app.reader

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [CoverCache] 的元数据缓存（`<key>.json`）单测。
 *
 * 只测纯 JVM 部分（磁盘 JSON 读写 + 文件指纹校验）：封面位图解码/渲染依赖 Android Bitmap，
 * 无法在无 Robolectric 的 JVM 测试中运行，留真机验证。
 */
class CoverCacheMetaTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 封面缓存目录（模拟 `filesDir/covers`）。 */
    private fun cacheDir(): File = File(tmp.root, CoverCache.DIR_NAME)

    private fun book(name: String = "book.epub", content: String = "abc"): File =
        tmp.newFile(name).apply { writeText(content) }

    private fun meta(title: String = "三体") = BookMeta(
        title = title,
        author = "刘慈欣",
        totalCount = 12,
        progressKey = "0123456789abcdef0123456789abcdef", // gitleaks:allow 测试假数据（progressKey 的真实形态是 32 位内容哈希，非凭据）
        coverHref = "../Images/cover.jpg",
    )

    @Test
    fun `writeMeta 后 readMeta 返回等价元数据`() {
        val cache = CoverCache(cacheDir())
        val file = book()
        cache.writeMeta(file, meta())

        val restored = cache.readMeta(file)
        assertNotNull(restored)
        assertEquals(meta(), restored)
    }

    @Test
    fun `文件时间戳变化后 readMeta 返回 null`() {
        val cache = CoverCache(cacheDir())
        val file = book()
        cache.writeMeta(file, meta())

        file.setLastModified(file.lastModified() + 60_000L)
        assertNull(cache.readMeta(file))
    }

    @Test
    fun `文件长度变化后 readMeta 返回 null`() {
        val cache = CoverCache(cacheDir())
        val file = book()
        cache.writeMeta(file, meta())

        file.appendText("changed")
        assertNull(cache.readMeta(file))
    }

    @Test
    fun `无缓存文件时 readMeta 返回 null`() {
        val cache = CoverCache(cacheDir())
        assertNull(cache.readMeta(book()))
    }

    @Test
    fun `损坏 JSON 时 readMeta 返回 null 而不抛异常`() {
        val cache = CoverCache(cacheDir())
        val file = book()
        // 先正常写一次拿到正确的键与文件，再把内容改坏
        cache.writeMeta(file, meta())
        val json = File(cacheDir(), "${CoverKeys.keyFor(file)}.json")
        json.writeText("{ 这不是合法 JSON")

        assertNull(cache.readMeta(file))
    }
}
