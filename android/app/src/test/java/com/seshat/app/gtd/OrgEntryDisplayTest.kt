package com.seshat.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [OrgEntryDisplay.summaryOf] 的纯 JVM 单测（M10.6 B4 真机验收缺陷 1）。
 *
 * 覆盖「第一个非计划行、非属性块行」规则的各条分支：planning 行、属性抽屉、
 * CRLF、纯空白、多行正文与「全部被跳过」。
 */
class OrgEntryDisplayTest {

    @Test
    fun summaryOf_skipsPlanningLine_returnsBody() {
        // 真机现象原样复现：DEADLINE 行在前，正文在后
        assertEquals(
            "正文描述",
            OrgEntryDisplay.summaryOf("   DEADLINE: <2026-10-20 Tue>\n   正文描述"),
        )
    }

    @Test
    fun summaryOf_onlyPlanningLine_returnsNull() {
        assertNull(OrgEntryDisplay.summaryOf("   SCHEDULED: <2026-10-10 Sat>"))
    }

    @Test
    fun summaryOf_skipsPropertiesDrawer_returnsBody() {
        assertEquals("正文", OrgEntryDisplay.summaryOf(":PROPERTIES:\n:ID: abc\n:END:\n正文"))
    }

    @Test
    fun summaryOf_blankBody_returnsNull() {
        assertNull(OrgEntryDisplay.summaryOf(""))
        assertNull(OrgEntryDisplay.summaryOf("   \n\t\n  "))
    }

    @Test
    fun summaryOf_multiLineBody_returnsFirstLine() {
        assertEquals("正文第一行", OrgEntryDisplay.summaryOf("正文第一行\n正文第二行"))
    }

    @Test
    fun summaryOf_crlfBody_hasNoCarriageReturn() {
        val summary = OrgEntryDisplay.summaryOf("   DEADLINE: <2026-10-20 Tue>\r\n正文\r\n")

        assertEquals("正文", summary)
        assertFalse("摘要不应残留 \\r", summary!!.contains('\r'))
    }

    @Test
    fun summaryOf_allPlanningKinds_returnsNull() {
        assertNull(
            OrgEntryDisplay.summaryOf(
                "DEADLINE: <2026-10-20 Tue>\nSCHEDULED: <2026-10-19 Mon>\nCLOSED: [2026-10-21 Wed]",
            ),
        )
    }

    @Test
    fun summaryOf_bareDrawerLinesOutsidePropertiesBlock_areSkipped() {
        assertEquals("正文", OrgEntryDisplay.summaryOf(":ID: abc\n:CREATED: [2026-10-18]\n正文"))
    }
}
