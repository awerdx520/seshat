package com.seshat.app.reader

/**
 * 章节序号与 `SeekBar` 进度（0-based，含两端）的双向换算与夹紧。
 *
 * 为什么单独抽成纯逻辑类：`SeekBar` 只接受 `0..max` 的整数进度，而章序号来自
 * `book.chapters`，两者在「0 章 / 1 章 / 越界」三种边界上语义不同（`max` 不能为负，
 * 1 章时不可拖动）。把这些夹紧规则放在无 Android 依赖的类里，可用 JVM 单测覆盖边界，
 * Activity 侧只剩「取值 → 调用 → 应用」三步。
 *
 * 同一套换算也用于 PDF 页码（M10.6 B2d）：页数与章数同构——`pageCount` 对应 `chapterCount`、
 * 最大页索引与 `maxFor` 一致，故 PDF 侧只做参数映射，不另写一份夹紧逻辑。
 */
internal object ChapterSeekMath {

    /** 章数 → `SeekBar.max`（0 章/1 章时为 0；`SeekBar.max` 为负会抛异常，故下界夹到 0）。 */
    fun maxFor(chapterCount: Int): Int = (chapterCount - 1).coerceAtLeast(0)

    /** 章序号 → `SeekBar` 进度（夹紧到 `[0, maxFor(chapterCount)]`）。 */
    fun progressOf(index: Int, chapterCount: Int): Int =
        index.coerceIn(0, maxFor(chapterCount))

    /** `SeekBar` 进度 → 章序号（夹紧到 `[0, maxFor(chapterCount)]`）。 */
    fun indexOf(progress: Int, chapterCount: Int): Int =
        progress.coerceIn(0, maxFor(chapterCount))

    /**
     * 用户输入的 1-based 章号 → 0-based 章序号。
     *
     * 语义边界：
     * - **超 `Int` 范围按无效处理（不夹紧）**：无法安全换算成章序号，返回 `null`；
     * - 全角数字（如 `"３"`）经 `toIntOrNull()` 内部的 `Character.digit` 会识别为等值 ASCII
     *   数字，故按**有效值**处理（`"３"` = `3` → 序号 2），与半角输入等价；
     * - 数值合法但超出章节上限 → 夹紧到最后一章。
     *
     * @return 非法输入（空白 / 非数字 / ≤ 0 / 超 `Int` 范围）或无章节时返回 `null`；
     *   超出章节上限夹紧到最后一章。
     */
    fun indexFromUserInput(raw: String?, chapterCount: Int): Int? {
        if (chapterCount <= 0) return null
        val trimmed = raw?.trim()
        if (trimmed.isNullOrEmpty()) return null
        val oneBased = trimmed.toIntOrNull() ?: return null
        if (oneBased <= 0) return null
        return (oneBased - 1).coerceIn(0, maxFor(chapterCount))
    }
}
