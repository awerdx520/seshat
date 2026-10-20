package com.seshat.app.reader

import java.io.ByteArrayInputStream
import java.io.File
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.zip.ZipInputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import org.w3c.dom.Node
import org.xml.sax.InputSource

/**
 * epub 内容读取抽象：屏蔽 zip 来源，便于单测用内存 zip 构造 [ByteArrayEpubSource]。
 */
interface EpubSource {
    /** zip 内全部条目的原始名称。 */
    fun names(): Set<String>

    /** 读取条目内容；不存在返回 null。 */
    fun read(name: String): ByteArray?
}

/**
 * 基于 zip 字节的 [EpubSource]：整本书解压进内存（MVP 书籍体积可接受，且避免磁盘缓存管理）。
 *
 * 条目查找做了容错：先按原始名精确匹配，其次按「URL 解码 + 去前导斜杠 + 统一分隔符」规范化后的名字匹配，
 * 以兼容 OPF 中 `%20` 编码或带前导 `/` 的 href。
 */
class ByteArrayEpubSource(bytes: ByteArray) : EpubSource {
    private val entries = LinkedHashMap<String, ByteArray>()
    private val normalizedIndex = HashMap<String, String>()

    init {
        ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
            while (true) {
                val entry = zis.nextEntry ?: break
                if (!entry.isDirectory) {
                    entries[entry.name] = zis.readBytes()
                    normalizedIndex.putIfAbsent(normalizeEntryName(entry.name), entry.name)
                }
            }
        }
    }

    override fun names(): Set<String> = entries.keys

    override fun read(name: String): ByteArray? {
        entries[name]?.let { return it }
        return normalizedIndex[normalizeEntryName(name)]?.let { entries[it] }
    }
}

/** 从文件构造 [EpubSource]。 */
fun zipSourceOf(file: File): EpubSource = ByteArrayEpubSource(file.readBytes())

/**
 * 文档标识：epub 字节内容的 SHA-256 前 16 字节（32 位十六进制）。
 *
 * 用内容哈希而非路径，跨设备/跨重命名稳定，便于 M3.4 与服务端 `document_id` 对齐。
 */
fun documentIdOf(data: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(data)
    return buildString(digest.size * 2) {
        digest.forEach { b -> append("%02x".format(b)) }
    }.substring(0, 32)
}

/** OPF manifest 项。 */
data class ManifestItem(
    val id: String,
    val href: String,
    val mediaType: String,
    val properties: String,
)

/** 章节：`index` 为 spine 顺序，`href` 为相对 epub 根的路径（已去 fragment）。 */
data class EpubChapter(val index: Int, val title: String, val href: String)

/** epub 解析结果。 */
data class EpubBook(
    val title: String,
    val chapters: List<EpubChapter>,
    val opfPath: String,
    val opfDir: String,
    val manifest: List<ManifestItem>,
    /** 作者（`dc:creator` 首个非空值）；缺失为 null。 */
    val author: String? = null,
    /**
     * 封面图片相对 [opfDir] 的路径；三级回退（EPUB3 properties → EPUB2 `<meta name="cover">` → 首张图片，
     * 见 [EpubParser.pickCoverHref]），缺失为 null。
     */
    val coverHref: String? = null,
    /** 保留层级的目录树（M10.9）；nav / NCX 都缺失时为空表，展示层回退扁平 [chapters]。 */
    val tocTree: List<TocNode> = emptyList(),
)

/** OPF 解析结果（中间结构，便于单测）。 */
data class OpfDocument(
    val title: String,
    val manifest: List<ManifestItem>,
    val spine: List<String>,
    val navItemId: String?,
    val ncxItemId: String?,
    /** `dc:creator` 首个非空值；缺失为 null。 */
    val creator: String? = null,
    /** 封面 href（三级回退，见 [EpubParser.pickCoverHref]）；缺失为 null。 */
    val coverHref: String? = null,
)

/** 目录项（来自 EPUB3 nav 或 EPUB2 NCX），href 为相对该文档所在目录的原始引用。 */
data class TocEntry(val href: String, val title: String)

/** epub 解析失败。 */
class EpubParseException(message: String) : Exception(message)

/**
 * epub 解析器（MVP：本地自解析，不依赖 Readium 等重型工具链）。
 *
 * 解析链：`META-INF/container.xml` → OPF 路径 → OPF 的 metadata/manifest/spine →
 * 按 spine 顺序生成章节列表；章节标题优先取 EPUB3 nav（`properties="nav"`），
 * 回退 EPUB2 NCX（spine 的 `toc` 属性或 `application/x-dtbncx+xml`），再回退章节文件名。
 */
object EpubParser {
    const val CONTAINER_PATH = "META-INF/container.xml"

    /** 解析整本书；缺少 container.xml / OPF 时抛 [EpubParseException]。 */
    fun parse(source: EpubSource): EpubBook {
        val containerBytes = source.read(CONTAINER_PATH)
            ?: throw EpubParseException("epub 缺少 $CONTAINER_PATH")
        val opfPath = findOpfPath(String(containerBytes, Charsets.UTF_8))
            ?: throw EpubParseException("container.xml 中未找到 rootfile full-path")

        val opfBytes = source.read(opfPath)
            ?: throw EpubParseException("OPF 文件不存在：$opfPath")
        val opf = parseOpf(String(opfBytes, Charsets.UTF_8))

        val opfDir = opfPath.substringBeforeLast('/', "")
        val toc = parseToc(opf, source, opfDir)
        // 目录树（M10.9）：nav / NCX 的 href 相对**文档自身目录**，故先算出该目录再解析。
        // 注意与 buildChapters 的 titleByHref 不做对齐——那里用 opfDir 作 nav href 的 base 是
        // 既有缺陷（nav 在子目录时章节标题会失配、回退文件名），本计划不改它以免扩大回归面。
        val navPath = opf.manifest.firstOrNull { it.id == opf.navItemId }
            ?.href
            ?.takeIf { it.isNotBlank() }
            ?.let { resolvePathFrom(opfDir, it) }
        val ncxPath = opf.manifest.firstOrNull { it.id == opf.ncxItemId }
            ?.href
            ?.takeIf { it.isNotBlank() }
            ?.let { resolvePathFrom(opfDir, it) }
        val tocTree = runCatching {
            val fromNav = navPath?.let { path ->
                // navDir 取「nav 文档路径的父目录」：href 相对它才有意义
                source.read(path)?.let { parseNavTree(String(it, Charsets.UTF_8), path.substringBeforeLast('/', "")) }
            }.orEmpty()
            // 与既有 parseToc 口径一致：nav 缺失**或解析为空**都回退 NCX
            if (fromNav.isNotEmpty()) {
                fromNav
            } else {
                ncxPath?.let { path ->
                    source.read(path)?.let { parseNcxTree(String(it, Charsets.UTF_8), path.substringBeforeLast('/', "")) }
                }.orEmpty()
            }
        }.getOrNull().orEmpty()
        return EpubBook(
            title = opf.title.ifBlank { "未命名" },
            chapters = buildChapters(opf, opfDir, toc),
            opfPath = opfPath,
            opfDir = opfDir,
            manifest = opf.manifest,
            author = opf.creator,
            coverHref = opf.coverHref,
            tocTree = tocTree,
        )
    }

    /** 从 container.xml 取 OPF 的相对路径（已规范化）。 */
    fun findOpfPath(containerXml: String): String? {
        val root = parseXml(containerXml)
        val rootfile = descendants(root, "rootfile").firstOrNull() ?: return null
        val fullPath = rootfile.getAttribute("full-path").orEmpty()
        if (fullPath.isBlank()) return null
        return normalizePath(fullPath)
    }

    /** 解析 OPF 的 metadata 书名、manifest、spine 顺序与目录文档定位信息。 */
    fun parseOpf(opfXml: String): OpfDocument {
        val root = parseXml(opfXml)
        val title = descendants(root, "title")
            .firstOrNull { it.textContent?.isNotBlank() == true }
            ?.textContent
            ?.trim()
            .orEmpty()

        val manifest = descendants(root, "item").map { item ->
            ManifestItem(
                id = item.getAttribute("id").orEmpty(),
                href = item.getAttribute("href").orEmpty(),
                mediaType = item.getAttribute("media-type").orEmpty(),
                properties = item.getAttribute("properties").orEmpty(),
            )
        }

        val spineElement = descendants(root, "spine").firstOrNull()
        // linear="no" 的条目不属于线性阅读顺序（封面、尾注等），MVP 跳过。
        val spine = descendants(root, "itemref")
            .filter { it.getAttribute("linear").orEmpty().lowercase() != "no" }
            .map { it.getAttribute("idref").orEmpty() }
            .filter { it.isNotBlank() }

        val navItemId = manifest.firstOrNull {
            it.properties.split(' ', '\t').any { p -> p == "nav" }
        }?.id
        val ncxFromSpine = spineElement?.getAttribute("toc").orEmpty().ifBlank { null }
        val ncxFromManifest = manifest.firstOrNull {
            it.mediaType.equals("application/x-dtbncx+xml", ignoreCase = true)
        }?.id

        // dc:creator：取首个非空值（多作者时仅保留第一位，见 tech-debt）。
        val creator = descendants(root, "creator")
            .firstOrNull { it.textContent?.isNotBlank() == true }
            ?.textContent
            ?.trim()

        // 封面：EPUB3 properties → EPUB2 <meta name="cover"> → 首张图片（见 pickCoverHref）
        val epub2CoverId = descendants(root, "meta")
            .firstOrNull { it.getAttribute("name").equals("cover", ignoreCase = true) }
            ?.getAttribute("content")
            ?.ifBlank { null }
        val coverHref = pickCoverHref(manifest, epub2CoverId)

        return OpfDocument(
            title = title,
            manifest = manifest,
            spine = spine,
            navItemId = navItemId,
            ncxItemId = ncxFromSpine ?: ncxFromManifest,
            creator = creator,
            coverHref = coverHref,
        )
    }

    /**
     * 选封面 href（三级回退）。
     *
     * 1. EPUB3：manifest 里 `properties` 分词含 `cover-image` 的 item；
     * 2. EPUB2：`<meta name="cover" content="<manifest id>"/>` 指向的 item；
     * 3. 兜底：manifest 中第一个 `media-type` 以 `image/` 开头的 item。
     *
     * 第 3 级是启发式：若书里第一张图不是封面（如出版社 logo），会显示错图——已知局限，
     * 记在 `openspec/tech-debt.md`。返回 null 表示连一张图都没有（UI 显示首字占位）。
     *
     * @param manifest OPF manifest 条目（顺序即文档顺序）
     * @param epub2CoverId `<meta name="cover">` 的 content 值；无则为 null
     */
    internal fun pickCoverHref(manifest: List<ManifestItem>, epub2CoverId: String?): String? {
        val epub3 = manifest.firstOrNull { item ->
            item.properties.split(Regex("\\s+")).any { it == "cover-image" }
        }?.href?.ifBlank { null }
        if (epub3 != null) return epub3

        val epub2 = epub2CoverId
            ?.let { id -> manifest.firstOrNull { it.id == id } }
            ?.href
            ?.ifBlank { null }
        if (epub2 != null) return epub2

        return manifest.firstOrNull {
            it.mediaType.startsWith("image/", ignoreCase = true)
        }?.href?.ifBlank { null }
    }

    /** 解析 EPUB3 nav 文档：取 `epub:type="toc"` 的 nav（缺失则第一个 nav）下的全部链接。 */
    fun parseNav(navXml: String): List<TocEntry> {
        val root = parseXml(navXml)
        val navs = descendants(root, "nav")
        val tocNav = navs.firstOrNull { nav ->
            val type = nav.getAttribute("epub:type").orEmpty().ifBlank { nav.getAttribute("type").orEmpty() }
            type.split(' ', '\t').any { it == "toc" }
        } ?: navs.firstOrNull() ?: return emptyList()

        return descendants(tocNav, "a").mapNotNull { a ->
            val href = a.getAttribute("href").orEmpty()
            val text = a.textContent?.trim().orEmpty()
            if (href.isBlank()) null else TocEntry(href, text)
        }
    }

    /** 解析 EPUB2 NCX：按 navMap 中 navPoint 的文档顺序取 (label, src)。 */
    fun parseNcx(ncxXml: String): List<TocEntry> {
        val root = parseXml(ncxXml)
        return descendants(root, "navPoint").mapNotNull { point ->
            val label = point.child("navLabel")?.child("text")?.textContent?.trim().orEmpty()
            val src = point.child("content")?.getAttribute("src").orEmpty()
            if (src.isBlank()) null else TocEntry(src, label)
        }
    }

    /**
     * 解析 EPUB3 nav 文档为**目录树**（保留 `<nav><ol><li>` 嵌套，M10.9）。
     *
     * **与既有 [parseNav] 的关系：两条独立支路，互不影响。** [parseNav] 用
     * `descendants(nav, "a")` 取全部后代并按文档顺序输出（服务 `chapters` 的标题匹配与分页），
     * 本函数按树层级递归（服务目录抽屉）。**不要**把 [parseNav] 改成「先调本函数再拍平」——
     * 两者在「`<li>` 内多个 `<a>`」「`<li><span><a>`」等写法下产出不同，改写会破坏既有行为。
     *
     * @param baseDir nav 文档**自身所在目录**（如 `OEBPS/nav`）；`<a href>` 相对它，
     *   故用 `resolvePathFrom(baseDir, href)` 归一化为 epub 根相对路径后再存。
     * @return 目录树；无 nav / 无 `<ol>` / XML 畸形 → 空表（**不抛异常**，与 [parseNav] 同等容错）
     */
    fun parseNavTree(navXml: String, baseDir: String): List<TocNode> = runCatching {
        val root = parseXml(navXml)
        val navs = descendants(root, "nav")
        val tocNav = navs.firstOrNull { nav ->
            val type = nav.getAttribute("epub:type").orEmpty().ifBlank { nav.getAttribute("type").orEmpty() }
            type.split(' ', '\t').any { it == "toc" }
        } ?: navs.firstOrNull()
        val ol = tocNav?.let { descendants(it, "ol").firstOrNull() }
        ol?.let { parseOl(it, baseDir) }.orEmpty()
    }.getOrDefault(emptyList())

    /**
     * 解析 EPUB2 NCX 为**目录树**（保留 `<navPoint>` 嵌套，M10.9）。
     *
     * 与 [parseNcx] 同样是两条独立支路（见 [parseNavTree] 的说明）。
     *
     * @param baseDir ncx 文档自身所在目录；`<content src>` 相对它
     * @return 目录树；无 navMap / XML 畸形 → 空表（不抛异常）
     */
    fun parseNcxTree(ncxXml: String, baseDir: String): List<TocNode> = runCatching {
        val root = parseXml(ncxXml)
        descendants(root, "navMap").firstOrNull()?.let { parseNavPoints(it, baseDir) }.orEmpty()
    }.getOrDefault(emptyList())

    /** 递归解析 `<ol>` 的**直接子** `<li>`（nav 树的一层）。 */
    private fun parseOl(ol: Element, baseDir: String): List<TocNode> =
        directChildren(ol, "li").mapNotNull { parseLi(it, baseDir) }

    /**
     * 解析单个 `<li>` 为一个树节点。
     *
     * 「本节点自己的 `<a>`」判定：优先 `li` 的直接子 `<a>`；否则取后代 `<a>` 中**第一个不在嵌套 `<ol>`
     * 子树内**的（向上回溯父链判断），避免把子项的 `<a>` 误当成本节点标题。
     * 既无标题锚点又无子项的空 `<li>` 返回 null（丢弃）。
     */
    private fun parseLi(li: Element, baseDir: String): TocNode? {
        val childOl = li.child("ol") ?: descendants(li, "ol").firstOrNull()
        val anchor = li.child("a") ?: firstAnchorOutsideNestedOls(li)
        val children = childOl?.let { parseOl(it, baseDir) }.orEmpty()
        if (anchor == null && children.isEmpty()) return null

        val href = anchor?.getAttribute("href")
            ?.takeIf { it.isNotBlank() }
            ?.let { resolvePathFrom(baseDir, it) }
        return TocNode(
            title = anchor?.textContent?.trim().orEmpty(),
            href = href,
            children = children,
        )
    }

    /** 取后代中第一个不属于 `li` 内嵌套 `<ol>` 子树的 `<a>`（即 li 自身的标题锚点）。 */
    private fun firstAnchorOutsideNestedOls(li: Element): Element? =
        descendants(li, "a").firstOrNull { anchor ->
            var parent = anchor.parentNode
            var insideNestedOl = false
            while (parent != null && parent !== li) {
                if (parent is Element && localName(parent) == "ol") {
                    insideNestedOl = true
                    break
                }
                parent = parent.parentNode
            }
            !insideNestedOl
        }

    /** 递归解析 `navPoint` 的**直接子** `navPoint`（NCX 树的一层）。 */
    private fun parseNavPoints(parent: Element, baseDir: String): List<TocNode> =
        directChildren(parent, "navPoint").map { point ->
            val title = descendants(point, "navLabel").firstOrNull()
                ?.let { label -> descendants(label, "text").firstOrNull()?.textContent?.trim() }
                .orEmpty()
            val href = descendants(point, "content").firstOrNull()
                ?.getAttribute("src")
                ?.takeIf { it.isNotBlank() }
                ?.let { resolvePathFrom(baseDir, it) }
            TocNode(title = title, href = href, children = parseNavPoints(point, baseDir))
        }

    /** 取全部直接子元素（按局部名；DOM 的 `child(name)` 只取第一个，树解析需要全部）。 */
    private fun directChildren(parent: Element, name: String): List<Element> {
        val nodes = parent.childNodes
        val result = ArrayList<Element>(nodes.length)
        for (i in 0 until nodes.length) {
            val node = nodes.item(i)
            if (node is Element && localName(node) == name) result.add(node)
        }
        return result
    }

    /** 从 manifest/spine 生成章节列表；标题按 toc 映射，缺失时回退文件名。 */
    private fun buildChapters(
        opf: OpfDocument,
        opfDir: String,
        tocEntries: List<TocEntry>,
    ): List<EpubChapter> {
        val titleByHref = LinkedHashMap<String, String>()
        tocEntries.forEach { entry ->
            val resolved = resolvePathFrom(opfDir, entry.href)
            if (entry.title.isNotBlank()) titleByHref.putIfAbsent(resolved, entry.title)
        }

        val byId = opf.manifest.associateBy { it.id }
        val chapters = ArrayList<EpubChapter>(opf.spine.size)
        opf.spine.forEach { idref ->
            val item = byId[idref] ?: return@forEach
            val href = resolvePathFrom(opfDir, item.href)
            if (href.isBlank()) return@forEach
            chapters += EpubChapter(
                index = chapters.size,
                title = titleByHref[href] ?: titleFromHref(item.href),
                href = href,
            )
        }
        return chapters
    }

    /** 目录文档 → 目录项列表（EPUB3 nav 优先，回退 NCX）。 */
    private fun parseToc(opf: OpfDocument, source: EpubSource, opfDir: String): List<TocEntry> {
        opf.navItemId?.let { navId ->
            val href = opf.manifest.firstOrNull { it.id == navId }?.href
            val bytes = href?.let { source.read(resolvePathFrom(opfDir, it)) }
            if (bytes != null) {
                val entries = parseNav(String(bytes, Charsets.UTF_8))
                if (entries.isNotEmpty()) return entries
            }
        }
        opf.ncxItemId?.let { ncxId ->
            val href = opf.manifest.firstOrNull { it.id == ncxId }?.href
            val bytes = href?.let { source.read(resolvePathFrom(opfDir, it)) }
            if (bytes != null) {
                return parseNcx(String(bytes, Charsets.UTF_8))
            }
        }
        return emptyList()
    }
}

// ---- 路径工具（纯逻辑，可单测） ----

/** 解析相对 epub 根的引用：去 fragment/query、统一分隔符、折叠 `.` 与 `..`。 */
fun resolvePathFrom(baseDir: String, ref: String): String {
    val clean = stripFragment(ref).replace('\\', '/')
    return if (clean.startsWith("/")) normalizePath(clean) else normalizePath("$baseDir/$clean")
}

/** 去掉 URL 的 fragment 与 query 部分。 */
fun stripFragment(ref: String): String = ref.substringBefore('#').substringBefore('?')

/** 规范化 epub 内路径：折叠空段与 `.`、处理 `..`（越出根后忽略），保留大小写。 */
fun normalizePath(path: String): String {
    val stack = ArrayList<String>()
    path.replace('\\', '/').split('/').forEach { part ->
        when (part) {
            "", "." -> Unit
            ".." -> if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
            else -> stack.add(part)
        }
    }
    return stack.joinToString("/")
}

/** 章节无目录标题时的回退标题：文件名（去目录与扩展名）。 */
internal fun titleFromHref(href: String): String {
    val name = stripFragment(href).substringAfterLast('/')
    return name.substringBeforeLast('.').ifBlank { name }
}

/** 条目名规范化：统一分隔符、去前导斜杠、URL 解码（解码失败保留原文）。 */
internal fun normalizeEntryName(name: String): String {
    val unified = name.replace('\\', '/').removePrefix("/")
    val decoded = try {
        URLDecoder.decode(unified, "UTF-8")
    } catch (_: IllegalArgumentException) {
        unified
    }
    return normalizePath(decoded)
}

// ---- XML 工具 ----

/**
 * 解析 XML 为 DOM：关闭 DTD/外部实体加载（epub 内 XHTML/NCX 常带外部 DOCTYPE，
 * 联网加载会失败或阻塞；Android 上部分 feature 不支持，逐项忽略异常）。
 */
internal fun parseXml(xml: String): Element {
    val factory = DocumentBuilderFactory.newInstance()
    factory.isNamespaceAware = false
    factory.isValidating = false
    listOf(
        "http://apache.org/xml/features/nonvalidating/load-external-dtd",
        "http://xml.org/sax/features/external-general-entities",
        "http://xml.org/sax/features/external-parameter-entities",
    ).forEach { feature ->
        try {
            factory.setFeature(feature, false)
        } catch (_: Exception) {
            // 部分解析器实现不支持该 feature，忽略。
        }
    }
    val builder = factory.newDocumentBuilder()
    builder.setEntityResolver { _, _ -> InputSource(java.io.StringReader("")) }
    return builder.parse(ByteArrayInputStream(xml.toByteArray(Charsets.UTF_8))).documentElement
}

/** 去命名空间前缀的元素名。 */
internal fun localName(node: Node): String = node.nodeName.substringAfterLast(':')

/** 按局部名取后代元素（文档顺序，含 root 自身）。 */
internal fun descendants(root: Element, name: String): List<Element> {
    val nodes = root.getElementsByTagName("*")
    val result = ArrayList<Element>(nodes.length)
    for (i in 0 until nodes.length) {
        val node = nodes.item(i)
        if (node is Element && localName(node) == name) result.add(node)
    }
    return result
}

/** 取直接子元素（按局部名）。 */
internal fun Element.child(name: String): Element? {
    val nodes = childNodes
    for (i in 0 until nodes.length) {
        val node = nodes.item(i)
        if (node is Element && localName(node) == name) return node
    }
    return null
}
