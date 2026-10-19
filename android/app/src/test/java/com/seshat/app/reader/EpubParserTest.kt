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

    // ---- 测试数据构造 ----

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
