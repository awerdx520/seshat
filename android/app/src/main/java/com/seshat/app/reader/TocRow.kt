package com.seshat.app.reader

/**
 * 目录抽屉的一行（M10.9）。
 *
 * @property title 显示文案（容器节点若标题为空，已用 `missingTitle` 占位）
 * @property targetIndex 跳转目标（EPUB 章节索引 / PDF 页索引）；**-1 表示纯容器，不可跳转**
 * @property depth 层级（0 起），渲染时缩进 `depth * 16dp`
 * @property hasChildren 是否有子节点（决定是否显示 ▸/▾）
 * @property expanded 当前是否展开（按展开集合回填，见 `TocFlatten.visibleRows`）
 * @property id 展开状态用的稳定标识——**必须对含容器节点在内的每个节点唯一**
 *   （不能用裸 href：容器节点 href 为 null 会全部撞车；同文件不同锚点去 fragment 后也会撞车）。
 *   本实现用 DFS 兄弟序号路径，如 `"0/1/2"`。
 */
internal data class TocRow(
    val title: String,
    val targetIndex: Int,
    val depth: Int,
    val hasChildren: Boolean,
    val expanded: Boolean = false,
    val id: String,
)

/**
 * 把目录树映射成行（纯函数，无 Android 依赖）。
 *
 * 只做「树 → 扁平行（保留 depth）」的转换，**不做折叠**——折叠由 `TocFlatten` 负责，
 * 这样「层级映射」与「展开状态」两类逻辑各自可单测。
 */
internal object TocRows {
    /**
     * EPUB：`tocTree` → 行。
     *
     * `TocNode.href` 已在解析层用 nav/ncx 文档目录归一化，故可直接与 `chapters[i].href` 精确比较；
     * **不要再传入 opfDir/navDir 做二次归一化**（会把 `OEBPS/x` 拼成 `OEBPS/OEBPS/x`）。
     *
     * @param missingTitle 容器节点标题为空时用它占位（Activity 传 `getString(R.string.reader_chapter_untitled)`）
     */
    fun forEpub(tree: List<TocNode>, chapters: List<EpubChapter>, missingTitle: String): List<TocRow> =
        flatten(
            nodes = tree,
            path = "",
            depth = 0,
            missingTitle = missingTitle,
            titleOf = { it.title },
            // 命中不到章节（锚点、跨文件目录、容器节点）一律 -1：不可跳转好过跳到错章节
            targetOf = { node ->
                node.href?.let { href -> chapters.indexOfFirst { it.href == href }.takeIf { it >= 0 } } ?: -1
            },
            childrenOf = { it.children },
        )

    /** EPUB 回退：`tocTree` 为空时用扁平 `chapters`，每章一行（depth = 0）。 */
    fun forEpubFlat(chapters: List<EpubChapter>, missingTitle: String): List<TocRow> =
        chapters.mapIndexed { index, chapter ->
            TocRow(
                title = chapter.title.ifBlank { missingTitle },
                targetIndex = index,
                depth = 0,
                hasChildren = false,
                id = "$index",
            )
        }

    /** PDF：`PdfOutlineItem` 树 → 行（`pageIndex` 直接作为 `targetIndex`；`-1` 视为不可跳转）。 */
    fun forPdf(tree: List<PdfOutlineReader.PdfOutlineItem>): List<TocRow> =
        flatten(
            nodes = tree,
            path = "",
            depth = 0,
            missingTitle = "",
            titleOf = { it.title },
            targetOf = { it.pageIndex },
            childrenOf = { it.children },
        )

    /**
     * 共用 DFS：先序展开 `nodes`，`id` 用「父路径 + 兄弟序号」拼接（根层为 `"0"`、`"1"`…）。
     *
     * 兄弟序号路径天然对每个节点唯一，且与标题/href 无关——容器节点（href 为 null）
     * 与「同文件不同锚点」都不会撞车。
     */
    private fun <T> flatten(
        nodes: List<T>,
        path: String,
        depth: Int,
        missingTitle: String,
        titleOf: (T) -> String,
        targetOf: (T) -> Int,
        childrenOf: (T) -> List<T>,
    ): List<TocRow> {
        val rows = ArrayList<TocRow>()
        nodes.forEachIndexed { index, node ->
            val id = if (path.isEmpty()) "$index" else "$path/$index"
            val children = childrenOf(node)
            rows.add(
                TocRow(
                    title = titleOf(node).ifBlank { missingTitle },
                    targetIndex = targetOf(node),
                    depth = depth,
                    hasChildren = children.isNotEmpty(),
                    id = id,
                )
            )
            rows.addAll(flatten(children, id, depth + 1, missingTitle, titleOf, targetOf, childrenOf))
        }
        return rows
    }
}

/**
 * 折叠/展开：按展开集合算出「当前应显示的行」（纯函数，无 Android 依赖）。
 *
 * 输入是 [TocRows] 产出的**完整 DFS 前序**行表（含所有层级），输出是折叠后的可见行。
 * 算法用「可见深度上限」单遍扫描，不需要重建树：
 * - `depth == 0` 的行总是可见，并把它决定的上限设为「已展开 ? 1 : 0」；
 * - `depth > 上限` 的行属于被折叠的子树，直接跳过；
 * - 每个可见行按集合回填 [TocRow.expanded]，供渲染决定画 ▸ 还是 ▾。
 */
internal object TocFlatten {
    /**
     * @param expanded 已展开节点的 id 集合（不在集合里的有子节点行视为折叠）
     * @return 可见行（保持原有顺序）；每行的 [TocRow.expanded] 已按集合回填
     */
    fun visibleRows(rows: List<TocRow>, expanded: Set<String>): List<TocRow> {
        val out = ArrayList<TocRow>(rows.size)
        // 当前允许出现的最大 depth；根行（depth 0）总可见
        var depthLimit = 0
        for (row in rows) {
            if (row.depth > depthLimit) continue // 落在被折叠的子树里
            val isExpanded = row.hasChildren && expanded.contains(row.id)
            out.add(row.copy(expanded = isExpanded))
            // 展开了就允许下一层；否则把上限收回到本行层级（后续兄弟及其子树按同规则判定）
            depthLimit = if (isExpanded) row.depth + 1 else row.depth
        }
        return out
    }
}
