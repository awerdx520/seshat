package com.seshat.app.reader

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [CoverKeys] 的纯逻辑单测：缓存键稳定性/区分度，以及 [CoverKeys.sampleSize] 的降采样取值。
 *
 * 本类不触碰任何 Android 类（无 Bitmap），可在 JVM 上直接跑。
 */
class CoverKeysTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 造一个书籍文件（内容任意，缓存键只看 名字 + 长度 + mtime）。 */
    private fun book(name: String = "book.epub", content: String = "abc"): File =
        tmp.newFile(name).apply { writeText(content) }

    @Test
    fun `keyFor 同一文件两次调用结果稳定`() {
        val file = book()
        assertEquals(CoverKeys.keyFor(file), CoverKeys.keyFor(file))
    }

    @Test
    fun `keyFor 输出 16 位十六进制`() {
        val key = CoverKeys.keyFor(book())
        assertEquals(16, key.length)
        assertTrue("应只含 [0-9a-f]，实际：$key", key.all { it in '0'..'9' || it in 'a'..'f' })
    }

    @Test
    fun `keyFor 不同文件名得到不同键`() {
        val a = book(name = "a.epub")
        val b = book(name = "b.epub", content = "abc")
        assertNotEquals(CoverKeys.keyFor(a), CoverKeys.keyFor(b))
    }

    @Test
    fun `keyFor 文件长度变化后键变化`() {
        val file = book()
        val before = CoverKeys.keyFor(file)
        // 追加内容 → length 变化（同时 mtime 也可能变，但长度已足以保证键变化）
        file.appendText("more-content")
        assertNotEquals(before, CoverKeys.keyFor(file))
    }

    @Test
    fun `keyFor 仅 mtime 变化键即变化`() {
        val file = book()
        val before = CoverKeys.keyFor(file)
        // 长度不变，仅把时间戳往后推（避免依赖文件系统时间精度）
        assertTrue(file.setLastModified(file.lastModified() + 60_000L))
        assertNotEquals(before, CoverKeys.keyFor(file))
    }

    @Test
    fun `sampleSize 标准等比降采样`() {
        // 1000 → 500：正好 2 倍
        assertEquals(2, CoverKeys.sampleSize(1000, 1000, 500, 500))
        // 1000 → 100：最多 8（1000/8=125 仍 >= 100，1000/16 < 100）
        assertEquals(8, CoverKeys.sampleSize(1000, 1000, 100, 100))
    }

    @Test
    fun `sampleSize 源图小于目标时返回 1`() {
        assertEquals(1, CoverKeys.sampleSize(100, 100, 1000, 1000))
    }

    @Test
    fun `sampleSize 非法请求尺寸返回 1`() {
        assertEquals(1, CoverKeys.sampleSize(1000, 1000, 0, 500))
        assertEquals(1, CoverKeys.sampleSize(1000, 1000, 500, -1))
        assertEquals(1, CoverKeys.sampleSize(0, 0, 100, 100))
    }

    @Test
    fun `sampleSize 非 2 的幂请求取最大合法幂`() {
        // 1000/2=500 >= 300，1000/4=250 < 300 → 2
        assertEquals(2, CoverKeys.sampleSize(1000, 1000, 300, 300))
    }

    @Test
    fun `sampleSize 两维取较小者限制`() {
        // 宽足够降采样，高不足 → 只能 1（两维都必须满足）
        assertEquals(1, CoverKeys.sampleSize(1000, 200, 100, 300))
        assertFalse(CoverKeys.sampleSize(1000, 200, 100, 300) > 1)
    }

    // ---- 封面首字占位（M10.8） ----

    @Test
    fun `initialOf 取书名首字符`() {
        assertEquals("三", CoverKeys.initialOf("三体"))
    }

    @Test
    fun `initialOf 跳过前导空白并转大写`() {
        assertEquals("A", CoverKeys.initialOf("  abc"))
        assertEquals("三", CoverKeys.initialOf("\n\t 三体"))
    }

    @Test
    fun `initialOf 空白书名返回问号`() {
        assertEquals("?", CoverKeys.initialOf("   "))
        assertEquals("?", CoverKeys.initialOf(""))
    }
}
