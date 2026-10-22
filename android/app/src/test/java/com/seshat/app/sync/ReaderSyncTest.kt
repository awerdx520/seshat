package com.seshat.app.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [createReaderSync] 的守卫逻辑单测：Activity 无法在 JVM 单测，这里是「同步装配」唯一的可测点。
 *
 * 覆盖三个守卫（uid 非空、config 非空、装配成功）以及「守卫不通过时零网络行为」的不变量
 * （[restFactory] 调用次数为 0）。泛型参数取 `String` / `String`，聚焦守卫而非字段映射。
 */
class ReaderSyncTest {

    /** 内存版服务端：只记录调用，不做真实 IO。 */
    private class FakeRest : RestSyncApi {
        var lastSetPosition: String? = null
        var lastSetUpdatedAt: String? = null

        override fun getProgress(uid: String): Progress? = null

        override fun setProgress(uid: String, position: String, updatedAt: String?): Progress {
            lastSetPosition = position
            lastSetUpdatedAt = updatedAt
            return Progress(uid = uid, position = position, updatedAt = "2026-10-18T10:00:00Z")
        }

        override fun createAnnotation(
            uid: String,
            location: String,
            text: String,
            kind: String,
            selectedText: String,
        ): Annotation = Annotation(id = 1, uid = uid, location = location, text = text, kind = kind)

        override fun listAnnotations(uid: String): List<Annotation> = emptyList()

        /** 断言守卫路径不发生更新/删除（本文件的用例只关心 pushProgress 透传）。 */
        override fun updateAnnotation(
            id: Long,
            location: String,
            text: String,
            kind: String,
            selectedText: String,
            updatedAt: String?,
        ): UpdateAnnotationResult = UpdateAnnotationResult.Conflict

        override fun deleteAnnotation(id: Long) = Unit
    }

    /** 内存版本地存储：`localProgress` 非 null 时 `pushProgress` 才会真正发请求。 */
    private class FakeStore(private val localProgress: String? = "chapter:1") :
        LocalSyncStore<String, String> {
        val savedProgress = mutableListOf<Pair<String, String>>()

        override fun loadProgress(uid: String): String? = localProgress

        override fun saveProgress(uid: String, progress: String) {
            savedProgress += uid to progress
        }

        override fun loadAnnotations(uid: String): List<String> = emptyList()

        override fun addAnnotation(uid: String, annotation: String) = Unit

        override fun updateAnnotation(uid: String, annotation: String): Boolean = false

        override fun removeAnnotation(uid: String, annotation: String): Boolean = false
    }

    /** 恒等映射：进度/批注在本地与远端使用同一字符串，断言不必关心编码细节。 */
    private class FakeMapper : SyncMapper<String, String> {
        override fun encodePosition(progress: String): String = progress

        /** 字符串模型没有时间戳概念：一律视为未知（`pushProgress` 传 `null`）。 */
        override fun updatedAt(progress: String): Long = 0L

        override fun decodeProgress(uid: String, position: String, updatedAt: String?): String =
            position

        override fun location(annotation: String): String = annotation

        override fun text(annotation: String): String = annotation

        override fun kind(annotation: String): String = "note"

        override fun selectedText(annotation: String): String = ""

        override fun serverId(annotation: String): Long? = null

        override fun isDirty(annotation: String): Boolean = false

        override fun fromRemote(remote: Annotation): String = remote.text
    }

    private val config = SeshatConfig(serverUrl = "https://seshat.example.com", token = "token")

    @Test
    fun nullUidReturnsNullWithoutCallingRestFactory() {
        var factoryCalls = 0

        val manager = createReaderSync<String, String>(
            uid = null,
            config = config,
            restFactory = { factoryCalls++; FakeRest() },
            store = FakeStore(),
            mapper = FakeMapper(),
        )

        assertNull(manager)
        assertEquals("无 uid 时不得构造 RestClient（零网络行为）", 0, factoryCalls)
    }

    @Test
    fun blankUidReturnsNullWithoutCallingRestFactory() {
        var factoryCalls = 0

        val manager = createReaderSync<String, String>(
            uid = "  ",
            config = config,
            restFactory = { factoryCalls++; FakeRest() },
            store = FakeStore(),
            mapper = FakeMapper(),
        )

        assertNull(manager)
        assertEquals("空白 uid 等价于无 uid", 0, factoryCalls)
    }

    @Test
    fun nullConfigReturnsNullWithoutCallingRestFactory() {
        var factoryCalls = 0

        val manager = createReaderSync<String, String>(
            uid = "doc-uid-1",
            config = null,
            restFactory = { factoryCalls++; FakeRest() },
            store = FakeStore(),
            mapper = FakeMapper(),
        )

        assertNull(manager)
        assertEquals("服务端未配置时不得构造 RestClient", 0, factoryCalls)
    }

    @Test
    fun validUidAndConfigBuildsManagerWithSingleRestFactoryCall() {
        var factoryCalls = 0

        val manager = createReaderSync<String, String>(
            uid = "doc-uid-1",
            config = config,
            restFactory = { factoryCalls++; FakeRest() },
            store = FakeStore(),
            mapper = FakeMapper(),
        )

        assertNotNull(manager)
        assertEquals("恰好构造一次 RestClient", 1, factoryCalls)
    }

    @Test
    fun builtManagerForwardsPushProgressToRestApi() {
        val rest = FakeRest()
        val manager = createReaderSync<String, String>(
            uid = "doc-uid-1",
            config = config,
            restFactory = { rest },
            store = FakeStore(localProgress = "chapter:7"),
            mapper = FakeMapper(),
        )

        // 装配正确性：manager 内部确实持有 restFactory 产出的 RestSyncApi 与传入的 store/mapper。
        assertNotNull(manager)
        val pushed = requireNotNull(manager).pushProgress("doc-uid-1")

        assertEquals("chapter:7", rest.lastSetPosition)
        assertEquals("chapter:7", pushed?.position)
        assertEquals("doc-uid-1", pushed?.uid)
        assertNull("映射器报告 updatedAt 未知时应传 null（服务端跳过冲突检测）", rest.lastSetUpdatedAt)
    }
}
