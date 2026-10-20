package com.seshat.app.reader

import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.min

/**
 * 左侧滑出的目录抽屉（M10.9）。
 *
 * **为什么不用 `DrawerLayout`**：它自带**边缘横向滑动手势**，会和横向阅读的翻页滑动抢事件；
 * 锁死手势又失去使用它的意义。故自实现：遮罩 + 面板 + `translationX` 动画，
 * **只允许从顶部「目录」按钮打开**。
 *
 * 抽屉是**覆盖层**，不是阅读器浮层：开合不触碰阅读区 padding（不要学 `applyContentPadding`）。
 *
 * 全部视图由代码构建（不新增 XML 布局 / drawable，也不引用任何资源 id 常量），
 * 挂到 Activity 的内容容器（一个 `FrameLayout`）上即可，两者共用。
 *
 * @param root 抽屉挂载的容器（Activity 的内容容器，是个 `FrameLayout`）
 * @param onPick 点击可跳转行（`targetIndex >= 0`）时回调
 */
internal class TocDrawer(
    private val root: FrameLayout,
    private val onPick: (Int) -> Unit,
) {
    private val density: Float = root.resources.displayMetrics.density

    /** 面板宽度：320dp 与屏宽 78% 取小（窄屏不铺满，留出一道可见的阅读区提示可点遮罩关闭）。 */
    private val panelWidth: Int = min(
        (320 * density).toInt(),
        (root.resources.displayMetrics.widthPixels * 0.78f).toInt(),
    )

    /** 全量行（含被折叠层级）。 */
    private var allRows: List<TocRow> = emptyList()

    /** 已展开节点的 id 集合。 */
    private var expanded: Set<String> = emptySet()

    /** 当前所在项的 targetIndex，用于高亮 + 默认展开其祖先链。 */
    private var currentTarget: Int = -1

    private val adapter = TocAdapter(
        onToggle = { id -> toggle(id) },
        onPick = { row ->
            hide()
            onPick(row.targetIndex)
        },
    )

    private val recycler = RecyclerView(root.context).apply {
        layoutManager = LinearLayoutManager(context)
        itemAnimator = null // 刷新走整体 notifyDataSetChanged，动画只会造成闪烁
        adapter = this@TocDrawer.adapter
        // 高度 0dp + weight 1f：占满头部之外的全部空间
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
    }

    /** 遮罩：半透明黑，点击关闭抽屉。 */
    private val scrim = View(root.context).apply {
        setBackgroundColor(0x99000000.toInt())
        isClickable = true
        visibility = View.GONE
        setOnClickListener { hide() }
    }

    /** 目录面板：头部（标题 + 关闭）+ 列表。 */
    private val panel = LinearLayout(root.context).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(0xFFFAFAFA.toInt())
        // 必须可点击：否则点面板空白处会穿透到遮罩，把抽屉直接关掉
        isClickable = true
        visibility = View.GONE
        addView(buildHeader(context))
        addView(recycler)
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
     * 打开抽屉。
     *
     * @param allRows 全量行（含被折叠层级）
     * @param currentTarget 当前所在的章节索引 / 页索引；用于高亮 + 自动展开其祖先 + 滚动到它
     */
    fun show(allRows: List<TocRow>, currentTarget: Int) {
        this.allRows = allRows
        this.currentTarget = currentTarget
        // 默认只展开当前项的祖先链：长目录若一次全铺开会把当前项挤到屏幕外
        this.expanded = ancestorsOf(allRows, currentTarget)
        adapter.submit(allRows, expanded, currentTarget)

        scrim.visibility = View.VISIBLE
        scrim.alpha = 0f
        scrim.animate().alpha(1f).setDuration(200).start()

        panel.visibility = View.VISIBLE
        // 首次打开时 panel.width 仍为 0（未测量），此时设 translationX 等于没设，会「闪出」无动画；
        // 故等一次布局后再设起点并滑入。滚动定位也放这里，保证 adapter 已刷新。
        panel.post {
            panel.translationX = -panel.width.toFloat()
            panel.animate().translationX(0f).setDuration(200).start()
            val index = adapter.indexOfTarget(currentTarget)
            if (index >= 0) recycler.scrollToPosition(index)
        }
    }

    /** 关闭抽屉（带滑出动画）。 */
    fun hide() {
        if (!isShowing) return
        scrim.animate().alpha(0f).setDuration(160).withEndAction { scrim.visibility = View.GONE }.start()
        panel.animate().translationX(-panel.width.toFloat()).setDuration(160).withEndAction {
            panel.visibility = View.GONE
        }.start()
    }

    /**
     * 算出当前项的祖先 id 集合（用于默认展开）。
     *
     * id 是 DFS 兄弟序号路径（如 `"0/2/1"`），故祖先即其各级前缀：`"0"`、`"0/2"`。
     */
    private fun ancestorsOf(rows: List<TocRow>, target: Int): Set<String> {
        if (target < 0) return emptySet()
        val id = rows.firstOrNull { it.targetIndex == target }?.id ?: return emptySet()
        val parts = id.split('/')
        val out = LinkedHashSet<String>()
        for (level in 1 until parts.size) {
            out.add(parts.subList(0, level).joinToString("/"))
        }
        return out
    }

    /** 切换某个节点的折叠状态，然后按新集合重算可见行。 */
    private fun toggle(id: String) {
        expanded = if (expanded.contains(id)) expanded - id else expanded + id
        adapter.submit(allRows, expanded, currentTarget)
    }

    /** 头部行：左「目录」标题、右「×」关闭。 */
    private fun buildHeader(context: Context): LinearLayout {
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(
                (16 * density).toInt(), (12 * density).toInt(),
                (16 * density).toInt(), (12 * density).toInt(),
            )
        }
        val title = TextView(context).apply {
            text = "目录"
            textSize = 15f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(0xFF212121.toInt())
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val close = TextView(context).apply {
            text = "×"
            textSize = 20f
            gravity = Gravity.CENTER
            setTextColor(0xFF616161.toInt())
            isClickable = true
            isFocusable = true
            setPadding((12 * density).toInt(), 0, (12 * density).toInt(), 0)
            minimumHeight = (44 * density).toInt() // 触控目标不小于 44dp
            setOnClickListener { hide() }
        }
        header.addView(title)
        header.addView(close)
        return header
    }
}
