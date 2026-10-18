package com.seshat.app.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * [NoteReader] 的纯 JVM 单测（[TemporaryFolder]，不依赖 Android 框架）。
 *
 * SAF 分支只测「resolver 缺失」这条早退路径：`ContentResolver` 是 Android 框架类，
 * 无 Robolectric 时无法真正读流。
 */
class NoteReaderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun write(name: String, content: String): File {
        val file = tmp.newFile(name)
        file.writeText(content)
        return file
    }

    @Test
    fun readLocalFile_returnsContent() {
        val file = write("a.org", "* 标题\n正文内容\n")

        assertEquals("本地文件应返回原文", "* 标题\n正文内容\n", NoteReader.read(NoteRef.LocalFile(file)))
    }

    @Test
    fun readLocalFile_missingFileReturnsNull() {
        val missing = File(tmp.root, "not-exists.org")

        assertNull(NoteReader.read(NoteRef.LocalFile(missing)))
    }

    @Test
    fun readLocalFile_emptyFileReturnsEmptyString() {
        val file = write("empty.md", "")

        // 空文件是合法文本，必须返回空串而不是 null（null 只表示读取失败）
        assertEquals("空文件应返回空串", "", NoteReader.read(NoteRef.LocalFile(file)))
    }

    @Test
    fun readSafDocument_withoutResolverReturnsNull() {
        assertNull(NoteReader.read(newSafDocument(), resolver = null))
    }

    @Test
    fun readLocalFile_nonUtf8KeepsReplacementCharsInsteadOfFailing() {
        val file = tmp.newFile("binary.md")
        file.writeBytes(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x00, 0x41))

        // 实测（Kotlin 2.0.21 + JDK 17）：File.readText 对非法 UTF-8 字节做替换（U+FFFD）
        // 而非抛异常，所以这里返回替换后的文本而不是 null —— 只有 IO 失败（文件不存在、
        // 无权限等）才返回 null。SAF 分支的 decodeToString 行为一致（同为替换）。
        val text = NoteReader.read(NoteRef.LocalFile(file))

        assertNotNull("非法 UTF-8 不应导致读取失败", text)
        assertTrue("非法字节应被替换为 U+FFFD", text!!.contains('\uFFFD'))
    }

    /**
     * 构造一个 [NoteRef.SafDocument]，但不解引用其 `uri`。
     *
     * 单元测试运行在 JVM 上，`android.net.Uri` 只有桩实现（`Uri.parse` 等一律抛
     * `RuntimeException: Stub!`，`Uri.EMPTY` 为 null），无法正常构造 Uri 对象；
     * 本用例只覆盖 [NoteReader.read] 中「resolver == null 直接返回 null」的分支，
     * 该分支不会触碰 `uri`，故用无构造器实例化拿到对象即可。若实现改成在判空
     * 之前解引用 `uri`，本用例会以 NPE 失败，仍是有效信号。
     */
    private fun newSafDocument(): NoteRef.SafDocument {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val unsafe = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        val allocate = unsafeClass.getMethod("allocateInstance", Class::class.java)
        return allocate.invoke(unsafe, NoteRef.SafDocument::class.java) as NoteRef.SafDocument
    }
}
