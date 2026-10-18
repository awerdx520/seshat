package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [ChapterSeekMath] 的纯 JVM 单测（无 Android 依赖）。
 *
 * 覆盖四类语义：
 * 1. 章数 → `SeekBar.max`：0 章与 1 章都退化为 0（不可拖动），多章为 `count - 1`；
 * 2. 章序号 → 进度、进度 → 章序号：两端夹紧（含越界上下）；
 * 3. 往返一致：`indexOf(progressOf(i)) == i`；
 * 4. 用户手输章号（1-based）→ 章序号（0-based）：trim、非数字、≤0、超 `Int` 范围返回 null；
 *    数值合法（含全角数字，`toIntOrNull()` 经 `Character.digit` 接受）但超出章节上限时夹紧到最后一章。
 */
class ChapterSeekMathTest {

    @Test
    fun maxForDegeneratesToZeroWhenNoOrSingleChapter() {
        assertEquals(0, ChapterSeekMath.maxFor(0))
        assertEquals(0, ChapterSeekMath.maxFor(1))
        // 负数章数（异常输入）同样退化为 0，不产生负 max（SeekBar.max 为负会抛异常）
        assertEquals(0, ChapterSeekMath.maxFor(-3))
    }

    @Test
    fun maxForIsLastIndexForMultipleChapters() {
        assertEquals(9, ChapterSeekMath.maxFor(10))
        assertEquals(1, ChapterSeekMath.maxFor(2))
    }

    @Test
    fun progressOfClampsBothEnds() {
        assertEquals(0, ChapterSeekMath.progressOf(0, 10))
        assertEquals(9, ChapterSeekMath.progressOf(9, 10))
        // 越界：上夹紧到 max，下夹紧到 0
        assertEquals(9, ChapterSeekMath.progressOf(42, 10))
        assertEquals(0, ChapterSeekMath.progressOf(-5, 10))
        // 无章/单章：进度恒为 0
        assertEquals(0, ChapterSeekMath.progressOf(3, 0))
        assertEquals(0, ChapterSeekMath.progressOf(0, 1))
    }

    @Test
    fun indexOfClampsBothEnds() {
        assertEquals(0, ChapterSeekMath.indexOf(0, 10))
        assertEquals(9, ChapterSeekMath.indexOf(9, 10))
        assertEquals(9, ChapterSeekMath.indexOf(99, 10))
        assertEquals(0, ChapterSeekMath.indexOf(-1, 10))
        // 无章：任何进度都落到 0（调用方会先判 chapterCount == 0 再跳转）
        assertEquals(0, ChapterSeekMath.indexOf(5, 0))
    }

    @Test
    fun progressRoundTripIsIdentityForAllValidChapters() {
        val count = 7
        for (i in 0 until count) {
            assertEquals(i, ChapterSeekMath.indexOf(ChapterSeekMath.progressOf(i, count), count))
        }
    }

    @Test
    fun indexFromUserInputAcceptsValidOneBasedNumber() {
        assertEquals(2, ChapterSeekMath.indexFromUserInput("3", 10))
        // 首章与末章（含 1-based 末章）
        assertEquals(0, ChapterSeekMath.indexFromUserInput("1", 10))
        assertEquals(9, ChapterSeekMath.indexFromUserInput("10", 10))
    }

    @Test
    fun indexFromUserInputTrimsWhitespace() {
        assertEquals(1, ChapterSeekMath.indexFromUserInput(" 2 ", 10))
        assertEquals(0, ChapterSeekMath.indexFromUserInput("\t1\n", 10))
    }

    @Test
    fun indexFromUserInputRejectsInvalidInput() {
        assertNull(ChapterSeekMath.indexFromUserInput("0", 10))
        assertNull(ChapterSeekMath.indexFromUserInput("-3", 10))
        assertNull(ChapterSeekMath.indexFromUserInput("abc", 10))
        assertNull(ChapterSeekMath.indexFromUserInput("", 10))
        assertNull(ChapterSeekMath.indexFromUserInput("   ", 10))
        assertNull(ChapterSeekMath.indexFromUserInput(null, 10))
        // 无章时任何输入都无效
        assertNull(ChapterSeekMath.indexFromUserInput("1", 0))
    }

    @Test
    fun indexFromUserInputClampsOverflowToLastChapter() {
        assertEquals(9, ChapterSeekMath.indexFromUserInput("99", 10))
        // 单章时只有「第 1 章」合法，且夹紧到序号 0
        assertEquals(0, ChapterSeekMath.indexFromUserInput("1", 1))
        assertEquals(0, ChapterSeekMath.indexFromUserInput("5", 1))
    }

    @Test
    fun indexFromUserInputRejectsNumberBeyondIntRange() {
        // 超 Int 范围：toIntOrNull 返回 null，按无效处理（不夹紧、不崩溃）
        assertNull(ChapterSeekMath.indexFromUserInput("99999999999999999999", 10))
        // 恰好越界一格的边界值同样无效
        assertNull(ChapterSeekMath.indexFromUserInput("2147483648", 10))
    }

    @Test
    fun indexFromUserInputTreatsFullWidthDigitsAsAsciiValue() {
        // 实测：`toIntOrNull()` 内部用 `Character.digit`，**接受**全角数字（U+FF13 → 3），
        // 故全角输入按有效值处理（`"３"` = 3 → 序号 2），与半角等价。
        assertEquals(2, ChapterSeekMath.indexFromUserInput("３", 10))
        assertEquals(9, ChapterSeekMath.indexFromUserInput("１０", 10))
    }

    @Test
    fun indexFromUserInputRejectsNegativeNumber() {
        // 负号虽可被 toIntOrNull 识别，但 ≤ 0 一律无效（不夹紧到第 1 章）
        assertNull(ChapterSeekMath.indexFromUserInput("-1", 10))
        assertNull(ChapterSeekMath.indexFromUserInput("-0", 10))
    }
}
