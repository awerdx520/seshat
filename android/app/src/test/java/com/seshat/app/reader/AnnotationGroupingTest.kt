package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [AnnotationGrouping] 的纯 JVM 单测（无 Android 依赖、无 Robolectric）。
 *
 * 守的不变量：分组顺序固定、空输入不抛异常、note/highlight 每条一行且标题/副标题取舍正确、
 * ink 折叠为一条带 `count` 的汇总行且「本页/共」文案只由页号决定、未知 kind 归入「其它」但不丢条目、
 * 标题与副标题上限 80 字符（80 原样、81 截断）、返回键三态优先级、待同步标记为 `null` 而非空串。
 */
class AnnotationGroupingTest {

    // ---- 构造辅助 ----

    private fun note(
        id: String,
        note: String = "备注-$id",
        selected: String = "原文-$id",
        pending: Boolean = false,
        page: Int? = null,
    ) = AnnotationItem(
        id = id,
        kind = AnnotationGrouping.KIND_NOTE,
        note = note,
        selectedText = selected,
        page = page,
        pending = pending,
    )

    private fun highlight(
        id: String,
        selected: String = "原文-$id",
        pending: Boolean = false,
        page: Int? = null,
    ) = AnnotationItem(
        id = id,
        kind = AnnotationGrouping.KIND_HIGHLIGHT,
        selectedText = selected,
        page = page,
        pending = pending,
    )

    private fun ink(id: String, page: Int?, pending: Boolean = false) = AnnotationItem(
        id = id,
        kind = AnnotationGrouping.KIND_INK,
        page = page,
        pending = pending,
    )

    private fun kinds(groups: List<AnnotationGroup>): List<String> = groups.map { it.kind }

    private fun onlyRow(groups: List<AnnotationGroup>, kind: String): AnnotationRow =
        groups.first { it.kind == kind }.rows.single()

    // ---- ① 空列表 ----

    @Test
    fun emptyInputYieldsNoGroups() {
        // 空列表是常态（新书没有任何批注）：必须返回空分组表，不能抛异常，也不能造出空组。
        assertEquals(emptyList<AnnotationGroup>(), AnnotationGrouping.group(emptyList()))
        assertEquals(emptyList<AnnotationRow>(), AnnotationGrouping.rows(emptyList()))
        // 两种 currentPage 取值都不改变该结论
        assertEquals(emptyList<AnnotationGroup>(), AnnotationGrouping.group(emptyList(), currentPage = 7))
    }

    // ---- ② note / highlight 各成行 + 待同步标记 ----

    @Test
    fun noteAndHighlightBecomeSeparateGroupsWithPendingMark() {
        val groups = AnnotationGrouping.group(
            listOf(
                note(id = "n1", pending = true),
                highlight(id = "h1", pending = false),
            )
        )

        assertEquals(listOf(AnnotationGrouping.KIND_NOTE, AnnotationGrouping.KIND_HIGHLIGHT), kinds(groups))
        assertEquals(AnnotationGrouping.TITLE_NOTE, groups[0].title)
        assertEquals(AnnotationGrouping.TITLE_HIGHLIGHT, groups[1].title)

        val noteRow = onlyRow(groups, AnnotationGrouping.KIND_NOTE)
        assertEquals("n1", noteRow.id)
        assertEquals(1, noteRow.count)
        assertTrue("dirty 条目必须带待同步标记", noteRow.pending)
        assertEquals(AnnotationGrouping.PENDING_LABEL, AnnotationGrouping.pendingLabel(noteRow.pending))

        val highlightRow = onlyRow(groups, AnnotationGrouping.KIND_HIGHLIGHT)
        assertEquals("h1", highlightRow.id)
        assertEquals(1, highlightRow.count)
        assertTrue("未 dirty 的条目不能带标记", !highlightRow.pending)
        assertNull(AnnotationGrouping.pendingLabel(highlightRow.pending))
    }

    @Test
    fun noteRowUsesNoteAsTitleAndSelectionAsSubtitle() {
        val row = onlyRow(
            AnnotationGrouping.group(listOf(note(id = "n1", note = "我的想法", selected = "书里这句话"))),
            AnnotationGrouping.KIND_NOTE,
        )

        assertEquals("我的想法", row.title)
        assertEquals("书里这句话", row.subtitle)
    }

    @Test
    fun highlightRowUsesSelectionAsTitleWithoutSubtitle() {
        // highlight 的备注恒为空：标题退回选中原文，且不留空副标题（避免渲染出多余空行）
        val row = onlyRow(
            AnnotationGrouping.group(listOf(highlight(id = "h1", selected = "书里这句话"))),
            AnnotationGrouping.KIND_HIGHLIGHT,
        )

        assertEquals("书里这句话", row.title)
        assertEquals("", row.subtitle)
    }

    // ---- ③ ink 折叠计数 ----

    @Test
    fun inkCollapsesToSingleSummaryRowWithCount() {
        val groups = AnnotationGrouping.group(
            listOf(ink("i1", page = 3), ink("i2", page = 3), ink("i3", page = 3)),
            currentPage = 3,
        )

        assertEquals(listOf(AnnotationGrouping.KIND_INK), kinds(groups))
        val rows = groups.single().rows
        assertEquals("3 笔手写只能占一行", 1, rows.size)
        assertEquals(3, rows.single().count)
        assertEquals(AnnotationGrouping.INK_SUMMARY_ID, rows.single().id)
    }

    // ---- ④ ink 同页 / 跨页两种文案 ----

    @Test
    fun inkOnCurrentPageSaysThisPage() {
        val row = onlyRow(
            AnnotationGrouping.group(listOf(ink("i1", page = 5), ink("i2", page = 5)), currentPage = 5),
            AnnotationGrouping.KIND_INK,
        )

        assertEquals("本页 2 处手写", row.title)
        assertEquals(5, row.page) // 同页 → 汇总行可跳转
    }

    @Test
    fun inkOnSamePageButNotCurrentPageSaysTotal() {
        // 全部在第 5 页、当前在第 7 页：不能说「本页」，但页号仍可跳转
        val row = onlyRow(
            AnnotationGrouping.group(listOf(ink("i1", page = 5), ink("i2", page = 5)), currentPage = 7),
            AnnotationGrouping.KIND_INK,
        )

        assertEquals("共 2 处手写", row.title)
        assertEquals(5, row.page)
    }

    @Test
    fun inkAcrossPagesSaysTotalWithoutPage() {
        val row = onlyRow(
            AnnotationGrouping.group(listOf(ink("i1", page = 3), ink("i2", page = 4)), currentPage = 3),
            AnnotationGrouping.KIND_INK,
        )

        assertEquals("共 2 处手写", row.title)
        assertNull("跨页汇总行没有唯一跳转目标", row.page)
    }

    @Test
    fun inkWithoutCurrentPageSaysTotal() {
        // EPUB 侧没有「页」概念（currentPage = null），一律用「共」文案
        val row = onlyRow(
            AnnotationGrouping.group(listOf(ink("i1", page = null), ink("i2", page = null))),
            AnnotationGrouping.KIND_INK,
        )

        assertEquals("共 2 处手写", row.title)
        assertNull(row.page)
    }

    @Test
    fun inkPendingPropagatesToSummaryRow() {
        // 汇总行代表整组：任一笔待同步就要显示标记
        val row = onlyRow(
            AnnotationGrouping.group(listOf(ink("i1", page = 1), ink("i2", page = 1, pending = true)), currentPage = 1),
            AnnotationGrouping.KIND_INK,
        )

        assertTrue(row.pending)
    }

    // ---- ⑤ 未知 kind 归入「其它」且不丢数据 ----

    @Test
    fun unknownKindsGoToOtherGroupWithoutLosingData() {
        val groups = AnnotationGrouping.group(
            listOf(
                note(id = "n1"),
                AnnotationItem(id = "x1", kind = "bookmark", note = "书签一"),
                ink("i1", page = 1),
                AnnotationItem(id = "x2", kind = "audio", selectedText = "待念的一段"),
            ),
            currentPage = 1,
        )

        assertEquals(
            listOf(
                AnnotationGrouping.KIND_NOTE,
                AnnotationGrouping.KIND_INK,
                AnnotationGrouping.KIND_OTHER,
            ),
            kinds(groups),
        )
        val other = groups.last()
        assertEquals(AnnotationGrouping.TITLE_OTHER, other.title)
        assertEquals("两条未知 kind 各占一行，一条都不能丢", listOf("x1", "x2"), other.rows.map { it.id })
        // 行内保留原始 kind，调用方仍能据此分派跳转/删除
        assertEquals(listOf("bookmark", "audio"), other.rows.map { it.kind })
        // 未知 kind 的文案仍按「备注优先、无备注退回原文」的同一规则生成
        assertEquals("书签一", other.rows[0].title)
        assertEquals("待念的一段", other.rows[1].title)
    }

    // ---- ⑥ 截断：80 上限（80 原样 / 81 截断） ----

    @Test
    fun truncateKeepsTextAtExactlyLimit() {
        val text = "字".repeat(AnnotationGrouping.MAX_TEXT)

        assertEquals("正好 80 字符不截断、不追加省略号", text, AnnotationGrouping.truncate(text))
        // 边界内侧（79）与很短文本同样原样返回，避免「一律追加省略号」的实现蒙混过关
        assertEquals("字".repeat(AnnotationGrouping.MAX_TEXT - 1), AnnotationGrouping.truncate("字".repeat(79)))
        assertEquals("短", AnnotationGrouping.truncate("短"))
    }

    @Test
    fun truncateCutsTextOverLimitWithEllipsis() {
        val text = "字".repeat(AnnotationGrouping.MAX_TEXT + 1)
        val cut = AnnotationGrouping.truncate(text)

        assertEquals(AnnotationGrouping.MAX_TEXT, cut.length)
        assertTrue(cut.endsWith(AnnotationGrouping.ELLIPSIS))
        assertEquals(text.take(AnnotationGrouping.MAX_TEXT - 1), cut.removeSuffix(AnnotationGrouping.ELLIPSIS))
        // 上限 <= 0 的防御分支
        assertEquals("", AnnotationGrouping.truncate(text, limit = 0))
    }

    @Test
    fun longNoteAndSelectionAreTruncatedInRow() {
        val longNote = "备".repeat(200)
        val longSelection = "选".repeat(200)
        val row = onlyRow(
            AnnotationGrouping.group(listOf(note(id = "n1", note = longNote, selected = longSelection))),
            AnnotationGrouping.KIND_NOTE,
        )

        assertEquals(AnnotationGrouping.MAX_TEXT, row.title.length)
        assertEquals(AnnotationGrouping.MAX_TEXT, row.subtitle.length)
        assertEquals(longNote.take(AnnotationGrouping.MAX_TEXT - 1), row.title.removeSuffix(AnnotationGrouping.ELLIPSIS))
    }

    // ---- ⑦ backKeyAction 三态 + 边界组合 ----

    @Test
    fun backKeyActionFollowsDrawerChromePriority() {
        // 抽屉开：无论工具栏是否可见都只关抽屉（模态层优先）
        assertEquals(
            BackKeyAction.CloseDrawer,
            AnnotationGrouping.backKeyAction(drawerOpen = true, chromeVisible = true),
        )
        assertEquals(
            BackKeyAction.CloseDrawer,
            AnnotationGrouping.backKeyAction(drawerOpen = true, chromeVisible = false),
        )
        // 抽屉关、工具栏可见：隐藏工具栏
        assertEquals(
            BackKeyAction.HideChrome,
            AnnotationGrouping.backKeyAction(drawerOpen = false, chromeVisible = true),
        )
        // 抽屉关、工具栏已隐藏：交还系统返回
        assertEquals(
            BackKeyAction.SystemBack,
            AnnotationGrouping.backKeyAction(drawerOpen = false, chromeVisible = false),
        )
    }

    // ---- ⑧ pendingLabel 两态（null 而非空串） ----

    @Test
    fun pendingLabelIsNullWhenClean() {
        assertNull(AnnotationGrouping.pendingLabel(dirty = false))
        assertNotNull(AnnotationGrouping.pendingLabel(dirty = true))
        assertEquals(AnnotationGrouping.PENDING_LABEL, AnnotationGrouping.pendingLabel(dirty = true))
        assertTrue("非 dirty 必须返回 null 而不是空串", AnnotationGrouping.pendingLabel(false) == null)
    }

    // ---- 附加不变量 ----

    @Test
    fun groupOrderIsFixedRegardlessOfInputOrder() {
        // 输入乱序（ink 在前、other 在中间）→ 输出仍是「备注 → 高亮 → 手写 → 其它」
        val groups = AnnotationGrouping.group(
            listOf(
                ink("i1", page = 1),
                AnnotationItem(id = "x1", kind = "weird", note = "怪东西"),
                highlight(id = "h1"),
                note(id = "n1"),
            ),
            currentPage = 1,
        )

        assertEquals(
            listOf(
                AnnotationGrouping.KIND_NOTE,
                AnnotationGrouping.KIND_HIGHLIGHT,
                AnnotationGrouping.KIND_INK,
                AnnotationGrouping.KIND_OTHER,
            ),
            kinds(groups),
        )
        // 组内保持输入顺序
        assertEquals(listOf("n1"), groups[0].rows.map { it.id })
        assertEquals(listOf("h1"), groups[1].rows.map { it.id })
    }

    @Test
    fun rowsFlattensEveryGroupInOrder() {
        val items = listOf(
            ink("i1", page = 1),
            ink("i2", page = 1),
            note(id = "n1"),
            highlight(id = "h1"),
        )

        val rows = AnnotationGrouping.rows(items, currentPage = 1)

        // 期望顺序：note 行 → highlight 行 → ink 汇总行（一条）
        assertEquals(listOf("n1", "h1", AnnotationGrouping.INK_SUMMARY_ID), rows.map { it.id })
        assertEquals(3, rows.size)
        assertTrue(rows.all { it.title.isNotBlank() })
    }

    @Test
    fun blankFieldsYieldEmptyTitleInsteadOfCrash() {
        // 脏数据（note 与选中原文都为空）不能抛异常；标题为空串，交由 UI 决定占位
        val row = onlyRow(
            AnnotationGrouping.group(listOf(note(id = "n1", note = "  ", selected = ""))),
            AnnotationGrouping.KIND_NOTE,
        )

        assertEquals("", row.title)
        assertEquals("", row.subtitle)
    }
}
