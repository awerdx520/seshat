package com.seshat.app.gtd

/**
 * 树节点。
 *
 * @property entry 该节点对应的原始条目。
 * @property index 在原扁平列表中的下标，作为稳定 id 使用（解析顺序不变即稳定）。
 * @property children 子节点，保持原始输入顺序。
 */
data class OrgNode(
    val entry: OrgEntry,
    val index: Int,
    val children: List<OrgNode>,
)

/**
 * 扁平化后的一行（供 RecyclerView 使用）。
 *
 * @property node 该行对应的树节点。
 * @property depth 缩进层级，0 起（根为 0）。
 * @property hasChildren 是否存在子节点（过滤视图中指「是否存在可见子节点」）。
 * @property collapsed 该行当前是否处于折叠状态（过滤视图中恒为 `false`，因为强制展开）。
 */
data class VisibleRow(
    val node: OrgNode,
    val depth: Int,
    val hasChildren: Boolean,
    val collapsed: Boolean,
)

/**
 * 扁平 → 树 的构建器，以及树 → 可见行 的扁平化（纯 JVM 逻辑，不依赖 Android 框架）。
 *
 * 层级判断一次性完成：`OrgEntry.level` 为原始星号数，树深度由祖先链计算得出，
 * 与「跳级」「首个标题层级不为 1」等不规范的 org 文档兼容。
 */
internal object OrgTreeBuilder {

    /** 构建期的可变节点（子列表可追加），最终冻结为不可变的 [OrgNode]。 */
    private class MutableNode(val entry: OrgEntry, val index: Int) {
        val children = mutableListOf<MutableNode>()

        fun freeze(): OrgNode = OrgNode(entry, index, children.map { it.freeze() })
    }

    /**
     * 扁平列表 → 森林（顶层节点列表）。
     *
     * 规则：用栈维护祖先链（栈内 level 严格递增）。
     * - 栈空 → 作为根（含「首项 level > 1」这种没有更高级祖先的情况）；
     * - 否则挂到栈顶（即最近一个 level 更小的祖先）下 —— 跳级（`*` 直接 `***`）
     *   也因此挂到该祖先下，深度不会凭空多出。
     */
    fun build(entries: List<OrgEntry>): List<OrgNode> {
        val roots = mutableListOf<MutableNode>()
        val stack = ArrayDeque<MutableNode>()
        entries.forEachIndexed { index, entry ->
            // 弹出所有 level >= 当前项的节点，栈顶剩下的就是更高级祖先
            while (stack.isNotEmpty() && stack.last().entry.level >= entry.level) {
                stack.removeLast()
            }
            val node = MutableNode(entry, index)
            val parent = stack.lastOrNull()
            if (parent == null) roots += node else parent.children += node
            stack.addLast(node)
        }
        return roots.map { it.freeze() }
    }

    /**
     * 树 → 可见行（深度优先、前序）。
     *
     * [collapsed] 含某节点的 [OrgNode.index] 时不展开其子树，该行本身仍输出且 `collapsed = true`。
     */
    fun flatten(roots: List<OrgNode>, collapsed: Set<Int>): List<VisibleRow> {
        val rows = mutableListOf<VisibleRow>()
        fun visit(nodes: List<OrgNode>, depth: Int) {
            for (node in nodes) {
                val isCollapsed = node.index in collapsed
                rows += VisibleRow(node, depth, node.children.isNotEmpty(), isCollapsed)
                if (!isCollapsed) visit(node.children, depth + 1)
            }
        }
        visit(roots, 0)
        return rows
    }

    /**
     * 搜索 + 保持树结构 → 可见行。
     *
     * 保留集合 = 命中节点 ∪ 命中节点的祖先链；未命中的分支整支隐藏。
     * 注意：命中根节点时，其子树中**未命中**的分支同样隐藏（只留命中节点的祖先链）。
     * 命中分支强制展开，故 [collapsed] 不参与输出判断，输出行的 `collapsed` 恒为 `false`。
     */
    @Suppress("UNUSED_PARAMETER")
    fun flattenFiltered(
        roots: List<OrgNode>,
        matched: Set<Int>,
        collapsed: Set<Int>,
    ): List<VisibleRow> {
        // 第一遍：自底向上传播「本子树是否有命中」，把祖先链一并纳入保留集合
        val keep = mutableSetOf<Int>()
        fun collect(node: OrgNode): Boolean {
            var hit = node.index in matched
            for (child in node.children) if (collect(child)) hit = true
            if (hit) keep += node.index
            return hit
        }
        roots.forEach { collect(it) }

        // 第二遍：前序输出保留节点；只沿保留分支下降 ⇒ 等价于强制展开
        val rows = mutableListOf<VisibleRow>()
        fun emit(nodes: List<OrgNode>, depth: Int) {
            for (node in nodes) {
                if (node.index !in keep) continue
                val visibleChildren = node.children.filter { it.index in keep }
                rows += VisibleRow(node, depth, visibleChildren.isNotEmpty(), false)
                emit(visibleChildren, depth + 1)
            }
        }
        emit(roots, 0)
        return rows
    }
}

/** 搜索匹配器：标题 + 正文，大小写不敏感。 */
internal object OrgSearchMatcher {

    /**
     * 返回命中节点的 [OrgNode.index] 集合（遍历整棵树，含深层节点）。
     *
     * query 空白 → 空集合（调用方据此显示完整树）。
     */
    fun match(roots: List<OrgNode>, query: String): Set<Int> {
        if (query.isBlank()) return emptySet()
        val matched = mutableSetOf<Int>()
        fun visit(nodes: List<OrgNode>) {
            for (node in nodes) {
                if (matches(node.entry, query)) matched += node.index
                visit(node.children)
            }
        }
        visit(roots)
        return matched
    }

    /** 单条是否命中（标题或正文包含 query，忽略大小写；query 空白视为不命中）。 */
    fun matches(entry: OrgEntry, query: String): Boolean {
        val needle = query.trim()
        if (needle.isEmpty()) return false
        return entry.title.contains(needle, ignoreCase = true) ||
            entry.body.contains(needle, ignoreCase = true)
    }
}
