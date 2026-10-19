package com.seshat.app.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R
import com.seshat.app.reader.BookItem
import com.seshat.app.reader.CoverKeys

/**
 * 书架网格适配器：把 [BookItem] 绑定到 [R.layout.item_book_card]。
 *
 * 单本书展示要素：封面（由外部 [coverLoader] 异步加载）+ 书名首字占位（封面缺失/解码失败时显示）
 * + 进度徽标（未读时隐藏）+ 标题 + 作者。
 *
 * 封面加载刻意交给调用方（Fragment）注入：本类不持有线程、缓存与 Context，
 * 便于后续替换为别的加载策略；也避免适配器与 [com.seshat.app.reader.CoverCache] 耦合。
 *
 * MVP 说明：整体替换 + [notifyDataSetChanged]（与 [com.seshat.app.gtd.GtdEntryAdapter] 一致）；
 * 书量在数百级别，无需 DiffUtil。
 *
 * @param onClick     单本书点击回调（打开阅读器）。
 * @param coverLoader 封面加载器：负责后台解码与回主线程 set；约定实现方用 `imageView.tag`
 *                    做复用校验（视图可能已被复用给另一本书）。
 */
class BookGridAdapter(
    private val onClick: (BookItem) -> Unit,
    private val coverLoader: (BookItem, ImageView) -> Unit,
) : RecyclerView.Adapter<BookGridAdapter.BookHolder>() {

    private val items = mutableListOf<BookItem>()

    /** 正在下载的文件名集合（`BookItem.file.name`）；由 Fragment 维护，用于显示「下载中…」。 */
    private val downloading = HashSet<String>()

    /** 单本书视图持有者。 */
    class BookHolder(view: View) : RecyclerView.ViewHolder(view) {
        val cover: ImageView = view.findViewById(R.id.bookCover)
        /** 封面缺失/解码失败时叠在封面上方的书名首字占位（M10.8）。 */
        val coverInitial: TextView = view.findViewById(R.id.coverInitial)
        val progress: TextView = view.findViewById(R.id.bookProgress)
        val status: TextView = view.findViewById(R.id.bookStatus)
        val title: TextView = view.findViewById(R.id.bookTitle)
        val author: TextView = view.findViewById(R.id.bookAuthor)
    }

    /**
     * 用 [newItems] 整体替换当前列表并刷新。
     *
     * @param newItems    书架条目（本地 + 远端未下载占位）
     * @param downloading 正在下载的文件名集合（按 `file.name` 匹配，与下载落点一致）
     */
    fun submit(newItems: List<BookItem>, downloading: Set<String> = emptySet()) {
        items.clear()
        items.addAll(newItems)
        this.downloading.clear()
        this.downloading.addAll(downloading)
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): BookHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_book_card, parent, false)
        return BookHolder(view)
    }

    override fun onBindViewHolder(holder: BookHolder, position: Int) {
        val item = items[position]
        val context = holder.itemView.context

        holder.title.text = item.title
        // 作者未知（PDF 恒为 null）时留空，而不是占位文案：卡片空间有限
        holder.author.text = item.author.orEmpty()

        // 进度徽标：0% 视为未读，隐藏以避免干扰；远端未下载条目 percent 恒 0，一并隐藏
        if (item.percent > 0 && item.isDownloaded) {
            holder.progress.visibility = View.VISIBLE
            holder.progress.text = context.getString(R.string.shelf_progress, item.percent)
        } else {
            holder.progress.visibility = View.GONE
        }

        // 状态徽标：下载中 优先于 未下载（下载中的条目同样 isDownloaded = false）
        when {
            item.file.name in downloading -> {
                holder.status.visibility = View.VISIBLE
                holder.status.text = context.getString(R.string.book_downloading)
            }

            !item.isDownloaded -> {
                holder.status.visibility = View.VISIBLE
                holder.status.text = context.getString(R.string.book_not_downloaded)
            }

            else -> holder.status.visibility = View.GONE
        }

        // 复用校验键：本视图即将展示哪本书
        holder.cover.tag = item.progressKey
        // 先清掉上一本书的位图，避免复用瞬间闪出别人的封面
        holder.cover.setImageDrawable(null)
        // 封面占位：先显示书名首字；解码成功时由 loadCover 隐藏（失败/无封面则继续显示，M10.8）
        holder.coverInitial.text = CoverKeys.initialOf(item.title)
        holder.coverInitial.visibility = View.VISIBLE
        // 未下载的条目没有本地文件：只露出占位底色 + 首字，不触发封面解码
        if (item.isDownloaded) {
            coverLoader(item, holder.cover)
        }

        // 点击整张卡片回调（每次 bind 重设，避免视图复用串号）
        holder.itemView.setOnClickListener { onClick(item) }
    }

    override fun getItemCount(): Int = items.size
}
