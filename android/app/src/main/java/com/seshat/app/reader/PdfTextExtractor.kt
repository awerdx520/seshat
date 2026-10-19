package com.seshat.app.reader

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.InputStream

/**
 * PDF 文本提取（长按菜单「复制本页文字」用）。
 *
 * 复用 pdfbox-android（与 [PdfOutlineReader] 同一依赖、同一「只在 reader 包内使用」约束）。
 * 只提取**单页**：整本提取在大文件上会占满内存，且用户只需要当前页。
 *
 * 注意：`PDDocument.load` 是阻塞 + 高内存操作，**调用方必须放到后台线程**；
 * 本类**不引用任何 Android 日志 API**（纯 JVM 单测里 android.jar 是 `Stub!` 空壳，调用即抛）。
 */
internal object PdfTextExtractor {
    /** 大小上限，与 [PdfOutlineReader.MAX_OUTLINE_BYTES] 一致；超过直接返回空串（防 OOM）。 */
    const val MAX_BYTES: Long = PdfOutlineReader.MAX_OUTLINE_BYTES

    /**
     * 提取指定页的纯文本。
     *
     * @param pageIndex 0-based 页索引；越界返回空串
     * @param sizeHint 文档字节数预估；`> [MAX_BYTES]` 直接返回空串（**不读流**）；未知传 -1
     * @return 页面文本；扫描版（无文本层）/加密/损坏/越界 → 空串，**不抛异常**
     */
    fun extractPage(input: InputStream, pageIndex: Int, sizeHint: Long = -1L): String {
        // 早退必须放在最前面：不触达 PdfBox（也不读流），便于纯 JVM 单测覆盖与防 OOM
        if (pageIndex < 0) return ""
        if (sizeHint > MAX_BYTES) return ""
        var doc: PDDocument? = null
        return try {
            val opened = PDDocument.load(input)
            doc = opened
            if (pageIndex >= opened.numberOfPages) return ""
            // PDFTextStripper 的页号是 1-based，故单页区间为 [pageIndex + 1, pageIndex + 1]
            val stripper = PDFTextStripper().apply {
                startPage = pageIndex + 1
                endPage = pageIndex + 1
            }
            stripper.getText(opened).trim()
        } catch (_: Exception) {
            // 加密 / 损坏 / 解析失败一律收敛为空串，调用方只负责提示「本页没有可复制的文字」
            ""
        } catch (_: LinkageError) {
            // [PDFTextStripper] 首次使用会静态初始化文本引擎（加载字形表等资源，走 `PDFBoxResourceLoader`）。
            // 资源未就绪时抛 `ExceptionInInitializerError`（属于 Error 而非 Exception）——生产环境由
            // [PdfReaderActivity.onCreate] 提前 `PDFBoxResourceLoader.init(applicationContext)` 保证，
            // 但仍按「绝不抛异常」的契约降级为空串（纯 JVM 单测就是这条路径）。
            ""
        } finally {
            // close() 不关调用方的流，流所有权留在调用方的 use {}
            runCatching { doc?.close() }
        }
    }
}
