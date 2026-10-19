package com.seshat.app.sync

import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [SyncCoordinator] 的 `move` 跟随单测（纯 JVM）：fake [SyncApis] 返回 rename 事件 +
 * 真实 [ResourceIndex]（内存 fake prefs）+ [TemporaryFolder] 充当 `booksDir` + 真实单线程 executor。
 *
 * 覆盖：本地存在旧文件 → 重命名；本地不存在 → 不创建；目标已存在 → 跳过并记日志；
 * `booksDir = null` → 不跟随；同名不同目录 → 无操作。
 *
 * 不注入真实 `android.util.Log`：JVM 单测里 `Log.w` 会抛 `RuntimeException("Stub!")`，
 * 因此生产装配把日志注入为 `logger` 回调（默认空实现）。
 */
class SyncCoordinatorRenameTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 内存 fake prefs：单键单值。 */
    private class FakePrefs {
        var stored: String? = null
        fun index() = ResourceIndex(read = { stored }, write = { stored = it })
    }

    /** 只返回一条 rename 事件的 fake 服务端；回填返回空页（本用例与回填无关）。 */
    private class RenameApis(private val change: ChangeDto) : SyncApis {
        var changeCalls = 0

        override fun roots(): List<RootDto> = listOf(RootDto("notes", "mirror", true))

        override fun changes(since: Long, limit: Int): ChangesPageDto {
            changeCalls++
            return ChangesPageDto(
                changes = listOf(change),
                nextCursor = since + 1,
                hasMore = false,
            )
        }

        override fun resources(root: String, sinceMtime: Long?, limit: Int): ResourcesPageDto =
            ResourcesPageDto()
    }

    private val prefs = FakePrefs()
    private val index = prefs.index()
    private lateinit var executor: ExecutorService

    @After
    fun tearDown() {
        if (this::executor.isInitialized) executor.shutdownNow()
    }

    /** rename 事件：`a/x.epub` → `b/y.epub`。 */
    private fun renameChange(
        uid: String = "u1",
        oldPath: String = "a/x.epub",
        newPath: String = "b/y.epub",
    ) = ChangeDto(
        seq = 1,
        uid = uid,
        op = "rename",
        root = "notes",
        path = newPath,
        oldPath = oldPath,
        blob = "blob-$uid",
        rev = "rev-$uid",
        changedAt = "2026-10-19T00:00:00Z",
    )

    /** 触发一次同步并等待回调；返回回调结果（超时 10s 直接失败）。 */
    private fun awaitSync(coordinator: SyncCoordinator): SyncOutcome {
        val latch = CountDownLatch(1)
        val results = Collections.synchronizedList(ArrayList<SyncOutcome>())
        val submitted = coordinator.syncNow {
            results += it
            latch.countDown()
        }
        assertTrue("syncNow 应接受任务", submitted)
        assertTrue("同步回调超时（10s）", latch.await(10, TimeUnit.SECONDS))
        assertEquals("回调应恰好一次", 1, results.size)
        return results[0]
    }

    /** 构造编排器：单线程 executor + 指定 booksDir + 捕获日志。 */
    private fun coordinator(
        api: SyncApis,
        booksDir: File?,
        logs: MutableList<String> = mutableListOf(),
    ): SyncCoordinator {
        executor = Executors.newSingleThreadExecutor()
        return SyncCoordinator(
            index = index,
            apis = { api },
            executor = executor,
            booksDir = booksDir,
            logger = { logs += it },
        )
    }

    // ---- 1. 本地存在旧文件 → 跟随重命名 ----

    @Test
    fun `本地存在旧文件时跟随重命名为新文件名`() {
        val dir = tmp.newFolder("books")
        val oldFile = File(dir, "x.epub").apply { writeText("old-content") }
        val newFile = File(dir, "y.epub")
        val logs = mutableListOf<String>()

        val outcome = awaitSync(coordinator(RenameApis(renameChange()), dir, logs))

        assertTrue("同步应成功：$outcome", outcome is SyncOutcome.Ok)
        assertFalse("旧文件应已不存在", oldFile.exists())
        assertTrue("新文件应存在", newFile.isFile)
        assertEquals("重命名应保留内容", "old-content", newFile.readText())
        assertTrue("成功跟随不应记日志：$logs", logs.isEmpty())
    }

    // ---- 2. 本地不存在旧文件 → 不创建、不崩 ----

    @Test
    fun `本地不存在旧文件时不创建新文件且不抛异常`() {
        val dir = tmp.newFolder("books")
        val logs = mutableListOf<String>()

        val outcome = awaitSync(coordinator(RenameApis(renameChange()), dir, logs))

        assertTrue("同步应成功：$outcome", outcome is SyncOutcome.Ok)
        assertFalse("本地没有旧文件时不应凭空创建新文件", File(dir, "y.epub").exists())
        assertEquals("无本地文件即无需跟随，不记日志", 0, logs.size)
        assertTrue("目录应保持空白", dir.listFiles().orEmpty().isEmpty())
    }

    // ---- 3. 目标已存在 → 跳过并记日志（不覆盖、不删除） ----

    @Test
    fun `目标文件已存在时跳过并记日志`() {
        val dir = tmp.newFolder("books")
        val oldFile = File(dir, "x.epub").apply { writeText("old-content") }
        val newFile = File(dir, "y.epub").apply { writeText("existing") }
        val logs = mutableListOf<String>()

        val outcome = awaitSync(coordinator(RenameApis(renameChange()), dir, logs))

        assertTrue("同步应成功：$outcome", outcome is SyncOutcome.Ok)
        assertTrue("旧文件应保留（不删除）", oldFile.isFile)
        assertEquals("重命名应保留内容", "old-content", oldFile.readText())
        assertEquals("目标文件不得被覆盖", "existing", newFile.readText())
        assertEquals("跳过时应记一条日志：$logs", 1, logs.size)
        assertTrue("日志不应为空串", logs[0].isNotBlank())
    }

    // ---- 4. booksDir = null → 不跟随 ----

    @Test
    fun `booksDir 为 null 时不跟随重命名`() {
        val dir = tmp.newFolder("books")
        val oldFile = File(dir, "x.epub").apply { writeText("old-content") }
        val logs = mutableListOf<String>()

        val outcome = awaitSync(coordinator(RenameApis(renameChange()), booksDir = null, logs = logs))

        assertTrue("同步应成功：$outcome", outcome is SyncOutcome.Ok)
        assertTrue("未提供 booksDir 时旧文件应原样保留", oldFile.isFile)
        assertFalse("未提供 booksDir 时不得创建新文件", File(dir, "y.epub").exists())
        assertTrue("未提供 booksDir 时直接返回，不记日志", logs.isEmpty())
    }

    // ---- 5. 同名不同目录（扁平存储下新旧 basename 相同）→ 无操作 ----

    @Test
    fun `新旧文件名相同时不做任何事`() {
        val dir = tmp.newFolder("books")
        val file = File(dir, "x.epub").apply { writeText("content") }
        val logs = mutableListOf<String>()

        val outcome = awaitSync(
            coordinator(
                RenameApis(renameChange(oldPath = "a/x.epub", newPath = "b/x.epub")),
                dir,
                logs,
            ),
        )

        assertTrue("同步应成功：$outcome", outcome is SyncOutcome.Ok)
        assertTrue("同名即无需重命名", file.isFile)
        assertEquals("content", file.readText())
        assertTrue("同名属正常情况，不记日志", logs.isEmpty())
    }
}
