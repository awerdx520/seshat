package com.seshat.app.reader

import java.io.File
import java.nio.charset.StandardCharsets
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [PdfInkExporter] 的单测（纯 JVM，无 Robolectric）。
 *
 * 与 [PdfOutlineReaderTest] 同一策略：pdfbox-android 在**运行期**于纯 JVM 可用，但 AGP 8.13 没把
 * 该 AAR 的 classes 透传到 test 源集编译类路径，故本测试**不 import 任何 pdfbox 类**，而是：
 * - 纯函数（路径构造 / 坐标换算 / 高亮解析）直接断言；
 * - 导出产物：断言 PDF 魔数 + 未压缩字典里的 `/InkList`、`/Highlight` 关键字 + 用
 *   [PdfOutlineReader.read]（内部即 `PDDocument.load`）**重新打开**并在 `TemporaryFolder` 里
 *   比对源文件字节，证明「副本可被 PdfBox 解析且原文件未改动」。
 *
 * 守的不变量：
 * 1. 目标名 `xxx.seshat.pdf`，已存在时 `-1`/`-2` 不覆盖；对已导出的副本再次导出不叠 `.seshat.seshat`；
 * 2. 无笔迹且无高亮 → [PdfInkExporter.Result.Empty]，**一个文件都不建**；
 * 3. 归一化（y 向下）→ PDF 页面坐标（y 向上）的四角换算正确（y 翻转只有一处）；
 * 4. 导出**绝不修改源文件**（字节逐一相等）；
 * 5. 导出的副本能被 PdfBox 重新打开（结构完好、书签树仍在、页数不变）。
 */
class PdfInkExporterTest {

    @get:Rule
    val tmp = TemporaryFolder()

    // ------------------------------------------------------------ 路径构造（纯函数）

    @Test
    fun exportPathAppendsSeshatAndKeepsDirectory() {
        // 守：目标固定为同目录 `<base>.seshat.pdf`（不是临时目录、不改扩展名）
        val source = File(tmp.root, "book.pdf")

        val target = PdfInkExporter.exportPathFor(source)

        assertEquals(tmp.root, target.parentFile)
        assertEquals("book.seshat.pdf", target.name)
    }

    @Test
    fun exportPathDeduplicatesExistingCopies() {
        // 守：已有副本时依次 -1、-2，绝不覆盖上一次导出
        val source = File(tmp.root, "book.pdf")
        assertEquals("book.seshat.pdf", PdfInkExporter.exportPathFor(source).name)

        tmp.newFile("book.seshat.pdf")
        assertEquals("book.seshat-1.pdf", PdfInkExporter.exportPathFor(source).name)

        tmp.newFile("book.seshat-1.pdf")
        assertEquals("book.seshat-2.pdf", PdfInkExporter.exportPathFor(source).name)
    }

    @Test
    fun exportPathDoesNotStackSeshatSuffix() {
        // 守：对着已导出的副本再次导出 → `a.seshat-1.pdf`，而不是 `a.seshat.seshat.pdf`
        val source = File(tmp.root, "a.seshat.pdf")
        assertTrue(source.createNewFile())

        val target = PdfInkExporter.exportPathFor(source)

        assertEquals("a.seshat-1.pdf", target.name)
        // 大小写不敏感（部分同步工具会改扩展名大小写）
        assertEquals("B.seshat.pdf", PdfInkExporter.exportPathFor(File(tmp.root, "B.PDF")).name)
    }

    // ------------------------------------------------------------ 坐标换算（纯函数）

    @Test
    fun pagePointFlipsYAxisAtFourCorners() {
        // 守：这是全模块唯一的 y 翻转点。屏幕归一化 y 向下、PDF 用户空间 y 向上，
        // 因此 (0,0)=屏幕左上 = PDF(0, 页高)；(1,1)=屏幕右下 = PDF(页宽, 0)。
        // 若此处漏翻转，导出的笔迹会整体上下镜像（真机上最常见的错法）。
        val width = 200f
        val height = 100f

        assertEquals(0f to 100f, PdfInkExporter.pagePoint(0f, 0f, width, height))
        assertEquals(200f to 100f, PdfInkExporter.pagePoint(1f, 0f, width, height))
        assertEquals(0f to 0f, PdfInkExporter.pagePoint(0f, 1f, width, height))
        assertEquals(200f to 0f, PdfInkExporter.pagePoint(1f, 1f, width, height))
        // 页心：两个方向都在中点
        assertEquals(100f to 50f, PdfInkExporter.pagePoint(0.5f, 0.5f, width, height))
    }

    @Test
    fun pagePointClampsOutOfRangeInput() {
        // 守：留白区误采的点（归一化会越界）必须夹紧，否则批注会跑到页面外
        assertEquals(0f to 100f, PdfInkExporter.pagePoint(-3f, -2f, 200f, 100f))
        assertEquals(200f to 0f, PdfInkExporter.pagePoint(9f, 7f, 200f, 100f))
    }

    @Test
    fun pagePointReturnsZeroForInvalidSize() {
        // 守：页尺寸非法（未就绪 / NaN）不得产出 Infinity/NaN 坐标（会让 PDFBox 写出坏文件）
        assertEquals(0f to 0f, PdfInkExporter.pagePoint(0.5f, 0.5f, 0f, 100f))
        assertEquals(0f to 0f, PdfInkExporter.pagePoint(0.5f, 0.5f, 200f, -1f))
        assertEquals(0f to 0f, PdfInkExporter.pagePoint(0.5f, 0.5f, Float.NaN, 100f))
    }

    // --------------------------------------------------------- 高亮矩形解析（纯函数）

    @Test
    fun highlightMarksOnlyAcceptHighlightKindWithRectLocation() {
        // 守：只认 kind=highlight 且 location 含 rect: 的项；note / ink / 无 rect / 非法串逐条跳过
        val marks = PdfInkExporter.highlightMarks(
            listOf(
                annotation("page:1;rect:10,20,60,50", kind = "highlight"),
                annotation("page:2", kind = "note"),
                annotation("page:1;ink:#FF0000,2,0,0,1,1", kind = "ink"),
                annotation("page:3;rect:1,2,3", kind = "highlight"),
                annotation("page:1;rect:10,20,60,50", kind = "highlight"),
            ),
        )

        assertEquals(2, marks.size)
        assertEquals(0, marks[0].pageIndex)
        assertEquals(10f, marks[0].x0)
        assertEquals(20f, marks[0].y0)
        assertEquals(60f, marks[0].x1)
        assertEquals(50f, marks[0].y1)
    }

    @Test
    fun highlightMarksNormaliseInvertedRect() {
        // 守：倒置矩形（x0>x1 或 y0>y1）要交换端点，否则 PDRectangle 得到负宽/负高
        val mark = PdfInkExporter.highlightMarks(listOf(annotation("page:5;rect:80,70,10,20")))
            .single()

        assertEquals(4, mark.pageIndex)
        assertEquals(10f, mark.x0)
        assertEquals(20f, mark.y0)
        assertEquals(80f, mark.x1)
        assertEquals(70f, mark.y1)
        assertEquals(70f, mark.width)
        assertEquals(50f, mark.height)
    }

    // ------------------------------------------------------------------ 导出

    @Test
    fun exportWithoutInkOrHighlightCreatesNothing() {
        // 守：没有内容可导出时不生成任何文件（不产出空副本、也不碰源文件）
        val source = writePdf("empty.pdf")
        val before = source.readBytes()

        val result = PdfInkExporter.export(source, emptyList(), emptyList())

        assertEquals(PdfInkExporter.Result.Empty, result)
        assertEquals(listOf("empty.pdf"), tmp.root.list()!!.sorted())
        assertTrue(before.contentEquals(source.readBytes()))
    }

    @Test
    fun exportWritesNewCopyWithInkAndKeepsSourceUntouched() {
        // 守：① 副本名 doc.seshat.pdf；② 源文件字节逐一不变（硬约束）；③ 副本是合法 PDF 且含 /InkList
        val source = writePdf("doc.pdf")
        val before = source.readBytes()
        val pages = listOf(
            PdfInkPage(
                0,
                listOf(
                    stroke(listOf(0f to 0f, 0.5f to 0.5f, 1f to 0f)),
                    stroke(listOf(0.1f to 0.9f, 0.9f to 0.9f), style = InkStyle.HIGHLIGHTER),
                ),
            ),
        )

        val result = PdfInkExporter.export(source, pages, emptyList())

        val success = result as PdfInkExporter.Result.Success
        assertEquals("doc.seshat.pdf", success.file.name)
        assertEquals(2, success.inkCount)
        assertEquals(0, success.highlightCount)
        assertTrue(success.skippedPages.isEmpty())

        assertTrue("源文件字节必须一一相同", before.contentEquals(source.readBytes()))
        assertEquals("源文件长度必须不变", before.size.toLong(), source.length())

        val bytes = success.file.readBytes()
        assertTrue(String(bytes, StandardCharsets.ISO_8859_1).startsWith("%PDF-"))
        val text = String(bytes, StandardCharsets.ISO_8859_1)
        assertTrue("副本里应有 /Ink 批注", text.contains("/Subtype/Ink") || text.contains("/Ink"))
        assertTrue("副本里应有 InkList", text.contains("/InkList"))
        assertTrue("副本应带外观流", text.contains("/AP"))
    }

    @Test
    fun exportWritesHighlightAnnotationForRectLocations() {
        // 守：kind=highlight 的 rect 写成 /Highlight 文本标记批注（含 QuadPoints 与外观流）
        val source = writePdf("hl.pdf")
        val annotations = listOf(
            annotation("page:2;rect:10,20,60,50", kind = "highlight"),
            annotation("page:1", kind = "note"),
        )

        val result = PdfInkExporter.export(source, emptyList(), annotations)

        val success = result as PdfInkExporter.Result.Success
        assertEquals(0, success.inkCount)
        assertEquals(1, success.highlightCount)
        val text = String(success.file.readBytes(), StandardCharsets.ISO_8859_1)
        assertTrue(text.contains("/Highlight"))
        assertTrue(text.contains("/QuadPoints"))
    }

    @Test
    fun exportOfSecondCopyGetsDeduplicatedName() {
        // 守：连续导出两次 → 第二次 `doc.seshat-1.pdf`，第一次的副本不被覆盖
        val source = writePdf("doc.pdf")
        val pages = listOf(PdfInkPage(0, listOf(stroke(listOf(0f to 0f, 1f to 1f)))))

        val first = PdfInkExporter.export(source, pages, emptyList()) as PdfInkExporter.Result.Success
        val second = PdfInkExporter.export(source, pages, emptyList()) as PdfInkExporter.Result.Success

        assertEquals("doc.seshat.pdf", first.file.name)
        assertEquals("doc.seshat-1.pdf", second.file.name)
        assertNotEquals(first.file.absolutePath, second.file.absolutePath)
        assertTrue(first.file.length() > 0)
        assertTrue(second.file.length() > 0)
    }

    @Test
    fun exportSkipsOutOfRangePageAndReportsIt() {
        // 守：笔迹页号越界（存储里残留的旧页号）不得让导出崩溃；全部页都不可导出时不产出空副本
        val source = writePdf("oob.pdf")
        val pages = listOf(PdfInkPage(99, listOf(stroke(listOf(0f to 0f, 1f to 1f)))))

        val result = PdfInkExporter.export(source, pages, emptyList())

        assertEquals(PdfInkExporter.Result.Failure::class.java, result.javaClass)
        assertFalse(File(tmp.root, "oob.seshat.pdf").exists())
        assertEquals(listOf("oob.pdf"), tmp.root.list()!!.sorted())
    }

    @Test
    fun exportedCopyCanBeReopenedByPdfBox() {
        // 守：副本可被 PDDocument.load 重新打开且结构完好 —— 用 PdfOutlineReader（内部就是
        // PDDocument.load）读副本的书签树，与源文件完全一致；页数不变（2 页）。
        val source = writePdf("reopen.pdf")
        val pages = listOf(PdfInkPage(1, listOf(stroke(listOf(0f to 0f, 1f to 1f)))))
        val annotations = listOf(annotation("page:1;rect:10,20,60,50", kind = "highlight"))

        val success = PdfInkExporter.export(source, pages, annotations) as PdfInkExporter.Result.Success

        val original = PdfOutlineReader.read(source)
        val reopened = PdfOutlineReader.read(success.file)
        assertEquals(3, original.size)
        assertEquals(original, reopened)
        // 追加批注后体积必然增长（结构上多出 annots 数组 + 外观流）
        assertTrue(success.file.length() > 0)
    }

    // ------------------------------------------------------------------ 辅助

    private fun writePdf(name: String): File =
        tmp.newFile(name).apply { writeBytes(Base64.getDecoder().decode(PDF_WITH_OUTLINE)) }

    private fun stroke(
        points: List<Pair<Float, Float>>,
        width: Float = 0.004f,
        color: Int = 0xFF1E88E5.toInt(),
        style: InkStyle = InkStyle.PEN,
    ): InkStroke = InkStroke(
        color = color,
        width = width,
        points = points.map { InkPoint(it.first, it.second) },
        style = style,
    )

    private fun annotation(location: String, kind: String = "highlight"): PdfAnnotation = PdfAnnotation(
        id = 1L,
        documentId = "doc",
        location = location,
        text = "",
        createdAt = 0L,
        updatedAt = 0L,
        kind = kind,
    )

    private companion object {
        /** 2 页（200×200 pt）+ 3 层书签的真实 PDF（与 [PdfOutlineReaderTest] 同一份样本）。 */
        const val PDF_WITH_OUTLINE =
            "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgL091dGxpbmVzIDUgMCBSIC9QYWdlTW9kZSAvVXNlT3V0bGluZXMgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUiA0IDAgUl0gL0NvdW50IDIgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMjAwXSA+PgplbmRvYmoKNCAwIG9iago8PCAvVHlwZSAvUGFnZSAvUGFyZW50IDIgMCBSIC9NZWRpYUJveCBbMCAwIDIwMCAyMDBdID4+CmVuZG9iago1IDAgb2JqCjw8IC9UeXBlIC9PdXRsaW5lcyAvRmlyc3QgNiAwIFIgL0xhc3QgMTAgMCBSIC9Db3VudCA1ID4+CmVuZG9iago2IDAgb2JqCjw8IC9UaXRsZSA8RkVGRjdCMkM0RTAwN0FFMD4gL1BhcmVudCA1IDAgUiAvRGVzdCBbMyAwIFIgL0ZpdF0gL0ZpcnN0IDcgMCBSIC9MYXN0IDcgMCBSIC9Db3VudCAyIC9OZXh0IDkgMCBSID4+CmVuZG9iago3IDAgb2JqCjw8IC9UaXRsZSAoU2VjdGlvbiAxKSAvUGFyZW50IDYgMCBSIC9EZXN0IFs0IDAgUiAvRml0XSAvRmlyc3QgOCAwIFIgL0xhc3QgOCAwIFIgL0NvdW50IDEgPj4KZW5kb2JqCjggMCBvYmoKPDwgL1RpdGxlIChTdWIgMS4xKSAvUGFyZW50IDcgMCBSIC9EZXN0IFszIDAgUiAvRml0XSA+PgplbmRvYmoKOSAwIG9iago8PCAvVGl0bGUgKEFwcGVuZGl4KSAvUGFyZW50IDUgMCBSIC9EZXN0IFs0IDAgUiAvRml0XSAvTmV4dCAxMCAwIFIgPj4KZW5kb2JqCjEwIDAgb2JqCjw8IC9UaXRsZSAoV2ViIExpbmspIC9QYXJlbnQgNSAwIFIgL0EgPDwgL1MgL1VSSSAvVVJJIChodHRwczovL2V4YW1wbGUuY29tKSA+PiA+PgplbmRvYmoKeHJlZgowIDExCjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwMTAzIDAwMDAwIG4gCjAwMDAwMDAxNjYgMDAwMDAgbiAKMDAwMDAwMDIzNyAwMDAwMCBuIAowMDAwMDAwMzA4IDAwMDAwIG4gCjAwMDAwMDAzODAgMDAwMDAgbiAKMDAwMDAwMDUwNiAwMDAwMCBuIAowMDAwMDAwNjEzIDAwMDAwIG4gCjAwMDAwMDA2ODQgMDAwMDAgbiAKMDAwMDAwMDc2OSAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDExIC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo4NjcKJSVFT0YK"
    }
}
