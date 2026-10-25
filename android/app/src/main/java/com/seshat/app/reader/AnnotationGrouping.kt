package com.seshat.app.reader

/**
 * 批注列表抽屉（M10.3 / T5）的**纯函数**分组逻辑。
 *
 * 全部逻辑无 Android 依赖（不引用 View / Context / Resources），可在 JVM 单测里直接跑；
 * UI 侧只负责「读 store → 映射成 [AnnotationItem] → 调 [AnnotationGrouping.group] → 渲染」。
 *
 * 设计要点：
 * - **一笔一条**：`kind=ink` 的批注在服务端是一笔一条（见 `docs/api.md §4.5.1`），
 *   若逐条渲染会淹没文本批注，故默认**折叠成一条汇总行**（带 `count`）。
 * - **分组顺序固定**（便签 → 高亮 → 手写 → 其它），与输入顺序无关，便于 UI 与测试稳定断言。
 * - **不丢数据**：未知 `kind` 的条目归入「其它」组，但每行仍保留原始 `kind` 与原始 `id`，
 *   调用方据此仍能定位到 store 里的记录做跳转/删除。
 * - **格式化克制**：纯函数只做「摘要/原文/备注 → 标题 + 副标题」的取舍与长度截断，
 *   分组标题、「本页/共 N 处手写」「[待同步]」等文案是**取值契约**（写死在本文件常量里），
 *   不做任何本地化之外的额外拼接。
 */

/**
 * 分组用的中性条目——由 Activity 从 [BookAnnotation]（`note`/`selectedText`）或
 * [PdfAnnotation]（`text`/`selectedText`）映射而来。
 *
 * @property id 稳定标识（调用方自行拼，如 `"epub:<uuid>"` / `"pdf:<id>"`），用于回查 store 记录
 * @property kind 批注种类，取值约定 `note` / `highlight` / `ink`；其它值归入「其它」组
 * @property note 备注正文（EPUB 侧的 `note`、PDF 侧的 `text`；`highlight`/`ink` 恒为空串）
 * @property selectedText 选中原文（`highlight` 必非空；`ink` 恒为空串）
 * @property page 跳转目标页（PDF 1-based）；EPUB 或无可跳页时传 `null`
 * @property pending 是否尚未上行（[AnnotationGrouping.pendingLabel] 的输入）
 */
internal data class AnnotationItem(
    val id: String,
    val kind: String,
    val note: String = "",
    val selectedText: String = "",
    val page: Int? = null,
    val pending: Boolean = false,
)

/**
 * 渲染用的一行。
 *
 * - `note` / `highlight` / 其它：每条批注一行，[count] 恒为 1
 * - `ink`：折叠汇总行，[count] 为手写笔数，[id] 为 [AnnotationGrouping.INK_SUMMARY_ID]
 *
 * @property id 回查 store 记录用的标识（ink 汇总行为固定占位值，不可直接用于删除）
 * @property kind 原始 `kind`（「其它」组内的行保留原值，便于调用方分派删除/跳转）
 * @property title 主文案（已按 [AnnotationGrouping.MAX_TEXT] 截断）
 * @property subtitle 副标题（有备注时放选中原文，已截断；其余为空串）
 * @property pending 是否需要显示 [AnnotationGrouping.PENDING_LABEL]
 * @property count 该行代表的批注条数（非 ink 恒为 1）
 * @property page 跳转页号；ink 汇总行仅在「全部同页」时有值，跨页为 `null`
 */
internal data class AnnotationRow(
    val id: String,
    val kind: String,
    val title: String,
    val subtitle: String = "",
    val pending: Boolean = false,
    val count: Int = 1,
    val page: Int? = null,
)

/**
 * 一个分组：分组标题 + 该组内的行。
 *
 * @property kind 分组种类（`note` / `highlight` / `ink`，或「其它」组的 [AnnotationGrouping.KIND_OTHER]）
 * @property title 分组标题（「便签」「高亮」「手写」「其它」）
 * @property rows 组内行（保持输入顺序；空组的组本身不会出现）
 */
internal data class AnnotationGroup(
    val kind: String,
    val title: String,
    val rows: List<AnnotationRow>,
)

/** 返回键的三态动作（优先级见 [AnnotationGrouping.backKeyAction]）。 */
internal enum class BackKeyAction {
    /** 抽屉开着：只关抽屉，不动工具栏。 */
    CloseDrawer,

    /** 抽屉未开、工具栏可见：隐藏工具栏（沉浸阅读）。 */
    HideChrome,

    /** 抽屉未开、工具栏已隐藏：交还系统返回（退出页面）。 */
    SystemBack,
}

/**
 * 批注分组与返回键判定的纯函数集合。
 *
 * 与 M10.9 目录抽屉同构：纯函数拆成独立文件（[TocRow] / [TocFlatten] 的范式），
 * 让「分组/文案/按键优先级」可 JVM 单测，UI 只做装配。
 */
internal object AnnotationGrouping {

    /** `kind` 取值：页级便签——无选中几何，`text` 必填。 */
    const val KIND_NOTE = "note"

    /** `kind` 取值：选中原文的标记（`text` 可空，写备注不改 kind）。 */
    const val KIND_HIGHLIGHT = "highlight"

    /** `kind` 取值：手写笔迹（一笔一条，默认折叠）。 */
    const val KIND_INK = "ink"

    /** 「其它」分组的占位 kind（行内仍保留原始 kind）。 */
    const val KIND_OTHER = "other"

    /** 分组标题：便签。 */
    const val TITLE_NOTE = "便签"

    /** 分组标题：高亮。 */
    const val TITLE_HIGHLIGHT = "高亮"

    /** 分组标题：手写。 */
    const val TITLE_INK = "手写"

    /** 分组标题：其它（未知 kind）。 */
    const val TITLE_OTHER = "其它"

    /** 标题/副标题的显示上限（字符数，含省略号）；超出按 [truncate] 截断。 */
    const val MAX_TEXT = 80

    /** 截断追加的省略号。 */
    const val ELLIPSIS = "…"

    /** 待同步标记文案（未同步为 `null` 而不是空串，见 [pendingLabel]）。 */
    const val PENDING_LABEL = "[待同步]"

    /** ink 折叠汇总行的固定 id（不指向任何 store 记录，**不可用于删除**）。 */
    const val INK_SUMMARY_ID = "ink:summary"

    /**
     * 按 `kind` 分组并产出渲染行。
     *
     * 分组顺序固定为「便签 → 高亮 → 手写 → 其它」，空组不出现；组内保持输入顺序。
     * 空输入返回空列表（不抛异常）。
     *
     * @param items 待分组的批注（调用方已从 store 映射成中性条目）
     * @param currentPage 当前阅读页（PDF 1-based；EPUB 传 `null`）：仅用于决定 ink 汇总行
     *   用「本页 N 处手写」还是「共 N 处手写」
     */
    fun group(items: List<AnnotationItem>, currentPage: Int? = null): List<AnnotationGroup> {
        if (items.isEmpty()) return emptyList()
        val groups = ArrayList<AnnotationGroup>(4)
        textGroup(KIND_NOTE, TITLE_NOTE, items)?.let(groups::add)
        textGroup(KIND_HIGHLIGHT, TITLE_HIGHLIGHT, items)?.let(groups::add)
        inkGroup(items, currentPage)?.let(groups::add)
        otherGroup(items)?.let(groups::add)
        return groups
    }

    /**
     * [group] 的扁平化便捷入口：需要「一个 ListAdapter 渲染全部行」时用它。
     *
     * 分组信息（`AnnotationGroup.title`）在此丢失，只保留行——分组标题请直接用 [group]。
     */
    fun rows(items: List<AnnotationItem>, currentPage: Int? = null): List<AnnotationRow> =
        group(items, currentPage).flatMap { it.rows }

    /**
     * 新建批注时的 `kind` 归属（**两维正交**：kind 只表类型，备注由 `text` 表达）。
     *
     * - 有任何选中原文 → [KIND_HIGHLIGHT]，**无论是否填了备注**（备注只写 `text`）；
     * - 没有选中原文（页级纯备注）→ [KIND_NOTE]。
     *
     * @param hasSelectedText 是否选中了正文文本
     * @param hasNote 是否填写了备注——**有意不参与判定**：备注是内容维度，不是类型维度；
     *   保留该参数是为了让「填了备注仍是 highlight」这条不变量在调用点与单测里都显式可见
     */
    @Suppress("UNUSED_PARAMETER")
    fun kindForSelection(hasSelectedText: Boolean, hasNote: Boolean = false): String =
        if (hasSelectedText) KIND_HIGHLIGHT else KIND_NOTE

    /**
     * 待同步标记：`dirty=true` 返回 [PENDING_LABEL]，否则返回 `null`。
     *
     * 返回 `null` 而不是空串，强制调用方在渲染层显式判空（避免「空串占位」导致布局跳动）。
     */
    fun pendingLabel(dirty: Boolean): String? = if (dirty) PENDING_LABEL else null

    /**
     * 返回键动作的三态优先级：抽屉开 → 关抽屉；否则工具栏可见 → 隐藏工具栏；否则交还系统。
     *
     * 与 M10.9 目录抽屉的按键优先级一致（抽屉是模态层，必须先关）。
     */
    fun backKeyAction(drawerOpen: Boolean, chromeVisible: Boolean): BackKeyAction = when {
        drawerOpen -> BackKeyAction.CloseDrawer
        chromeVisible -> BackKeyAction.HideChrome
        else -> BackKeyAction.SystemBack
    }

    /**
     * 长度截断：`limit` 是**结果上限**（含省略号）。
     *
     * - `text.length <= limit` → 原样返回（不追加省略号）
     * - 超长 → 保留前 `limit - 1` 个字符 + [ELLIPSIS]，结果长度恰为 `limit`
     * - `limit <= 0` → 空串（防御调用方传错）
     */
    fun truncate(text: String, limit: Int = MAX_TEXT): String {
        if (limit <= 0) return ""
        if (text.length <= limit) return text
        return text.take(limit - 1) + ELLIPSIS
    }

    /** 某一已知 kind 的「每条一行」分组；该 kind 无条目时返回 `null`。 */
    private fun textGroup(kind: String, title: String, items: List<AnnotationItem>): AnnotationGroup? {
        val rows = items.filter { it.kind == kind }.map(::singleRow)
        return if (rows.isEmpty()) null else AnnotationGroup(kind = kind, title = title, rows = rows)
    }

    /** 未知 kind 一律归入「其它」组：每行保留原始 `kind`/`id`，条目不丢。 */
    private fun otherGroup(items: List<AnnotationItem>): AnnotationGroup? {
        val known = setOf(KIND_NOTE, KIND_HIGHLIGHT, KIND_INK)
        val rows = items.filter { it.kind !in known }.map(::singleRow)
        return if (rows.isEmpty()) null else AnnotationGroup(kind = KIND_OTHER, title = TITLE_OTHER, rows = rows)
    }

    /** 单条批注 → 一行：标题优先备注，无备注时退回选中原文；副标题只在「有备注」时放原文。 */
    private fun singleRow(item: AnnotationItem): AnnotationRow {
        val note = truncate(item.note.trim())
        val selected = truncate(item.selectedText.trim())
        return AnnotationRow(
            id = item.id,
            kind = item.kind,
            title = note.ifBlank { selected },
            subtitle = if (note.isBlank()) "" else selected,
            pending = item.pending,
            count = 1,
            page = item.page,
        )
    }

    /**
     * ink 折叠为**一条**汇总行。
     *
     * 页号：`inkItems.map { it.page }.distinct().singleOrNull()` —— 只有「所有手写都给出页号且
     * 完全一致」时才得到非 null 的 `page`（行内带 `page`，可跳转）；跨页、或任一条缺页号
     * （`page == null`）时 `page = null`，该汇总行不可跳转。
     *
     * 文案与页号是两件事，只由「所有手写是否同页且该页就是当前页」决定：
     * - `page != null` 且等于 [currentPage] → 「本页 N 处手写」
     * - 其余（跨页 / 无页信息 / 同页但不是当前页）→ 「共 N 处手写」
     * 因此「同页但不是当前页」的汇总行**仍带页号**（可跳转），只是文案用「共」。
     *
     * `pending` 取「任一笔未同步」——汇总行代表整组，只显示一个标记即可。
     */
    private fun inkGroup(items: List<AnnotationItem>, currentPage: Int?): AnnotationGroup? {
        val inkItems = items.filter { it.kind == KIND_INK }
        if (inkItems.isEmpty()) return null
        // 全部同页才拿到非空页号；跨页或含 null 页号时为 null
        val page = inkItems.map { it.page }.distinct().singleOrNull()
        val onCurrentPage = page != null && currentPage != null && page == currentPage
        val title = if (onCurrentPage) {
            "本页 ${inkItems.size} 处手写"
        } else {
            "共 ${inkItems.size} 处手写"
        }
        val row = AnnotationRow(
            id = INK_SUMMARY_ID,
            kind = KIND_INK,
            title = title,
            subtitle = "",
            pending = inkItems.any { it.pending },
            count = inkItems.size,
            page = page,
        )
        return AnnotationGroup(kind = KIND_INK, title = TITLE_INK, rows = listOf(row))
    }
}
