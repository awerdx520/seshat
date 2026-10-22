package com.seshat.app.reader

import android.content.Context
import android.graphics.Typeface
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.min

/**
 * 左侧滑出的批注抽屉（M10.3 / T5）。
 *
 * **复用 [TocDrawer] 的骨架**：遮罩 + `translationX` 面板，**不用 `DrawerLayout`**
 * （它自带边缘横向滑动手势，会和横向翻页滑动抢事件），**零新增 XML / 零新增 `R.id.`**，
 * 全部视图由代码构建并挂到 Activity 的内容容器上。
 *
 * 与目录抽屉的关系：两者互斥（同时只能开一个），由 Activity 在打开前先关另一个——
 * 抽屉自身不感知对方，避免两个组件互相引用。
 *
 * 面板结构（自上而下）：
 * 1. 头部行：标题「批注」+ 右对齐「×」（40dp 高）；
 * 2. 1dp 分隔线；
 * 3. 内容区：分组列表（分组标题 + 条目行）/ 空态文案二选一，占满剩余高度。
 *
 * 分组与文案**全部来自纯函数** [AnnotationGrouping]（`group` / `pendingLabel` / `INK_SUMMARY_ID`），
 * 本类只负责装配视图与交互分派，不含任何业务判定。
 *
 * ## ink 汇总行的处置（本轮选定：只读展示 + 删除入口置灰）
 *
 * `kind=ink` 的服务端记录是**一笔一条**，抽屉里折叠成一条「本页/共 N 处手写」汇总行
 * （[AnnotationGrouping.INK_SUMMARY_ID]）。该行**不可删除**：
 * - 「⋮」菜单按钮对该行隐藏（删除入口置灰），长按只给一句提示；
 * - 原因：汇总行背后是 N 条独立记录，删除要么逐条确认（N 次弹窗），要么按
 *   `page:<n>;ink:` 前缀批量删（需在服务端按 location 前缀查 uid 的全部批注，属另一轮的范围）；
 * - 点击汇总行仍可**跳转**到该组所在页（Activity 侧按 kind 找到第一条 ink 记录定位）。
 *
 * @param root 抽屉挂载的容器（Activity 的内容容器，是个 `FrameLayout`）
 * @param onItemClick 点击条目行（需要跳转）时回调
 * @param onItemEdit 菜单选「编辑备注」时回调（`note` / `highlight` 行）
 * @param onItemDelete 菜单选「删除」并确认后回调
 * @param onClose 抽屉关闭时回调（供 Activity 做状态联动）
 */
internal class AnnotationDrawer(
    private val root: FrameLayout,
    private val onItemClick: (AnnotationRow) -> Unit,
    private val onItemEdit: (AnnotationRow) -> Unit,
    private val onItemDelete: (AnnotationRow) -> Unit,
    private val onClose: () -> Unit = {},
) {
    private val density: Float = root.resources.displayMetrics.density

    /** 面板宽度：320dp 与屏宽 78% 取小（窄屏不铺满，留出一道可见的阅读区提示可点遮罩关闭）。 */
    private val panelWidth: Int = min(
        (320 * density).toInt(),
        (root.resources.displayMetrics.widthPixels * 0.78f).toInt(),
    )

    /** 渲染行的两种形态：分组标题 / 条目。 */
    private sealed interface DrawerRow {
        data class Header(val title: String) : DrawerRow

        data class Entry(val row: AnnotationRow) : DrawerRow
    }

    private val adapter = RowAdapter()

    private val recycler = RecyclerView(root.context).apply {
        layoutManager = LinearLayoutManager(context)
        itemAnimator = null // 整体 notifyDataSetChanged 刷新，动画只会造成闪烁
        adapter = this@AnnotationDrawer.adapter
        visibility = View.GONE
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f,
        )
    }

    /** 空态：「尚无批注」15sp + 提示行（同色系更淡），与目录抽屉的书签空态风格一致。 */
    private val emptyView = TextView(root.context).apply {
        text = "尚无批注\n选中正文后点顶栏的批注按钮可添加"
        gravity = Gravity.CENTER
        textSize = 15f
        setTextColor(0xFF9E9E9E.toInt())
        visibility = View.GONE
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f,
        )
    }

    /** 遮罩：半透明黑，点击关闭抽屉。 */
    private val scrim = View(root.context).apply {
        setBackgroundColor(0x99000000.toInt())
        isClickable = true
        visibility = View.GONE
        setOnClickListener { hide() }
    }

    /** 面板：头部 + 分隔线 + 内容区。 */
    private val panel = LinearLayout(root.context).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(0xFFF7F7F7.toInt())
        // 必须可点击：否则点面板空白处会穿透到遮罩，把抽屉直接关掉
        isClickable = true
        visibility = View.GONE
        addView(buildHeader(context))
        addView(
            View(context).apply {
                setBackgroundColor(0x14000000)
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    (1 * density).toInt(),
                )
            },
        )
        addView(recycler)
        addView(emptyView)
    }

    init {
        // addView 顺序必须是「遮罩 → 面板」：后加的在上层，否则面板被遮罩盖住
        val fillParent = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        root.addView(scrim, fillParent)
        root.addView(
            panel,
            FrameLayout.LayoutParams(panelWidth, ViewGroup.LayoutParams.MATCH_PARENT).apply {
                gravity = Gravity.START
            },
        )
    }

    /** 抽屉是否正在显示（含滑出动画中）。 */
    val isShowing: Boolean get() = scrim.visibility == View.VISIBLE

    /**
     * 显示（或刷新）抽屉。
     *
     * **首次打开**播放遮罩淡入 + 面板滑入；**已显示时再次调用**（删除/编辑后的刷新）
     * 只替换数据，不重播动画、不重置滚动位置。
     *
     * @param items 由 Activity 从各自 store 映射出的中性条目
     * @param currentPage 当前阅读页（PDF 1-based；EPUB 传 `null`），只影响 ink 汇总文案
     */
    fun show(items: List<AnnotationItem>, currentPage: Int? = null) {
        val refresh = isShowing
        val flat = ArrayList<DrawerRow>()
        for (group in AnnotationGrouping.group(items, currentPage)) {
            flat += DrawerRow.Header(group.title)
            group.rows.forEach { flat += DrawerRow.Entry(it) }
        }
        adapter.submit(flat)
        val empty = flat.isEmpty()
        recycler.visibility = if (empty) View.GONE else View.VISIBLE
        emptyView.visibility = if (empty) View.VISIBLE else View.GONE
        // 刷新时条目可能变少：滚回顶部，避免停在已消失的位置
        if (refresh && !empty) recycler.scrollToPosition(0)

        if (refresh) return
        scrim.visibility = View.VISIBLE
        scrim.alpha = 0f
        scrim.animate().alpha(1f).setDuration(200).start()
        panel.visibility = View.VISIBLE
        // 首次打开时 panel.width 仍为 0（未测量），此时设 translationX 等于没设，会「闪出」无动画
        panel.post {
            panel.translationX = -panel.width.toFloat()
            panel.animate().translationX(0f).setDuration(200).start()
        }
    }

    /** 关闭抽屉（带滑出动画）。 */
    fun hide() {
        if (!isShowing) return
        scrim.animate().alpha(0f).setDuration(160).withEndAction {
            scrim.visibility = View.GONE
        }.start()
        panel.animate().translationX(-panel.width.toFloat()).setDuration(160).withEndAction {
            panel.visibility = View.GONE
        }.start()
        onClose()
    }

    /** 头部行：左标题「批注」+ 右对齐「×」，40dp 高。 */
    private fun buildHeader(context: Context): LinearLayout {
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding((14 * density).toInt(), 0, (12 * density).toInt(), 0)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                (40 * density).toInt(),
            )
        }
        header.addView(
            TextView(context).apply {
                text = "批注"
                textSize = 14f
                setTypeface(null, Typeface.BOLD)
                setTextColor(0xFF212121.toInt())
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            },
        )
        header.addView(
            TextView(context).apply {
                text = "×"
                textSize = 18f
                gravity = Gravity.CENTER
                setTextColor(0xFF616161.toInt())
                isClickable = true
                isFocusable = true
                minimumHeight = (40 * density).toInt()
                setPadding((12 * density).toInt(), 0, (12 * density).toInt(), 0)
                setOnClickListener { hide() }
            },
        )
        return header
    }

    /**
     * 条目行的菜单：编辑 / 删除。
     *
     * ink 汇总行不给菜单（删除入口置灰），只提示一句；其余行弹两项，删除再走一次确认。
     */
    private fun showRowMenu(row: AnnotationRow) {
        if (row.kind == AnnotationGrouping.KIND_INK) {
            Toast.makeText(
                root.context,
                "手写笔迹按笔记录，暂不支持从列表删除",
                Toast.LENGTH_SHORT,
            ).show()
            return
        }
        AlertDialog.Builder(root.context)
            .setItems(arrayOf("编辑备注", "删除")) { _, which ->
                when (which) {
                    0 -> onItemEdit(row)
                    else -> confirmDelete(row)
                }
            }
            .show()
    }

    /** 删除前的二次确认（批注删除不可撤销，且会传播到服务端）。 */
    private fun confirmDelete(row: AnnotationRow) {
        AlertDialog.Builder(root.context)
            .setTitle("删除这条批注？")
            .setMessage(row.title)
            .setPositiveButton("删除") { _, _ -> onItemDelete(row) }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /** 分组标题 + 条目行两种 viewType 的适配器（手写，避免为两行引入 XML item 布局）。 */
    private inner class RowAdapter : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private val items = ArrayList<DrawerRow>()

        fun submit(list: List<DrawerRow>) {
            items.clear()
            items.addAll(list)
            notifyDataSetChanged()
        }

        override fun getItemCount(): Int = items.size

        override fun getItemViewType(position: Int): Int =
            if (items[position] is DrawerRow.Header) TYPE_HEADER else TYPE_ENTRY

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val context = parent.context
            return if (viewType == TYPE_HEADER) {
                HeaderHolder(buildGroupTitle(context))
            } else {
                EntryHolder(buildEntry(context))
            }
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            when (val item = items[position]) {
                is DrawerRow.Header -> (holder as HeaderHolder).title.text = item.title
                is DrawerRow.Entry -> (holder as EntryHolder).bind(item.row)
            }
        }
    }

    /** 分组标题视图：12sp 灰字、上下 6dp、浅灰底。 */
    private fun buildGroupTitle(context: Context): TextView = TextView(context).apply {
        textSize = 12f
        setTextColor(0xFF9E9E9E.toInt())
        setBackgroundColor(0xFFEFEFEF.toInt())
        setPadding((14 * density).toInt(), (6 * density).toInt(), (14 * density).toInt(), (6 * density).toInt())
        layoutParams = RecyclerView.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
    }

    /** 条目行视图：左侧（标题 / 副标题 / 待同步）× 右侧「⋮」菜单按钮。 */
    private fun buildEntry(context: Context): LinearLayout {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding((14 * density).toInt(), (10 * density).toInt(), (6 * density).toInt(), (10 * density).toInt())
            layoutParams = RecyclerView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }
        val body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val title = TextView(context).apply {
            textSize = 15f
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setTextColor(0xFF212121.toInt())
        }
        val subtitle = TextView(context).apply {
            textSize = 12f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setTextColor(0xFF757575.toInt())
            visibility = View.GONE
        }
        val pending = TextView(context).apply {
            textSize = 11f
            setTextColor(0xFFFF8F00.toInt())
            visibility = View.GONE
        }
        body.addView(title)
        body.addView(subtitle)
        body.addView(pending)
        val menu = TextView(context).apply {
            text = "⋮"
            textSize = 18f
            gravity = Gravity.CENTER
            setTextColor(0xFF616161.toInt())
            isClickable = true
            isFocusable = true
            minWidth = (44 * density).toInt()
            minHeight = (44 * density).toInt()
        }
        row.addView(body)
        row.addView(menu)
        row.tag = EntryTag(title, subtitle, pending, menu)
        return row
    }

    /** 条目行内各子控件的引用（避免每次 bind 都 findViewById）。 */
    private class EntryTag(
        val title: TextView,
        val subtitle: TextView,
        val pending: TextView,
        val menu: TextView,
    )

    private inner class HeaderHolder(val title: TextView) :
        RecyclerView.ViewHolder(title)

    private inner class EntryHolder(private val container: LinearLayout) :
        RecyclerView.ViewHolder(container) {
        fun bind(row: AnnotationRow) {
            val tag = container.tag as EntryTag
            tag.title.text = row.title
            // 分组已表明 kind，这里不再重复；副标题只在有内容时占位
            tag.subtitle.text = row.subtitle
            tag.subtitle.visibility = if (row.subtitle.isBlank()) View.GONE else View.VISIBLE
            // pendingLabel 返回 null（未同步）→ 不占位
            val label = AnnotationGrouping.pendingLabel(row.pending)
            tag.pending.text = label.orEmpty()
            tag.pending.visibility = if (label == null) View.GONE else View.VISIBLE
            // ink 汇总行：删除入口置灰（整行灰字 + 隐藏菜单按钮）
            val ink = row.kind == AnnotationGrouping.KIND_INK
            tag.title.setTextColor(if (ink) 0xFF9E9E9E.toInt() else 0xFF212121.toInt())
            tag.menu.visibility = if (ink) View.GONE else View.VISIBLE
            tag.menu.setOnClickListener { showRowMenu(row) }
            container.setOnClickListener { onItemClick(row) }
            container.setOnLongClickListener {
                showRowMenu(row)
                true
            }
        }
    }

    private companion object {
        /** viewType：分组标题。 */
        const val TYPE_HEADER = 0

        /** viewType：条目行。 */
        const val TYPE_ENTRY = 1
    }
}

/** 顶栏「批注列表」入口的文案（与既有「添加批注」按钮区分，不新增字符串资源）。 */
internal const val ANNOTATION_DRAWER_ENTRY_LABEL = "列表"
