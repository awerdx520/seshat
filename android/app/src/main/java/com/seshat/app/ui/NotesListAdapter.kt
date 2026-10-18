package com.seshat.app.ui

import android.content.res.ColorStateList
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R
import com.seshat.app.gtd.OrgEntryDisplay
import com.seshat.app.gtd.VisibleRow

/**
 * 笔记列表适配器：把 [VisibleRow]（树扁平化后的一行）绑定到 `item_note_entry`。
 *
 * 单行展示要素：TODO 状态徽标（复用 [OrgEntryDisplay] 的配色）+ 标题 + 标签（与标题同行）
 * + 折叠箭头，下一行为正文摘要。层级缩进按 [VisibleRow.depth] 计算（基础 8dp + 每级 16dp），
 * 与 `GtdEntryAdapter` 的做法保持一致。
 *
 * MVP 说明：列表整体替换，使用 [notifyDataSetChanged]（示例文档数据量小，无需 DiffUtil）。
 *
 * @param onRowClick 整行点击回调。
 * @param onCollapseToggle 折叠箭头点击回调（仅在有子节点时触发）。
 */
class NotesListAdapter(
    private val onRowClick: (VisibleRow) -> Unit,
    private val onCollapseToggle: (VisibleRow) -> Unit,
) : RecyclerView.Adapter<NotesListAdapter.RowHolder>() {

    private val rows = mutableListOf<VisibleRow>()

    /** 单行视图持有者。 */
    class RowHolder(view: View) : RecyclerView.ViewHolder(view) {
        val titleRow: LinearLayout = view.findViewById(R.id.noteTitleRow)
        val badge: TextView = view.findViewById(R.id.noteTodoBadge)
        val title: TextView = view.findViewById(R.id.noteTitle)
        val tags: TextView = view.findViewById(R.id.noteTags)
        val collapse: TextView = view.findViewById(R.id.noteCollapse)
        val summary: TextView = view.findViewById(R.id.noteSummary)
    }

    /** 用 [newRows] 整体替换当前列表并刷新。 */
    fun submit(newRows: List<VisibleRow>) {
        rows.clear()
        rows.addAll(newRows)
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_note_entry, parent, false)
        return RowHolder(view)
    }

    override fun onBindViewHolder(holder: RowHolder, position: Int) {
        val row = rows[position]
        val entry = row.node.entry
        val context = holder.itemView.context
        val density = context.resources.displayMetrics.density

        // 层级缩进：只改 paddingStart，top/end/bottom 保持 XML 中的值。
        val basePaddingPx = (BASE_PADDING_DP * density).toInt()
        val indentPx = row.depth * (INDENT_PER_LEVEL_DP * density).toInt()
        holder.itemView.setPadding(
            basePaddingPx + indentPx,
            holder.itemView.paddingTop,
            holder.itemView.paddingEnd,
            holder.itemView.paddingBottom,
        )

        // TODO 状态徽标（无状态则隐藏）；配色与 GTD 列表共用
        val state = entry.todoState
        if (state != null) {
            holder.badge.visibility = View.VISIBLE
            holder.badge.text = state
            holder.badge.backgroundTintList = ColorStateList.valueOf(OrgEntryDisplay.badgeColor(state))
        } else {
            holder.badge.visibility = View.GONE
        }

        // 标题（空标题兜底占位）
        holder.title.text = entry.title.ifEmpty { context.getString(R.string.notes_no_title) }

        // 标签（形如 :a:b:，与标题同行；无则隐藏）
        val tagText = OrgEntryDisplay.tagText(entry.tags)
        if (tagText != null) {
            holder.tags.visibility = View.VISIBLE
            holder.tags.text = tagText
        } else {
            holder.tags.visibility = View.GONE
        }

        // 正文摘要：正文首个非空行；无则隐藏
        val summary = OrgEntryDisplay.summaryOf(entry.body)
        if (summary != null) {
            holder.summary.visibility = View.VISIBLE
            holder.summary.text = summary
        } else {
            holder.summary.visibility = View.GONE
        }

        // 折叠箭头：仅有子节点时可见，▾ 展开 / ▸ 折叠
        if (row.hasChildren) {
            holder.collapse.visibility = View.VISIBLE
            holder.collapse.text = if (row.collapsed) COLLAPSE_ARROW else EXPAND_ARROW
            holder.collapse.setOnClickListener { onCollapseToggle(row) }
        } else {
            holder.collapse.visibility = View.GONE
            holder.collapse.setOnClickListener(null)
        }

        // 整行点击（每次 bind 重设，避免视图复用串号）
        holder.itemView.setOnClickListener { onRowClick(row) }
    }

    override fun getItemCount(): Int = rows.size

    private companion object {
        /** 行根布局基础内边距（与 item_note_entry.xml 的 start padding 对齐）。 */
        const val BASE_PADDING_DP = 8

        /** 每深一级的缩进步长。 */
        const val INDENT_PER_LEVEL_DP = 16

        /** 折叠状态箭头。 */
        const val COLLAPSE_ARROW = "▸"

        /** 展开状态箭头。 */
        const val EXPAND_ARROW = "▾"
    }
}
