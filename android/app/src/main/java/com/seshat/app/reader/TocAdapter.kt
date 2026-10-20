package com.seshat.app.reader

import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/**
 * 目录抽屉的列表适配器（M10.9）。
 *
 * 行视图由代码构建（项目虽以 XML 布局为主，但目录行是一维列表且样式全由 `depth` / `hasChildren`
 * 驱动，代码构建比再拆一份 item XML 更直观，也避免两处重复）。
 *
 * 交互分工：
 * - 点**箭头** → [onToggle]（折叠/展开，仅 `hasChildren` 的行有箭头）；
 * - 点**标题** → [onPick]（跳转；`targetIndex < 0` 的纯容器行改为切换折叠）。
 */
internal class TocAdapter(
    private val onToggle: (String) -> Unit,
    private val onPick: (TocRow) -> Unit,
) : RecyclerView.Adapter<TocAdapter.Holder>() {

    /** 当前可见行（折叠后，顺序同 DFS 前序）。 */
    private var visible: List<TocRow> = emptyList()

    /** 当前所在项的 targetIndex，用于高亮；`-1` 表示无。 */
    private var currentTarget: Int = -1

    /** 全量行（含被折叠的），用于展开/折叠后重新计算可见行。 */
    private var all: List<TocRow> = emptyList()

    /** 已展开节点的 id 集合。 */
    private var expanded: Set<String> = emptySet()

    /** 提交数据：内部用 [TocFlatten.visibleRows] 算出可见行后整体刷新。 */
    fun submit(all: List<TocRow>, expanded: Set<String>, currentTarget: Int) {
        this.all = all
        this.expanded = expanded
        this.currentTarget = currentTarget
        refreshVisible()
    }

    /** 按当前全量行与展开集合重算可见行并整体刷新。 */
    private fun refreshVisible() {
        visible = TocFlatten.visibleRows(all, expanded)
        notifyDataSetChanged()
    }

    /** 当前可见行里，第一个 `targetIndex == target` 的索引（用于滚动定位）；找不到返回 -1。 */
    fun indexOfTarget(target: Int): Int = visible.indexOfFirst { it.targetIndex == target }

    override fun getItemCount(): Int = visible.size

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val context = parent.context
        val density = context.resources.displayMetrics.density
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = (44 * density).toInt()
            isClickable = true
            isFocusable = true
            setPadding(0, 0, (12 * density).toInt(), 0)
        }
        val arrow = TextView(context).apply {
            gravity = Gravity.CENTER
            textSize = 12f
            setTextColor(0xFF616161.toInt())
            layoutParams = LinearLayout.LayoutParams(
                (24 * density).toInt(),
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        val title = TextView(context).apply {
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            textSize = 14f
            setTextColor(0xFF212121.toInt())
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        row.addView(arrow)
        row.addView(title)
        return Holder(row, arrow, title, density)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val row = visible.getOrNull(position) ?: return
        holder.bind(row, row.targetIndex >= 0 && row.targetIndex == currentTarget)
    }

    /** 单行视图引用 + 绑定逻辑。 */
    inner class Holder(
        private val container: LinearLayout,
        private val arrow: TextView,
        private val title: TextView,
        private val density: Float,
    ) : RecyclerView.ViewHolder(container) {
        /** 按行数据回填缩进、箭头、标题、选中底色与两级点击行为。 */
        fun bind(row: TocRow, selected: Boolean) {
            container.setPadding(
                ((8 + row.depth * 16) * density).toInt(), 0, (12 * density).toInt(), 0,
            )
            // 无子节点时箭头占位不可见（保留宽度，避免标题左右抖动）
            arrow.visibility = if (row.hasChildren) View.VISIBLE else View.INVISIBLE
            arrow.text = if (row.expanded) "▾" else "▸"
            title.text = row.title
            container.setBackgroundColor(if (selected) 0x1F000000 else Color.TRANSPARENT)
            arrow.setOnClickListener {
                if (row.hasChildren) onToggle(row.id)
            }
            container.setOnClickListener {
                if (row.targetIndex >= 0) onPick(row) else if (row.hasChildren) onToggle(row.id)
            }
        }
    }
}
