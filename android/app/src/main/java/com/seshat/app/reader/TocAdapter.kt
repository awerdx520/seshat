package com.seshat.app.reader

import android.graphics.Color
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/**
 * 目录抽屉的列表适配器（M10.9 / M10.10）。
 *
 * 行视图由代码构建（项目虽以 XML 布局为主，但目录行是一维列表且样式全由 `depth` / `hasChildren`
 * 驱动，代码构建比再拆一份 item XML 更直观，也避免两处重复）。
 *
 * 行结构（自左向右）：
 * 1. 选中竖条（3dp，`#1565C0`，选中才可见，占位保留以免文字抖动）；
 * 2. 折叠箭头（▸/▾，20dp，`hasChildren` 才可见）；
 * 3. 标题（weight = 1，13sp，单行 END 省略，已读项追加 ✓）；
 * 4. 页码列（44dp，12sp，右对齐；EPUB 显示章号、PDF 显示页号，均为 1-based，容器行为空）。
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

    /** 当前所在项的 targetIndex，用于高亮与「已读」判定；`-1` 表示无。 */
    private var currentTarget: Int = -1

    /** 全量行（含被折叠的），用于展开/折叠后重新计算可见行。 */
    private var all: List<TocRow> = emptyList()

    /** 已展开节点的 id 集合。 */
    private var expanded: Set<String> = emptySet()

    /**
     * 提交数据：内部用 [TocFlatten.visibleRows] 算出可见行后整体刷新。
     *
     * 签名保持不变（Q3 接线前 Activity 仍在用两参重载的抽屉）。
     */
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
            minimumHeight = (40 * density).toInt()
            isClickable = true
            isFocusable = true
            // 左侧不再留全局 padding（让位给选中竖条），缩进完全由 depth 决定，见 bind()
            setPaddingRelative(0, 0, (10 * density).toInt(), 0)
        }
        // RecyclerView 对无 layoutParams 的根视图会调 generateDefaultLayoutParams()（WRAP_CONTENT），
        // 导致选中高亮块只包住文字宽度而非铺满整行；显式给 MATCH_PARENT 修正。
        row.layoutParams = RecyclerView.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        val indicator = View(context).apply {
            setBackgroundColor(0xFF1565C0.toInt())
            // 未选中时用 INVISIBLE 而非 GONE：保留 3dp 占位，选中状态切换时文字不横向跳动
            visibility = View.INVISIBLE
            layoutParams = LinearLayout.LayoutParams(
                (3 * density).toInt(),
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        val arrow = TextView(context).apply {
            gravity = Gravity.CENTER
            textSize = 11f
            setTextColor(0xFF616161.toInt())
            layoutParams = LinearLayout.LayoutParams(
                (20 * density).toInt(),
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        val title = TextView(context).apply {
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            textSize = 13f
            setTextColor(0xFF212121.toInt())
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val page = TextView(context).apply {
            maxLines = 1
            textSize = 12f
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            setTextColor(0xFF9E9E9E.toInt())
            layoutParams = LinearLayout.LayoutParams(
                (44 * density).toInt(),
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }
        row.addView(indicator)
        row.addView(arrow)
        row.addView(title)
        row.addView(page)
        return Holder(row, indicator, arrow, title, page, density)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val row = visible.getOrNull(position) ?: return
        holder.bind(
            row = row,
            selected = row.targetIndex >= 0 && row.targetIndex == currentTarget,
            currentTarget = currentTarget,
        )
    }

    /** 单行视图引用 + 绑定逻辑。 */
    inner class Holder(
        private val container: LinearLayout,
        private val indicator: View,
        private val arrow: TextView,
        private val title: TextView,
        private val page: TextView,
        private val density: Float,
    ) : RecyclerView.ViewHolder(container) {
        /**
         * 按行数据回填缩进、选中竖条、箭头、标题（含已读 ✓）、页码与两级点击行为。
         *
         * @param selected 是否为当前所在项（竖条 + 蓝色加粗标题 + 浅蓝底）
         * @param currentTarget 当前所在项索引；`targetIndex` 小于它的可跳转行视为「已读」
         */
        fun bind(row: TocRow, selected: Boolean, currentTarget: Int) {
            container.setPaddingRelative(
                (row.depth * 12 * density).toInt(), 0, (10 * density).toInt(), 0,
            )
            indicator.visibility = if (selected) View.VISIBLE else View.INVISIBLE
            // 无子节点时箭头占位不可见（保留宽度，避免标题左右抖动）
            arrow.visibility = if (row.hasChildren) View.VISIBLE else View.INVISIBLE
            arrow.text = if (row.expanded) "▾" else "▸"
            // 当前项之前的可跳转行都算已读（PDF 页号同理：页号小于当前页即已读）。
            // 直接拼字符串即可，不必上 Spannable——✓ 与标题同色，视觉上已足够区分。
            val isRead = row.targetIndex >= 0 && row.targetIndex < currentTarget
            title.text = if (isRead) "${row.title} \u2713" else row.title
            page.text = if (row.targetIndex >= 0) (row.targetIndex + 1).toString() else ""
            title.setTextColor(if (selected) 0xFF1565C0.toInt() else 0xFF212121.toInt())
            title.setTypeface(null, if (selected) Typeface.BOLD else Typeface.NORMAL)
            container.setBackgroundColor(if (selected) 0x141565C0 else Color.TRANSPARENT)
            arrow.setOnClickListener {
                if (row.hasChildren) onToggle(row.id)
            }
            container.setOnClickListener {
                if (row.targetIndex >= 0) onPick(row) else if (row.hasChildren) onToggle(row.id)
            }
        }
    }
}
