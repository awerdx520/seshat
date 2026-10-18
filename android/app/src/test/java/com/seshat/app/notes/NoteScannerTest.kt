package com.seshat.app.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** [NoteScanner] 的纯 JVM 单测（TemporaryFolder，不依赖 Android 框架）。 */
class NoteScannerTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun write(name: String, content: String = ""): File {
        val file = tmp.newFile(name)
        file.writeText(content)
        return file
    }

    // ---------- scanLocal ----------

    @Test
    fun scanLocal_missingDirectoryReturnsEmpty() {
        val missing = File(tmp.root, "not-exists")

        assertTrue(NoteScanner.scanLocal(missing).isEmpty())
    }

    @Test
    fun scanLocal_onlyOrgAndMarkdownCollected() {
        write("a.org", "* A\n")
        write("b.md", "# B\n")
        write("c.txt", "text\n")
        write("d.png", "binary\n")

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(listOf("A", "B"), items.map { it.title }.sorted())
        assertEquals(
            listOf(NoteFormat.ORG, NoteFormat.MARKDOWN),
            items.sortedBy { it.title }.map { it.format },
        )
    }

    @Test
    fun scanLocal_ignoresSubdirectories() {
        write("top.org", "* Top\n")
        val sub = tmp.newFolder("sub")
        File(sub, "nested.org").writeText("* Nested\n")

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(listOf("Top"), items.map { it.title })
    }

    @Test
    fun scanLocal_fallsBackToFirstHeading() {
        write("plain.org", "#+TITLE: 文档标题\n\n* 我的标题\n** 子标题\n")

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(1, items.size)
        assertEquals("我的标题", items[0].title)
    }

    @Test
    fun scanLocal_markdownWithoutHeadingFallsBackToFileName() {
        write("no-heading.md", "只有正文，没有标题。\n")

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(1, items.size)
        assertEquals("no-heading", items[0].title)
    }

    @Test
    fun scanLocal_nonUtf8ContentFallsBackToFileName() {
        // 非 UTF-8 内容读取会抛异常，扫描须吞掉并回退到文件名（不中断整次扫描）
        val file = tmp.newFile("binary.md")
        file.writeBytes(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x00, 0x41))

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(1, items.size)
        assertEquals("binary", items[0].title)
    }

    @Test
    fun scanLocal_sortsByModifiedTimeDescending() {
        val older = write("older.org", "* Older\n")
        val newer = write("newer.org", "* Newer\n")
        older.setLastModified(1_600_000_000_000L)
        newer.setLastModified(1_700_000_000_000L)

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(listOf("Newer", "Older"), items.map { it.title })
        assertTrue(items[0].modifiedAt > items[1].modifiedAt)
    }

    @Test
    fun scanLocal_denoteNameWinsOverHeading() {
        write("20240101T120000--denote标题__tag1.org", "* 文件内标题\n")

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(1, items.size)
        assertEquals("denote标题", items[0].title)
        assertEquals(listOf("tag1"), items[0].tags)
    }

    @Test
    fun scanLocal_sourceDefaultsToPrivate() {
        write("a.org", "* A\n")

        val items = NoteScanner.scanLocal(tmp.root)

        assertEquals(NoteSourceKind.PRIVATE, items[0].source)
    }

    @Test
    fun scanLocal_externalSourcePropagated() {
        write("a.org", "* A\n")

        val items = NoteScanner.scanLocal(tmp.root, NoteSourceKind.EXTERNAL)

        assertEquals(NoteSourceKind.EXTERNAL, items[0].source)
    }

    // ---------- firstHeading ----------

    @Test
    fun firstHeading_orgWithTodoKeywordAndPriority() {
        assertEquals("任务", NoteScanner.firstHeading("* TODO [#A] 任务\n", NoteFormat.ORG))
    }

    @Test
    fun firstHeading_orgStripsTrailingTags() {
        assertEquals(
            "带标签的标题",
            NoteScanner.firstHeading("* 带标签的标题 :work:urgent:\n", NoteFormat.ORG),
        )
    }

    @Test
    fun firstHeading_orgSkipsKeywordLines() {
        val text = "#+TITLE: 文档标题\n#+FILETAGS: :notes:\n\n* 真正的标题\n"
        assertEquals("真正的标题", NoteScanner.firstHeading(text, NoteFormat.ORG))
    }

    @Test
    fun firstHeading_markdownHeading() {
        assertEquals("标题", NoteScanner.firstHeading("正文\n## 标题 ##\n", NoteFormat.MARKDOWN))
    }

    @Test
    fun firstHeading_noneReturnsNull() {
        assertNull(NoteScanner.firstHeading("普通段落\n", NoteFormat.MARKDOWN))
        assertNull(NoteScanner.firstHeading("#+TITLE: 只有关键字\n", NoteFormat.ORG))
    }
}
