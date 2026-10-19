package com.seshat.app.reader

import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream

/**
 * 限长输入流：累计读取超过 [maxBytes] 时抛 [IOException]。
 *
 * **为什么不信任调用方给的 sizeHint**：`ContentResolver.openAssetFileDescriptor(uri).length`
 * 是外部 DocumentsProvider **自报**的值，恶意/粗糙的实现可以谎报 0 或 -1，从而绕过上层的
 * 大小预检，让 PDF 解析把任意大的流读进内存（OOM）。这里把上限变成**流本身的约束**：
 * 无论对方怎么报，读超了就直接断。
 *
 * 抛 [IOException] 而不是自定义异常：与 `openInputStream` 的失败路径同类，调用方既有的
 * `catch (IOException)` / `runCatching` 降级逻辑无需改动（回退页码目录、提示无文字）。
 */
internal class BoundedInputStream(
    input: InputStream,
    private val maxBytes: Long,
) : FilterInputStream(input) {

    private var total: Long = 0L

    override fun read(): Int {
        val value = super.read()
        if (value >= 0) count(1L)
        return value
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val read = super.read(b, off, len)
        if (read > 0) count(read.toLong())
        return read
    }

    override fun skip(n: Long): Long {
        val skipped = super.skip(n)
        if (skipped > 0) count(skipped)
        return skipped
    }

    private fun count(delta: Long) {
        total += delta
        if (total > maxBytes) {
            throw IOException("输入流超过解析上限（$maxBytes 字节）")
        }
    }
}
