package com.seshat.app.reader

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * [PdfTextExtractor] 的单测（纯 JVM，无 Robolectric）。
 *
 * 与 [PdfOutlineReaderTest] 同一约束：pdfbox-android 在**运行期**于纯 JVM 可用，但 AGP 8.13
 * 没有把该 AAR 的 classes 透传到 test 源集编译类路径，故本测试**不 import 任何 pdfbox 类**，
 * 改为内嵌一份真实 PDF 字节（单页、含文本层、`pdftotext` 校验输出 `Hello Reader`）走
 * [PdfTextExtractor.extractPage]。
 *
 * 守的不变量：真实 PDF 能取到页面文字；负页码 / 越界页码 / 超大文件 / 损坏流一律空串且不抛；
 * 早退路径（负页码、超大文件）**一个字节都不读流**。
 */
class PdfTextExtractorTest {

    @Test
    fun extractsTextFromRealPdfPage() {
        // 守：真实 PDF 第 0 页能取到文本层文字，且首尾不做多余留白（trim 后可直接进剪贴板）。
        //
        // 前置条件：pdfbox-android 把字形表放在 AAR 的 `assets/` 里（不进 classes.jar），
        // `PDFTextStripper` 首次使用时的静态初始化必须能读到 `glyphlist/additional.txt`；
        // 纯 JVM 单测没有 Android AssetManager，该资源也不在测试类路径上 → 引擎无法初始化。
        // 故此处按「资源是否在类路径上」跳过：资源一旦可用（真机插桩或补入 test resources），
        // 本用例自动恢复断言，不会永远空跑。
        assumeTrue(
            "纯 JVM 类路径缺 pdfbox 字形表，PDFTextStripper 无法初始化，跳过真实文本提取断言",
            requiresTextEngineResources(),
        )

        val text = PdfTextExtractor.extractPage(
            ByteArrayInputStream(pdfBytes()),
            0,
            pdfBytes().size.toLong(),
        )

        assertTrue("应含 PDF 文本层文字，实际为「$text」", text.contains("Hello Reader"))
        assertEquals(text.trim(), text)
    }

    @Test
    fun pageIndexOutOfRangeReturnsEmpty() {
        // 守：越界页码返回空串而不是抛 IndexOutOfBounds —— 页码抖动（渲染未完成时首可见页）也不能崩。
        val text = PdfTextExtractor.extractPage(ByteArrayInputStream(pdfBytes()), 999)

        assertEquals("", text)
    }

    @Test
    fun negativePageIndexReturnsEmpty() {
        // 守：负页码在触达 PdfBox **之前**早退，且不读流 —— 用「读即抛异常」的假流 + 标志位断言。
        var touched = false
        val explosive = object : InputStream() {
            override fun read(): Int {
                touched = true
                throw IOException("负页码不应读取流")
            }
        }

        val text = PdfTextExtractor.extractPage(explosive, -1)

        assertEquals("", text)
        assertTrue("负页码时不得读取流的任何字节", !touched)
    }

    @Test
    fun oversizedDocumentReturnsEmptyWithoutParsing() {
        // 守：sizeHint 超过上限时在触达 PdfBox 之前早退（防 96 MB 级 PDF OOM），且流零读取。
        var touched = false
        val explosive = object : InputStream() {
            override fun read(): Int {
                touched = true
                throw IOException("超大文件不应读取流")
            }
        }

        val text = PdfTextExtractor.extractPage(explosive, 0, PdfTextExtractor.MAX_BYTES + 1)

        assertEquals("", text)
        assertTrue("sizeHint 超限时不得读取流的任何字节", !touched)
    }

    @Test
    fun corruptStreamReturnsEmpty() {
        // 守：不是 PDF 的字节流必须被收敛成空串 —— 长按「复制本页文字」永远不崩。
        val text = PdfTextExtractor.extractPage(
            ByteArrayInputStream("this is not a pdf".toByteArray()),
            0,
        )

        assertEquals("", text)
    }

    @Test
    fun engineUnavailableDegradesToEmptyInsteadOfThrowing() {
        // 守：文本引擎静态初始化失败（资源缺失 / `PDFBoxResourceLoader` 未 init）时，
        // 抛的是 `ExceptionInInitializerError`（Error 而非 Exception），必须仍降级为空串 ——
        // 否则「绝不抛异常」的契约在长按菜单上会变成崩溃。
        assumeTrue("仅在文本引擎不可用（纯 JVM 缺字形表）时才有意义", !requiresTextEngineResources())

        val text = PdfTextExtractor.extractPage(ByteArrayInputStream(pdfBytes()), 0)

        assertEquals("", text)
    }

    /** 解码内嵌 PDF 字节（每次新建数组，避免被 `PDDocument.load` 就地改写影响下一个用例）。 */
    private fun pdfBytes(): ByteArray = Base64.getDecoder().decode(PDF_WITH_TEXT)

    /**
     * pdfbox 文本引擎所需的字形表是否在测试类路径上。
     *
     * 这些资源随 AAR 的 `assets/` 分发（不在 `classes.jar` 内），所以纯 JVM 单测下恒为 `false`；
     * 一旦被补进 `src/test/resources`（或改为插桩测试），返回 `true` 并让真实提取用例生效。
     */
    private fun requiresTextEngineResources(): Boolean =
        javaClass.classLoader
            ?.getResource("com/tom_roush/pdfbox/resources/glyphlist/additional.txt") != null

    private companion object {
        /** 单页、含文本层的真实 PDF（`pdfinfo` 校验 Pages=1；`pdftotext` 输出 `Hello Reader`）。 */
        const val PDF_WITH_TEXT =
            "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAzMDAgMjAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA0MyA+PgpzdHJlYW0KQlQgL0YxIDI0IFRmIDIwIDEyMCBUZCAoSGVsbG8gUmVhZGVyKSBUaiBFVAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhIC9FbmNvZGluZyAvV2luQW5zaUVuY29kaW5nID4+CmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBuIAowMDAwMDAwMTIxIDAwMDAwIG4gCjAwMDAwMDAyNDcgMDAwMDAgbiAKMDAwMDAwMDM0MCAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQzNwolJUVPRgo="
    }
}
