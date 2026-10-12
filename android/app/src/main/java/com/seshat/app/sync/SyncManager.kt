package com.seshat.app.sync

import com.seshat.app.reader.AnnotationStore
import com.seshat.app.reader.BookAnnotation
import com.seshat.app.reader.PdfAnnotation
import com.seshat.app.reader.PdfAnnotationStore
import com.seshat.app.reader.PdfProgress
import com.seshat.app.reader.PdfProgressStore
import com.seshat.app.reader.ReadingProgress
import com.seshat.app.reader.ReadingProgressStore
import java.time.OffsetDateTime

/**
 * 服务端状态同步所需的最小 REST 能力（进度 + 批注）。
 *
 * 抽象为接口而非直接依赖 [RestClient]，使 [SyncManager] 可在 JVM 单测中用 fake 替换；
 * [RestClient] 保持 M3.1 原样不变，避免其方法默认参数被 override 规则破坏。
 */
interface RestSyncApi {
    /** 获取阅读进度；服务端无记录（304/404 等）时返回 `null`。 */
    fun getProgress(documentId: String): Progress?

    /** 覆盖写入阅读进度，返回服务端实际保存的记录。 */
    fun setProgress(documentId: String, position: String): Progress

    /** 创建批注，返回含服务端分配 id 的完整对象。 */
    fun createAnnotation(documentId: String, location: String, text: String): Annotation

    /** 列出某文档的全部批注。 */
    fun listAnnotations(documentId: String): List<Annotation>
}

/** 把 M3.1 的 [RestClient] 适配为 [RestSyncApi]（不改动既有客户端实现）。 */
class RestClientSyncAdapter(private val client: RestClient) : RestSyncApi {
    override fun getProgress(documentId: String): Progress? = client.getProgress(documentId)

    override fun setProgress(documentId: String, position: String): Progress =
        client.setProgress(documentId, position)

    override fun createAnnotation(documentId: String, location: String, text: String): Annotation =
        client.createAnnotation(documentId, location, text)

    override fun listAnnotations(documentId: String): List<Annotation> =
        client.listAnnotations(documentId)
}

/**
 * 本地进度 / 批注读写抽象。
 *
 * [SyncManager] 只依赖该接口，不感知 epub（[ReadingProgressStore] / [AnnotationStore]）
 * 或 pdf（[PdfProgressStore] / [PdfAnnotationStore]）的具体实现。
 *
 * @param P 本地进度模型（epub 为 [ReadingProgress]，pdf 为 [PdfProgress]）。
 * @param A 本地批注模型（epub 为 [BookAnnotation]，pdf 为 [PdfAnnotation]）。
 */
interface LocalSyncStore<P, A> {
    fun loadProgress(docId: String): P?

    fun saveProgress(docId: String, progress: P)

    fun loadAnnotations(docId: String): List<A>

    fun addAnnotation(docId: String, annotation: A)
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

    /** 服务端 `position` + `updated_at` → 本地进度模型。 */
    fun decodeProgress(docId: String, position: String, updatedAt: String?): P

    /** 本地批注 → 服务端 `location`。 */
    fun location(annotation: A): String

    /** 本地批注 → 服务端 `text`。 */
    fun text(annotation: A): String

    /** 服务端批注对象 → 本地批注模型。 */
    fun fromRemote(remote: Annotation): A
}

/** [SyncManager.syncDocument] 的结果摘要。 */
data class SyncSummary(
    /** 文档 id。 */
    val docId: String,
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
 * 幂等语义：批注以 `location + text` 作为去重键，推送前跳过服务端已存在的、拉取时跳过本地已存在的，
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
     * 本地无进度时不推送，返回 `null`。
     */
    fun pushProgress(docId: String): Progress? {
        val local = store.loadProgress(docId) ?: return null
        return rest.setProgress(docId, mapper.encodePosition(local))
    }

    /**
     * 服务端进度 → 本地；返回写入本地的进度。
     * 服务端无记录时返回 `null`，不触碰本地数据。
     */
    fun pullProgress(docId: String): P? {
        val remote = rest.getProgress(docId) ?: return null
        val local = mapper.decodeProgress(docId, remote.position, remote.updatedAt)
        store.saveProgress(docId, local)
        return local
    }

    /**
     * 本地批注 → 服务端逐条推送，跳过服务端已存在的（`location + text` 相同者）。
     * 返回本次新建的服务端批注对象。
     */
    fun pushAnnotations(docId: String): List<Annotation> {
        val local = store.loadAnnotations(docId)
        if (local.isEmpty()) return emptyList()
        val remoteKeys = rest.listAnnotations(docId)
            .map { annotationKey(it.location, it.text) }
            .toSet()
        return local
            .filter { annotationKey(mapper.location(it), mapper.text(it)) !in remoteKeys }
            .map { rest.createAnnotation(docId, mapper.location(it), mapper.text(it)) }
    }

    /**
     * 服务端批注 → 合并进本地 store，跳过本地已存在的（`location + text` 相同者）。
     * 返回本次新增到本地的批注。
     */
    fun pullAnnotations(docId: String): List<A> {
        val remote = rest.listAnnotations(docId)
        if (remote.isEmpty()) return emptyList()
        val localKeys = store.loadAnnotations(docId)
            .map { annotationKey(mapper.location(it), mapper.text(it)) }
            .toMutableSet()
        val added = mutableListOf<A>()
        for (item in remote) {
            val key = annotationKey(item.location, item.text)
            if (!localKeys.add(key)) continue
            val local = mapper.fromRemote(item)
            store.addAnnotation(docId, local)
            added += local
        }
        return added
    }

    /** 一次完成 pushProgress + pushAnnotations + pullProgress + pullAnnotations。 */
    fun syncDocument(docId: String): SyncSummary {
        val pushedProgress = pushProgress(docId)
        val pushedAnnotations = pushAnnotations(docId).size
        val pulled = pullProgress(docId)
        val pulledAnnotations = pullAnnotations(docId).size
        return SyncSummary(
            docId = docId,
            pushedProgress = pushedProgress,
            pulledProgress = pulled != null,
            pushedAnnotations = pushedAnnotations,
            pulledAnnotations = pulledAnnotations,
        )
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
    override fun loadProgress(docId: String): ReadingProgress? = progressStore.load(docId)

    override fun saveProgress(docId: String, progress: ReadingProgress) {
        // 以 docId 为准写键，避免调用方传入的 documentId 与目标文档不一致。
        progressStore.save(progress.copy(documentId = docId))
    }

    override fun loadAnnotations(docId: String): List<BookAnnotation> = annotationStore.list(docId)

    override fun addAnnotation(docId: String, annotation: BookAnnotation) {
        annotationStore.add(annotation.copy(documentId = docId))
    }
}

// ---- pdf 侧适配（包装 M3.3 的 store，不修改其实现） ----

/** 包装 pdf 的 [PdfProgressStore] / [PdfAnnotationStore] 为统一同步存储。 */
class PdfLocalSyncStore(
    private val progressStore: PdfProgressStore,
    private val annotationStore: PdfAnnotationStore,
) : LocalSyncStore<PdfProgress, PdfAnnotation> {
    override fun loadProgress(docId: String): PdfProgress? = progressStore.load(docId)

    override fun saveProgress(docId: String, progress: PdfProgress) {
        progressStore.save(docId, progress)
    }

    override fun loadAnnotations(docId: String): List<PdfAnnotation> = annotationStore.list(docId)

    override fun addAnnotation(docId: String, annotation: PdfAnnotation) {
        annotationStore.add(annotation.copy(documentId = docId))
    }
}

// ---- 字段映射实现 ----

/** epub 进度/批注 ↔ 服务端 DTO 映射。 */
class EpubSyncMapper : SyncMapper<ReadingProgress, BookAnnotation> {
    /** position 编码为 `<chapterIndex>:<scrollY>`（如 `3:42`）。 */
    override fun encodePosition(progress: ReadingProgress): String =
        "${progress.chapterIndex}:${progress.scrollY}"

    override fun decodeProgress(docId: String, position: String, updatedAt: String?): ReadingProgress {
        val parts = position.split(':')
        val chapter = parts.getOrNull(0)?.toIntOrNull() ?: 0
        val scroll = parts.getOrNull(1)?.toIntOrNull() ?: 0
        return ReadingProgress(
            documentId = docId,
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
        documentId = remote.documentId,
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

    override fun decodeProgress(docId: String, position: String, updatedAt: String?): PdfProgress =
        PdfProgress(
            page = position.toIntOrNull() ?: 0,
            updatedAt = parseRfc3339Millis(updatedAt),
        )

    /** pdf 批注位置即本地 `location`（`page:<n>`）。 */
    override fun location(annotation: PdfAnnotation): String = annotation.location

    override fun text(annotation: PdfAnnotation): String = annotation.text

    override fun fromRemote(remote: Annotation): PdfAnnotation = PdfAnnotation(
        id = remote.id,
        documentId = remote.documentId,
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
