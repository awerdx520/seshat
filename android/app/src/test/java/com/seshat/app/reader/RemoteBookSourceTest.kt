package com.seshat.app.reader

import com.seshat.app.sync.ResourceEntry
import com.seshat.app.sync.ResourceIndex
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [RemoteBookSource] 单测：远端清单筛选（扩展名 / 墓碑 / root）、文件名提取、mtime 排序，
 * 以及「远端条目是否已落盘」的长度判定。
 *
 * 索引用内存 fake（[ResourceIndex] 的读写函数注入），不触碰 SharedPreferences。
 */
class RemoteBookSourceTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 用内存 fake 构造索引并批量写入 [entries]（一次性落盘）。 */
    private fun indexOf(vararg entries: ResourceEntry): ResourceIndex {
        var stored: String? = null
        val index = ResourceIndex(read = { stored }, write = { stored = it })
        index.upsertAll(entries.toList())
        return index
    }

    /** 造索引条目（默认值覆盖 length 匹配所需字段）。 */
    private fun entry(
        path: String,
        root: String = "main",
        uid: String = "uid-$path",
        size: Long = 100,
        mtime: Long = 1_000,
        deleted: Boolean = false,
    ) = ResourceEntry(
        uid = uid,
        root = root,
        path = path,
        size = size,
        mtime = mtime,
        deleted = deleted,
    )

    /** 造远端条目（直接给需要测的字段，name 一般由 path 派生）。 */
    private fun remote(
        name: String,
        size: Long = 100,
        mtime: Long = 1_000,
        path: String = name,
    ) = RemoteBook(uid = "uid-$path", root = "main", path = path, name = name, size = size, mtime = mtime)

    // ---- fromIndex ----

    @Test
    fun fromIndexKeepsOnlyEpubAndPdf() {
        val index = indexOf(
            entry("lib/a.epub"),
            entry("lib/b.PDF"),
            entry("lib/notes.txt"),
            entry("lib/todo.org"),
            entry("lib/noext"),
        )

        val books = RemoteBookSource.fromIndex(index, "main")

        assertEquals(listOf("a.epub", "b.PDF"), books.map { it.name })
    }

    @Test
    fun fromIndexSkipsTombstones() {
        val index = indexOf(
            entry("lib/alive.epub"),
            entry("lib/gone.epub", deleted = true),
        )

        val books = RemoteBookSource.fromIndex(index, "main")

        assertEquals(listOf("alive.epub"), books.map { it.name })
    }

    @Test
    fun fromIndexOnlyReadsGivenRoot() {
        val index = indexOf(
            entry("a.epub", root = "main"),
            entry("b.epub", root = "other"),
        )

        val books = RemoteBookSource.fromIndex(index, "main")

        assertEquals(listOf("a.epub"), books.map { it.name })
        assertEquals("main", books.single().root)
    }

    @Test
    fun nameIsFileNamePartOfPath() {
        val index = indexOf(entry("lib/sub/deep/深入浅出.epub"))

        val book = RemoteBookSource.fromIndex(index, "main").single()

        assertEquals("深入浅出.epub", book.name)
        assertEquals("lib/sub/deep/深入浅出.epub", book.path)
        assertEquals("uid-lib/sub/deep/深入浅出.epub", book.uid)
    }

    @Test
    fun fromIndexSortsByMtimeDescending() {
        val index = indexOf(
            entry("old.epub", mtime = 100),
            entry("newest.epub", mtime = 900),
            entry("middle.epub", mtime = 500),
        )

        val books = RemoteBookSource.fromIndex(index, "main")

        assertEquals(listOf("newest.epub", "middle.epub", "old.epub"), books.map { it.name })
    }

    @Test
    fun fromIndexOnEmptyIndexReturnsEmptyList() {
        val index = indexOf()

        assertEquals(emptyList<RemoteBook>(), RemoteBookSource.fromIndex(index, "main"))
    }

    // ---- localFileOf ----

    @Test
    fun localFileOfReturnsFileWhenLengthMatches() {
        val dir = tmp.newFolder("books-match")
        val file = File(dir, "a.epub").apply { writeBytes(ByteArray(100)) }

        val result = RemoteBookSource.localFileOf(dir, remote("a.epub", size = 100))

        assertEquals(file, result)
    }

    @Test
    fun localFileOfReturnsNullWhenLengthDiffers() {
        val dir = tmp.newFolder("books-mismatch")
        File(dir, "a.epub").writeBytes(ByteArray(100))

        assertNull(RemoteBookSource.localFileOf(dir, remote("a.epub", size = 99)))
    }

    @Test
    fun localFileOfReturnsNullWhenMissing() {
        val dir = tmp.newFolder("books-missing")

        assertNull(RemoteBookSource.localFileOf(dir, remote("a.epub")))
    }

    @Test
    fun localFileOfOnlyChecksExistenceWhenSizeUnknown() {
        val dir = tmp.newFolder("books-unknown-size")
        File(dir, "a.epub").writeBytes(ByteArray(7))

        // size 未回填（0 / 负数）时不做长度校验
        assertEquals(File(dir, "a.epub"), RemoteBookSource.localFileOf(dir, remote("a.epub", size = 0)))
        assertEquals(File(dir, "a.epub"), RemoteBookSource.localFileOf(dir, remote("a.epub", size = -1)))
    }
}
