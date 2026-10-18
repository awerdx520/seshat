package com.seshat.app.reader

/**
 * 章节目录对话框的条目文案构造（纯逻辑，无 Android 依赖，可 JVM 单测）。
 *
 * 为什么单独抽出来：[EpubChapter.title] 虽是非空 `String`，但解析层在目录（nav/NCX）里
 * 找不到对应条目时会回退文件名，极端情况下仍可能是空白串；而「空白标题用什么占位文案」
 * 需要 Android 资源（`getString`），两者混在 Activity 里就不可单测。这里把「序号 + 标题
 * + 空白回退」的纯文本规则与资源取值分离：Activity 传入已解析好的占位文案。
 */
internal object TocItemText {

    /**
     * 章节列表 → 目录条目文案（`"1. 标题"`，序号 1-based，与 `chapters` 的 spine 顺序一致）。
     *
     * @param missingTitle 标题不可用（空串或全空白）时的占位文案（由调用方从资源取）。
     */
    fun labels(chapters: List<EpubChapter>, missingTitle: String): List<String> =
        chapters.mapIndexed { i, chapter ->
            val title = chapter.title.trim().takeIf { it.isNotEmpty() } ?: missingTitle
            "${i + 1}. $title"
        }
}
