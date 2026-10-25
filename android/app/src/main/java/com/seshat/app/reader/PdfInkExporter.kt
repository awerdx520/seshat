package com.seshat.app.reader

import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSFloat
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.handlers.PDHighlightAppearanceHandler
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.handlers.PDInkAppearanceHandler
import java.io.File

/**
 * 把本地手写笔迹与高亮批注导出到**新 PDF 副本** `xxx.seshat.pdf`（纯逻辑，无 Android 依赖）。
 *
 * ## 硬约束：原文件只读
 * 源 PDF 只被 `PDDocument.load`（读）打开，导出结果**永远写到新文件**（先 `save` 到同目录
 * `.part` 临时文件，成功后 `renameTo` 目标名）。任何异常路径都会删掉临时文件并返回
 * [Result.Failure]，**绝不写回源文件**——源文件可能正在 WebDAV 同步、或是带签名的 PDF，
 * 原地修改会破坏签名并使同步冲突（见计划注意事项）。
 *
 * ## 为什么不是 `PDAnnotationInk`
 * pdfbox-android 2.0.27.0 **没有** `PDAnnotationInk` 这个便捷类（实测：AAR 的 classes.jar 里
 * 只有 `PDAnnotation` / `PDAnnotationLink` / `PDAnnotationMarkup` / `PDAnnotationTextMarkup` 等，
 * 无 `PDAnnotationInk`），但 `/Ink` 批注的**写入能力是完整的**：
 * `PDAnnotationMarkup.SUB_TYPE_INK`、`PDInkAppearanceHandler` 都在。因此这里按规范直接构造
 * `/Subtype /Ink` 的 `COSDictionary`（`Rect` / `C` / `CA` / `F` / `BS` / `InkList`），再用
 * [PDAnnotationMarkup] 包一层交给 [PDInkAppearanceHandler] 生成外观流（`/AP`）。
 *
 * ## 为什么必须显式生成外观流（`/AP`）
 * PDF 查看器**不保证**会为批注现算外观：没有 `/AP` 的 `/Ink` 或 `/Highlight` 在不少阅读器里
 * 直接不可见（实测：`PDAnnotationTextMarkup.constructAppearances()` 在 2.0.27.0 里对
 * `/Highlight` 不产出 `/AP`，必须直接调用 `PDHighlightAppearanceHandler.generateNormalAppearance()`）。
 * 本模块对两类批注都显式生成外观流，保证「通用阅读器可见」。
 *
 * ## 与屏幕渲染的一致性
 * 坐标、线宽、透明度三个口径全部复用既有实现，不另起一套：
 * - 归一化 → PDF point 与 y 翻转：[pagePoint]（y 轴翻转的唯一落点）；
 * - 线宽：`InkStroke.width`（相对页宽归一化）→ pt 用 [InkAnnotationMapper.widthPt]，笔型倍率用
 *   [InkGeometry.styleWidthScale]；
 * - 透明度：笔型的 alpha 用 [InkGeometry.styleAlpha]（屏幕上 `Paint.setAlpha` 会覆盖颜色自带
 *   alpha，导出必须同口径，否则荧光笔会变成实心粗线）。
 *
 * ## 已知取舍（tech-debt 见 openspec/tech-debt.md）
 * - **旋转页（`/Rotate` ≠ 0）跳过**：归一化坐标是相对**渲染后（已应用旋转）**的显示矩形，而
 *   PDF 批注坐标是页面默认用户空间（未旋转），直接把二者相乘会让笔迹错位 90°。宁可少导出一页
 *   并在结果里报出页码，也不产出错位的副本。
 * - 高亮批注**没有颜色字段**（[PdfAnnotation] 只有 `kind` / `location` / `text`），导出统一用
 *   [DEFAULT_HIGHLIGHT_ARGB]，与 Emacs 端高亮装饰色近似。
 */
internal object PdfInkExporter {

    /**
     * 导出结果（`sealed` 而非返回 `null`：调用方要区分「没有可导出的内容」与「导出失败」，
     * 前者不该弹错误提示）。
     */
    sealed interface Result {
        /**
         * 导出成功。
         *
         * @param file 新副本（同目录 `xxx.seshat.pdf`；已存在时带 `-1`/`-2` 后缀）
         * @param inkCount 写入的 `/Ink` 批注数
         * @param highlightCount 写入的 `/Highlight` 批注数
         * @param skippedPages 被跳过的页（1-based，供 UI 如实提示；空表示全部导出）
         */
        data class Success(
            val file: File,
            val inkCount: Int,
            val highlightCount: Int,
            val skippedPages: List<Int>,
        ) : Result

        /** 导出失败，[reason] 是可直接展示给用户的中文短句（不含路径，避免泄露本地目录）。 */
        data class Failure(val reason: String) : Result

        /** 既无笔迹也无高亮：不生成任何文件。 */
        data object Empty : Result
    }

    /** 副本名的固定中缀：`a.pdf` → `a.seshat.pdf`。 */
    const val SUFFIX = ".seshat"

    /**
     * 高亮批注的默认颜色（ARGB，RGB 分量与 Emacs 端
     * `seshat-reader-annotation-highlight-color` 的默认值 `(1.0 0.85 0.0)` 一致）。
     *
     * [PdfAnnotation] 没有颜色字段，故由本模块给定；alpha 不在此体现——`/Highlight` 的外观流
     * 由 `PDHighlightAppearanceHandler` 以 Multiply 混合生成，天然半透明。
     */
    const val DEFAULT_HIGHLIGHT_ARGB: Int = 0xFFFFD900.toInt()

    /** 线宽下限（pt）：0 宽线在许多阅读器里不可见，夹一个下限保证「导出后一定看得见」。 */
    private const val MIN_WIDTH_PT = 0.3f

    /** 一笔至少要两个点才画得出来（单点在该格式下无法表达成一个可见笔画）。 */
    private const val MIN_STROKE_POINTS = 2

    // ---------------------------------------------------------------- 路径构造（纯函数）

    /**
     * 计算导出目标路径：同目录、`<base>.seshat.pdf`，**已存在时依次尝试** `-1`、`-2`…（绝不覆盖）。
     *
     * `base` 取源文件名去掉 `.pdf` 后缀；若去掉后仍以 [SUFFIX] 结尾（例如对已导出的副本再次导出），
     * 会先剥掉这一层，得到 `a.seshat-1.pdf` 而不是 `a.seshat.seshat.pdf`。
     *
     * 本函数**只做命名计算，不创建/不检查权限**；实际写入由 [export] 负责。
     */
    fun exportPathFor(source: File): File {
        val dir = source.absoluteFile.parentFile ?: File(".")
        val name = source.name
        val stem = if (name.endsWith(".pdf", ignoreCase = true)) name.dropLast(4) else name
        val base = if (stem.endsWith(SUFFIX)) stem.dropLast(SUFFIX.length) else stem
        var candidate = File(dir, "$base$SUFFIX.pdf")
        var index = 0
        // 目标名可能正好等于源文件（对 `.seshat.pdf` 再次导出时），故循环条件同时排除源路径
        while (candidate.exists() || candidate.absolutePath == source.absolutePath) {
            index += 1
            candidate = File(dir, "$base$SUFFIX-$index.pdf")
        }
        return candidate
    }

    // ------------------------------------------------------------ 坐标换算（纯函数）

    /**
     * 归一化坐标（0..1，**y 轴向下**，相对 FIT_CENTER 显示矩形）→ PDF 页面坐标（**y 轴向上**）。
     *
     * 这是全模块唯一的 y 翻转点：屏幕/手写的 `(0,0)` 是**左上角**，而 PDF 用户空间的原点在
     * **左下角**，故 `yPdf = (1 - ny) × height`。举例（页高 `h`）：
     * - `(0,0)` → `(0, h)`：屏幕左上 = PDF 左上角；
     * - `(1,1)` → `(w, 0)`：屏幕右下 = PDF 右下角。
     *
     * 输入先夹紧到 0..1（留白区误采的点不会越界，与 [InkGeometry.toNormalized] 的既有约定一致）；
     * 非法尺寸（≤0 / NaN）返回 `(0,0)`，由调用方按「跳过该页」处理。
     */
    fun pagePoint(nx: Float, ny: Float, widthPt: Float, heightPt: Float): Pair<Float, Float> {
        if (!widthPt.isFinite() || !heightPt.isFinite() || widthPt <= 0f || heightPt <= 0f) return 0f to 0f
        val x = nx.coerceIn(0f, 1f) * widthPt
        val y = (1f - ny.coerceIn(0f, 1f)) * heightPt
        return x to y
    }

    /**
     * 一个待写入的高亮矩形（PDF point，**y 轴向上**，已相对页面左下角）。
     *
     * @param pageIndex 0-based（`location` 的 `page:<n>` 是 1-based，构造时已减 1）
     */
    data class HighlightMark(
        val pageIndex: Int,
        val x0: Float,
        val y0: Float,
        val x1: Float,
        val y1: Float,
    ) {
        val width: Float get() = x1 - x0
        val height: Float get() = y1 - y0
    }

    /**
     * 从批注表里挑出可导出的高亮矩形（纯函数，可 JVM 单测）。
     *
     * 只认 `kind == "highlight"` 且 `location` 能被 [LocationCodec] 解析成
     * `Parsed.PageRect`（`page:<n>;rect:<x0>,<y0>,<x1>,<y1>`，坐标口径为 PDF point、**y 向下**）
     * 的项；`page < 1`、缺 `rect`、坐标不成对的项逐条跳过（不整体失败）。
     *
     * y 翻转在 [export] 里按页高完成（本函数拿不到页尺寸，故不做翻转）—— 这里只做
     * 「倒置矩形归一化」（`x0 > x1` 时交换端点，避免负宽矩形）。
     */
    fun highlightMarks(annotations: List<PdfAnnotation>): List<HighlightMark> {
        val marks = ArrayList<HighlightMark>()
        for (annotation in annotations) {
            if (annotation.kind != KIND_HIGHLIGHT) continue
            val rect = LocationCodec.parse(annotation.location) as? LocationCodec.Parsed.PageRect ?: continue
            if (rect.page < 1) continue
            val x0 = minOf(rect.x0, rect.x1).toFloat()
            val x1 = maxOf(rect.x0, rect.x1).toFloat()
            val y0 = minOf(rect.y0, rect.y1).toFloat()
            val y1 = maxOf(rect.y0, rect.y1).toFloat()
            if (x1 <= x0 || y1 <= y0) continue
            marks.add(HighlightMark(rect.page - 1, x0, y0, x1, y1))
        }
        return marks
    }

    // ---------------------------------------------------------------- 导出

    /**
     * 导出 `source` 的副本：把 [pages] 里的笔迹写成 `/Ink` 批注、把 [annotations] 里的
     * `kind=highlight` 矩形写成 `/Highlight` 批注，两者都带 `/AP` 外观流。
     *
     * 调用方**必须放到后台线程**（PDF 解析 + 写盘，阻塞且吃内存）。
     *
     * @param pages 手写笔迹（[PdfInkPage.page] 为 0-based，与 [PdfInkStore] 同口径）
     * @param annotations 本地批注表（只用 `kind=highlight` 且 `location` 含 `rect:` 的项）
     * @param highlightArgb 高亮颜色（ARGB；[PdfAnnotation] 无颜色字段，故由调用方给定）
     * @return 见 [Result]；**无笔迹且无高亮时返回 [Result.Empty]，不创建文件**
     */
    fun export(
        source: File,
        pages: List<PdfInkPage>,
        annotations: List<PdfAnnotation>,
        highlightArgb: Int = DEFAULT_HIGHLIGHT_ARGB,
    ): Result {
        // 先用纯函数判定「有没有东西可导出」：无内容时连 PDDocument.load 都不做
        val drawablePages = pages.mapNotNull { page ->
            val strokes = page.strokes.filter { it.points.size >= MIN_STROKE_POINTS }
            if (strokes.isEmpty()) null else page.page to strokes
        }.toMap()
        val marksByPage = highlightMarks(annotations).groupBy { it.pageIndex }
        if (drawablePages.isEmpty() && marksByPage.isEmpty()) return Result.Empty
        if (!source.isFile || !source.canRead()) return Result.Failure(REASON_UNREADABLE)

        val target = exportPathFor(source)
        val temp = File(target.parentFile, target.name + ".part")
        var document: PDDocument? = null
        var inkCount = 0
        var highlightCount = 0
        val skipped = ArrayList<Int>()
        try {
            document = PDDocument.load(source)
            val pageTree = document.pages
            for (pageIndex in (drawablePages.keys + marksByPage.keys).sorted()) {
                if (pageIndex < 0 || pageIndex >= pageTree.count) {
                    skipped.add(pageIndex + 1)
                    continue
                }
                val page = pageTree.get(pageIndex)
                // 旋转页：归一化坐标相对「渲染后」矩形，与 PDF 用户空间差一个 90° 旋转 → 跳过
                if (page.rotation % 360 != 0) {
                    skipped.add(pageIndex + 1)
                    continue
                }
                val box = page.cropBox ?: page.mediaBox ?: continue
                inkCount += drawablePages[pageIndex].orEmpty().count { stroke ->
                    addInkAnnotation(document, page, box, stroke)
                }
                marksByPage[pageIndex].orEmpty().forEach { mark ->
                    addHighlightAnnotation(document, page, box, mark, highlightArgb)
                    highlightCount += 1
                }
            }
            if (inkCount == 0 && highlightCount == 0) {
                // 全部页被跳过（旋转/越界）→ 不产出空副本
                return Result.Failure(REASON_NOTHING_EXPORTABLE)
            }
            document.save(temp)
        } catch (_: Throwable) {
            // 收敛所有失败（IO / 加密 / 畸形结构 / 内存）；临时文件必须清掉，绝不留下半成品
            runCatching { temp.delete() }
            return Result.Failure(REASON_FAILED)
        } finally {
            runCatching { document?.close() }
        }
        // 落盘成功才改名：renameTo 同目录下是原子替换语义（目标名此前已确保不存在）
        if (!temp.renameTo(target)) {
            runCatching { temp.delete() }
            return Result.Failure(REASON_FAILED)
        }
        return Result.Success(target, inkCount, highlightCount, skipped.sorted())
    }

    // ---------------------------------------------------------------- 内部实现

    /**
     * 写一条 `/Ink` 批注并生成外观流。
     *
     * @return 是否写入成功（单笔失败只影响这一笔，不毁掉整份文档）
     */
    private fun addInkAnnotation(
        document: PDDocument,
        page: PDPage,
        box: PDRectangle,
        stroke: InkStroke,
    ): Boolean = runCatching {
        val originX = box.lowerLeftX
        val originY = box.lowerLeftY
        // box 坐标（左下角为原点、y 向上）直接拼成 InkList：PDFBox 的页面用户空间即 box 空间
        val points = stroke.points.map { point ->
            val (x, y) = pagePoint(point.x, point.y, box.width, box.height)
            (originX + x) to (originY + y)
        }
        val widthPt = maxOf(
            MIN_WIDTH_PT,
            InkAnnotationMapper.widthPt(stroke.width, box.width.toDouble()).toFloat() *
                InkGeometry.styleWidthScale(stroke.style),
        )
        val dictionary = COSDictionary()
        dictionary.setItem(COSName.TYPE, COSName.getPDFName("Annot"))
        dictionary.setItem(COSName.SUBTYPE, COSName.getPDFName("Ink"))
        dictionary.setItem(COSName.RECT, rectArray(points, widthPt))
        dictionary.setItem(COSName.getPDFName("C"), colorArray(stroke.color))
        dictionary.setItem(COSName.getPDFName("CA"), COSFloat(InkGeometry.styleAlpha(stroke.style) / 255f))
        // F=4（Print）：导出副本要能直接打印出笔迹
        dictionary.setItem(COSName.getPDFName("F"), COSFloat(4f))
        val border = COSDictionary()
        border.setItem(COSName.W, COSFloat(widthPt))
        border.setItem(COSName.getPDFName("S"), COSName.getPDFName("S"))
        dictionary.setItem(COSName.BS, border)
        val inkList = COSArray()
        val path = COSArray()
        points.forEach { (x, y) ->
            path.add(COSFloat(x))
            path.add(COSFloat(y))
        }
        inkList.add(path)
        dictionary.setItem(COSName.getPDFName("InkList"), inkList)
        val annotation = PDAnnotationMarkup(dictionary)
        page.annotations.add(annotation)
        PDInkAppearanceHandler(annotation, document).generateNormalAppearance()
    }.isSuccess

    /**
     * 写一条 `/Highlight` 文本标记批注并生成外观流。
     *
     * [mark] 的坐标是「PDF point、y 向下」（与 `location` 的 `rect:` 同口径），这里翻成 y 向上：
     * `yBottom = box.upperRightY - y1`、`yTop = box.upperRightY - y0`。
     */
    private fun addHighlightAnnotation(
        document: PDDocument,
        page: PDPage,
        box: PDRectangle,
        mark: HighlightMark,
        highlightArgb: Int,
    ) {
        val annotation = PDAnnotationTextMarkup(PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT)
        val left = box.lowerLeftX + mark.x0
        val right = box.lowerLeftX + mark.x1
        val top = box.upperRightY - mark.y0
        val bottom = box.upperRightY - mark.y1
        annotation.rectangle = PDRectangle(left, bottom, right - left, top - bottom)
        // quadPoints 顺序按规范：左上、右上、左下、右下（均以 y 向上为准）
        annotation.quadPoints = floatArrayOf(left, top, right, top, left, bottom, right, bottom)
        annotation.color = PDColor(colorComponents(highlightArgb), PDDeviceRGB.INSTANCE)
        annotation.isPrinted = true
        page.annotations.add(annotation)
        PDHighlightAppearanceHandler(annotation, document).generateNormalAppearance()
    }

    /** 点序列 → `[x0 y0 x1 y1]` 包围盒（四周各留半个线宽，保证外观流不被裁掉）。 */
    private fun rectArray(points: List<Pair<Float, Float>>, widthPt: Float): COSArray {
        val pad = widthPt / 2f
        var minX = Float.MAX_VALUE
        var minY = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE
        var maxY = -Float.MAX_VALUE
        points.forEach { (x, y) ->
            if (x < minX) minX = x
            if (y < minY) minY = y
            if (x > maxX) maxX = x
            if (y > maxY) maxY = y
        }
        val array = COSArray()
        array.add(COSFloat(minX - pad))
        array.add(COSFloat(minY - pad))
        array.add(COSFloat(maxX + pad))
        array.add(COSFloat(maxY + pad))
        return array
    }

    /** ARGB → `/C` 的 RGB 三分量数组（alpha 单独走 `/CA`，不进 `/C`）。 */
    private fun colorArray(argb: Int): COSArray {
        val array = COSArray()
        colorComponents(argb).forEach { array.add(COSFloat(it)) }
        return array
    }

    /** ARGB → `[r, g, b]`（0..1）。 */
    private fun colorComponents(argb: Int): FloatArray = floatArrayOf(
        ((argb shr 16) and 0xFF) / 255f,
        ((argb shr 8) and 0xFF) / 255f,
        (argb and 0xFF) / 255f,
    )

    /** 服务端 `kind` 的高亮取值（与 [AnnotationGrouping.KIND_HIGHLIGHT] 同源）。 */
    private const val KIND_HIGHLIGHT = AnnotationGrouping.KIND_HIGHLIGHT

    /** 失败文案（不含本地路径；调用方直接 Toast）。 */
    private const val REASON_UNREADABLE = "源文件不可读，无法导出"
    private const val REASON_NOTHING_EXPORTABLE = "没有可导出的内容（旋转页暂不支持）"
    private const val REASON_FAILED = "导出失败，原文件未改动"
}
