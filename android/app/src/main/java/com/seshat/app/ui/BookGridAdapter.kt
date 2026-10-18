package com.seshat.app.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R
import com.seshat.app.reader.BookItem

/**
 * 书架网格适配器：把 [BookItem] 绑定到 [R.layout.item_book_card]。
 *
 * 单本书展示要素：封面（由外部 [coverLoader] 异步加载）+ 进度徽标（未读时隐藏）+ 标题 + 作者。
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

    /** 单本书视图持有者。 */
    class BookHolder(view: View) : RecyclerView.ViewHolder(view) {
        val cover: ImageView = view.findViewById(R.id.bookCover)
        val progress: TextView = view.findViewById(R.id.bookProgress)
        val title: TextView = view.findViewById(R.id.bookTitle)
        val author: TextView = view.findViewById(R.id.bookAuthor)
    }

    /** 用 [newItems] 整体替换当前列表并刷新。 */
    fun submit(newItems: List<BookItem>) {
        items.clear()
        items.addAll(newItems)
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

        // 进度徽标：0% 视为未读，隐藏以避免干扰
        if (item.percent > 0) {
            holder.progress.visibility = View.VISIBLE
            holder.progress.text = context.getString(R.string.shelf_progress, item.percent)
        } else {
            holder.progress.visibility = View.GONE
        }

        // 复用校验键：本视图即将展示哪本书
        holder.cover.tag = item.progressKey
        // 先清掉上一本书的位图，避免复用瞬间闪出别人的封面
        holder.cover.setImageDrawable(null)
        coverLoader(item, holder.cover)

        // 点击整张卡片回调（每次 bind 重设，避免视图复用串号）
        holder.itemView.setOnClickListener { onClick(item) }
    }

    override fun getItemCount(): Int = items.size
}
