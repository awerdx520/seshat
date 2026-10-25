package com.seshat.app.reader

import android.content.Context
import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableString
import android.text.TextUtils
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
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
 * 左侧滑出的目录抽屉（M10.9 / M10.10）。
 *
 * **为什么不用 `DrawerLayout`**：它自带**边缘横向滑动手势**，会和横向阅读的翻页滑动抢事件；
 * 锁死手势又失去使用它的意义。故自实现：遮罩 + 面板 + `translationX` 动画，
 * **只允许从顶部「目录」按钮打开**。
 *
 * 抽屉是**覆盖层**，不是阅读器浮层：开合不触碰阅读区 padding（不要学 `applyContentPadding`）。
 *
 * 面板结构（自上而下）：
 * 1. 头部行：只有右对齐的「×」关闭（40dp 高；当前在哪个标签由 tab 行表明，重复标题是噪音）；
 * 2. tab 行：「目录」/「书签」两个等宽标签（40dp 高）；
 * 3. 2dp 指示条（宽度 = 面板宽 / 2，切换时 `translationX` 平移）；
 * 4. 1dp 分隔线；
 * 5. 内容区：目录列表 / 书签页（含空态）二选一，占满剩余高度；
 * 6. 「+ 增加新书签」按钮（仅书签页可见）；
 * 7. 底部固定状态行（文案由调用方按当前阅读位置拼好传入，空串则整行隐藏）。
 *
 * 全部视图由代码构建（不新增 XML 布局 / drawable，也不引用任何资源 id 常量），
 * 挂到 Activity 的内容容器（一个 `FrameLayout`）上即可，两者共用。
 *
 * @param root 抽屉挂载的容器（Activity 的内容容器，是个 `FrameLayout`）
 * @param onPick 点击可跳转行（`targetIndex >= 0`）时回调（目录行给章节/页索引，书签行给书签页索引）
 */
internal class TocDrawer(
    private val root: FrameLayout,
    private val onPick: (Int) -> Unit,
) {
    private val density: Float = root.resources.displayMetrics.density

    /** 面板宽度：300dp 与屏宽 72% 取小（窄屏不铺满，留出一道可见的阅读区提示可点遮罩关闭）。 */
    private val panelWidth: Int = min(
        (300 * density).toInt(),
        (root.resources.displayMetrics.widthPixels * 0.72f).toInt(),
    )

    /** 全量行（含被折叠层级）。 */
    private var allRows: List<TocRow> = emptyList()

    /** 已展开节点的 id 集合。 */
    private var expanded: Set<String> = emptySet()

    /** 当前所在项的 targetIndex，用于高亮 + 默认展开其祖先链。 */
    private var currentTarget: Int = -1

    /** 「+ 增加新书签」的点击回调；每次 [show] 覆盖（回调由调用方持有，抽屉不长期保存业务对象）。 */
    private var bookmarkAddAction: () -> Unit = {}

    /** 书签行 × 的删除回调；每次 [show] 覆盖。 */
    private var bookmarkDeleteAction: (PdfBookmark) -> Unit = {}

    /** 当前选中标签（0 = 目录，1 = 书签）；刷新已打开的抽屉时据此保留用户所在标签。 */
    private var selectedTab: Int = 0

    private val adapter = TocAdapter(
        onToggle = { id -> toggle(id) },
        onPick = { row ->
            hide()
            onPick(row.targetIndex)
        },
    )

    /** 书签列表适配器：点行跳转（同样先收起抽屉），点 × 走 [bookmarkDeleteAction]。 */
    private val bookmarkAdapter = BookmarkAdapter(
        onPick = { bookmark ->
            hide()
            onPick(bookmark.page)
        },
        onDelete = { bookmark -> bookmarkDeleteAction(bookmark) },
    )

    private val recycler = RecyclerView(root.context).apply {
        layoutManager = LinearLayoutManager(context)
        itemAnimator = null // 刷新走整体 notifyDataSetChanged，动画只会造成闪烁
        adapter = this@TocDrawer.adapter
        // 高度 0dp + weight 1f：占满头部与底部之外的剩余空间
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
    }

    private val bookmarkRecycler = RecyclerView(root.context).apply {
        layoutManager = LinearLayoutManager(context)
        itemAnimator = null
        adapter = this@TocDrawer.bookmarkAdapter
        visibility = View.VISIBLE
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
    }

    /** 书签空态：「尚无书签」15sp + 提示 12sp，两行文案用 Span 区分字号与灰度（不新增字符串资源）。 */
    private val bookmarkEmpty = TextView(root.context).apply {
        text = buildEmptyBookmarkText(bookmarksSupported = true)
        gravity = Gravity.CENTER
        textSize = 15f
        visibility = View.GONE
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
    }

    /** 书签页容器（列表 + 空态二选一），与目录列表在同一位置互换显示。 */
    private val bookmarkPage = LinearLayout(root.context).apply {
        orientation = LinearLayout.VERTICAL
        visibility = View.GONE
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
        addView(bookmarkRecycler)
        addView(bookmarkEmpty)
    }

    /** 「+ 增加新书签」：仅在书签页可见（列表态与空态都显示）。 */
    private val addBookmarkButton = TextView(root.context).apply {
        text = "+ 增加新书签"
        textSize = 14f
        gravity = Gravity.CENTER
        setTextColor(0xFF1565C0.toInt())
        isClickable = true
        isFocusable = true
        minimumHeight = (44 * density).toInt()
        visibility = View.GONE
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (44 * density).toInt(),
        )
        setOnClickListener { bookmarkAddAction() }
    }

    /** 底部固定状态行（如「第 3 章 · 2/3」）；空串时整行 GONE，不占高度。 */
    private val statusLineView = TextView(root.context).apply {
        textSize = 12f
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        setTextColor(0xFF757575.toInt())
        setPaddingRelative(
            (12 * density).toInt(), (8 * density).toInt(),
            (12 * density).toInt(), (8 * density).toInt(),
        )
        visibility = View.GONE
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
    }

    /** 「目录」标签（等宽左半）。 */
    private val tabToc = buildTab(root.context, "目录") { selectTab(0) }

    /** 「书签」标签（等宽右半）。 */
    private val tabBookmark = buildTab(root.context, "书签") { selectTab(1) }

    /** 2dp 指示条：宽度固定为面板宽的一半，切换 tab 时靠 translationX 平移。 */
    private val tabIndicator = View(root.context).apply {
        setBackgroundColor(0xFF1565C0.toInt())
        layoutParams = LinearLayout.LayoutParams(
            panelWidth / 2,
            (2 * density).toInt(),
        )
    }

    /** 遮罩：半透明黑，点击关闭抽屉。 */
    private val scrim = View(root.context).apply {
        setBackgroundColor(0x99000000.toInt())
        isClickable = true
        visibility = View.GONE
        setOnClickListener { hide() }
    }

    /** 面板：头部 + tab 行 + 指示条 + 分隔线 + 内容区 + 书签按钮 + 状态行。 */
    private val panel = LinearLayout(root.context).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(0xFFF7F7F7.toInt())
        // 必须可点击：否则点面板空白处会穿透到遮罩，把抽屉直接关掉
        isClickable = true
        visibility = View.GONE
        addView(buildHeader(context))
        addView(buildTabRow(context))
        addView(tabIndicator)
        // tab 行与内容区之间的细分隔线：不用 drawable（1dp View 即可）
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
        addView(bookmarkPage)
        addView(addBookmarkButton)
        addView(statusLineView)
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

    /** 旧签名：仅目录（Q3 接线前由两个 Activity 使用）。 */
    fun show(allRows: List<TocRow>, currentTarget: Int) = show(
        allRows = allRows,
        currentTarget = currentTarget,
        statusLine = "",
        bookmarks = emptyList(),
        onBookmarkAdd = {},
        onBookmarkDelete = {},
    )

    /**
     * 新签名：目录 + 书签 + 底部状态行。
     *
     * **首次打开**会把抽屉重置回「目录」标签、并把书签页恢复到列表态/空态之一，
     * 避免上次留下的标签或滚动位置造成困惑。
     *
     * **已显示时再次调用**（书签增删后的刷新路径）不做入场动画、不重置标签页，
     * 只替换数据并滚动到当前项——否则会「面板重新滑入 + 遮罩闪一下」，
     * 且用户在「书签」页删一条就被弹回「目录」页。
     *
     * @param allRows 全量行（含被折叠层级）
     * @param currentTarget 当前所在的章节索引 / 页索引；用于高亮、已读标记 + 自动展开其祖先 + 滚动到它
     * @param statusLine 底部固定状态行文案（如「第 3 章 · 2/3」或「第 5/12 页 · 3 个书签」）；空串则不显示该行
     * @param bookmarks 书签列表（按页升序）
     * @param onBookmarkAdd 「增加新书签」按钮回调
     * @param onBookmarkDelete 书签行 × 回调
     * @param bookmarksSupported 当前阅读器是否支持书签：EPUB 没有任何书签入口（调用方传
     *   `bookmarks = emptyList()`），此时空态**不能**渲染「点顶栏的书签图标可添加」的指引
     *   （那是个不存在的按钮），只保留「尚无书签」一行
     */
    fun show(
        allRows: List<TocRow>,
        currentTarget: Int,
        statusLine: String,
        bookmarks: List<PdfBookmark>,
        onBookmarkAdd: () -> Unit,
        onBookmarkDelete: (PdfBookmark) -> Unit,
        bookmarksSupported: Boolean = true,
    ) {
        val refresh = isShowing
        this.allRows = allRows
        this.currentTarget = currentTarget
        this.bookmarkAddAction = onBookmarkAdd
        this.bookmarkDeleteAction = onBookmarkDelete
        // 默认只展开当前项的祖先链：长目录若一次全铺开会把当前项挤到屏幕外
        this.expanded = ancestorsOf(allRows, currentTarget)
        adapter.submit(allRows, expanded, currentTarget)

        bookmarkAdapter.submit(bookmarks)
        val hasBookmarks = bookmarks.isNotEmpty()
        bookmarkRecycler.visibility = if (hasBookmarks) View.VISIBLE else View.GONE
        bookmarkEmpty.visibility = if (hasBookmarks) View.GONE else View.VISIBLE
        // 空态文案随「是否支持书签」重建：EPUB 只留标题，不提示不存在的入口
        bookmarkEmpty.text = buildEmptyBookmarkText(bookmarksSupported)

        statusLineView.text = statusLine
        statusLineView.visibility = if (statusLine.isEmpty()) View.GONE else View.VISIBLE

        // 首次打开停在目录标签；刷新时保留用户当前标签，不做指示条动画（面板已显示，动画没有意义）
        selectTab(if (refresh) selectedTab else 0, animate = false)

        if (!refresh) {
            scrim.visibility = View.VISIBLE
            scrim.alpha = 0f
            scrim.animate().alpha(1f).setDuration(200).start()

            panel.visibility = View.VISIBLE
        }
        // 首次打开时 panel.width 仍为 0（未测量），此时设 translationX 等于没设，会「闪出」无动画；
        // 故等一次布局后再设起点并滑入。滚动定位也放这里，保证 adapter 已刷新。
        panel.post {
            if (!refresh) {
                panel.translationX = -panel.width.toFloat()
                panel.animate().translationX(0f).setDuration(200).start()
            }
            // 刷新后书签行可能变少，滚动定位统一交给下面的 indexOfTarget
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
     * 切换到指定标签页。
     *
     * @param index 0 = 目录，1 = 书签
     * @param animate 是否给指示条做 150ms 平移动画（[show] 里重置为目录时传 false）
     */
    private fun selectTab(index: Int, animate: Boolean = true) {
        val showBookmarks = index == 1
        selectedTab = if (showBookmarks) 1 else 0
        recycler.visibility = if (showBookmarks) View.GONE else View.VISIBLE
        bookmarkPage.visibility = if (showBookmarks) View.VISIBLE else View.GONE
        // 书签页附带「+ 增加新书签」；目录页不需要
        addBookmarkButton.visibility = if (showBookmarks) View.VISIBLE else View.GONE
        tabToc.setTextColor(if (showBookmarks) 0xFF616161.toInt() else 0xFF212121.toInt())
        tabBookmark.setTextColor(if (showBookmarks) 0xFF212121.toInt() else 0xFF616161.toInt())
        tabToc.setTypeface(null, if (showBookmarks) Typeface.NORMAL else Typeface.BOLD)
        tabBookmark.setTypeface(null, if (showBookmarks) Typeface.BOLD else Typeface.NORMAL)

        val target = if (showBookmarks) panelWidth / 2f else 0f
        if (animate) {
            tabIndicator.animate().translationX(target).setDuration(150).start()
        } else {
            tabIndicator.animate().cancel()
            tabIndicator.translationX = target
        }
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

    /** 头部行：只保留右对齐的「×」关闭（标题由 tab 行表明，重复标题是噪音）；高度 40dp。 */
    private fun buildHeader(context: Context): LinearLayout {
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL or Gravity.END
            setPadding(0, 0, (12 * density).toInt(), 0)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, (40 * density).toInt(),
            )
        }
        val close = TextView(context).apply {
            text = "×"
            textSize = 18f
            gravity = Gravity.CENTER
            setTextColor(0xFF616161.toInt())
            isClickable = true
            isFocusable = true
            setPadding((12 * density).toInt(), 0, (12 * density).toInt(), 0)
            minimumHeight = (40 * density).toInt() // 头部已降到 40dp，触控目标随之对齐
            setOnClickListener { hide() }
        }
        header.addView(close)
        return header
    }

    /** tab 行：两个等宽标签，40dp 高。 */
    private fun buildTabRow(context: Context): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, (40 * density).toInt(),
        )
        addView(tabToc)
        addView(tabBookmark)
    }

    /** 单个 tab 标签：weight = 1 等分宽度、居中、14sp。 */
    private fun buildTab(context: Context, label: String, onClick: () -> Unit): TextView =
        TextView(context).apply {
            text = label
            textSize = 14f
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            minimumHeight = (40 * density).toInt()
            setTextColor(0xFF616161.toInt())
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f)
            setOnClickListener { onClick() }
        }

    /**
     * 书签空态文案：「尚无书签」15sp `#9E9E9E` + 提示行 12sp `#BDBDBD`（同色系更淡）。
     *
     * 提示行由 [TocDrawerText.emptyBookmarkLines] 决定：不支持书签的阅读器（EPUB）没有顶栏
     * 书签图标，此时只渲染标题一行——否则就是在指引用户去点一个不存在的按钮。
     */
    private fun buildEmptyBookmarkText(bookmarksSupported: Boolean): CharSequence {
        val lines = TocDrawerText.emptyBookmarkLines(bookmarksSupported)
        val first = lines.first
        val hint = lines.second
        val text = if (hint == null) first else "$first\n$hint"
        val span = SpannableString(text)
        span.setSpan(
            ForegroundColorSpan(0xFF9E9E9E.toInt()),
            0, first.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
        if (hint != null) {
            // 基线 15sp，提示行按 0.8 倍缩到 12sp（用相对倍率以跟随系统字体缩放）
            val hintStart = first.length + 1
            span.setSpan(
                RelativeSizeSpan(0.8f),
                hintStart, text.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
            span.setSpan(
                ForegroundColorSpan(0xFFBDBDBD.toInt()),
                hintStart, text.length, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        return span
    }
}
