package com.seshat.app.reader

/** 阅读器滚动视口的进度锚点：第 [position] 项 + 项内已滚出的像素 [offset]。 */
data class ScrollAnchor(val position: Int, val offset: Int)

/** 可见项的垂直范围（像素，相对 RecyclerView 视口；`top` 可为负）。 */
data class ItemBounds(val position: Int, val top: Int, val bottom: Int)

/**
 * 阅读器「可见位置 ↔ 进度锚点」的换算（纯逻辑，无 Android 依赖，可 JVM 单测）。
 *
 * 用途：竖向连续滚动模式下，RecyclerView 只给出「首个可见项位置 + 该项顶部的 y 坐标」，
 * 需要换算出跨模式一致的 `(position, offset)` 语义（PDF 为页码；EPUB 为章节 + 章内偏移）。
 */
object ScrollProgressMath {

    /**
     * 由视口信息换算进度锚点。
     *
     * @param visiblePosition 首个可见项的位置（`findFirstVisibleItemPosition()`）。
     * @param itemTop 首个可见项顶部相对视口顶部的 y 坐标（`findViewByPosition(...).top`，向上滚出时为负）。
     * @param previousItemHeight 上一项的高度（`itemTop > 0` 时用于把偏移算回上一项）；未知时传 0。
     */
    fun progressFromViewport(
        visiblePosition: Int,
        itemTop: Int,
        previousItemHeight: Int,
    ): ScrollAnchor {
        if (visiblePosition <= 0) {
            return ScrollAnchor(0, (-itemTop).coerceAtLeast(0))
        }
        if (itemTop > 0) {
            // 防御性分支：真实 RecyclerView 布局下「首个可见项 top > 0」意味着上一项仍在视口内，
            // findFirstVisibleItemPosition() 通常已返回上一项，故此分支极少触发；保留以便
            // 布局异常或自定义 LayoutManager 时仍能给出合理锚点。
            return ScrollAnchor(
                position = visiblePosition - 1,
                // 上一项末尾到视口顶部的距离 = 上一项高度 - 上一项露出的 top
                offset = (previousItemHeight - itemTop).coerceAtLeast(0),
            )
        }
        return ScrollAnchor(visiblePosition, (-itemTop).coerceAtLeast(0))
    }

    /** 由进度锚点还原 `scrollToPositionWithOffset` 需要的 offset（负值表示项顶在视口上方）。 */
    fun itemOffsetFor(anchor: ScrollAnchor): Int = -anchor.offset.coerceAtLeast(0)

    /**
     * 取覆盖视口中心点的项。
     *
     * 竖向连续滚动时通常有多个项同屏（尤其短章/短页），此时「当前项」应是用户视线中心所在那项，
     * 而不是 [androidx.recyclerview.widget.LinearLayoutManager.findFirstVisibleItemPosition]（那只是顶部项）。
     *
     * 区间采用**半开区间** `[top, bottom)`：中心点恰好落在两项交界时归入下一项，符合「继续向下滚动」的直觉。
     *
     * @param items 当前可见项的垂直范围（按 position 升序）。
     * @param viewportCenter 视口中心点的 y 坐标（通常为 RecyclerView 高度的一半）。
     * @return 覆盖中心点的项位置；中心点落在所有项之外时返回距离最近的项；空列表返回 `null`。
     */
    fun visibleCenterPosition(items: List<ItemBounds>, viewportCenter: Int): Int? {
        if (items.isEmpty()) return null
        items.firstOrNull { viewportCenter >= it.top && viewportCenter < it.bottom }?.let {
            return it.position
        }
        return items.minByOrNull { item ->
            when {
                viewportCenter < item.top -> item.top - viewportCenter
                viewportCenter >= item.bottom -> viewportCenter - item.bottom
                else -> 0
            }
        }?.position
    }
}
