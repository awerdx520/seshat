package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [TapZone] 的纯 JVM 单测（无 Android 依赖、无 Robolectric）。
 *
 * 守的不变量：三段区间的边界归属（左区左闭右开、右区左开右闭、中间区闭区间）、
 * 越界归一化、`NaN` 兜底，以及「PREV → TOGGLE → NEXT」不回头的单调性。
 */
class TapZoneTest {

    @Test
    fun leftZoneBeforeEdge() {
        // 最左端（0%）必须翻上一屏，否则左侧点击区从第一像素起就失效。
        assertEquals(TapZone.Zone.PREV, TapZone.zone(0.0f))
    }

    @Test
    fun leftZoneJustBeforeEdge() {
        // 左区是左闭右开 [0, 0.25)：0.249 仍在左区内。
        assertEquals(TapZone.Zone.PREV, TapZone.zone(0.249f))
    }

    @Test
    fun leftEdgeIsToggle() {
        // 边界点归中间区：否则 25% 处点击会「擦边」翻页，用户想切浮层却翻了屏。
        assertEquals(TapZone.Zone.TOGGLE, TapZone.zone(0.25f))
    }

    @Test
    fun middleIsToggle() {
        // 屏幕正中是切换浮层的唯一安全区，必须稳定落在 TOGGLE。
        assertEquals(TapZone.Zone.TOGGLE, TapZone.zone(0.5f))
    }

    @Test
    fun rightEdgeIsToggle() {
        // 边界点归中间区：75% 处同样是 TOGGLE（与 leftEdge 对称）。
        assertEquals(TapZone.Zone.TOGGLE, TapZone.zone(0.75f))
    }

    @Test
    fun rightZoneJustAfterEdge() {
        // 右区是左开右闭 (0.75, 1]：0.751 已进入右区。
        assertEquals(TapZone.Zone.NEXT, TapZone.zone(0.751f))
    }

    @Test
    fun rightZoneAtOne() {
        // 最右端（100%）必须翻下一屏，右闭区间包含 1.0。
        assertEquals(TapZone.Zone.NEXT, TapZone.zone(1.0f))
    }

    @Test
    fun negativeClampedToPrev() {
        // 越界负值（布局/滚动竞态）归一化到 0，仍应是最左区而非误判为中间区。
        assertEquals(TapZone.Zone.PREV, TapZone.zone(-0.5f))
    }

    @Test
    fun aboveOneClampedToNext() {
        // 越界大于 1 归一化到 1，仍应是最右区。
        assertEquals(TapZone.Zone.NEXT, TapZone.zone(1.5f))
    }

    @Test
    fun nanFallsBackToToggle() {
        // NaN（0/0 之类的宽度为 0 除法）不能让点击「无处可去」，一律兜底为切换浮层。
        assertEquals(TapZone.Zone.TOGGLE, TapZone.zone(Float.NaN))
    }

    @Test
    fun customEdgesRespected() {
        // 自定义边界要真正生效：0.5 < leftEdge=0.6 属左区，不能被默认的 0.25 抢走。
        assertEquals(TapZone.Zone.PREV, TapZone.zone(0.5f, leftEdge = 0.6f, rightEdge = 0.9f))
        // 自定义中间区同样为闭区间：右边界 0.9 归 TOGGLE，0.91 才进右区。
        assertEquals(TapZone.Zone.TOGGLE, TapZone.zone(0.9f, leftEdge = 0.6f, rightEdge = 0.9f))
        assertEquals(TapZone.Zone.NEXT, TapZone.zone(0.91f, leftEdge = 0.6f, rightEdge = 0.9f))
    }

    @Test
    fun zonesAreMonotonic() {
        // 从左到右遍历时分区只能「不回头的递进」：PREV* → TOGGLE* → NEXT*，
        // 一旦回头说明边界判定有洞（例如中间区被切碎），点击行为会突跳。
        val zones = (0..20).map { i -> TapZone.zone(i * 0.05f) }
        assertEquals(TapZone.Zone.PREV, zones.first())
        assertEquals(TapZone.Zone.NEXT, zones.last())
        assertTrue(zones.contains(TapZone.Zone.TOGGLE))
        zones.zipWithNext { a, b -> assertTrue("$a -> $b 分区倒退", a.ordinal <= b.ordinal) }
    }

    @Test
    fun evenThirdsMatchExpectation() {
        // 三段各取一点：左 10% 翻上一屏、正中 50% 切浮层、右 90% 翻下一屏。
        // 这条用例守的是「整条链路的三段语义」，防止默认边界被误改成其它比例。
        assertEquals(TapZone.Zone.PREV, TapZone.zone(0.1f))
        assertEquals(TapZone.Zone.TOGGLE, TapZone.zone(0.5f))
        assertEquals(TapZone.Zone.NEXT, TapZone.zone(0.9f))
    }

    @Test
    fun tinyNegativeIsPrev() {
        // 极小的负值（浮点误差导致的越界）不能因为「差的远不够」被当成中间区。
        assertEquals(TapZone.Zone.PREV, TapZone.zone(-0.0001f))
    }

    @Test
    fun tinyAboveOneIsNext() {
        // 极小的大于 1 的越界值（同理）必须归到最右区，否则右边缘点击会失灵。
        assertEquals(TapZone.Zone.NEXT, TapZone.zone(1.0001f))
    }
}
