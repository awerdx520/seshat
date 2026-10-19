package com.seshat.app.notes

import android.net.Uri
import java.io.File

/** 笔记格式（本计划只支持这两种）。 */
enum class NoteFormat { ORG, MARKDOWN }

/** 笔记来源（决定是否可写）。 */
enum class NoteSourceKind { PRIVATE, EXTERNAL }

/**
 * 统一引用：私有目录文件或 SAF 文档。
 *
 * [LocalFile] 可写（走 java.io.File）；[SafDocument] 只读（避免跨 provider 写入语义差异）。
 */
sealed interface NoteRef {
    data class LocalFile(val file: File) : NoteRef
    data class SafDocument(val uri: Uri) : NoteRef
}

/**
 * 书架/列表用的一条笔记。
 *
 * @property ref 底层引用（本地文件或 SAF 文档）。
 * @property title 展示标题（来源见 [NoteScanner] 的回退链）。
 * @property format 笔记格式。
 * @property modifiedAt 最后修改时间（毫秒时间戳）。
 * @property tags 标签（denote 文件名中的标签优先；denote 无标签时取 org 的 `#+FILETAGS:`；都没有为空表）。
 * @property source 来源，决定是否可写。
 */
data class NoteItem(
    val ref: NoteRef,
    val title: String,
    val format: NoteFormat,
    val modifiedAt: Long,
    val tags: List<String>,
    val source: NoteSourceKind,
)
