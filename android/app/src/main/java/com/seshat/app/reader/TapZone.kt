package com.seshat.app.reader

/**
 * 点击分区判定（纯函数，无 Android 依赖）。
 *
 * 阅读器把可见宽度按比例切成三段：左侧 [PREV] 区、中间 [TOGGLE] 区、右侧 [NEXT] 区。
 * 竖向模式左侧向上翻一屏、右侧向下翻一屏；横向模式左侧/右侧翻章；中间一律切换浮层显隐。
 *
 * 抽成纯函数是为了能在纯 JVM 单测里覆盖边界（`RecyclerView` 的点击回调本身不可单测）。
 */
internal object TapZone {
    /** 点击落在哪个区。 */
    enum class Zone { PREV, TOGGLE, NEXT }

    /**
     * 按水平位置比例判定分区。
     *
     * @param fraction 点击位置占可见宽度的比例，`0f` 为最左、`1f` 为最右；
     *   越界值（负值 / 大于 1）按 [coerceIn] 归一化；`NaN` 视为中间区（安全兜底）。
     * @param leftEdge 左区右边界（含该点归中间区即左闭右开语义见下），默认 0.25
     * @param rightEdge 右区左边界，默认 0.75
     * @return 分区：`fraction < leftEdge` → [Zone.PREV]；`fraction > rightEdge` → [Zone.NEXT]；
     *   其余（含恰好等于 [leftEdge]/[rightEdge]）→ [Zone.TOGGLE]
     */
    fun zone(fraction: Float, leftEdge: Float = 0.25f, rightEdge: Float = 0.75f): Zone {
        // NaN 与任何数比较都为 false，若不提前拦截会一路落到「中间区」——这里显式兜底，语义清晰。
        if (fraction.isNaN()) return Zone.TOGGLE
        // 触摸点理论上恒在 [0, width] 内，但滚动/布局竞态下可能越界，先归一化再判定。
        val f = fraction.coerceIn(0f, 1f)
        return when {
            // 左区为左闭右开 [0, leftEdge)：边界点归中间区，避免 25% 处「擦边」翻页。
            f < leftEdge -> Zone.PREV
            // 右区为左开右闭 (rightEdge, 1]：同理，75% 处归中间区。
            f > rightEdge -> Zone.NEXT
            // 中间区为闭区间 [leftEdge, rightEdge]。
            else -> Zone.TOGGLE
        }
    }
}
