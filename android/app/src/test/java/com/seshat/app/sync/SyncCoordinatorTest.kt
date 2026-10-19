package com.seshat.app.sync

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SyncCoordinator] 单测（纯 JVM）：fake [SyncApis] 记录调用次数 + 真实 [ResourceIndex]
 * （内存 fake prefs）+ 真实单线程 executor。
 *
 * 覆盖：未配置零网络、cursor=0 走 bootstrap、cursor>0 走 pull、backfill 遍历所有根、
 * 异常转 Failed、roots 缓存与失效、executor 关闭后提交返回 false、回调线程语义。
 */
class SyncCoordinatorTest {

    /** 内存 fake prefs：单键单值（与 [ResourceIndexTest] 保持一致的最小实现）。 */
    private class FakePrefs {
        var stored: String? = null
        fun index() = ResourceIndex(read = { stored }, write = { stored = it })
    }

    /**
     * 可编排的 fake 服务端：记录每个方法的调用次数与入参。
     *
     * 默认行为：`roots()` 返回单个 mirror 根、`changes` 返回空页（游标原地、无更多）、
     * `resources` 返回空页——足以让整条链路正常结束。
     */
    private class FakeApis(
        private val rootsList: List<RootDto> = listOf(RootDto("notes", "mirror", true)),
    ) : SyncApis {
        var rootsCalls = 0
        val changeSinceCalls: MutableList<Long> = ArrayList()
        val resourceRootCalls: MutableList<String> = ArrayList()

        /** 覆盖 changes 的响应（入参为 since）。 */
        var changesResponse: (Long) -> ChangesPageDto = { since ->
            ChangesPageDto(changes = emptyList(), nextCursor = since, hasMore = false)
        }

        /** 非 null 时 `changes` 抛出该异常（模拟网络/协议错误）。 */
        var changesError: RuntimeException? = null

        /** 覆盖 resources 的响应（入参为 root）。 */
        var resourcesResponse: (String) -> ResourcesPageDto = { ResourcesPageDto() }

        val totalCalls: Int
            get() = rootsCalls + changeSinceCalls.size + resourceRootCalls.size

        override fun roots(): List<RootDto> {
            rootsCalls++
            return rootsList
        }

        override fun changes(since: Long, limit: Int): ChangesPageDto {
            changeSinceCalls += since
            changesError?.let { throw it }
            return changesResponse(since)
        }

        override fun resources(root: String, sinceMtime: Long?, limit: Int): ResourcesPageDto {
            resourceRootCalls += root
            return resourcesResponse(root)
        }
    }

    private val prefs = FakePrefs()
    private val index = prefs.index()
    private lateinit var executor: ExecutorService

    /** 每个测试独立一个单线程 executor（与生产装配一致），避免用例间串扰。 */
    private fun newExecutor(): ExecutorService =
        Executors.newSingleThreadExecutor().also { executor = it }

    @After
    fun tearDown() {
        if (this::executor.isInitialized) executor.shutdownNow()
    }

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

    /** 构造 dirty 的本地条目（回填候选）。 */
    private fun dirtyEntry(uid: String, root: String) = ResourceEntry(
        uid = uid,
        root = root,
        path = "$uid.epub",
        blob = "",
        size = 0,
        mtime = 0,
        deleted = false,
        dirty = true,
    )

    // ---- 1. 未配置：零网络 ----

    @Test
    fun `未配置时回调 NotConfigured 且零网络调用`() {
        newExecutor()
        val fake = FakeApis()
        var apiReads = 0
        // 生产语义：apis() 返回 null 表示服务端未配置（地址/令牌缺失）
        val coordinator = SyncCoordinator(index, { apiReads++; null }, executor)

        val outcome = awaitSync(coordinator)

        assertEquals(SyncOutcome.NotConfigured, outcome)
        assertEquals("apis() 只读一次配置（无网络）", 1, apiReads)
        assertEquals("roots() 零调用", 0, fake.rootsCalls)
        assertEquals("changes() 零调用", 0, fake.changeSinceCalls.size)
        assertEquals("resources() 零调用", 0, fake.resourceRootCalls.size)
        assertEquals("fake 上没有任何调用", 0, fake.totalCalls)
    }

    @Test
    fun `未配置时回调发生在 executor 线程而非调用线程`() {
        newExecutor()
        val coordinator = SyncCoordinator(index, { null }, executor)
        val latch = CountDownLatch(1)
        var callbackThread: String? = null
        coordinator.syncNow {
            callbackThread = Thread.currentThread().name
            latch.countDown()
        }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        assertNotNull(callbackThread)
        assertFalse(
            "回调不应在调用线程（${Thread.currentThread().name}）执行：实际 $callbackThread",
            callbackThread == Thread.currentThread().name,
        )
    }

    // ---- 2. cursor == 0 → bootstrap ----

    @Test
    fun `cursor 为 0 时从 since 0 开始拉取变更`() {
        newExecutor()
        val fake = FakeApis()
        var calls = 0
        fake.changesResponse = { since -> calls++; ChangesPageDto(emptyList(), nextCursor = since, hasMore = false) }
        val coordinator = SyncCoordinator(index, { fake }, executor)

        val outcome = awaitSync(coordinator)

        assertTrue("应回调 Ok：$outcome", outcome is SyncOutcome.Ok)
        assertEquals("changes 应被调用一次", 1, calls)
        assertEquals("首次 since 必须为 0（bootstrap）", 0L, fake.changeSinceCalls.first())
    }

    // ---- 3. cursor > 0 → pull ----

    @Test
    fun `cursor 大于 0 时从既有游标继续拉取`() {
        newExecutor()
        index.setCursor(42)
        val fake = FakeApis()
        fake.changesResponse = { since -> ChangesPageDto(emptyList(), nextCursor = since + 5, hasMore = false) }
        val coordinator = SyncCoordinator(index, { fake }, executor)

        val outcome = awaitSync(coordinator)

        assertEquals("首次 since 必须为既有游标 42", 42L, fake.changeSinceCalls.first())
        assertEquals(47L, (outcome as SyncOutcome.Ok).cursor)
        assertEquals(47L, index.cursor())
    }

    // ---- 4. backfill 在所有根上执行 ----

    @Test
    fun `回填遍历 roots 的每一个根`() {
        newExecutor()
        index.upsert(dirtyEntry("u1", "a"))
        index.upsert(dirtyEntry("u2", "b"))
        val fake = FakeApis(
            rootsList = listOf(RootDto("a", "mirror", true), RootDto("b", "ondemand")),
        )
        // 每个根返回自身的那条资源，回填后清脏，分页一次结束
        fake.resourcesResponse = { root ->
            ResourcesPageDto(
                items = listOf(
                    ResourceDto(
                        uid = "u${if (root == "a") 1 else 2}",
                        root = root,
                        path = "u${if (root == "a") 1 else 2}.epub",
                        size = 10,
                        mtime = 7,
                    ),
                ),
                hasMore = false,
            )
        }
        val coordinator = SyncCoordinator(index, { fake }, executor)

        val outcome = awaitSync(coordinator)

        assertEquals("resources 应在每个根上各调用一次", listOf("a", "b"), fake.resourceRootCalls)
        assertEquals(2, (outcome as SyncOutcome.Ok).backfilled)
        assertEquals("两个根的 dirty 都应已清空", 0, index.dirtyEntries("a").size + index.dirtyEntries("b").size)
        assertEquals(10L, index.findByUid("u1")!!.size)
        assertFalse("回填后 dirty 应为 false", index.findByUid("u1")!!.dirty)
    }

    // ---- 5. 异常 → Failed ----

    @Test
    fun `拉取异常时回调 Failed 且携带原始消息`() {
        newExecutor()
        val fake = FakeApis()
        fake.changesError = RuntimeException("boom")
        val coordinator = SyncCoordinator(index, { fake }, executor)

        val outcome = awaitSync(coordinator)

        assertTrue("应回调 Failed：$outcome", outcome is SyncOutcome.Failed)
        assertTrue("消息应含 boom", (outcome as SyncOutcome.Failed).message.contains("boom"))
    }

    // ---- 6. roots 缓存 ----

    @Test
    fun `roots 缓存命中且 invalidateRoots 后重新拉取`() {
        newExecutor()
        val fake = FakeApis()
        val coordinator = SyncCoordinator(index, { fake }, executor)

        coordinator.roots()
        coordinator.roots()
        assertEquals("连续两次 roots() 只应请求一次", 1, fake.rootsCalls)

        coordinator.invalidateRoots()
        coordinator.roots()
        assertEquals("失效后应重新请求", 2, fake.rootsCalls)
    }

    // ---- 7. roots 失败不缓存 ----

    @Test
    fun `roots 拉取失败返回空表且不缓存`() {
        newExecutor()
        var attempt = 0
        val fake = FakeApis()
        val failingApis = object : SyncApis {
            override fun roots(): List<RootDto> {
                attempt++
                throw RuntimeException("roots down")
            }

            override fun changes(since: Long, limit: Int) = fake.changes(since, limit)

            override fun resources(root: String, sinceMtime: Long?, limit: Int) =
                fake.resources(root, sinceMtime, limit)
        }
        val coordinator = SyncCoordinator(index, { failingApis }, executor)

        assertTrue("失败应返回空表", coordinator.roots().isEmpty())
        assertTrue(coordinator.roots().isEmpty())
        assertEquals("失败不缓存：两次调用各请求一次", 2, attempt)
    }

    // ---- 8. executor 已关闭 → 返回 false ----

    @Test
    fun `executor 关闭后 syncNow 返回 false 而不抛异常`() {
        newExecutor()
        executor.shutdownNow()
        val fake = FakeApis()
        val coordinator = SyncCoordinator(index, { fake }, executor)

        val submitted = coordinator.syncNow { }

        assertFalse("提交到已关闭的 executor 应返回 false", submitted)
    }
}
