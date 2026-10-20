package com.seshat.app.reader

/**
 * 目录树节点（EPUB 章节树与 PDF 书签树的统一模型，M10.9）。
 *
 * **不加 `internal`**：它出现在 public 的 [EpubBook.tocTree] 上，Kotlin 不允许 public 类暴露
 * internal 类型（会编译失败）。
 */
data class TocNode(
    /** 标题；容器节点（`<li>` 内无 `<a>`）为空串，占位文案由展示层注入。 */
    val title: String,
    /**
     * 跳转目标（EPUB）：**已归一化的 epub 根相对路径**（如 `OEBPS/text/ch1.xhtml`），
     * 由 [EpubParser.parseNavTree] / [EpubParser.parseNcxTree] 用**文档自身所在目录**作 base 归一化。
     * 容器节点为 null；PDF 恒为 null（用 [pageIndex]）。
     */
    val href: String? = null,
    /** 跳转目标页（PDF 用；EPUB 恒 -1）。 */
    val pageIndex: Int = -1,
    val children: List<TocNode> = emptyList(),
)
