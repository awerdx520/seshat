package com.seshat.app.reader

import java.util.Locale

/**
 * 批注 location 的编解码（纯逻辑，无 Android 依赖，可 JVM 单测）。
 *
 * 支持四种形态（见 openspec M10.3「location 约定」）：
 *
 * | 载体 | 形态 |
 * |---|---|
 * | PDF 文本批注 | `page:<n>`（1-based） |
 * | PDF 高亮 | `page:<n>;rect:<x0>,<y0>,<x1>,<y1>` |
 * | PDF 笔迹 | `page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`（一笔一条，PDF point） |
 * | EPUB | `chapter:<spineIndex>@<startOffset>-<endOffset>`（spine 0-based，半开区间） |
 *
 * 两条硬约束（编码/解码的闭合性）：
 * 1. [parse] 对**任何输入都不抛异常**，识别不了就返回 [Parsed.Unknown]；
 * 2. [encodeInk] / [encodeChapter] 的返回值**必然能被 [parse] 重新解析**——因此编码侧对
 *    非法取值（页号 0、负线宽、负数偏移、含分隔符的颜色）做夹紧或净化，而不是产出半截串。
 *    否则会出现「编码成功但记录不可解析」的静默不一致。
 *
 * 坐标为 PDF point（原点左上、y 向下），保留两位小数；归一化 0..1 → point 的换算复用
 * [InkGeometry.toDisplay]（把 `DisplayRect(0,0,页宽,页高)` 传进去即得 point，不重复实现公式）。
 */
object LocationCodec {

    /** [parse] 的结果（不可变值对象，`data class` 便于测试直接比对）。 */
    sealed interface Parsed {
        /** `page:<n>`：PDF 文本批注（页号 1-based）。 */
        data class Page(val page: Int) : Parsed

        /** `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`：PDF 高亮矩形（PDF point）。 */
        data class PageRect(
            val page: Int,
            val x0: Double,
            val y0: Double,
            val x1: Double,
            val y1: Double,
        ) : Parsed

        /**
         * `page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`：一笔手写笔迹（PDF point）。
         *
         * [points] 允许为空：页面尺寸未知时编码不出来坐标（见 [encodeInk]），解码得到空列表。
         */
        data class PageInk(
            val page: Int,
            val color: String,
            val widthPt: Double,
            val points: List<Pair<Double, Double>>,
        ) : Parsed

        /** `chapter:<i>@<s>-<e>`：EPUB 章内选区（spine 序号 0-based，字符偏移半开区间）。 */
        data class Chapter(val spineIndex: Int, val startOffset: Int, val endOffset: Int) : Parsed

        /** 无法识别的原串（保留原样，供调用方展示或走旧逻辑兜底）。 */
        data class Unknown(val raw: String) : Parsed
    }

    private const val PAGE_PREFIX = "page:"
    private const val CHAPTER_PREFIX = "chapter:"
    private const val RECT_PREFIX = "rect:"
    private const val INK_PREFIX = "ink:"

    /**
     * 单条 ink 批注允许的最大坐标点数（防御性上限）。
     *
     * location 串来自服务端/对端写入，长度不受本端控制；不设上限时一个超长串就能让
     * [parse] 分配百万级 [Double] 列表（解析阶段即内存膨胀，且下游 Map/渲染还要再复制一遍）。
     * 正常一笔手写只有几百个采样点，1 万点足够覆盖长笔画；超限按「不可识别」处理（返回
     * [Parsed.Unknown]，**不抛异常**，与 [parse] 的容错契约一致）。
     * 编码侧 [encodeInk] 同源截断（见其文档），保证「编码结果必然可解析」的闭合性。
     */
    const val MAX_INK_POINTS = 10000

    /** rect 的坐标分量个数（`x0,y0,x1,y1`）：数量天然收敛，同时作为解析期的字段数上限。 */
    private const val RECT_VALUES = 4

    /** 颜色缺失时的占位值（表示「未指定」；两端都把 color 当不透明串处理）。 */
    private const val DEFAULT_COLOR = "0"

    /** 页号段：只接受十进制数字（`toIntOrNull` 会放过 `+12` 这类带符号写法，故用正则收紧）。 */
    private val PAGE_HEAD = Regex("page:(\\d{1,9})")

    /** EPUB 段：`chapter:<i>@<s>-<e>`，三段均须为十进制数字。 */
    private val CHAPTER_BODY = Regex("chapter:(\\d{1,9})@(\\d{1,9})-(\\d{1,9})")

    // ---- 解析 ----

    /**
     * 解析 location 串。
     *
     * 容错：首尾空白被忽略；任何不合法输入（空串、`page:0`、缺字段、坐标不成对、`chapter` 缺 `@`/`-`）
     * 一律返回 [Parsed.Unknown]（`raw` 保留原始未 trim 的输入），**不抛异常**。
     */
    fun parse(location: String): Parsed {
        val text = location.trim()
        if (text.isEmpty()) return Parsed.Unknown(location)
        return when {
            text.startsWith(CHAPTER_PREFIX) -> parseChapter(location, text)
            text.startsWith(PAGE_PREFIX) -> parsePage(location, text)
            else -> Parsed.Unknown(location)
        }
    }

    private fun parsePage(original: String, text: String): Parsed {
        val segments = text.split(';')
        if (segments.size > 2) return Parsed.Unknown(original)
        val page = pageNumber(segments[0]) ?: return Parsed.Unknown(original)
        return when (val tail = segments.getOrNull(1)) {
            null -> Parsed.Page(page)
            else -> when {
                tail.startsWith(RECT_PREFIX) -> parseRect(original, page, tail.removePrefix(RECT_PREFIX))
                tail.startsWith(INK_PREFIX) -> parseInk(original, page, tail.removePrefix(INK_PREFIX))
                else -> Parsed.Unknown(original)
            }
        }
    }

    /** 页号（1-based）；非数字或 <1 返回 null。 */
    private fun pageNumber(head: String): Int? =
        PAGE_HEAD.matchEntire(head)?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it >= 1 }

    private fun parseRect(original: String, page: Int, body: String): Parsed {
        // 字段数先于逐段解析判断：超长 body 直接在分段阶段被拒，不构造超长 Double 列表
        val values = doubles(body, RECT_VALUES) ?: return Parsed.Unknown(original)
        if (values.size != RECT_VALUES) return Parsed.Unknown(original)
        return Parsed.PageRect(page, values[0], values[1], values[2], values[3])
    }

    private fun parseInk(original: String, page: Int, body: String): Parsed {
        if (body.isEmpty()) return Parsed.Unknown(original)
        val fields = body.split(',')
        // 至少要有 color 与 widthPt 两段
        if (fields.size < 2) return Parsed.Unknown(original)
        val color = fields[0].trim()
        if (color.isEmpty()) return Parsed.Unknown(original)
        val widthPt = fields[1].trim().toDoubleOrNull() ?: return Parsed.Unknown(original)
        val coordinates = fields.drop(2)
        // 坐标必须成对（x, y）
        if (coordinates.size % 2 != 0) return Parsed.Unknown(original)
        // 点数上限：超限视为不可识别（不抛异常），避免超长 location 引发内存膨胀
        if (coordinates.size / 2 > MAX_INK_POINTS) return Parsed.Unknown(original)
        val values = ArrayList<Double>(coordinates.size)
        for (item in coordinates) {
            values += item.trim().toDoubleOrNull() ?: return Parsed.Unknown(original)
        }
        val points = values.chunked(2).map { it[0] to it[1] }
        return Parsed.PageInk(page, color, widthPt, points)
    }

    /**
     * `chapter:<i>@<s>-<e>`。
     *
     * `start > end`（倒置区间）一律判为非法返回 [Parsed.Unknown]：区间在协议里是半开区间
     * `[start, end)`，倒置值只能是数据损坏（编码侧已归一化，见 [encodeChapter]），
     * 若照单全收会让下游用 `end - start` 算出负长度、做 substring 时直接抛异常。
     */
    private fun parseChapter(original: String, text: String): Parsed {
        val match = CHAPTER_BODY.matchEntire(text) ?: return Parsed.Unknown(original)
        val spineIndex = match.groupValues[1].toIntOrNull() ?: return Parsed.Unknown(original)
        val startOffset = match.groupValues[2].toIntOrNull() ?: return Parsed.Unknown(original)
        val endOffset = match.groupValues[3].toIntOrNull() ?: return Parsed.Unknown(original)
        if (startOffset > endOffset) return Parsed.Unknown(original)
        return Parsed.Chapter(spineIndex, startOffset, endOffset)
    }

    /**
     * 逗号分隔的数字段 → Double 列表；任一段不可解析（含空段）或段数超过 [max] 返回 null。
     *
     * [max] 让「分量个数固定」的形态（rect 的 4 个）在读入边长串时就短路，不需要先构造
     * 完整列表再判长度。
     */
    private fun doubles(body: String, max: Int): List<Double>? {
        val parts = body.split(',')
        if (parts.size > max) return null
        return parts.map { it.trim().toDoubleOrNull() ?: return null }
    }

    // ---- 编码 ----

    /**
     * 编码一笔 PDF 笔迹。
     *
     * 归一化 0..1 的 [points] 先夹紧到 0..1（与 [InkGeometry.toNormalized] 的既有约定一致，
     * 留白区误采的点不会越界），再按 [pageWidthPt] × [pageHeightPt] 换算为 PDF point，保留两位小数。
     *
     * **点数上限**：只取前 [MAX_INK_POINTS] 个点（超出的尾部采样点丢弃）。上限与
     * [parseInk] 同源，否则会出现「编码成功但解码判为不可识别」——闭合性破裂。正常一笔远小于该上限。
     *
     * **降级取舍**：页面尺寸任一维 ≤0（PDF 页面尺寸未就绪）或 [points] 为空时，只编码
     * `page:<n>;ink:<color>,<widthPt>`（不带坐标）。理由：
     * - 坐标无从换算/无点可换算，硬编码 0.0 会伪造出「页面左上角有一点」的假数据；
     * - 但页号、颜色、线宽是已知事实，保留后跨端仍能显示「第 n 页手写（0 笔）」而不丢批注本体；
     * - 该形态可被 [parse] 解析回 `PageInk(points = emptyList())`，维持编码闭合性
     *   （若改返回 `Unknown` 语义，会出现「编码成功但记录不可解析」的静默不一致）。
     * 需要「是否值得上传」的调用方自行判 `points.isNotEmpty()`。
     *
     * @param page 页码（1-based；≤0 夹紧为 1，保证可解析）
     * @param color 颜色串（`, ; @` 与空白会被剔除，空串回退 [DEFAULT_COLOR]）
     * @param widthPt 线宽（PDF point；负数夹紧为 0）
     */
    fun encodeInk(
        page: Int,
        color: String,
        widthPt: Double,
        points: List<InkPoint>,
        pageWidthPt: Double,
        pageHeightPt: Double,
    ): String {
        val head = "$PAGE_PREFIX${page.coerceAtLeast(1)};ink:${sanitizedColor(color)},${format(widthPt)}"
        if (points.isEmpty() || pageWidthPt <= 0.0 || pageHeightPt <= 0.0) return head
        // 复用既有换算：显示矩形铺满整页（left/top = 0）时，toDisplay 的结果即 PDF point
        val pageRect = DisplayRect(0f, 0f, pageWidthPt.toFloat(), pageHeightPt.toFloat())
        val coordinates = points.take(MAX_INK_POINTS).joinToString(",") { point ->
            val normalized = InkPoint(point.x.coerceIn(0f, 1f), point.y.coerceIn(0f, 1f))
            val (x, y) = InkGeometry.toDisplay(normalized, pageRect)
            "${format(x)},${format(y)}"
        }
        return "$head,$coordinates"
    }

    /**
     * 编码 EPUB 章内选区：`chapter:<spineIndex>@<startOffset>-<endOffset>`。
     *
     * 负值（无意义的输入）夹紧为 0；**`start > end` 时归一化为 `min-max`**（而不是原样输出）：
     * [parseChapter] 已把倒置区间判为非法，若编码侧还产出倒置串，就会出现「编码成功但记录
     * 不可解析」的静默不一致（违反本对象的两条闭合性约束）。选择归一化而非「返回不可编码信号」，
     * 是因为调用方（选区点击上行）此时手里已有确定的选区，丢信息比交换端点更糟；
     * 确实需要拒绝倒置区间的调用方应在上游自行判 `start <= end`。
     */
    fun encodeChapter(spineIndex: Int, startOffset: Int, endOffset: Int): String {
        val start = startOffset.coerceAtLeast(0)
        val end = endOffset.coerceAtLeast(0)
        return "$CHAPTER_PREFIX${spineIndex.coerceAtLeast(0)}@${minOf(start, end)}-${maxOf(start, end)}"
    }

    /** 剔除会破坏 location 分隔语义的字符；结果为空时回退占位值。 */
    private fun sanitizedColor(color: String): String =
        color.filterNot { it == ',' || it == ';' || it == '@' || it.isWhitespace() }
            .ifEmpty { DEFAULT_COLOR }

    /** 数值 → 两位小数字本（固定 [Locale.US]，避免地区设置把小数点变成逗号）。 */
    private fun format(value: Float): String =
        if (value.isFinite()) "%.2f".format(Locale.US, value.coerceAtLeast(0f)) else "0.00"

    private fun format(value: Double): String = format(value.toFloat())
}
