package com.seshat.app.reader

import java.util.Locale

/**
 * 手写笔迹 → `kind=ink` 批注的**纯映射**（无 Android 依赖，可 JVM 单测）。
 *
 * 背景（M10.3 / T6）：[PdfInkStore] 仍是手写笔迹的**渲染唯一真相**，本模块只产出「同步镜像」——
 * 把一笔本地笔迹翻译成一条服务端批注的 `location`（`page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`，
 * 见 `docs/api.md §4.5.1`），镜像本身不参与绘制。
 *
 * ## 单位换算（三处，缺一处都会跨端错位）
 * 1. **页号**：本地 `PdfInkPage.page` / `PdfPageAdapter` 的 position 是 **0-based**，而 location 的
 *    `page:<n>` 是 **1-based**，故入口一律 `pageIndex + 1`（对应 Activity 里
 *    `"page:${firstVisiblePage() + 1}"` 的既有写法）。
 * 2. **坐标**：本地点序列是归一化 0..1（相对页面显示矩形），PDF point 空间的原点左上、y 向下，
 *    换算 `x_pt = nx × pageWidthPt`、`y_pt = ny × pageHeightPt` 由 [LocationCodec.encodeInk] 完成
 *    （它内部复用 [InkGeometry.toDisplay]，不重复实现公式）。
 * 3. **线宽**：`InkStroke.width` 是**归一化**线宽（相对页面显示矩形宽度），乘 [pageWidthPt] 得 pt。
 *
 * ## 页尺寸口径（`pageWidthPt` 的来源）
 * `PdfRenderer.Page.width/height` 是页面在 **72 dpi（= PDF point，1:1）** 下的尺寸，与渲染位图尺寸
 * 无关——适配器把位图缩放到 `renderWidth` 像素只是显示缩放，归一化坐标已消除该缩放。因此直接取
 * `Page.width/height` 即 pt，无需再乘任何 DPI 系数（见 `docs/api.md §4.5.1` 的换算公式）。
 *
 * ## 颜色格式
 * `InkStroke.color` 是 ARGB `Int` → 编码为 `#AARRGGBB`（大写八位十六进制，如 `#FFE53935`），
 * 与 `docs/api.md §4.5.1` 的约定一致，也与 [LocationCodec] 的 `sanitize`（只剔除 `,` `;` `@`
 * 与空白）兼容——`#` 与十六进制字符都能原样穿过，[LocationCodec.parse] 能取回同串。
 * **不用 `#RRGGBB`**：会丢掉 alpha，而马克笔/荧光笔（[InkStyle.MARKER] / [InkStyle.HIGHLIGHTER]）
 * 的半透明是其视觉本体，丢 alpha 后跨端还原会变成实心粗线。
 */
internal object InkAnnotationMapper {

    /** 手写批注的 `kind` 取值（服务端 `kind` 只约定不校验，见 `docs/api.md §4`）。 */
    const val KIND_INK = "ink"

    /** ink 批注的 `text` 恒为空串（备注正文对一笔手写无意义，服务端已按 kind 放宽校验）。 */
    private const val INK_TEXT = ""

    /**
     * ARGB `Int` → `#AARRGGBB`（大写十六进制）。
     *
     * 补零到 8 位：alpha 为 0 或很小时不能退化成 6/7 位，否则跨端解析宽度不一。
     */
    fun colorHex(argb: Int): String = "#" + "%08X".format(Locale.US, argb)

    /**
     * 归一化线宽 × 页宽 → PDF point。
     *
     * 非法输入（NaN / Infinity / 页宽 ≤0）一律返回 `0.0` 而不是抛异常：
     * 线宽为 0 仍是一条可解析、可显示的批注，而抛异常会让「落笔完成」这条主路径崩在同步镜像上。
     */
    fun widthPt(normalizedWidth: Float, pageWidthPt: Double): Double {
        if (!normalizedWidth.isFinite() || !pageWidthPt.isFinite() || pageWidthPt <= 0.0) return 0.0
        return normalizedWidth.coerceAtLeast(0f) * pageWidthPt
    }

    /**
     * 一笔笔迹 → ink location；**无法编码时返回 `null`**。
     *
     * 返回 `null` 的唯一情形是点序列为空：此时 [LocationCodec.encodeInk] 仍会产出
     * `page:<n>;ink:<color>,<widthPt>`（可解析的降级形态），但它代表「0 笔的批注」——
     * 上传到服务端只会变成一条没有内容的空条目，故这里直接判定为「不值得登记」。
     *
     * @param pageIndex 页面索引，**0-based**（`PdfPageAdapter` 的 position / `PdfInkPage.page`）
     */
    fun inkLocation(
        pageIndex: Int,
        stroke: InkStroke,
        pageWidthPt: Double,
        pageHeightPt: Double,
    ): String? {
        if (stroke.points.isEmpty()) return null
        return LocationCodec.encodeInk(
            page = pageIndex + 1,
            color = colorHex(stroke.color),
            widthPt = widthPt(stroke.width, pageWidthPt),
            points = stroke.points,
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
        )
    }

    /**
     * 批注幂等键 `(kind, location, text)`，NUL 分隔避免边界歧义。
     *
     * 与 `SyncManager.annotationKey`、服务端 `(uid, kind, location, text)`、Emacs 队列同构；
     * 这里独立实现一份是为了让「补登前先本地去重」在 JVM 单测里可断言，不必拉起同步层。
     */
    fun key(kind: String, location: String, text: String): String = "$kind\u0000$location\u0000$text"

    /** 本地是否已登记同键批注（`kind` 只认 ink，`text` 恒空串）。 */
    fun isRegistered(existing: List<PdfAnnotation>, location: String): Boolean =
        existing.any { it.kind == KIND_INK && it.text == INK_TEXT && it.location == location }

    /**
     * 构造一条 ink 同步镜像批注（**不落库**，由调用方 `annotationStore.add` 分配本地 id）。
     *
     * `id = 0L` 让 [PdfAnnotationStore.add] 走「分配 nextId」分支（绝不复用服务端 id）；
     * `dirty = true` 表示「待上行」——服务端 `(uid, kind, location, text)` 幂等去重是重复补登的兜底。
     */
    fun inkAnnotation(documentId: String, location: String, now: Long = System.currentTimeMillis()): PdfAnnotation =
        PdfAnnotation(
            id = 0L,
            documentId = documentId,
            location = location,
            text = INK_TEXT,
            createdAt = now,
            updatedAt = now,
            kind = KIND_INK,
            selectedText = "",
            serverId = null,
            dirty = true,
        )

    /**
     * 计算「需要一次性补登」的 ink location 列表（按页序、页内笔迹顺序）。
     *
     * 三重跳过，避免每次打开书都发 N 个 POST：
     * 1. 页面尺寸未知（[pageSizePt] 返回 `null`）→ 跳过该页（编码不出坐标，不伪造 0.0）；
     * 2. 点序列为空 → 跳过（同 [inkLocation]）；
     * 3. 本地已有同 `(kind, location, text)` 的批注 → 跳过（**客户端幂等键**，本轮新增）；
     *    同一批笔迹里两笔完全重合时，第二笔也会被本条挡住（location 天然相同）。
     *
     * 服务端 `(uid, kind, location, text)` 命中返回 200，是「本地被清空后再次补登」的第二道兜底。
     *
     * @param pages 本地笔迹（[PdfInkPage.page] 为 0-based）
     * @param existing 本地已有的全部批注（[PdfAnnotationStore.list] 的结果）
     * @param pageSizePt 页索引（0-based）→ `(宽 pt, 高 pt)`；取不到返回 `null`
     */
    fun pendingInkLocations(
        pages: List<PdfInkPage>,
        existing: List<PdfAnnotation>,
        pageSizePt: (Int) -> Pair<Double, Double>?,
    ): List<String> {
        val keys = existing.map { key(it.kind, it.location, it.text) }.toMutableSet()
        val pending = mutableListOf<String>()
        for (page in pages.sortedBy { it.page }) {
            if (page.strokes.isEmpty()) continue
            val size = pageSizePt(page.page) ?: continue
            for (stroke in page.strokes) {
                val location = inkLocation(page.page, stroke, size.first, size.second) ?: continue
                // 以 set 判重：既挡住「本地已有」，也挡住「同批内的完全重合笔迹」
                if (!keys.add(key(KIND_INK, location, INK_TEXT))) continue
                pending += location
            }
        }
        return pending
    }
}
