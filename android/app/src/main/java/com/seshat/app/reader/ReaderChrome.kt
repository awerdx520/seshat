package com.seshat.app.reader

/**
 * 阅读区 padding 计算（纯函数，无 Android 依赖）。
 *
 * 浮层是 overlay（`layout_gravity` 叠在阅读区上，不占布局），因此阅读区必须按浮层的
 * **可见性 + 高度**预留 padding：可见时留出浮层高度（正文不被遮挡，且 `clipToPadding = false`
 * 让正文能延伸浮层下方），隐藏时归零（阅读区铺满整屏）。抽成纯函数是为了在纯 JVM 单测里覆盖
 * 这两条分支——`View` 的布局回调本身不可单测。
 */
internal object ReaderChrome {
    /** 阅读区需要预留的上下 padding（像素）。 */
    data class ContentPadding(val top: Int, val bottom: Int)

    /**
     * 按浮层可见性与高度算阅读区 padding。
     *
     * 不可见或高度未测量（`<= 0`）一律按 0 计：浮层 GONE 后 `View.height` 仍返回上一次
     * 测量的旧值，故必须由 [topVisible]/[bottomVisible] 决定是否计入，不能只看高度。
     */
    fun padding(
        topVisible: Boolean,
        bottomVisible: Boolean,
        topHeight: Int,
        bottomHeight: Int,
    ): ContentPadding = ContentPadding(
        top = if (topVisible && topHeight > 0) topHeight else 0,
        bottom = if (bottomVisible && bottomHeight > 0) bottomHeight else 0,
    )
}
