package com.seshat.app.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R
import com.seshat.app.notes.NoteFormat
import com.seshat.app.notes.NoteItem
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 笔记库列表适配器（M10.7 T7）：把 [NoteItem]（本地文件或 SAF 文档）绑定到 `item_note_file`。
 *
 * 与 [NotesListAdapter] 的分工：
 * - 本适配器 → 「笔记」段：**一个文件一行**，只展示标题 + 格式/修改时间 + 标签；
 * - [NotesListAdapter] → 「Agenda」段：仍是 org 条目的树形/扁平展示（不改）。
 *
 * 单行要素：标题（单行省略）、元信息（`ORG`/`MD` + `yyyy-MM-dd HH:mm`）、denote 标签 `:a:b:`。
 * 点击整行回调 [onOpen]，由宿主 Fragment 按 [com.seshat.app.notes.NoteRef] 类型分派到阅读页。
 *
 * MVP 说明：整体替换 + [notifyDataSetChanged]（与 [NotesListAdapter] 保持一致，暂不引入 DiffUtil）。
 *
 * @param onOpen 整行点击回调。
 */
class NoteFileAdapter(
    private val onOpen: (NoteItem) -> Unit,
) : RecyclerView.Adapter<NoteFileAdapter.NoteHolder>() {

    private val items = mutableListOf<NoteItem>()

    /** 单行视图持有者。 */
    class NoteHolder(view: View) : RecyclerView.ViewHolder(view) {
        val title: TextView = view.findViewById(R.id.noteFileTitle)
        val meta: TextView = view.findViewById(R.id.noteFileMeta)
        val tags: TextView = view.findViewById(R.id.noteFileTags)
    }

    /** 用 [newItems] 整体替换当前列表并刷新。 */
    fun submit(newItems: List<NoteItem>) {
        items.clear()
        items.addAll(newItems)
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): NoteHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_note_file, parent, false)
        return NoteHolder(view)
    }

    override fun onBindViewHolder(holder: NoteHolder, position: Int) {
        val item = items[position]
        val context = holder.itemView.context

        // 标题（扫描器已做回退链，理论上非空；空标题仍给占位，避免行看起来是空的）
        holder.title.text = item.title.ifEmpty { context.getString(R.string.notes_no_title) }

        // 元信息：格式 + 修改时间
        holder.meta.text = context.getString(
            R.string.note_file_meta,
            formatLabel(item.format),
            formatModified(item.modifiedAt),
        )

        // 标签（denote 名称里的标签，形如 :a:b:；无标签隐藏）
        if (item.tags.isEmpty()) {
            holder.tags.visibility = View.GONE
        } else {
            holder.tags.visibility = View.VISIBLE
            holder.tags.text = ":" + item.tags.joinToString(":") + ":"
        }

        // 整行点击（每次 bind 重设，避免视图复用串号）
        holder.itemView.setOnClickListener { onOpen(item) }
    }

    override fun getItemCount(): Int = items.size

    /** 格式标签：org → `ORG`，markdown → `MD`。 */
    private fun formatLabel(format: NoteFormat): String = when (format) {
        NoteFormat.ORG -> "ORG"
        NoteFormat.MARKDOWN -> "MD"
    }

    /**
     * 修改时间格式化（本地时区 `yyyy-MM-dd HH:mm`）。
     *
     * 时间戳为 0（provider 未提供修改时间）时显示占位符，避免出现 1970 年。
     */
    private fun formatModified(timestamp: Long): String =
        if (timestamp <= 0L) {
            UNKNOWN_TIME
        } else {
            SimpleDateFormat(TIME_PATTERN, Locale.getDefault()).format(Date(timestamp))
        }

    private companion object {
        /** 修改时间格式（与列表设计稿一致）。 */
        const val TIME_PATTERN = "yyyy-MM-dd HH:mm"

        /** 时间未知占位。 */
        const val UNKNOWN_TIME = "-"
    }
}
