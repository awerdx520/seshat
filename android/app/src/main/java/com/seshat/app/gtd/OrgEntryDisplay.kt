package com.seshat.app.gtd

import android.graphics.Color

/**
 * 条目展示的公共格式化逻辑（TODO 状态徽标配色、标签文本）。
 *
 * 抽出的原因：[GtdEntryAdapter] 与 `NotesListAdapter` 都需要一致的徽标配色与标签写法，
 * 集中在此处避免颜色表出现两份副本（改色只需改一处）。
 *
 * 说明：`android.graphics.Color.parseColor` 依赖 Android 运行时，故本对象不参与纯 JVM 单元测试。
 */
internal object OrgEntryDisplay {

    /** 进行中状态（TODO/NEXT/STARTED/WAITING/HOLD 等）徽标底色。 */
    val COLOR_ACTIVE: Int = Color.parseColor("#1565C0")

    /** 已完成状态徽标底色。 */
    val COLOR_DONE: Int = Color.parseColor("#2E7D32")

    /** 已取消状态徽标底色。 */
    val COLOR_CANCELLED: Int = Color.parseColor("#757575")

    private const val STATE_DONE = "DONE"
    private const val STATE_CANCELLED = "CANCELLED"

    /**
     * 按 TODO 状态返回徽标底色。
     *
     * @param state TODO 关键字；`null` 不会调用本函数（无状态时调用方直接隐藏徽标）。
     */
    fun badgeColor(state: String?): Int = when (state) {
        STATE_DONE -> COLOR_DONE
        STATE_CANCELLED -> COLOR_CANCELLED
        else -> COLOR_ACTIVE
    }

    /**
     * 标签列表 → org 风格标签文本（形如 `:a:b:`）；空列表返回 `null`，由调用方隐藏视图。
     */
    fun tagText(tags: List<String>): String? =
        if (tags.isEmpty()) null
        else tags.joinToString(separator = ":", prefix = ":", postfix = ":")

    /**
     * 正文摘要：取正文中第一个非空行并 trim；无可用行返回 `null`，由调用方隐藏视图。
     */
    fun summaryOf(body: String): String? =
        body.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
}
