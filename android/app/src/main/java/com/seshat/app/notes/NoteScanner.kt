package com.seshat.app.notes

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File

/**
 * 笔记扫描器。
 *
 * - [scanLocal]：私有目录扫描，纯 JVM（只用 `java.io.File`），可单测；
 * - [scanSaf]：SAF 目录扫描，需要 `ContentResolver`（Android 框架），无纯 JVM 单测。
 *
 * 两者共用同一套「扩展名过滤 + 标题回退链 + 排序」规则，保证列表行为一致。
 */
internal object NoteScanner {

    /** 支持的扩展名（忽略大小写）。 */
    val SUPPORTED_EXTENSIONS = setOf("org", "md")

    /** org heading：允许 TODO 关键字与优先级 cookie。 */
    private val ORG_HEADING =
        Regex("""^\*+\s+(?:(?:TODO|DONE|NEXT|WAITING|CANCELLED)\s+)?(?:\[#[A-Z]\]\s*)?(.+)$""")

    /** markdown heading（1~6 级）。 */
    private val MARKDOWN_HEADING = Regex("""^#{1,6}\s+(.+)$""")

    /** org heading 末尾的 `:tag1:tag2:` 段。 */
    private val ORG_TRAILING_TAGS = Regex("""\s+:[\w@:]+:$""")

    /** markdown 标题末尾的可选闭合 `#`。 */
    private val MARKDOWN_TRAILING_HASHES = Regex("""#+$""")

    /** org `#+FILETAGS:` 关键字行：允许前导空白，关键字大小写不敏感。 */
    private val ORG_FILETAGS = Regex("""^\s*#\+filetags:\s*(.*)$""", RegexOption.IGNORE_CASE)

    /**
     * 扫描本地目录（不递归子目录）：
     * - 只收扩展名为 org/md 的普通文件；
     * - 标题回退链：denote 解析 → 文件首个 heading → 文件名去扩展名；
     * - 按 modifiedAt 倒序（新→旧），时间相同按标题升序保证顺序稳定。
     *
     * 目录不存在/不可读 → 返回空表（不抛）。
     *
     * @param dir 待扫描目录。
     * @param source 结果中每条笔记的来源标记。
     */
    fun scanLocal(dir: File, source: NoteSourceKind = NoteSourceKind.PRIVATE): List<NoteItem> {
        val files = dir.listFiles() ?: return emptyList()
        return files.asSequence()
            .filter { it.isFile }
            .mapNotNull { file -> toItem(file, source) }
            .sortedWith(compareByDescending<NoteItem> { it.modifiedAt }.thenBy { it.title })
            .toList()
    }

    /** 单文件 → [NoteItem]；扩展名不支持时返回 `null`。 */
    private fun toItem(file: File, source: NoteSourceKind): NoteItem? {
        val format = formatOf(file.extension) ?: return null
        val denote = DenoteName.parse(file.name)
        // 只有在「需要文件内容」时才读一次（denote 有标签且能给出标题时完全不读）：
        // ① denote 未命中 → 要找标题回退链里的首个 heading；② denote 命中但无标签 → 要找 #+FILETAGS:
        val text = if (needsText(denote)) readTextOrEmpty(file) else null
        val title = denote?.title
            ?: firstHeading(text.orEmpty(), format)
            ?: file.nameWithoutExtension
        return NoteItem(
            ref = NoteRef.LocalFile(file),
            title = title,
            format = format,
            modifiedAt = file.lastModified(),
            tags = tagsOf(denote, text),
            source = source,
        )
    }

    /** 是否需要读文件内容（详见 [toItem] 的两条读文件理由）。 */
    private fun needsText(denote: DenoteName.ParsedName?): Boolean =
        denote == null || denote.tags.isEmpty()

    /**
     * 标签合并：denote 文件名标签优先；denote 缺失或为空时回退到 org 的 `#+FILETAGS:`。
     *
     * @param text 文件内容；denote 有标签时为 `null`（此时无需读文件）。
     */
    private fun tagsOf(denote: DenoteName.ParsedName?, text: String?): List<String> =
        denote?.tags?.takeIf { it.isNotEmpty() } ?: fileTags(text.orEmpty())

    /**
     * 扫描 SAF 目录（只遍历一层，不递归）：
     * - 用 [DocumentsContract] 查询子文档，取非目录且扩展名命中的项；
     * - 标题回退链同 [scanLocal]（denote → 首个 heading → 文件名）；读内容需 [resolver]；
     * - 按 modifiedAt 倒序；任何异常 → 返回已扫到的部分（不抛）。
     *
     * 只遍历一层：SAF 子目录需要用户逐个授权，且深度遍历在大目录下查询成本高；
     * 需要多层目录时由用户再次添加目录即可。
     *
     * @param resolver 用于查询与读取文档内容。
     * @param treeUri 用户授权的目录树（`ACTION_OPEN_DOCUMENT_TREE` 的结果）。
     * @return 命中的笔记；授权失效（[SecurityException]）时返回空表。
     */
    fun scanSaf(resolver: ContentResolver, treeUri: Uri): List<NoteItem> {
        val items = mutableListOf<NoteItem>()
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
            resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(0) ?: continue
                    val displayName = cursor.getString(1) ?: continue
                    // 子目录跳过（只遍历一层）
                    if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                    val format = formatOf(displayName.substringAfterLast('.', "")) ?: continue
                    // provider 可能不提供修改时间（列为 null）→ 当作 0，排序时沉底
                    val modifiedAt = if (cursor.isNull(3)) 0L else cursor.getLong(3)
                    items += toSafItem(
                        resolver = resolver,
                        treeUri = treeUri,
                        documentId = documentId,
                        displayName = displayName,
                        format = format,
                        modifiedAt = modifiedAt,
                    )
                }
            }
        } catch (_: SecurityException) {
            // 授权失效（用户撤销了目录访问权限）：视为没有笔记，不抛给 UI
            return emptyList()
        } catch (_: Exception) {
            // 查询/读取中途失败：保留已扫到的部分
        }
        return items.sortedWith(compareByDescending<NoteItem> { it.modifiedAt }.thenBy { it.title })
    }

    /** 单个 SAF 子文档 → [NoteItem]；标题回退链与 [scanLocal] 一致。 */
    private fun toSafItem(
        resolver: ContentResolver,
        treeUri: Uri,
        documentId: String,
        displayName: String,
        format: NoteFormat,
        modifiedAt: Long,
    ): NoteItem {
        val ref = NoteRef.SafDocument(DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId))
        // SAF 读流很贵：仅「需要内容」时才读一次（denote 有标签且给出标题时不读）
        val denote = DenoteName.parse(displayName)
        val text = if (needsText(denote)) NoteReader.read(ref, resolver) else null
        val title = denote?.title
            ?: firstHeading(text.orEmpty(), format)
            ?: displayName.substringBeforeLast('.', displayName)
        return NoteItem(
            ref = ref,
            title = title,
            format = format,
            modifiedAt = modifiedAt,
            tags = tagsOf(denote, text),
            source = NoteSourceKind.EXTERNAL,
        )
    }

    /** 扩展名 → 格式；不支持返回 `null`。 */
    private fun formatOf(extension: String): NoteFormat? = when (extension.lowercase()) {
        "org" -> NoteFormat.ORG
        "md" -> NoteFormat.MARKDOWN
        else -> null
    }

    /** 读文本；IO 异常或非 UTF-8 内容时返回空串，让标题回退到文件名。 */
    private fun readTextOrEmpty(file: File): String =
        runCatching { file.readText() }.getOrDefault("")

    /**
     * 从文件文本提取首个 heading（org 的 `*`~ 或 markdown 的 `#`）；没有返回 null。
     *
     * org 的 `#+TITLE:` 等关键字行不是 heading（不以 `*` 开头），自然被跳过。
     */
    fun firstHeading(text: String, format: NoteFormat): String? {
        val regex = when (format) {
            NoteFormat.ORG -> ORG_HEADING
            NoteFormat.MARKDOWN -> MARKDOWN_HEADING
        }
        text.lineSequence().forEach { rawLine ->
            val line = rawLine.trimEnd()
            val match = regex.matchEntire(line) ?: return@forEach
            val cleaned = when (format) {
                NoteFormat.ORG -> match.groupValues[1].replace(ORG_TRAILING_TAGS, "")
                NoteFormat.MARKDOWN -> match.groupValues[1].replace(MARKDOWN_TRAILING_HASHES, "")
            }.trim()
            // 去掉标签/闭合 # 后为空 → 继续找下一个 heading
            if (cleaned.isNotEmpty()) return cleaned
        }
        return null
    }

    /**
     * 从 org 文本提取 `#+FILETAGS: :a:b:` 的标签列表；不存在返回空表。
     *
     * 规则：行首匹配 `#+FILETAGS:`（允许前导空白、忽略大小写）→ 取其后内容 →
     * 去首尾空白与 `:` → 按 `:` 分割 → 过滤空串。只取第一处命中（每文件一个关键字的常态）。
     */
    fun fileTags(text: String): List<String> {
        text.lineSequence().forEach { rawLine ->
            val match = ORG_FILETAGS.matchEntire(rawLine.trimEnd()) ?: return@forEach
            val body = match.groupValues[1].trim().trim(':')
            return body.split(':').filter { it.isNotEmpty() }
        }
        return emptyList()
    }
}
