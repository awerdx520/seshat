package com.seshat.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** [MainTab] 的恢复与索引映射测试：保证进程重建后 tab 能稳定还原。 */
class MainTabTest {

    @Test
    fun restoreWithNullReturnsNotes() {
        assertEquals(MainTab.NOTES, MainTab.restore(null))
    }

    @Test
    fun restoreWithZeroReturnsNotes() {
        assertEquals(MainTab.NOTES, MainTab.restore(0))
    }

    @Test
    fun restoreWithOneReturnsReader() {
        assertEquals(MainTab.READER, MainTab.restore(1))
    }

    @Test
    fun restoreWithOutOfRangeReturnsNotes() {
        assertEquals(MainTab.NOTES, MainTab.restore(2))
    }

    @Test
    fun restoreWithNegativeReturnsNotes() {
        assertEquals(MainTab.NOTES, MainTab.restore(-1))
    }

    @Test
    fun indexOfMatchesRestore() {
        assertEquals(0, MainTab.indexOf(MainTab.NOTES))
        assertEquals(1, MainTab.indexOf(MainTab.READER))
    }
}
