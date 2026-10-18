package com.seshat.app.sync

import com.seshat.app.reader.AnnotationStore
import com.seshat.app.reader.BookAnnotation
import com.seshat.app.reader.PdfAnnotation
import com.seshat.app.reader.PdfAnnotationStore
import com.seshat.app.reader.PdfProgress
import com.seshat.app.reader.PdfProgressStore
import com.seshat.app.reader.ReadingProgress
import com.seshat.app.reader.ReadingProgressStore
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

/**
 * 服务端状态同步所需的最小 REST 能力（进度 + 批注）。
 *
 * 抽象为接口而非直接依赖 [RestClient]，使 [SyncManager] 可在 JVM 单测中用 fake 替换；
 * [RestClient] 保持 M3.1 原样不变，避免其方法默认参数被 override 规则破坏
 * （override 不允许重复声明默认值，所以由 [RestClientSyncAdapter] 转发而非直接实现）。
 */
interface RestSyncApi {
    /** 获取阅读进度；服务端无记录（304/404 等）时返回 `null`。 */
    fun getProgress(uid: String): Progress?

    /**
     * 覆盖写入阅读进度，返回服务端实际保存的记录。
     *
     * [updatedAt] 为 RFC 3339 时间戳（本地进度的最后修改时间）。服务端 409 语义：
     * - `null`（本地时间戳未知）→ 服务端写入当前时间，**不做冲突检测**（最后写胜）；
     * - 非 `null` → 若该值落后于服务端已有记录的 `updated_at`，服务端返回 409 冲突。
     */
    fun setProgress(uid: String, position: String, updatedAt: String? = null): Progress

    /** 创建批注，返回含服务端分配 id 的完整对象。 */
    fun createAnnotation(uid: String, location: String, text: String): Annotation

    /** 列出某 uid 的全部批注。 */
    fun listAnnotations(uid: String): List<Annotation>
}

/** 把 M3.1 的 [RestClient] 适配为 [RestSyncApi]（不改动既有客户端实现）。 */
class RestClientSyncAdapter(private val client: RestClient) : RestSyncApi {
    override fun getProgress(uid: String): Progress? = client.getProgress(uid)

    override fun setProgress(uid: String, position: String, updatedAt: String?): Progress =
        client.setProgress(uid, position, updatedAt)

    override fun createAnnotation(uid: String, location: String, text: String): Annotation =
        client.createAnnotation(uid, location, text)

    override fun listAnnotations(uid: String): List<Annotation> =
        client.listAnnotations(uid)
}

/**
 * 本地进度 / 批注读写抽象。
 *
 * [SyncManager] 只依赖该接口，不感知 epub（[ReadingProgressStore] / [AnnotationStore]）
 * 或 pdf（[PdfProgressStore] / [PdfAnnotationStore]）的具体实现。
 *
 * 所有方法的键都是 **uid**：有服务端 uid 时用 uid，没有时退回本地旧 documentId
 * （本地模型字段仍叫 `documentId`，其值即 effectiveKey）。
 *
 * @param P 本地进度模型（epub 为 [ReadingProgress]，pdf 为 [PdfProgress]）。
 * @param A 本地批注模型（epub 为 [BookAnnotation]，pdf 为 [PdfAnnotation]）。
 */
interface LocalSyncStore<P, A> {
    fun loadProgress(uid: String): P?

    fun saveProgress(uid: String, progress: P)

    fun loadAnnotations(uid: String): List<A>

    fun addAnnotation(uid: String, annotation: A)
}

/**
 * 本地模型与服务端 DTO 之间的字段映射。
 *
 * 进度本地字段（epub 的 chapterIndex+scrollY、pdf 的 page）序列化为服务端 `position` 字符串；
 * 批注本地字段映射为服务端 `location` / `text`，并支持从服务端对象还原本地模型。
 */
interface SyncMapper<P, A> {
    /** 本地进度 → 服务端 `position` 字符串。 */
    fun encodePosition(progress: P): String

    /** 本地进度中的 `updated_at`（epoch millis）；0 表示未知。 */
    fun updatedAt(progress: P): Long

    /** 服务端 `position` + `updated_at` → 本地进度模型（`uid` 写入本地 `documentId` 字段）。 */
    fun decodeProgress(uid: String, position: String, updatedAt: String?): P

    /** 本地批注 → 服务端 `location`。 */
    fun location(annotation: A): String

    /** 本地批注 → 服务端 `text`。 */
    fun text(annotation: A): String

    /** 服务端批注对象 → 本地批注模型。 */
    fun fromRemote(remote: Annotation): A
}

/** [SyncManager.syncDocument] 的结果摘要。 */
data class SyncSummary(
    /** 本次同步使用的 uid（服务端资源标识；M7 之后旧称 document_id）。 */
    val uid: String,
    /** 本次推送后的服务端进度；本地无进度时为 `null`。 */
    val pushedProgress: Progress?,
    /** 本次是否从服务端拉取到进度并写入本地。 */
    val pulledProgress: Boolean,
    /** 本次推送到服务端的新建批注数。 */
    val pushedAnnotations: Int,
    /** 本次从服务端合并进本地的新增批注数。 */
    val pulledAnnotations: Int,
)

/**
 * 阅读进度 / 批注的双向同步编排器。
 *
 * 依赖 [RestSyncApi]（服务端）、[LocalSyncStore]（本地存取）、[SyncMapper]（字段映射）三者，
 * 通过泛型 + 接口注入屏蔽 epub / pdf 差异：SyncManager 本身不引用任何具体 store 类。
 *
 * ## uid 语义
 * 所有方法的参数名都是 `uid`（服务端资源标识；M7 之后旧称 `document_id`）：26 位
 * Crockford Base32，由服务端生成、客户端不解析只透传。本地键可能是 uid，也可能是迁移前的
 * 旧 documentId（内容哈希 / uri）；**有 uid 时必须用 uid**，否则推送出去的数据无法按 uid 读回。
 * 因此 `uid` 为空白即「本机离线阅读 / 未登记」——所有入口零网络请求（与
 * [createReaderSync] 的守卫同源）。
 *
 * ## 幂等语义
 * 批注以 `location + text` 作为去重键，推送前跳过服务端已存在的、拉取时跳过本地已存在的，
 * 因此重复调用不会产生重复批注。
 *
 * @param P 本地进度模型。
 * @param A 本地批注模型。
 */
class SyncManager<P, A>(
    private val rest: RestSyncApi,
    private val store: LocalSyncStore<P, A>,
    private val mapper: SyncMapper<P, A>,
) {
    /**
     * 本地进度 → 服务端；返回服务端回读结果。
     *
     * 本地无进度、或 uid 空白时不推送，返回 `null`。空白 uid 意味着没有服务端身份，
     * 必须零网络请求（否则会在远端生成再也读不回来的孤儿数据）。
     */
    fun pushProgress(uid: String): Progress? {
        if (uid.isBlank()) return null
        val local = store.loadProgress(uid) ?: return null
        return rest.setProgress(uid, mapper.encodePosition(local), mapUpdatedAt(local))
    }

    /**
     * 服务端进度 → 本地；返回写入本地的进度。
     * 服务端无记录时返回 `null`；uid 空白时直接返回 `null`（零网络请求），不触碰本地数据。
     */
    fun pullProgress(uid: String): P? {
        if (uid.isBlank()) return null
        val remote = rest.getProgress(uid) ?: return null
        val local = mapper.decodeProgress(uid, remote.position, remote.updatedAt)
        store.saveProgress(uid, local)
        return local
    }

    /**
     * 本地批注 → 服务端逐条推送，跳过服务端已存在的（`location + text` 相同者）。
     * 返回本次新建的服务端批注对象；uid 空白时返回空列表（零网络请求）。
     */
    fun pushAnnotations(uid: String): List<Annotation> {
        if (uid.isBlank()) return emptyList()
        val local = store.loadAnnotations(uid)
        if (local.isEmpty()) return emptyList()
        val remoteKeys = rest.listAnnotations(uid)
            .map { annotationKey(it.location, it.text) }
            .toSet()
        return local
            .filter { annotationKey(mapper.location(it), mapper.text(it)) !in remoteKeys }
            .map { rest.createAnnotation(uid, mapper.location(it), mapper.text(it)) }
    }

    /**
     * 服务端批注 → 合并进本地 store，跳过本地已存在的（`location + text` 相同者）。
     * 返回本次新增到本地的批注；uid 空白时返回空列表（零网络请求）。
     */
    fun pullAnnotations(uid: String): List<A> {
        if (uid.isBlank()) return emptyList()
        val remote = rest.listAnnotations(uid)
        if (remote.isEmpty()) return emptyList()
        val localKeys = store.loadAnnotations(uid)
            .map { annotationKey(mapper.location(it), mapper.text(it)) }
            .toMutableSet()
        val added = mutableListOf<A>()
        for (item in remote) {
            val key = annotationKey(item.location, item.text)
            if (!localKeys.add(key)) continue
            val local = mapper.fromRemote(item)
            store.addAnnotation(uid, local)
            added += local
        }
        return added
    }

    /**
     * 一次完成 pushProgress + pushAnnotations + pullProgress + pullAnnotations。
     *
     * uid 空白时直接返回空摘要、**不调用任何 rest 方法**（与四个单步入口的守卫一致）。
     */
    fun syncDocument(uid: String): SyncSummary {
        if (uid.isBlank()) {
            return SyncSummary(
                uid = uid,
                pushedProgress = null,
                pulledProgress = false,
                pushedAnnotations = 0,
                pulledAnnotations = 0,
            )
        }
        val pushedProgress = pushProgress(uid)
        val pushedAnnotations = pushAnnotations(uid).size
        val pulled = pullProgress(uid)
        val pulledAnnotations = pullAnnotations(uid).size
        return SyncSummary(
            uid = uid,
            pushedProgress = pushedProgress,
            pulledProgress = pulled != null,
            pushedAnnotations = pushedAnnotations,
            pulledAnnotations = pulledAnnotations,
        )
    }

    /**
     * 本地 `updatedAt`（epoch millis）→ 服务端可用的 RFC 3339 字符串。
     * `<= 0` 视为未知，返回 `null`：服务端填当前时间并跳过 409 冲突检测。
     */
    private fun mapUpdatedAt(progress: P): String? {
        val millis = mapper.updatedAt(progress)
        return if (millis <= 0L) null else formatRfc3339Millis(millis)
    }

    /** 批注去重键：以 NUL 分隔避免 location / text 边界歧义。 */
    private fun annotationKey(location: String, text: String): String = "$location\u0000$text"
}

// ---- epub 侧适配（包装 M3.2 的 store，不修改其实现） ----

/** 包装 epub 的 [ReadingProgressStore] / [AnnotationStore] 为统一同步存储。 */
class EpubLocalSyncStore(
    private val progressStore: ReadingProgressStore,
    private val annotationStore: AnnotationStore,
) : LocalSyncStore<ReadingProgress, BookAnnotation> {
    override fun loadProgress(uid: String): ReadingProgress? = progressStore.load(uid)

    override fun saveProgress(uid: String, progress: ReadingProgress) {
        // 以 uid 为准写键：本地模型的 documentId 字段存的就是 effectiveKey（T4a）。
        progressStore.save(progress.copy(documentId = uid))
    }

    override fun loadAnnotations(uid: String): List<BookAnnotation> = annotationStore.list(uid)

    override fun addAnnotation(uid: String, annotation: BookAnnotation) {
        annotationStore.add(annotation.copy(documentId = uid))
    }
}

// ---- pdf 侧适配（包装 M3.3 的 store，不修改其实现） ----

/** 包装 pdf 的 [PdfProgressStore] / [PdfAnnotationStore] 为统一同步存储。 */
class PdfLocalSyncStore(
    private val progressStore: PdfProgressStore,
    private val annotationStore: PdfAnnotationStore,
) : LocalSyncStore<PdfProgress, PdfAnnotation> {
    override fun loadProgress(uid: String): PdfProgress? = progressStore.load(uid)

    override fun saveProgress(uid: String, progress: PdfProgress) {
        progressStore.save(uid, progress)
    }

    override fun loadAnnotations(uid: String): List<PdfAnnotation> = annotationStore.list(uid)

    override fun addAnnotation(uid: String, annotation: PdfAnnotation) {
        annotationStore.add(annotation.copy(documentId = uid))
    }
}

// ---- 字段映射实现 ----

/** epub 进度/批注 ↔ 服务端 DTO 映射。 */
class EpubSyncMapper : SyncMapper<ReadingProgress, BookAnnotation> {
    /** position 编码为 `<chapterIndex>:<scrollY>`（如 `3:42`）。 */
    override fun encodePosition(progress: ReadingProgress): String =
        "${progress.chapterIndex}:${progress.scrollY}"

    override fun updatedAt(progress: ReadingProgress): Long = progress.updatedAt

    override fun decodeProgress(uid: String, position: String, updatedAt: String?): ReadingProgress {
        val parts = position.split(':')
        val chapter = parts.getOrNull(0)?.toIntOrNull() ?: 0
        val scroll = parts.getOrNull(1)?.toIntOrNull() ?: 0
        return ReadingProgress(
            documentId = uid,
            chapterIndex = chapter,
            scrollY = scroll,
            updatedAt = parseRfc3339Millis(updatedAt),
        )
    }

    /** epub 批注位置编码为 `chapter-<chapterIndex>`。 */
    override fun location(annotation: BookAnnotation): String = "chapter-${annotation.chapterIndex}"

    /** 批注内容取 [BookAnnotation.note]。 */
    override fun text(annotation: BookAnnotation): String = annotation.note

    override fun fromRemote(remote: Annotation): BookAnnotation = BookAnnotation(
        id = remote.id.toString(),
        documentId = remote.uid,
        chapterIndex = chapterIndexOf(remote.location),
        selectedText = "",
        note = remote.text,
        createdAt = parseRfc3339Millis(remote.createdAt),
    )

    private fun chapterIndexOf(location: String): Int =
        location.removePrefix("chapter-").substringBefore(':').toIntOrNull() ?: 0
}

/** pdf 进度/批注 ↔ 服务端 DTO 映射。 */
class PdfSyncMapper : SyncMapper<PdfProgress, PdfAnnotation> {
    /** position 编码为页码字符串（如 `12`）。 */
    override fun encodePosition(progress: PdfProgress): String = progress.page.toString()

    override fun updatedAt(progress: PdfProgress): Long = progress.updatedAt

    override fun decodeProgress(uid: String, position: String, updatedAt: String?): PdfProgress =
        PdfProgress(
            page = position.toIntOrNull() ?: 0,
            updatedAt = parseRfc3339Millis(updatedAt),
        )

    /** pdf 批注位置即本地 `location`（`page:<n>`）。 */
    override fun location(annotation: PdfAnnotation): String = annotation.location

    override fun text(annotation: PdfAnnotation): String = annotation.text

    override fun fromRemote(remote: Annotation): PdfAnnotation = PdfAnnotation(
        id = remote.id,
        documentId = remote.uid,
        location = remote.location,
        text = remote.text,
        createdAt = parseRfc3339Millis(remote.createdAt),
        updatedAt = parseRfc3339Millis(remote.updatedAt ?: remote.createdAt),
    )
}

/** RFC 3339 时间戳 → epoch 毫秒；空白或不可解析返回 0。 */
internal fun parseRfc3339Millis(value: String?): Long {
    if (value.isNullOrBlank()) return 0L
    return try {
        OffsetDateTime.parse(value).toInstant().toEpochMilli()
    } catch (_: Exception) {
        0L
    }
}

/**
 * epoch 毫秒 → RFC 3339（UTC）时间戳，**秒精度**，如 `2026-10-18T07:30:00Z`；与 [parseRfc3339Millis] 配对。
 *
 * 只在 `millis > 0` 时被调用（0 表示未知，应传 `null` 而非 `1970-01-01T00:00:00Z`，
 * 后者会让服务端以为本地时间戳极旧而误判 409）。
 *
 * ## 为什么必须截断到秒
 * 服务端（`internal/storage/state.go`）声明的是 `const timestampLayout = time.RFC3339`，
 * Go 的 [time.Parse] 按该布局**严格**匹配：`time.RFC3339` 不含小数秒，因此
 * `2026-10-18T07:30:00.123Z` 会被判 `invalid_argument`，接口返回 400。
 * 而本地 `updatedAt` 取自 `System.currentTimeMillis()`，毫秒几乎从不为 0——
 * 不截断就等于**每次 `PUT /api/progress` 都 400**（进度同步完全失效）。
 * 代价是秒内的多次修改共享同一时间戳，对「最后写胜 / 409 冲突检测」的秒级语义无影响。
 */
internal fun formatRfc3339Millis(millis: Long): String =
    OffsetDateTime.ofInstant(Instant.ofEpochMilli(millis), ZoneOffset.UTC)
        .truncatedTo(ChronoUnit.SECONDS)
        .toString()
