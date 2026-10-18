package com.seshat.app.gtd

import android.content.res.ColorStateList
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R

/**
 * GTD 列表适配器：把 [OrgEntry] 绑定到 [R.layout.item_gtd_entry]。
 *
 * 单条条目展示要素：TODO 状态徽标（按状态着色）+ 优先级 + 标题 + 标签 + deadline（若有）。
 * 标题行按 [OrgEntry.level] 做层级缩进（每深一级缩进 [INDENT_PER_LEVEL_DP] dp），以体现 org 标题层级。
 *
 * MVP 说明：列表整体替换，使用 [notifyDataSetChanged]；数据量小（示例文档），无需 DiffUtil。
 */
class GtdEntryAdapter : RecyclerView.Adapter<GtdEntryAdapter.EntryViewHolder>() {

    private val items = mutableListOf<OrgEntry>()

    /** 条目点击回调；参数为被点击的 [OrgEntry]（M4.3：用于切换 TODO 状态）。 */
    var onItemClick: ((OrgEntry) -> Unit)? = null

    /** 单条条目视图持有者。 */
    class EntryViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val titleRow: LinearLayout = view.findViewById(R.id.entryTitleRow)
        val badge: TextView = view.findViewById(R.id.entryTodoBadge)
        val priority: TextView = view.findViewById(R.id.entryPriority)
        val title: TextView = view.findViewById(R.id.entryTitle)
        val tags: TextView = view.findViewById(R.id.entryTags)
        val deadline: TextView = view.findViewById(R.id.entryDeadline)
    }

    /** 用 [newItems] 整体替换当前列表并刷新。 */
    fun submit(newItems: List<OrgEntry>) {
        items.clear()
        items.addAll(newItems)
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): EntryViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_gtd_entry, parent, false)
        return EntryViewHolder(view)
    }

    override fun onBindViewHolder(holder: EntryViewHolder, position: Int) {
        val entry = items[position]
        val context = holder.itemView.context
        val density = context.resources.displayMetrics.density

        // 层级缩进：顶层 0dp，每深一级增加固定缩进。
        val basePaddingPx = (BASE_PADDING_DP * density).toInt()
        val indentPx = (entry.level - 1).coerceAtLeast(0) *
            (INDENT_PER_LEVEL_DP * density).toInt()
        holder.itemView.setPadding(
            basePaddingPx + indentPx,
            holder.itemView.paddingTop,
            holder.itemView.paddingRight,
            holder.itemView.paddingBottom,
        )

        // TODO 状态徽标（无状态则隐藏）
        val state = entry.todoState
        if (state != null) {
            holder.badge.visibility = View.VISIBLE
            holder.badge.text = state
            holder.badge.backgroundTintList = ColorStateList.valueOf(OrgEntryDisplay.badgeColor(state))
        } else {
            holder.badge.visibility = View.GONE
        }

        // 优先级（无则隐藏）
        val priority = entry.priority
        if (priority != null) {
            holder.priority.visibility = View.VISIBLE
            holder.priority.text =
                context.getString(R.string.gtd_priority_format, priority.toString())
        } else {
            holder.priority.visibility = View.GONE
        }

        // 标题（空标题兜底占位）
        holder.title.text = entry.title.ifEmpty { context.getString(R.string.gtd_no_title) }

        // 标签（形如 :a:b:；无则隐藏）
        if (entry.tags.isNotEmpty()) {
            holder.tags.visibility = View.VISIBLE
            holder.tags.text = entry.tags.joinToString(separator = ":", prefix = ":", postfix = ":")
        } else {
            holder.tags.visibility = View.GONE
        }

        // deadline（无则隐藏）
        val deadline = entry.deadline
        if (deadline != null) {
            holder.deadline.visibility = View.VISIBLE
            holder.deadline.text = context.getString(R.string.gtd_deadline_format, deadline)
        } else {
            holder.deadline.visibility = View.GONE
        }

        // 点击整行回调（每次 bind 重设，避免视图复用串号）
        holder.itemView.setOnClickListener { onItemClick?.invoke(entry) }
    }

    override fun getItemCount(): Int = items.size

    private companion object {
        /** 条目根布局基础内边距（与 item_gtd_entry.xml 的 start padding 对齐）。 */
        const val BASE_PADDING_DP = 12

        /** 每深一级标题的缩进步长。 */
        const val INDENT_PER_LEVEL_DP = 16
    }
}
