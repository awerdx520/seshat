package com.seshat.app.reader

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BoundedInputStream] 的单测（纯 JVM）。
 *
 * 守的不变量：限长是**流本身的约束**，而不是调用方自报 sizeHint 的推断——恶意 DocumentsProvider
 * 谎报 `length` 为 0/-1 时，读超上限仍必须被硬性掐断（抛 [IOException]，与打开流失败同类，
 * 调用方既有降级逻辑无需改动）。
 */
class BoundedInputStreamTest {

    @Test
    fun passesThroughUnderLimit() {
        // 守：未超限时字节原样透传（限长不能改变正常读取结果）
        val payload = "0123456789".toByteArray()

        val content = BoundedInputStream(ByteArrayInputStream(payload), 100L).use { it.readBytes() }

        assertEquals(10, content.size)
        assertTrue(payload.contentEquals(content))
    }

    @Test
    fun throwsWhenExceedingLimit() {
        // 守：上限 10 的流读到第 200 字节时必须抛 IOException（谎报大小的 provider 走这条路径）
        val stream = BoundedInputStream(ByteArrayInputStream(ByteArray(200)), 10L)

        assertThrows(IOException::class.java) {
            val buffer = ByteArray(200)
            stream.read(buffer, 0, buffer.size)
        }
    }

    @Test
    fun bulkReadCountsBytes() {
        // 守：read(ByteArray, off, len) 大块读也要计量 —— 只覆盖 read() 单字节版本会漏掉真实路径
        val stream = BoundedInputStream(ByteArrayInputStream(ByteArray(64)), 32L)
        val buffer = ByteArray(16)

        // 前两次共 32 字节正好等于上限：仍合法
        assertEquals(16, stream.read(buffer, 0, 16))
        assertEquals(16, stream.read(buffer, 0, 16))
        // 第 33 字节起越界
        assertThrows(IOException::class.java) { stream.read(buffer, 0, 16) }
    }

    @Test
    fun skipCountsBytes() {
        // 守：skip 同样计入预算（PdfBox 解析会跳过字节，不能成为绕过上限的旁路）
        val stream = BoundedInputStream(ByteArrayInputStream(ByteArray(100)), 10L)

        assertThrows(IOException::class.java) { stream.skip(100L) }
    }

    @Test
    fun zeroLimitThrowsOnFirstByte() {
        // 守：上限 0 时第一个字节即抛（空文档可以读，任何内容都不行）
        val stream = BoundedInputStream(ByteArrayInputStream(byteArrayOf(42)), 0L)

        assertThrows(IOException::class.java) { stream.read() }
    }

    @Test
    fun closeDelegatesToWrapped() {
        // 守：close() 必须关闭底层流（所有权语义与 FilterInputStream 一致，避免 fd 泄漏）
        var closed = false
        val source = object : InputStream() {
            override fun read(): Int = -1

            override fun close() {
                closed = true
            }
        }

        BoundedInputStream(source, 10L).close()

        assertTrue("close() 应转发给被包装的流", closed)
    }
}
