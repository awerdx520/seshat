package com.seshat.app.reader

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [PdfOutlineReader] 的单测（纯 JVM，无 Robolectric）。
 *
 * 测试策略说明：pdfbox-android 在 **运行期** 于纯 JVM 可用（已实测：`PDDocument.load` 正常，
 * 无 `NoClassDefFoundError` / `RuntimeException("Stub!")`），但 AGP 8.13 没有把该 AAR 的
 * classes 透传到 test 源集编译类路径，因此本测试**不 import 任何 pdfbox 类**，改为内嵌两份
 * 真实 PDF 字节（手写结构、xref 正确、`pdfinfo` 校验通过）走 [PdfOutlineReader.read]：
 *
 * - `PDF_WITH_OUTLINE`：2 页 + 3 层书签（`第一章` → `Section 1` → `Sub 1.1`）、一个
 *   指向第 2 页的 `Appendix`、一个只有 `/A` URI 动作（无 `/Dest`）的 `Web Link`；
 * - `PDF_WITHOUT_OUTLINE`：2 页、无 `/Outlines`。
 *
 * 守的不变量：书签树结构与页码（0-based）、无 outline / 损坏 / 不存在 / 超大文件一律空表不抛、
 * [PdfOutlineReader.flatten] 前序且父先于子、[PdfOutlineReader.pageDirectory] 1-based 文案 + 0-based 索引。
 */
class PdfOutlineReaderTest {

    @get:Rule
    val tmp = TemporaryFolder()

    // ------------------------------------------------------------------ read：真解析

    @Test
    fun readRealPdfBuildsOutlineTree() {
        // 守：真实 PDF 的 outline 被解析成树 —— 顶层 3 项、标题解码正确（含中文 UTF-16BE）、
        // 每一层页码按 0-based 取到正确页。若页码索引表建错，附录会错落到第 1 页（0）。
        val items = PdfOutlineReader.read(writePdf("outlined.pdf", PDF_WITH_OUTLINE))

        assertEquals(3, items.size)
        assertEquals("第一章", items[0].title)
        assertEquals(0, items[0].pageIndex)
        assertEquals(1, items[0].children.size)
        assertEquals("Section 1", items[0].children[0].title)
        assertEquals(1, items[0].children[0].pageIndex)
        assertEquals(1, items[0].children[0].children.size)
        assertEquals("Sub 1.1", items[0].children[0].children[0].title)
        assertEquals(0, items[0].children[0].children[0].pageIndex)
        assertEquals("Appendix", items[1].title)
        assertEquals(1, items[1].pageIndex)
        assertTrue(items[1].children.isEmpty())
    }

    @Test
    fun readBookmarkWithoutPageDestinationGetsUnknownPage() {
        // 守：只有 URI 动作（无 /Dest）的书签不能崩、也不能伪造页码 —— 必须是 UNKNOWN(-1)，
        // 调用方据此保持当前页，避免点目录跳到第 0 页。
        val items = PdfOutlineReader.read(writePdf("uri.pdf", PDF_WITH_OUTLINE))

        assertEquals("Web Link", items[2].title)
        assertEquals(PdfOutlineReader.UNKNOWN_PAGE_INDEX, items[2].pageIndex)
    }

    @Test
    fun readFlattenedOrderIsPreOrderWithDepth() {
        // 守：书签树拍平后是前序（父先于子）且 depth 逐层 +1，供目录对话框按缩进直接渲染。
        val flat = PdfOutlineReader.flatten(PdfOutlineReader.read(writePdf("order.pdf", PDF_WITH_OUTLINE)))

        assertEquals(
            listOf("第一章", "Section 1", "Sub 1.1", "Appendix", "Web Link"),
            flat.map { it.title },
        )
        assertEquals(listOf(0, 1, 2, 0, 0), flat.map { it.depth })
        assertEquals(listOf(0, 1, 0, 1, -1), flat.map { it.pageIndex })
    }

    @Test
    fun readRealPdfWithoutOutlineReturnsEmpty() {
        // 守：无 /Outlines 的 PDF 返回空表（调用方回退页码目录），而不是抛异常或返回 null 项。
        assertTrue(PdfOutlineReader.read(writePdf("plain.pdf", PDF_WITHOUT_OUTLINE)).isEmpty())
    }

    @Test
    fun readCorruptFileReturnsEmpty() {
        // 守：损坏文件（不是 PDF）必须被 IOException 收敛成空表 —— 目录对话框永远打得开。
        val broken = tmp.newFile("broken.pdf").apply { writeBytes("this is not a pdf".toByteArray()) }
        assertTrue(PdfOutlineReader.read(broken).isEmpty())
    }

    // ------------------------------------------------------- read：PdfBox 之前的早退路径

    @Test
    fun readMissingFileReturnsEmpty() {
        // 守：文件不存在时立即返回空表（早于任何 PdfBox 调用），不抛 FileNotFoundException。
        val missing = File(tmp.root, "no-such.pdf")
        assertTrue(!missing.exists())
        assertTrue(PdfOutlineReader.read(missing).isEmpty())
    }

    @Test
    fun readOversizedFileReturnsEmpty() {
        // 守：超过 MAX_OUTLINE_BYTES(50 MiB) 直接空表 —— 96 MB 级 PDF 不能因解析 outline 而 OOM。
        // 用稀疏文件造 60 MiB，不实际写入 60 MiB 数据。
        val big = tmp.newFile("huge.pdf")
        RandomAccessFile(big, "rw").use { it.setLength(PdfOutlineReader.MAX_OUTLINE_BYTES + 1) }

        assertEquals(PdfOutlineReader.MAX_OUTLINE_BYTES + 1, big.length())
        assertTrue(PdfOutlineReader.read(big).isEmpty())
    }

    // ------------------------------------------------------------------ flatten（纯函数）

    @Test
    fun flattenEmptyListReturnsEmpty() {
        // 守：空表进出空表（无 outline 时不产生幽灵目录项）。
        assertTrue(PdfOutlineReader.flatten(emptyList()).isEmpty())
    }

    @Test
    fun flattenPutsParentBeforeChildren() {
        // 守：手造树的前序顺序 —— 兄弟按原顺序，子项紧跟父项之后。
        val tree = listOf(
            PdfOutlineReader.PdfOutlineItem(
                "A", 0,
                listOf(
                    PdfOutlineReader.PdfOutlineItem("A-1", 1),
                    PdfOutlineReader.PdfOutlineItem("A-2", 2, listOf(PdfOutlineReader.PdfOutlineItem("A-2-a", 3))),
                ),
            ),
            PdfOutlineReader.PdfOutlineItem("B", 4),
        )

        val flat = PdfOutlineReader.flatten(tree)

        assertEquals(listOf("A", "A-1", "A-2", "A-2-a", "B"), flat.map { it.title })
        assertEquals(listOf(0, 1, 1, 2, 0), flat.map { it.depth })
        assertEquals(listOf(0, 1, 2, 3, 4), flat.map { it.pageIndex })
    }

    @Test
    fun flattenStartDepthOffsetsRoots() {
        // 守：depth 参数是根节点的起始层级（便于把一棵子树嵌进已有目录）。
        val tree = listOf(PdfOutlineReader.PdfOutlineItem("root", 0, listOf(PdfOutlineReader.PdfOutlineItem("child", 1))))

        assertEquals(listOf(3, 4), PdfOutlineReader.flatten(tree, depth = 3).map { it.depth })
    }

    // ------------------------------------------------------------- pageDirectory（纯函数）

    @Test
    fun pageDirectoryHasOneBasedLabelsAndZeroBasedIndexes() {
        // 守：文案 1-based（第 1 页…）、pageIndex 0-based，否则点「第 1 页」会跳到第 2 页。
        val dir = PdfOutlineReader.pageDirectory(3)

        assertEquals(3, dir.size)
        assertEquals(listOf("第 1 页", "第 2 页", "第 3 页"), dir.map { it.title })
        assertEquals(listOf(0, 1, 2), dir.map { it.pageIndex })
        assertEquals(listOf(0, 0, 0), dir.map { it.depth })
    }

    @Test
    fun pageDirectoryEmptyForNonPositiveCount() {
        // 守：pageCount 为 0 或负（PDF 解析异常时的兜底值）返回空表，而不是产生 0 项或负页码项。
        assertTrue(PdfOutlineReader.pageDirectory(0).isEmpty())
        assertTrue(PdfOutlineReader.pageDirectory(-3).isEmpty())
    }

    // --------------------------------------------------- read：InputStream（content:// 入口）

    @Test
    fun readStreamOverSizeHintReturnsEmptyWithoutParsing() {
        // 守：sizeHint 超限时在触达 PdfBox **之前**早退，且一个字节都不从流里读（防 96 MB 级 OOM）。
        // 用「读即抛异常」的假流：若实现真的读了流，异常会被收敛成空表，仅靠返回值无法区分，
        // 故额外用标志位断言流未被读取。
        var touched = false
        val explosive = object : InputStream() {
            override fun read(): Int {
                touched = true
                throw IOException("超大文件不应读取流")
            }
        }

        val items = PdfOutlineReader.read(explosive, PdfOutlineReader.MAX_OUTLINE_BYTES + 1)

        assertTrue(items.isEmpty())
        assertTrue("sizeHint 超限时不得读取流的任何字节", !touched)
    }

    @Test
    fun readStreamParsesSameAsFile() {
        // 守：InputStream 入口与 File 入口共用同一段转换逻辑 —— 同一份字节得到完全相同的书签树
        // （标题/页码/层级逐项相等），否则 content:// 与 file:// 打开的目录会不一致。
        val bytes = Base64.getDecoder().decode(PDF_WITH_OUTLINE)

        val fromFile = PdfOutlineReader.read(writePdf("stream-same.pdf", PDF_WITH_OUTLINE))
        val fromStream = ByteArrayInputStream(bytes).use {
            PdfOutlineReader.read(it, bytes.size.toLong())
        }

        assertEquals(3, fromStream.size)
        assertEquals(fromFile, fromStream)
    }

    // ---------------------------------------------------------------------- 辅助

    private fun writePdf(name: String, base64: String): File =
        tmp.newFile(name).apply { writeBytes(Base64.getDecoder().decode(base64)) }

    private companion object {
        /** 2 页 + 3 层书签 + URI 书签的真实 PDF（pdfinfo 校验：Pages=2）。 */
        const val PDF_WITH_OUTLINE =
            "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgL091dGxpbmVzIDUgMCBSIC9QYWdlTW9kZSAvVXNlT3V0bGluZXMgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUiA0IDAgUl0gL0NvdW50IDIgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMjAwXSA+PgplbmRvYmoKNCAwIG9iago8PCAvVHlwZSAvUGFnZSAvUGFyZW50IDIgMCBSIC9NZWRpYUJveCBbMCAwIDIwMCAyMDBdID4+CmVuZG9iago1IDAgb2JqCjw8IC9UeXBlIC9PdXRsaW5lcyAvRmlyc3QgNiAwIFIgL0xhc3QgMTAgMCBSIC9Db3VudCA1ID4+CmVuZG9iago2IDAgb2JqCjw8IC9UaXRsZSA8RkVGRjdCMkM0RTAwN0FFMD4gL1BhcmVudCA1IDAgUiAvRGVzdCBbMyAwIFIgL0ZpdF0gL0ZpcnN0IDcgMCBSIC9MYXN0IDcgMCBSIC9Db3VudCAyIC9OZXh0IDkgMCBSID4+CmVuZG9iago3IDAgb2JqCjw8IC9UaXRsZSAoU2VjdGlvbiAxKSAvUGFyZW50IDYgMCBSIC9EZXN0IFs0IDAgUiAvRml0XSAvRmlyc3QgOCAwIFIgL0xhc3QgOCAwIFIgL0NvdW50IDEgPj4KZW5kb2JqCjggMCBvYmoKPDwgL1RpdGxlIChTdWIgMS4xKSAvUGFyZW50IDcgMCBSIC9EZXN0IFszIDAgUiAvRml0XSA+PgplbmRvYmoKOSAwIG9iago8PCAvVGl0bGUgKEFwcGVuZGl4KSAvUGFyZW50IDUgMCBSIC9EZXN0IFs0IDAgUiAvRml0XSAvTmV4dCAxMCAwIFIgPj4KZW5kb2JqCjEwIDAgb2JqCjw8IC9UaXRsZSAoV2ViIExpbmspIC9QYXJlbnQgNSAwIFIgL0EgPDwgL1MgL1VSSSAvVVJJIChodHRwczovL2V4YW1wbGUuY29tKSA+PiA+PgplbmRvYmoKeHJlZgowIDExCjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwMTAzIDAwMDAwIG4gCjAwMDAwMDAxNjYgMDAwMDAgbiAKMDAwMDAwMDIzNyAwMDAwMCBuIAowMDAwMDAwMzA4IDAwMDAwIG4gCjAwMDAwMDAzODAgMDAwMDAgbiAKMDAwMDAwMDUwNiAwMDAwMCBuIAowMDAwMDAwNjEzIDAwMDAwIG4gCjAwMDAwMDA2ODQgMDAwMDAgbiAKMDAwMDAwMDc2OSAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDExIC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo4NjcKJSVFT0YK"

        /** 2 页、无 outline 的真实 PDF（pdfinfo 校验：Pages=2）。 */
        const val PDF_WITHOUT_OUTLINE =
            "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUiA0IDAgUl0gL0NvdW50IDIgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMjAwXSA+PgplbmRvYmoKNCAwIG9iago8PCAvVHlwZSAvUGFnZSAvUGFyZW50IDIgMCBSIC9NZWRpYUJveCBbMCAwIDIwMCAyMDBdID4+CmVuZG9iagp4cmVmCjAgNQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBuIAowMDAwMDAwMTI3IDAwMDAwIG4gCjAwMDAwMDAxOTggMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA1IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgoyNjkKJSVFT0YK"
    }
}
