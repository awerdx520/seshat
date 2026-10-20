package com.seshat.app.reader

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** EpubParser 的 spine/OPF/nav 解析与路径工具单测（全部纯 JVM，无需 Android 运行时）。 */
class EpubParserTest {

    @Test
    fun parseResolvesTitleChaptersAndSpineOrder() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("OEBPS/content.opf"),
                    "OEBPS/content.opf" to opfXml(
                        title = "测试书",
                        manifest = """
                            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                            <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
                            <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
                        """.trimIndent(),
                        // spine 故意与 manifest 声明顺序不同，验证以 spine 为准
                        spine = """<itemref idref="c2"/><itemref idref="c1"/>""",
                    ),
                    "OEBPS/nav.xhtml" to navXml(
                        "第一章" to "text/c2.xhtml",
                        "第二章" to "text/c1.xhtml",
                    ),
                ),
            ),
        )

        assertEquals("测试书", book.title)
        assertEquals("OEBPS/content.opf", book.opfPath)
        assertEquals("OEBPS", book.opfDir)
        assertEquals(3, book.manifest.size)
        assertEquals(listOf("第一章", "第二章"), book.chapters.map { it.title })
        assertEquals(listOf(0, 1), book.chapters.map { it.index })
        assertEquals(
            listOf("OEBPS/text/c2.xhtml", "OEBPS/text/c1.xhtml"),
            book.chapters.map { it.href },
        )
    }

    @Test
    fun nonLinearSpineItemsAreSkipped() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("content.opf"),
                    "content.opf" to opfXml(
                        title = "跳过封面",
                        manifest = """
                            <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
                            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                        """.trimIndent(),
                        spine = """<itemref idref="cover" linear="no"/><itemref idref="c1"/>""",
                    ),
                ),
            ),
        )

        assertEquals(listOf("c1.xhtml"), book.chapters.map { it.href })
    }

    @Test
    fun fallsBackToNcxWhenNavIsAbsent() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("OEBPS/content.opf"),
                    "OEBPS/content.opf" to opfXml(
                        title = "EPUB2 书",
                        manifest = """
                            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                            <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
                        """.trimIndent(),
                        spine = """<itemref idref="c1"/>""",
                        spineAttrs = " toc=\"ncx\"",
                    ),
                    "OEBPS/toc.ncx" to ncxXml("绪论" to "text/c1.xhtml"),
                ),
            ),
        )

        assertEquals(listOf("绪论"), book.chapters.map { it.title })
    }

    @Test
    fun fallsBackToFileNameWhenTocIsMissing() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("content.opf"),
                    "content.opf" to opfXml(
                        title = "无目录",
                        manifest = """<item id="c1" href="text/chapter-one.xhtml" media-type="application/xhtml+xml"/>""",
                        spine = """<itemref idref="c1"/>""",
                    ),
                ),
            ),
        )

        assertEquals(listOf("chapter-one"), book.chapters.map { it.title })
    }

    @Test
    fun manifestHrefIsResolvedAgainstOpfDirectory() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("EPUB/package.opf"),
                    "EPUB/package.opf" to opfXml(
                        title = "嵌套",
                        manifest = """<item id="c1" href="./text/c1.xhtml#top" media-type="application/xhtml+xml"/>""",
                        spine = """<itemref idref="c1"/>""",
                    ),
                ),
            ),
        )

        assertEquals(listOf("EPUB/text/c1.xhtml"), book.chapters.map { it.href })
    }

    @Test
    fun missingContainerXmlThrows() {
        try {
            EpubParser.parse(ByteArrayEpubSource(epubBytes("dummy.txt" to "x")))
            fail("应当抛出 EpubParseException")
        } catch (expected: EpubParseException) {
            assertTrue(expected.message!!.contains(EpubParser.CONTAINER_PATH))
        }
    }

    @Test
    fun resolvePathHandlesParentAndDotSegments() {
        assertEquals("OEBPS/text/c1.xhtml", resolvePathFrom("OEBPS", "text/c1.xhtml"))
        assertEquals("OEBPS/css/a.css", resolvePathFrom("OEBPS/text", "../css/a.css"))
        assertEquals("OEBPS/images/a.png", resolvePathFrom("OEBPS/text/sub", "../../images/a.png"))
        assertEquals("text/c1.xhtml", resolvePathFrom("OEBPS", "/text/c1.xhtml"))
        assertEquals("OEBPS/text/c1.xhtml", resolvePathFrom("OEBPS", "text/./c1.xhtml"))
    }

    @Test
    fun normalizePathFoldsRedundantSegments() {
        assertEquals("a/b", normalizePath("/a//b/"))
        assertEquals("b", normalizePath("a/../b"))
        assertEquals("", normalizePath("../a/../a/.."))
        assertEquals("", normalizePath("./"))
    }

    @Test
    fun stripFragmentRemovesQueryAndFragment() {
        assertEquals("c1.xhtml", stripFragment("c1.xhtml#top"))
        assertEquals("c1.xhtml", stripFragment("c1.xhtml?v=1#top"))
    }

    @Test
    fun documentIdIsStableSha256Prefix() {
        val a = byteArrayOf(1, 2, 3)
        val id = documentIdOf(a)
        assertEquals(32, id.length)
        assertTrue(id.all { it in "0123456789abcdef" })
        assertEquals(id, documentIdOf(a))
        assertNotEquals(id, documentIdOf(byteArrayOf(1, 2, 4)))
    }

    @Test
    fun sampleEpubFromTestResourcesIsParsed() {
        val bytes = javaClass.getResourceAsStream("/sample.epub")!!.use { it.readBytes() }
        val book = EpubParser.parse(ByteArrayEpubSource(bytes))

        assertEquals("示例书：笔记系统的阅读器", book.title)
        assertEquals(3, book.chapters.size)
        assertEquals(
            listOf("第一章 打开一本书", "第二章 解析 spine", "第三章 批注与进度"),
            book.chapters.map { it.title },
        )
        assertEquals(
            listOf(
                "OEBPS/text/chapter1.xhtml",
                "OEBPS/text/chapter2.xhtml",
                "OEBPS/text/chapter3.xhtml",
            ),
            book.chapters.map { it.href },
        )
    }

    @Test
    fun sampleEpubResourcesAreReadableThroughSource() {
        val bytes = javaClass.getResourceAsStream("/sample.epub")!!.use { it.readBytes() }
        val source = ByteArrayEpubSource(bytes)

        assertTrue(source.names().contains("META-INF/container.xml"))
        assertTrue((source.read("OEBPS/images/cover.png")?.size ?: 0) > 0)
        // 前导斜杠容错
        assertNotNull(source.read("/OEBPS/css/style.css"))
        assertNull(source.read("OEBPS/missing.xhtml"))
    }

    // ---- author / cover 元数据（M10.6 B3a） ----

    @Test
    fun parseOpfReadsCreatorFromDcCreator() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "有作者",
                manifest = """<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>""",
                spine = """<itemref idref="c1"/>""",
                metadata = "<dc:creator>张三</dc:creator>",
            ),
        )

        assertEquals("张三", opf.creator)
    }

    @Test
    fun parseOpfWithoutCreatorLeavesItNull() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "无作者",
                manifest = """<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>""",
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertNull(opf.creator)
        // 顺带确认 metadata 块本身解析正常（排除「整份 OPF 没解析出来」的假阳性）
        assertEquals("无作者", opf.title)
    }

    @Test
    fun parseFillsAuthorEndToEnd() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("OEBPS/content.opf"),
                    "OEBPS/content.opf" to opfXml(
                        title = "端到端作者",
                        manifest = """<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>""",
                        spine = """<itemref idref="c1"/>""",
                        metadata = "<dc:creator>李四</dc:creator>",
                    ),
                ),
            ),
        )

        assertEquals("李四", book.author)
    }

    @Test
    fun parseOpfReadsCoverHrefFromCoverImageProperty() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "有封面",
                manifest = """
                    <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertEquals("images/cover.jpg", opf.coverHref)
    }

    @Test
    fun parseOpfRecognisesCoverImageAmongMultipleProperties() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "多属性封面",
                manifest = """
                    <item id="cover" href="images/cover.png" media-type="image/png" properties="nav cover-image"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertEquals("images/cover.png", opf.coverHref)
    }

    @Test
    fun parseOpfWithoutCoverItemLeavesCoverHrefNull() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "无封面",
                manifest = """
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertNull(opf.coverHref)
    }

    @Test
    fun parseFillsCoverHrefEndToEnd() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("OEBPS/content.opf"),
                    "OEBPS/content.opf" to opfXml(
                        title = "端到端封面",
                        manifest = """
                            <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                        """.trimIndent(),
                        spine = """<itemref idref="c1"/>""",
                    ),
                ),
            ),
        )

        assertEquals("images/cover.jpg", book.coverHref)
        assertNull(book.author)
    }

    // ---- 封面三级回退（M10.8） ----

    @Test
    fun coverFromEpub3Properties() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "EPUB3 封面",
                manifest = """
                    <item id="cover" href="images/epub3.jpg" media-type="image/jpeg" properties="cover-image"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertEquals("images/epub3.jpg", opf.coverHref)
    }

    @Test
    fun coverFromEpub2MetaWhenNoEpub3Property() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "EPUB2 封面",
                manifest = """
                    <item id="img-first" href="images/logo.png" media-type="image/png"/>
                    <item id="cover-img" href="images/epub2.jpg" media-type="image/jpeg"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
                metadata = """<meta name="cover" content="cover-img"/>""",
            ),
        )

        assertEquals("images/epub2.jpg", opf.coverHref)
    }

    @Test
    fun coverFallsBackToFirstImage() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "无声明封面",
                manifest = """
                    <item id="css" href="style.css" media-type="text/css"/>
                    <item id="img" href="img/a.png" media-type="image/png"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertEquals("img/a.png", opf.coverHref)
    }

    @Test
    fun coverSkipsNonImageItems() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "非图片在前",
                manifest = """
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="img" href="img/b.jpg" media-type="image/jpeg"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertEquals("img/b.jpg", opf.coverHref)
    }

    @Test
    fun coverNullWhenNoImageAtAll() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "只有文本",
                manifest = """
                    <item id="css" href="style.css" media-type="text/css"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
            ),
        )

        assertNull(opf.coverHref)
    }

    @Test
    fun coverPrefersEpub3OverEpub2AndFirstImage() {
        val opf = EpubParser.parseOpf(
            opfXml(
                title = "三者并存",
                manifest = """
                    <item id="img-first" href="images/first.png" media-type="image/png"/>
                    <item id="epub2" href="images/epub2.jpg" media-type="image/jpeg"/>
                    <item id="epub3" href="images/epub3.jpg" media-type="image/jpeg" properties="cover-image"/>
                    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                """.trimIndent(),
                spine = """<itemref idref="c1"/>""",
                metadata = """<meta name="cover" content="epub2"/>""",
            ),
        )

        assertEquals("images/epub3.jpg", opf.coverHref)
    }

    // ---- 目录树（M10.9） ----

    @Test
    fun parseNavTreeSingleLevel() {
        val tree = EpubParser.parseNavTree(
            navTreeXml(
                """
                <li><a href="text/ch1.xhtml">第一章</a></li>
                <li><a href="text/ch2.xhtml">第二章</a></li>
                """.trimIndent(),
            ),
            baseDir = "OEBPS",
        )

        assertEquals(listOf("第一章", "第二章"), tree.map { it.title })
        assertEquals(listOf("OEBPS/text/ch1.xhtml", "OEBPS/text/ch2.xhtml"), tree.map { it.href })
        assertEquals(0, tree.sumOf { it.children.size })
    }

    @Test
    fun parseNavTreeTwoLevels() {
        val tree = EpubParser.parseNavTree(
            navTreeXml(
                """
                <li><a href="text/part1.xhtml">第一卷</a>
                  <ol><li><a href="text/ch1.xhtml">第一章</a></li></ol>
                </li>
                """.trimIndent(),
            ),
            baseDir = "OEBPS",
        )

        assertEquals(1, tree.size)
        assertEquals("第一卷", tree[0].title)
        assertEquals("OEBPS/text/part1.xhtml", tree[0].href)
        assertEquals(listOf("第一章"), tree[0].children.map { it.title })
        assertEquals(0, tree[0].children[0].children.size)
    }

    @Test
    fun parseNavTreeThreeLevels() {
        val tree = EpubParser.parseNavTree(
            navTreeXml(
                """
                <li><a href="p.xhtml">卷</a>
                  <ol><li><a href="c.xhtml">章</a>
                    <ol><li><a href="s.xhtml">节</a></li></ol>
                  </li></ol>
                </li>
                """.trimIndent(),
            ),
            baseDir = "OEBPS",
        )

        assertEquals("卷", tree[0].title)
        assertEquals("章", tree[0].children[0].title)
        assertEquals("节", tree[0].children[0].children[0].title)
        assertEquals("OEBPS/s.xhtml", tree[0].children[0].children[0].href)
        assertEquals(0, tree[0].children[0].children[0].children.size)
    }

    @Test
    fun parseNavTreeLeafWithoutChildren() {
        val tree = EpubParser.parseNavTree(
            navTreeXml("""<li><a href="c1.xhtml">只有标题</a></li>"""),
            baseDir = "OEBPS",
        )

        assertEquals(1, tree.size)
        assertEquals("只有标题", tree[0].title)
        assertTrue(tree[0].children.isEmpty())
    }

    @Test
    fun parseNavTreeLiWithoutAnchorKeepsChildren() {
        // 容器节点：无 <a>，只有 <span> 名称 + 子 <ol>。子项的 <a> 不能被误当成本节点标题。
        val tree = EpubParser.parseNavTree(
            navTreeXml(
                """<li><span>上卷</span><ol><li><a href="c1.xhtml">第一章</a></li></ol></li>""",
            ),
            baseDir = "OEBPS",
        )

        assertEquals(1, tree.size)
        assertNull(tree[0].href)
        assertEquals("", tree[0].title)
        assertEquals(1, tree[0].children.size)
        assertEquals("第一章", tree[0].children[0].title)
    }

    @Test
    fun parseNavTreeHandlesAnchorNestedInSpan() {
        val tree = EpubParser.parseNavTree(
            navTreeXml(
                """
                <li><span><a href="c1.xhtml">第一章</a></span>
                  <ol><li><a href="c1-1.xhtml">第一节</a></li></ol>
                </li>
                """.trimIndent(),
            ),
            baseDir = "OEBPS",
        )

        assertEquals("第一章", tree[0].title)
        assertEquals("OEBPS/c1.xhtml", tree[0].href)
        assertEquals(1, tree[0].children.size)
        assertEquals("第一节", tree[0].children[0].title)
    }

    @Test
    fun parseNavTreeMultipleTopLevelOls() {
        // 与 parseNav 口径一致：只认 toc nav 内的**第一个** <ol>。
        val nav = """<?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>目录</title></head>
            <body><nav epub:type="toc">
              <ol><li><a href="a.xhtml">A</a></li></ol>
              <ol><li><a href="b.xhtml">B</a></li></ol>
            </nav></body>
            </html>
        """.trimIndent()

        val tree = EpubParser.parseNavTree(nav, "OEBPS")

        assertEquals(listOf("A"), tree.map { it.title })
        assertEquals(listOf("OEBPS/a.xhtml"), tree.map { it.href })
    }

    @Test
    fun parseNavTreeKeepsOnlyFirstAnchorPerLi() {
        val nav = navTreeXml("""<li><a href="a.xhtml">A</a><a href="b.xhtml">B</a></li>""")

        val tree = EpubParser.parseNavTree(nav, "OEBPS")

        // 树只保留本节点首个 <a>；parseNav 的扁平口径仍是 2 条——两条独立支路，服务不同用途。
        assertEquals(1, tree.size)
        assertEquals("A", tree[0].title)
        assertEquals("OEBPS/a.xhtml", tree[0].href)
        assertEquals(2, EpubParser.parseNav(nav).size)
    }

    @Test
    fun parseNcxTreeNested() {
        val ncx = ncxTreeXml(
            """
            <navPoint id="n0" playOrder="1">
              <navLabel><text>第一部</text></navLabel><content src="text/p1.xhtml"/>
              <navPoint id="n1" playOrder="2">
                <navLabel><text>第一章</text></navLabel><content src="text/c1.xhtml"/>
              </navPoint>
              <navPoint id="n2" playOrder="3">
                <navLabel><text>第二章</text></navLabel><content src="text/c2.xhtml"/>
                <navPoint id="n3" playOrder="4">
                  <navLabel><text>第一节</text></navLabel><content src="text/c2s1.xhtml"/>
                </navPoint>
              </navPoint>
            </navPoint>
            """.trimIndent(),
        )

        val tree = EpubParser.parseNcxTree(ncx, "OEBPS")

        assertEquals(1, tree.size)
        assertEquals("第一部", tree[0].title)
        assertEquals("OEBPS/text/p1.xhtml", tree[0].href)
        assertEquals(listOf("第一章", "第二章"), tree[0].children.map { it.title })
        assertEquals(1, tree[0].children[1].children.size)
        assertEquals("OEBPS/text/c2s1.xhtml", tree[0].children[1].children[0].href)
    }

    @Test
    fun parseNcxTreeSingleLevel() {
        val tree = EpubParser.parseNcxTree(
            ncxTreeXml(
                """
                <navPoint id="n0" playOrder="1"><navLabel><text>绪论</text></navLabel><content src="c1.xhtml"/></navPoint>
                <navPoint id="n1" playOrder="2"><navLabel><text>本论</text></navLabel><content src="c2.xhtml"/></navPoint>
                """.trimIndent(),
            ),
            baseDir = "OEBPS",
        )

        assertEquals(listOf("绪论", "本论"), tree.map { it.title })
        assertEquals(listOf("OEBPS/c1.xhtml", "OEBPS/c2.xhtml"), tree.map { it.href })
        assertEquals(0, tree.sumOf { it.children.size })
    }

    /** 回归闸门：每 `<li>` 至多一个 `<a>` 时，扁平 parseNav 与树的前序 href 序列必须一致。 */
    @Test
    fun parseNavFlatUnchangedWhenTreeAdded() {
        val nav = navTreeXml(
            """
            <li><a href="p1.xhtml">卷甲</a>
              <ol>
                <li><a href="c1.xhtml">第一章</a></li>
                <li><a href="c2.xhtml">第二章</a>
                  <ol><li><a href="c2s1.xhtml">第一节</a></li></ol>
                </li>
              </ol>
            </li>
            <li><a href="p2.xhtml">卷乙</a></li>
            """.trimIndent(),
        )

        val flat = EpubParser.parseNav(nav).map { resolvePathFrom("OEBPS", it.href) }
        val treeHrefs = preorderHrefs(EpubParser.parseNavTree(nav, "OEBPS"))

        assertEquals(
            listOf(
                "OEBPS/p1.xhtml",
                "OEBPS/c1.xhtml",
                "OEBPS/c2.xhtml",
                "OEBPS/c2s1.xhtml",
                "OEBPS/p2.xhtml",
            ),
            flat,
        )
        assertEquals(flat, treeHrefs)
    }

    @Test
    fun parseNavTreeReturnsEmptyOnMalformedXml() {
        val broken = """<html><body><nav epub:type="toc"><ol><li><a href="a.xhtml">A</a></ol></nav></body></html>"""

        assertTrue(EpubParser.parseNavTree(broken, "OEBPS").isEmpty())
    }

    /** M-1 关键验证：`href` 必须相对**nav 文档自身目录**归一化，而非 opf 目录。 */
    @Test
    fun parseNavTreeNormalizesHrefAgainstBaseDir() {
        val tree = EpubParser.parseNavTree(
            navTreeXml("""<li><a href="../text/ch1.xhtml">第一章</a></li>"""),
            baseDir = "OEBPS/nav",
        )

        assertEquals("OEBPS/text/ch1.xhtml", tree[0].href)
    }

    /** 端到端：parse() 用 nav 文档所在目录作 base 填 tocTree（nav 在子目录时也正确）。 */
    @Test
    fun parseFillsTocTreeUsingNavDocumentDirectory() {
        val book = EpubParser.parse(
            ByteArrayEpubSource(
                epubBytes(
                    "META-INF/container.xml" to containerXml("OEBPS/content.opf"),
                    "OEBPS/content.opf" to opfXml(
                        title = "导航在子目录",
                        manifest = """
                            <item id="nav" href="nav/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                            <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
                        """.trimIndent(),
                        spine = """<itemref idref="c1"/>""",
                    ),
                    "OEBPS/nav/nav.xhtml" to navTreeXml(
                        """<li><a href="../text/ch1.xhtml">第一章</a></li>""",
                    ),
                ),
            ),
        )

        assertEquals(1, book.tocTree.size)
        assertEquals("第一章", book.tocTree[0].title)
        assertEquals("OEBPS/text/ch1.xhtml", book.tocTree[0].href)
        assertEquals(1, book.chapters.size)
    }

    // ---- 测试数据构造 ----

    /** 目录树的前序遍历 href 序列（只取有跳转的节点）。 */
    private fun preorderHrefs(nodes: List<TocNode>): List<String> =
        nodes.flatMap { node -> listOfNotNull(node.href) + preorderHrefs(node.children) }

    /** 构造 EPUB3 nav 文档；[items] 是 `<ol>` 内的 `<li>` 片段（可任意嵌套）。 */
    private fun navTreeXml(items: String): String = """<?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>目录</title></head>
        <body><nav epub:type="toc"><ol>$items</ol></nav></body>
        </html>
    """.trimIndent()

    /** 构造 EPUB2 NCX 文档；[points] 是 `navMap` 内的 `<navPoint>` 片段（可任意嵌套）。 */
    private fun ncxTreeXml(points: String): String = """<?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>$points</navMap>
        </ncx>
    """.trimIndent()

    private fun epubBytes(vararg entries: Pair<String, String>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            entries.forEach { (name, content) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(content.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun containerXml(opfPath: String): String = """<?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
    """.trimIndent()

    /** [metadata] 用于追加额外 metadata 元素（如 `dc:creator`），默认空以保持既有用例不变。 */
    private fun opfXml(
        title: String,
        manifest: String,
        spine: String,
        spineAttrs: String = "",
        metadata: String = "",
    ): String = """<?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:test</dc:identifier>
            <dc:title>$title</dc:title>
            <dc:language>zh</dc:language>
            $metadata
          </metadata>
          <manifest>
            $manifest
          </manifest>
          <spine$spineAttrs>
            $spine
          </spine>
        </package>
    """.trimIndent()

    private fun navXml(vararg entries: Pair<String, String>): String {
        val items = entries.joinToString("") { (title, href) -> """<li><a href="$href">$title</a></li>""" }
        return """<?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>目录</title></head>
            <body><nav epub:type="toc"><ol>$items</ol></nav></body>
            </html>
        """.trimIndent()
    }

    private fun ncxXml(vararg entries: Pair<String, String>): String {
        val points = entries.mapIndexed { i, (title, src) ->
            """<navPoint id="n$i" playOrder="${i + 1}"><navLabel><text>$title</text></navLabel><content src="$src"/></navPoint>"""
        }.joinToString("")
        return """<?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>$points</navMap>
            </ncx>
        """.trimIndent()
    }
}
