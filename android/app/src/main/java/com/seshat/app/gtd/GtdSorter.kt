package com.seshat.app.gtd

import java.time.LocalDate

/**
 * Agenda 排序（与 [GtdFilter] 的过滤职责分离，纯 JVM 逻辑，不依赖 Android 框架）。
 *
 * 所有排序均使用 `sortedWith`（稳定排序），同键条目保持输入顺序。
 * 参与比较的键是 [datePrefix] 归一化后的 ISO 日期字符串，可直接按字典序比较。
 */
internal object GtdSorter {

    /** 按 scheduled 升序；无 scheduled（或无法解析）的置后。 */
    fun byScheduled(entries: List<OrgEntry>): List<OrgEntry> =
        entries.sortedWith(
            compareBy<OrgEntry, String?>(nullsLast()) { datePrefix(it.scheduled) },
        )

    /** 按 deadline 升序；无 deadline（或无法解析）的置后。 */
    fun byDeadline(entries: List<OrgEntry>): List<OrgEntry> =
        entries.sortedWith(
            compareBy<OrgEntry, String?>(nullsLast()) { datePrefix(it.deadline) },
        )

    /** 按「最早日期」（scheduled 与 deadline 取较早者）升序；两者都无的置后。 */
    fun byEarliestDate(entries: List<OrgEntry>): List<OrgEntry> =
        entries.sortedWith(
            compareBy<OrgEntry, String?>(nullsLast()) { entry ->
                listOfNotNull(datePrefix(entry.scheduled), datePrefix(entry.deadline)).minOrNull()
            },
        )

    /**
     * 从形如 `<2026-10-20 Tue>` / `<2026-10-20 Tue 10:00>` / `2026-10-20` 的原文中取日期。
     *
     * 处理：剥离首尾空白与尖括号 → 取第一个空白前的 token → 必须是合法 `yyyy-MM-dd`
     * （`LocalDate.parse` 会拒绝非零填充的 `2026-1-5` 与越界月份/日期）。
     *
     * @return 零填充的 ISO 日期字符串（如 `2026-10-20`），可直接字典序比较；非法/缺失返回 `null`。
     */
    fun datePrefix(raw: String?): String? {
        val text = raw?.trim()?.trim('<', '>')?.trim() ?: return null
        val token = text.takeWhile { !it.isWhitespace() }
        return runCatching { LocalDate.parse(token).toString() }.getOrNull()
    }
}
