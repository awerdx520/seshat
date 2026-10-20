package com.seshat.app.reader

import android.graphics.Typeface
import android.text.format.DateUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 书签列表适配器（M10.10 目录抽屉的第二个标签）。
 *
 * 行：左侧标题（书签名），右侧创建时间，最右一个 × 删除按钮。
 * 空态由 [TocDrawer] 负责渲染，不在本适配器内。
 *
 * 右列为什么显示时间而不是页码：标题添加时默认就是「第 N 页」，再写一遍页码是纯重复；
 * 换成时间后同一行提供「哪一页（标题）+ 什么时候标的」两个正交信息。
 *
 * 行视图同样代码构建（与 [TocAdapter] 一致的取舍：一维列表 + 样式全由数据驱动，
 * 不必再拆一份 item XML）。
 *
 * 交互分工：
 * - 点**整行** → [onPick]（跳转到该书签页）；
 * - 点**×** → [onDelete]（删除该书签，行内不留二次确认，交给调用方决定）。
 *
 * @param onPick 点击行回调（跳转）
 * @param onDelete 点击 × 回调（删除）
 */
internal class BookmarkAdapter(
    private val onPick: (PdfBookmark) -> Unit,
    private val onDelete: (PdfBookmark) -> Unit,
) : RecyclerView.Adapter<BookmarkAdapter.Holder>() {

    /** 当前书签列表（按页升序，由调用方保证）。 */
    private var items: List<PdfBookmark> = emptyList()

    /** 提交书签列表并整体刷新（书签数量少，整体刷新比 diff 更简单可靠）。 */
    fun submit(items: List<PdfBookmark>) {
        this.items = items
        notifyDataSetChanged()
    }

    override fun getItemCount(): Int = items.size

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val context = parent.context
        val density = context.resources.displayMetrics.density
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = (44 * density).toInt()
            isClickable = true
            isFocusable = true
            setPaddingRelative(
                (12 * density).toInt(), 0, (8 * density).toInt(), 0,
            )
        }
        // 行背景用主题的 selectableItemBackground（不新增 drawable）：
        // 通过 TypedValue 解析属性资源 id，全程不写资源 id 常量。
        val outValue = TypedValue()
        if (context.theme.resolveAttribute(
                android.R.attr.selectableItemBackground, outValue, true,
            )
        ) {
            row.setBackgroundResource(outValue.resourceId)
        }
        row.layoutParams = RecyclerView.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        val title = TextView(context).apply {
            maxLines = 2
            textSize = 13f
            setTextColor(0xFF212121.toInt())
            setTypeface(typeface, Typeface.NORMAL)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val page = TextView(context).apply {
            maxLines = 1
            textSize = 12f
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            setTextColor(0xFF9E9E9E.toInt())
            // 宽度自适应：右列已从「第 N 页」改为时间（「HH:mm」/「MM-dd HH:mm」），固定 44dp 会截断
            setPaddingRelative((8 * density).toInt(), 0, 0, 0)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }
        val delete = TextView(context).apply {
            text = "×"
            textSize = 16f
            gravity = Gravity.CENTER
            setTextColor(0xFF9E9E9E.toInt())
            isClickable = true
            isFocusable = true
            layoutParams = LinearLayout.LayoutParams(
                (32 * density).toInt(),
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        row.addView(title)
        row.addView(page)
        row.addView(delete)
        return Holder(row, title, page, delete)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val bookmark = items.getOrNull(position) ?: return
        holder.bind(bookmark)
    }

    /** 单行视图引用 + 绑定逻辑。 */
    inner class Holder(
        private val container: LinearLayout,
        private val title: TextView,
        private val page: TextView,
        private val delete: TextView,
    ) : RecyclerView.ViewHolder(container) {
        /** 回填书签名与创建时间，并挂上整行跳转与 × 删除两个点击行为。 */
        fun bind(bookmark: PdfBookmark) {
            title.text = bookmark.title
            page.text = formatStamp(bookmark.createdAt)
            container.setOnClickListener { onPick(bookmark) }
            delete.setOnClickListener { onDelete(bookmark) }
        }
    }

    private companion object {
        /**
         * 当天只显示 `HH:mm`，跨天补日期 `MM-dd HH:mm`（只有时间在隔天列表里无法判断是哪天）。
         *
         * [SimpleDateFormat] 非线程安全，故每线程一份（[ThreadLocal]）：RecyclerView 的 bind 只在
         * 主线程发生，实际只有一份被用到，成本可忽略；行数少也不必为它做对象池。
         */
        private val timeFormat: ThreadLocal<SimpleDateFormat> =
            ThreadLocal.withInitial { SimpleDateFormat("HH:mm", Locale.getDefault()) }

        /** 跨天格式（含日期）。 */
        private val crossDayFormat: ThreadLocal<SimpleDateFormat> =
            ThreadLocal.withInitial { SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()) }

        /** 书签创建时间 → 右列展示文案。 */
        private fun formatStamp(createdAt: Long): String {
            val date = Date(createdAt)
            val format = if (DateUtils.isToday(createdAt)) {
                timeFormat.get()
            } else {
                crossDayFormat.get()
            }
            return format?.format(date).orEmpty()
        }
    }
}
