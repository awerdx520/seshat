package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** [PendingDeletes] 待删队列（离线删除待重试）的纯 JVM 单测。 */
class PendingDeletesTest {

    private val prefs = FakeSharedPreferences()
    private val queue = PendingDeletes(prefs)

    @Test
    fun keyUsesUidPrefix() {
        assertEquals("pending_deletes_uid-1", PendingDeletes.key("uid-1"))
    }

    @Test
    fun emptyByDefault() {
        assertTrue(queue.list("uid-1").isEmpty())
        assertFalse(prefs.contains(PendingDeletes.key("uid-1")))
    }

    @Test
    fun addKeepsInsertionOrder() {
        queue.add("uid-1", 7L)
        queue.add("uid-1", 9L)
        assertEquals(listOf(7L, 9L), queue.list("uid-1"))
    }

    /** 幂等写入：重复 add 同一 id 不产生重复项，也不重排。 */
    @Test
    fun addIsIdempotent() {
        queue.add("uid-1", 7L)
        queue.add("uid-1", 9L)
        queue.add("uid-1", 7L)
        assertEquals(listOf(7L, 9L), queue.list("uid-1"))
    }

    @Test
    fun removeDropsOnlyThatId() {
        queue.add("uid-1", 7L)
        queue.add("uid-1", 9L)

        queue.remove("uid-1", 7L)
        assertEquals(listOf(9L), queue.list("uid-1"))

        // 移除不存在的 id 为无操作（幂等）
        queue.remove("uid-1", 42L)
        assertEquals(listOf(9L), queue.list("uid-1"))
    }

    @Test
    fun clearEmptiesQueue() {
        queue.add("uid-1", 7L)
        queue.add("uid-1", 9L)

        queue.clear("uid-1")

        assertTrue(queue.list("uid-1").isEmpty())
    }

    @Test
    fun uidsAreIsolated() {
        queue.add("uid-A", 1L)
        queue.add("uid-B", 2L)

        assertEquals(listOf(1L), queue.list("uid-A"))
        assertEquals(listOf(2L), queue.list("uid-B"))

        queue.clear("uid-A")

        assertTrue(queue.list("uid-A").isEmpty())
        assertEquals(listOf(2L), queue.list("uid-B"))
    }

    /** 跨实例持久化（同一 prefs 上的新实例能读到旧值）。 */
    @Test
    fun survivesNewInstanceOnSamePrefs() {
        queue.add("uid-1", 5L)
        assertEquals(listOf(5L), PendingDeletes(prefs).list("uid-1"))
    }

    @Test
    fun corruptJsonReturnsEmptyInsteadOfThrowing() {
        prefs.putRaw(PendingDeletes.key("uid-1"), "{not valid json")
        assertTrue(queue.list("uid-1").isEmpty())
    }

    // ---- 并发（R1 blocking 回归：写方法必须 @Synchronized） ----

    /**
     * 4 线程并发 `add` 同一 uid 的 800 个不同 serverId → 一条都不能丢。
     *
     * 生产里正是这个形状：主线程删除批注时 `add`、同步线程 flush 时 `remove`/`add`，
     * 两侧都是「读列表 → 改 → 整键回写」。没有 `@Synchronized` 时后写覆盖先写，
     * 丢掉的 serverId 对应服务端记录永不删除（下次 pull 复现成幽灵批注）。
     * 存储层（[FakeSharedPreferences]）本身线程安全，因此本用例只会因 store 层竞态失败。
     */
    @Test
    fun concurrentAddsLoseNoEntries() {
        val threads = 4
        val perThread = 200
        runConcurrently(threads) { index ->
            repeat(perThread) { offset -> queue.add("uid-1", (index * perThread + offset).toLong()) }
        }

        val ids = queue.list("uid-1")
        assertEquals("并发 add 丢条目", threads * perThread, ids.size)
        assertEquals((0 until threads * perThread).map { it.toLong() }.toSet(), ids.toSet())
    }

    /**
     * add 与 remove 并发交错（两个线程各改不同 id 区间）→ 结果仍与串行执行一致。
     *
     * 预置 0..199，随后并发「追加 200..399」与「移除 0..199」：两个操作触及的 id 不相交，
     * 串行执行的结果恒为 `{200..399}`，因此任何丢更新都会让断言失败。
     */
    @Test
    fun concurrentAddAndRemoveMatchSerialResult() {
        repeat(200) { queue.add("uid-1", it.toLong()) }

        runConcurrently(2) { index ->
            if (index == 0) {
                (200L until 400L).forEach { queue.add("uid-1", it) }
            } else {
                (0L until 200L).forEach { queue.remove("uid-1", it) }
            }
        }

        assertEquals((200L until 400L).toList(), queue.list("uid-1"))
    }

    /** 起 [threads] 个线程同时执行 [body]（用 CountDownLatch 对齐起跑，30 秒上限）。 */
    private fun runConcurrently(threads: Int, body: (index: Int) -> Unit) {
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val pool = Executors.newFixedThreadPool(threads)
        try {
            repeat(threads) { index ->
                pool.execute {
                    start.await()
                    try {
                        body(index)
                    } finally {
                        done.countDown()
                    }
                }
            }
            start.countDown()
            assertTrue("并发用例未在 30 秒内完成（疑似死锁）", done.await(30, TimeUnit.SECONDS))
        } finally {
            pool.shutdown()
        }
    }
}
