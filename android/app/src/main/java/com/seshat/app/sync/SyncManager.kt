package com.seshat.app.sync

import com.seshat.app.reader.AnnotationStore
import com.seshat.app.reader.BookAnnotation
import com.seshat.app.reader.LocationCodec
import com.seshat.app.reader.PdfAnnotation
import com.seshat.app.reader.PdfAnnotationStore
import com.seshat.app.reader.PdfProgress
import com.seshat.app.reader.PdfProgressStore
import com.seshat.app.reader.PendingDeletes
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
    fun createAnnotation(
        uid: String,
        location: String,
        text: String,
        kind: String = "note",
        selectedText: String = "",
    ): Annotation

    /** 列出某 uid 的全部批注。 */
    fun listAnnotations(uid: String): List<Annotation>

    /**
     * 覆盖更新既有批注（`PUT /api/annotations/{id}`），返回可判别结果。
     *
     * 409 不抛异常而是返回 [UpdateAnnotationResult.Conflict]：冲突是同步流程的预期分支，
     * 用返回值强制调用方在编译期穷尽「重拉 + 以服务端版本为准」的处理。
     *
     * [updatedAt] 为 RFC 3339 时间戳；`null` 表示本地时间戳未知 → 服务端填当前时间且**不做**
     * 冲突检测（最后写胜）。批注模型目前没有可靠的本地上行时间戳，故 [SyncManager] 传 `null`。
     */
    fun updateAnnotation(
        id: Long,
        location: String,
        text: String,
        kind: String,
        selectedText: String,
        updatedAt: String?,
    ): UpdateAnnotationResult

    /** 删除批注（服务端 404 视为成功：目标已达成，幂等删除）。 */
    fun deleteAnnotation(id: Long)
}

/** 把 M3.1 的 [RestClient] 适配为 [RestSyncApi]（不改动既有客户端实现）。 */
class RestClientSyncAdapter(private val client: RestClient) : RestSyncApi {
    override fun getProgress(uid: String): Progress? = client.getProgress(uid)

    override fun setProgress(uid: String, position: String, updatedAt: String?): Progress =
        client.setProgress(uid, position, updatedAt)

    override fun createAnnotation(
        uid: String,
        location: String,
        text: String,
        kind: String,
        selectedText: String,
    ): Annotation = client.createAnnotation(uid, location, text, kind, selectedText)

    override fun listAnnotations(uid: String): List<Annotation> =
        client.listAnnotations(uid)

    /** 原样转发 [RestClient.updateAnnotation] 的可判别结果（`Ok` / `Conflict`）。 */
    override fun updateAnnotation(
        id: Long,
        location: String,
        text: String,
        kind: String,
        selectedText: String,
        updatedAt: String?,
    ): UpdateAnnotationResult =
        client.updateAnnotation(id, location, text, kind, selectedText, updatedAt)

    /** 原样转发；[RestClient.deleteAnnotation] 已把 404 视为成功。 */
    override fun deleteAnnotation(id: Long) = client.deleteAnnotation(id)
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

    /**
     * 按 [A] **自带的本地 id** 原地替换一条批注（保持列表顺序）。
     *
     * 为什么不把 id 作为独立参数：本地 id 类型随模型而异（pdf 为 `Long`、epub 为 `String`），
     * 泛型参数 `A` 无法表达该差异；若引入第三个类型参数 `ID`，所有装配点（[SyncManager]、
     * `createReaderSync`、两个 adapter、全部 fake）都要跟着多一个类型实参，收益远低于成本。
     * 让模型自带 id、由 store 实现自行取用是最简洁的方案：调用方只持有模型对象。
     *
     * @return 是否命中既有记录；未命中不写入（避免静默追加重复条目）。
     */
    fun updateAnnotation(uid: String, annotation: A): Boolean

    /**
     * 按 [A] **自带的本地 id** 移除一条批注（本地 id 未分配时由实现按 `serverId` 兜底匹配）。
     *
     * 与 [updateAnnotation] 同一 id 方案（模型自带 id，接口不携带 id 类型）。
     *
     * @return 是否真的删除了记录。
     */
    fun removeAnnotation(uid: String, annotation: A): Boolean
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

    /** 本地批注 → 服务端 `kind`（`note` / `highlight` / `ink`；空值按 `note`）。 */
    fun kind(annotation: A): String

    /** 本地批注 → 服务端 `selected_text`（选中原文；未知按空串）。 */
    fun selectedText(annotation: A): String

    /** 本地批注 → 服务端 id；`null` 表示尚未上传（需 POST，而非 PUT）。 */
    fun serverId(annotation: A): Long?

    /** 本地批注是否有未上行改动（`dirty`；决定 `serverId != null` 的记录是否要 PUT）。 */
    fun isDirty(annotation: A): Boolean

    /** 服务端批注对象 → 本地批注模型（本地 id **不得**复用服务端 id，服务端 id 只写入 `serverId`）。 */
    fun fromRemote(remote: Annotation): A

    /**
     * 服务端对象合并进**既有**本地记录：内容与 `serverId` 取服务端版本，本地 id 保留 [local] 的。
     *
     * 为什么需要它：[fromRemote] 刻意把本地 id 置为「未分配」（见其契约），直接写回 store 会
     * 因 id 不匹配而更新失败。合并语义必须由 mapper 提供——只有具体 mapper 能做 `copy(id=...)`。
     * 默认实现退化为 [fromRemote]（留给不需要保留本地 id 的极简 mapper / 测试替身）。
     */
    fun mergeRemote(local: A, remote: Annotation): A = fromRemote(remote)

    /** 复位「已上行」标记（`dirty = false`）；默认原样返回（无 dirty 概念的模型）。 */
    fun markSynced(annotation: A): A = annotation
}

/** [SyncManager.syncDocument] 的结果摘要。 */
data class SyncSummary(
    /** 本次同步使用的 uid（服务端资源标识；M7 之后旧称 document_id）。 */
    val uid: String,
    /** 本次推送后的服务端进度；本地无进度时为 `null`。 */
    val pushedProgress: Progress?,
    /** 本次是否从服务端拉取到进度并写入本地。 */
    val pulledProgress: Boolean,
    /** 本次推送到服务端的新建批注数（POST 成功数）。 */
    val pushedAnnotations: Int,
    /** 本次从服务端合并进本地的批注变更数（新增 + 更新）。 */
    val pulledAnnotations: Int,
    /** 本次以 PUT 上行的既有批注数（M10.3 T3 起；默认 0 保持向后兼容）。 */
    val updatedAnnotations: Int = 0,
    /** 本次成功传播的服务端删除数（含 DELETE 404 幂等命中；默认 0）。 */
    val deletedAnnotations: Int = 0,
    /** 本次因 409 以服务端版本为准、本地改动被覆盖的批注数（默认 0）。 */
    val conflictAnnotations: Int = 0,
    /**
     * 本次进度推送「409 冲突 → 重发仍 409」而失败（默认 `false`）。
     *
     * 与 [pushedProgress] 为 `null` 的区别：`null` 只说明「没有服务端认可的进度值」，
     * 可能是本地无进度（正常），也可能是推送失败（需提示）。该位把「失败」显式区分出来，
     * 避免整轮同步把冲突静默记成「推送失败（已忽略）」。
     */
    val progressRejected: Boolean = false,
)

/**
 * 进度推送的可判别结果（409 冲突合并语义，计划 T3）。
 *
 * 为什么需要可判别结果：`pushProgress` 曾把 409 交给调用方的 `runCatching` 记一句
 * 「推送失败（已忽略）」——本地较新的进度就此永久留在本机，服务端仍是旧值，两端长期分叉。
 * 409 是**预期分支**，必须显式处理并让调用方看见结局。
 */
sealed interface ProgressPushResult {
    /** 服务端已保存本地值（首次成功，或 409 后带新时间戳重发成功）。 */
    data class Pushed(val progress: Progress) : ProgressPushResult

    /** 409 后判定**服务端较新**：已用服务端值覆盖本地，视为成功（不重发）。[progress] 为服务端版本。 */
    data class Merged(val progress: Progress) : ProgressPushResult

    /** 409 后重发仍冲突：本地值未上行。调用方必须提示/重试，**不得静默忽略**。 */
    data class Rejected(val remote: Progress?) : ProgressPushResult

    /** 零请求路径：uid 空白或本地无进度。 */
    data object Skipped : ProgressPushResult
}

/** 一次批注推送的结果（[SyncManager.pushAnnotationsDetailed]）。 */
data class AnnotationPushResult<A>(
    /** 服务端返回的最新对象（新建 + 更新），顺序与本地遍历顺序一致。 */
    val pushed: List<Annotation> = emptyList(),
    /** 其中通过 POST 新建的条数。 */
    val created: Int = 0,
    /** 其中通过 PUT 更新的条数。 */
    val updated: Int = 0,
    /**
     * 因 409 冲突而**以服务端版本为准**的本地记录快照（本地改动被覆盖，不静默丢弃）。
     *
     * 调用方可用它产出一条「以下改动已被服务端版本替换」的提示（T5 UI）。
     */
    val conflicts: List<A> = emptyList(),
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
 * 批注以 `(kind, location, text)` 作为去重键：推送前跳过服务端已存在的、拉取时跳过内容已一致的，
 * 因此重复调用不会产生重复批注；同 location、不同 kind 视为两条独立批注。
 *
 * ## 状态回填
 * 无论 POST / PUT 还是拉取合并，写回本地一律走 `updateAnnotation`（保留本地 id），
 * 并把服务端 `id` 写入 `serverId`、`dirty` 复位——本地 id 与服务端 id 始终互不污染。
 *
 * @param P 本地进度模型。
 * @param A 本地批注模型。
 */
class SyncManager<P, A>(
    private val rest: RestSyncApi,
    private val store: LocalSyncStore<P, A>,
    private val mapper: SyncMapper<P, A>,
    /**
     * 待删队列（离线删除的服务端 id，`pending_deletes_<uid>`）。
     *
     * `null` 表示调用方未装配队列（仅进度同步 / 单测场景）：此时 [pushDeletes] 是**零请求**
     * 的空操作。生产装配见 `createReaderSync`。
     */
    private val pendingDeletes: PendingDeletes? = null,
) {
    /**
     * 本地进度 → 服务端；返回服务端回读结果（`null` 表示未推送或推送失败）。
     *
     * 兼容入口：语义等同 [pushProgressDetailed] 的 `Pushed`/`Merged`，其余情况返回 `null`。
     * 需要区分「本地无进度」与「409 重发仍失败」时请直接用 [pushProgressDetailed]。
     */
    fun pushProgress(uid: String): Progress? = when (val result = pushProgressDetailed(uid)) {
        is ProgressPushResult.Pushed -> result.progress
        is ProgressPushResult.Merged -> result.progress
        is ProgressPushResult.Rejected -> null
        ProgressPushResult.Skipped -> null
    }

    /**
     * 本地进度 → 服务端，返回**可判别结果**（含 409 冲突合并，计划 T3）。
     *
     * 流程：
     * 1. 正常 `PUT`，成功即 [ProgressPushResult.Pushed]；
     * 2. 命中 **409**（本地 `updated_at` 落后于服务端）→ 重拉服务端进度 `GET /api/progress/{uid}`：
     *    - 服务端较新（或本地时间戳未知）→ 用服务端值覆盖本地 store，返回
     *      [ProgressPushResult.Merged]（视为成功，**不重发**）；
     *    - 本地较新 → 用「严格大于服务端 `updated_at`」的时间戳重发**一次**（见
     *      [RETRY_TIMESTAMP_STEP_MILLIS]），成功即 [ProgressPushResult.Pushed]；
     *      （服务端当前规则是「请求时间戳严格更旧才 409」，因此该分支是防御性的：本地毫秒较新、
     *      但上行被截断到秒而与库内同秒时，严格规则的服务端不会冲突，更严格的中间层/未来规则会。）
     *    - 重发仍 409（或服务端记录已消失且重发也冲突）→ [ProgressPushResult.Rejected]，
     *      **不静默忽略**（[syncDocument] 会把该结局记入 [SyncSummary.progressRejected]）；
     * 3. **非 409** 的异常原样上抛（与其它端点的统一抛错语义一致，行为不变）。
     *
     * 本地无进度、uid 空白 → [ProgressPushResult.Skipped]（零网络请求）。
     */
    fun pushProgressDetailed(uid: String): ProgressPushResult {
        if (uid.isBlank()) return ProgressPushResult.Skipped
        val local = store.loadProgress(uid) ?: return ProgressPushResult.Skipped
        val position = mapper.encodePosition(local)
        return try {
            ProgressPushResult.Pushed(rest.setProgress(uid, position, mapUpdatedAt(local)))
        } catch (error: ApiException) {
            if (error.statusCode != HTTP_CONFLICT) throw error
            mergeProgressConflict(uid, local, position)
        }
    }

    /**
     * 进度 409 的合并：重拉服务端版本，比 `updated_at` 后决定「覆盖本地」还是「带新时间戳重发一次」。
     *
     * 重拉拿到 `null`（服务端记录在 409 与重拉之间被删）时没有可比的版本，直接用本地原时间戳
     * 重发一次——这类竞态重发通常就能落地；仍 409 则判失败。
     */
    private fun mergeProgressConflict(uid: String, local: P, position: String): ProgressPushResult {
        val remote = rest.getProgress(uid)
            ?: return retryProgress(uid, position, mapUpdatedAt(local), remote = null)
        val localMillis = mapper.updatedAt(local)
        val remoteMillis = parseRfc3339Millis(remote.updatedAt)
        // 本地时间戳未知（0）时信息不足，按「服务端为准」处理，与 pushAnnotations 的取舍一致
        val localWins = localMillis > 0L && localMillis > remoteMillis
        if (!localWins) {
            val merged = mapper.decodeProgress(uid, remote.position, remote.updatedAt)
            store.saveProgress(uid, merged)
            return ProgressPushResult.Merged(remote)
        }
        // 严格递增：服务端按秒精度比较，前进至少 1 秒（见 RETRY_TIMESTAMP_STEP_MILLIS）
        val retryMillis = maxOf(localMillis, remoteMillis + RETRY_TIMESTAMP_STEP_MILLIS)
        return retryProgress(uid, position, formatRfc3339Millis(retryMillis), remote)
    }

    /** 冲突后的单次重发：成功 → [ProgressPushResult.Pushed]；再 409 → [ProgressPushResult.Rejected]。 */
    private fun retryProgress(
        uid: String,
        position: String,
        updatedAt: String?,
        remote: Progress?,
    ): ProgressPushResult = try {
        ProgressPushResult.Pushed(rest.setProgress(uid, position, updatedAt))
    } catch (error: ApiException) {
        if (error.statusCode != HTTP_CONFLICT) throw error
        ProgressPushResult.Rejected(remote)
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
     * 本地批注 → 服务端逐条推送，返回服务端返回的对象（新建 + 更新）；uid 空白时返回空列表（零网络请求）。
     *
     * 语义见 [pushAnnotationsDetailed]；冲突等附加信息由后者提供。
     */
    fun pushAnnotations(uid: String): List<Annotation> = pushAnnotationsDetailed(uid).pushed

    /**
     * 本地批注 → 服务端逐条推送（POST 新建 / PUT 更新），并把服务端返回的对象回填本地。
     *
     * 每条本地批注按以下顺序判定：
     * 1. `serverId == null`（从未上传）：
     *    - 服务端已有同 `(kind, location, text)` 记录 → **认领**它（回填 `serverId`、清 `dirty`），
     *      不发 POST——上次 POST 成功但本地未回填（进程中途被杀）时不会产生重复批注；
     *    - 否则 `POST /api/annotations`，成功后用返回对象回填 `serverId` + 服务端字段并清 `dirty`。
     * 2. `serverId != null && dirty`：`PUT /api/annotations/{serverId}`；
     *    - `Ok` → 用返回对象回填并清 `dirty`；
     *    - `Conflict` → 重拉服务端版本并**以服务端为准**覆盖本地（同时清 `dirty`），
     *      本地改动作为冲突记录返回给调用方，不静默丢弃。
     * 3. 其余（`serverId != null && !dirty`）→ 跳过，零请求。
     *
     * 回填一律走 [LocalSyncStore.updateAnnotation]（按模型自带的本地 id 原地替换），
     * 因此本地 id 保持稳定、不会因同步而变动。
     *
     * 推送遇网络异常时异常向上抛出（`ApiException` / `IOException`）；此时已完成的条目
     * 均已回填，未完成的仍带 `dirty`，下次调用可安全重试（服务端幂等键兜底）。
     */
    fun pushAnnotationsDetailed(uid: String): AnnotationPushResult<A> {
        if (uid.isBlank()) return AnnotationPushResult()
        val local = store.loadAnnotations(uid)
        if (local.isEmpty()) return AnnotationPushResult()

        val remote = rest.listAnnotations(uid)
        val remoteByKey = remote.associateBy { annotationKey(it.kind, it.location, it.text) }.toMutableMap()
        val pushed = mutableListOf<Annotation>()
        val conflicts = mutableListOf<A>()
        var created = 0
        var updated = 0

        for (item in local) {
            val location = mapper.location(item)
            val text = mapper.text(item)
            val kind = mapper.kind(item)
            val selectedText = mapper.selectedText(item)
            val serverId = mapper.serverId(item)

            if (serverId == null) {
                val existing = remoteByKey[annotationKey(kind, location, text)]
                if (existing != null) {
                    // 服务端已有同键记录：认领而非重复创建（幂等兜底）。
                    store.updateAnnotation(uid, mapper.markSynced(mapper.mergeRemote(item, existing)))
                    continue
                }
                val serverObject = rest.createAnnotation(uid, location, text, kind, selectedText)
                remoteByKey[annotationKey(serverObject.kind, serverObject.location, serverObject.text)] = serverObject
                store.updateAnnotation(uid, mapper.markSynced(mapper.mergeRemote(item, serverObject)))
                pushed += serverObject
                created++
                continue
            }

            if (!mapper.isDirty(item)) continue

            val result = rest.updateAnnotation(
                id = serverId,
                location = location,
                text = text,
                kind = kind,
                selectedText = selectedText,
                // 本地批注模型没有可靠的上行时间戳（epub 只有 createdAt），传 null 让服务端
                // 不做冲突检测：宁可「最后写胜」，也不要因时间戳陈旧而把本地改动判成冲突丢掉。
                updatedAt = null,
            )
            when (result) {
                is UpdateAnnotationResult.Ok -> {
                    store.updateAnnotation(uid, mapper.markSynced(mapper.mergeRemote(item, result.annotation)))
                    pushed += result.annotation
                    updated++
                }
                UpdateAnnotationResult.Conflict -> {
                    conflicts += item
                    resolveConflict(uid, item, serverId)
                }
            }
        }
        return AnnotationPushResult(pushed = pushed, created = created, updated = updated, conflicts = conflicts)
    }

    /**
     * 409 冲突的服务端优先合并：重拉服务端版本并覆盖本地（清 `dirty`）。
     *
     * 服务端记录已不存在（被别端删除）时，本地记录一并移除——否则它会永远推不上去、
     * 也永远拉不回来（幽灵条目）。两种情况都把本地旧快照计入冲突列表（由调用方提示）。
     */
    private fun resolveConflict(uid: String, local: A, serverId: Long) {
        val serverVersion = rest.listAnnotations(uid).firstOrNull { it.id == serverId }
        if (serverVersion == null) {
            store.removeAnnotation(uid, local)
            return
        }
        store.updateAnnotation(uid, mapper.markSynced(mapper.mergeRemote(local, serverVersion)))
    }

    /**
     * 传播待删队列：逐条 `DELETE /api/annotations/{serverId}`，成功后出队；返回成功条数。
     *
     * - 404 由 [RestSyncApi.deleteAnnotation] 视为成功（目标已达成），照常出队；
     * - 出队后顺手清掉本地仍残留同 `serverId` 的记录（删除流程中途被杀留下的孤儿）；
     * - 某条 DELETE 抛异常（网络不可达）时异常上抛、**该条与后续条目仍留在队列**，下次重试；
     * - uid 空白、或未装配队列 → 零请求返回 0。
     */
    fun pushDeletes(uid: String): Int {
        if (uid.isBlank()) return 0
        val queue = pendingDeletes ?: return 0
        val pending = queue.list(uid)
        if (pending.isEmpty()) return 0
        var done = 0
        for (serverId in pending) {
            rest.deleteAnnotation(serverId)
            queue.remove(uid, serverId)
            store.loadAnnotations(uid)
                .filter { mapper.serverId(it) == serverId }
                .forEach { store.removeAnnotation(uid, it) }
            done++
        }
        return done
    }

    /**
     * 本地删除一条批注，并决定是否要上行（删除路径的唯一判定点，供阅读器 UI 调用）。
     *
     * - 先本地移除（[LocalSyncStore.removeAnnotation]）；
     * - `serverId != null` → 入待删队列，下次 [pushDeletes] 发 `DELETE`（离线也安全：队列持久化）；
     * - `serverId == null`（从未上传）→ **不发 DELETE、不入队**——服务端不认识这条记录；
     * - uid 空白（未登记）→ 只做本地移除：队列按 uid 分键，没有身份就无处归属。
     *
     * 删除**不复用** `dirty`：`dirty` 只表示「新增/修改待上行」，与「待删」是两套语义。
     *
     * @return 本地是否真的删除了记录（服务端传播是否成功由 [pushDeletes] 决定）。
     */
    fun deleteAnnotation(uid: String, annotation: A): Boolean {
        val removed = store.removeAnnotation(uid, annotation)
        val serverId = mapper.serverId(annotation)
        if (serverId != null && uid.isNotBlank()) pendingDeletes?.add(uid, serverId)
        return removed
    }

    /**
     * 服务端批注 → 合并进本地 store，返回本次新增或更新的本地记录；uid 空白时返回空列表（零网络请求）。
     *
     * **三路匹配**（顺序即优先级）：
     * 1. 本地 `serverId` 命中服务端 `id` → [LocalSyncStore.updateAnnotation] 覆盖内容；
     * 2. 未命中 → 按 `(kind, location, text)` 兜底查本地（仅匹配 `serverId == null` 的记录，
     *    避免把两条不同服务端记录合并成一条），命中则 update 并回填 `serverId`；
     * 3. 仍未命中 → [LocalSyncStore.addAnnotation]（本地 id 由 store 分配，绝不复用服务端 id）。
     *
     * 内容与服务端完全一致的记录**不写库、不计入返回值**，因此重复调用是幂等的。
     */
    fun pullAnnotations(uid: String): List<A> {
        if (uid.isBlank()) return emptyList()
        val remote = rest.listAnnotations(uid)
        if (remote.isEmpty()) return emptyList()
        val local = store.loadAnnotations(uid)
        val byServerId = local
            .mapNotNull { annotation -> mapper.serverId(annotation)?.let { it to annotation } }
            .toMap()
            .toMutableMap()
        val byKey = local
            .filter { mapper.serverId(it) == null }
            .associateBy { localKey(it) }
            .toMutableMap()
        val touched = mutableListOf<A>()
        for (item in remote) {
            val key = annotationKey(item.kind, item.location, item.text)
            val matched = byServerId[item.id] ?: byKey[key]
            if (matched != null) {
                // 本地有未上行改动（dirty）且已有 serverId 时**不得**用服务端版本覆盖：读者常离线改
                // 备注、下次打开书籍就先 pull，直接覆盖等于静默丢弃本地编辑。留给下一次 push 上行；
                // 真正的冲突（409）由 pushAnnotationsDetailed 走「服务端为准 + 返回冲突提示」。
                if (mapper.serverId(matched) != null && mapper.isDirty(matched)) continue
                if (sameContent(matched, item)) continue
                val merged = mapper.markSynced(mapper.mergeRemote(matched, item))
                store.updateAnnotation(uid, merged)
                byServerId[item.id] = merged
                byKey.remove(localKey(matched))
                touched += merged
                continue
            }
            val added = mapper.fromRemote(item)
            store.addAnnotation(uid, added)
            byServerId[item.id] = added
            touched += added
        }
        return touched
    }

    /**
     * 一次完成 pushProgress + pushAnnotations + pushDeletes + pullProgress + pullAnnotations。
     *
     * **删除必须早于拉取**：待删队列里的记录在服务端仍存在，若先拉取会被重新写回本地
     * （删了又出现）。
     *
     * uid 空白时直接返回空摘要、**不调用任何 rest 方法**（与各单步入口的守卫一致）。
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
        val progressPush = pushProgressDetailed(uid)
        val pushedProgress = when (progressPush) {
            is ProgressPushResult.Pushed -> progressPush.progress
            is ProgressPushResult.Merged -> progressPush.progress
            is ProgressPushResult.Rejected, ProgressPushResult.Skipped -> null
        }
        val push = pushAnnotationsDetailed(uid)
        val deleted = pushDeletes(uid)
        val pulled = pullProgress(uid)
        val pulledAnnotations = pullAnnotations(uid).size
        return SyncSummary(
            uid = uid,
            pushedProgress = pushedProgress,
            pulledProgress = pulled != null,
            pushedAnnotations = push.created,
            pulledAnnotations = pulledAnnotations,
            updatedAnnotations = push.updated,
            deletedAnnotations = deleted,
            conflictAnnotations = push.conflicts.size,
            progressRejected = progressPush is ProgressPushResult.Rejected,
        )
    }

    /** 本地记录的完整内容键 `(kind, location, text)`，用于 pull 的兜底匹配。 */
    private fun localKey(annotation: A): String =
        annotationKey(mapper.kind(annotation), mapper.location(annotation), mapper.text(annotation))

    /** 本地记录与服务端对象的内容是否已一致（含 `selectedText`）；一致则 pull 无需写库。 */
    private fun sameContent(local: A, remote: Annotation): Boolean =
        localKey(local) == annotationKey(remote.kind, remote.location, remote.text) &&
            mapper.selectedText(local) == remote.selectedText

    /**
     * 批注去重键：`kind + location + text` 三段，以 NUL 分隔避免边界歧义。
     *
     * 与服务端 `(uid, kind, location, text)`、Emacs 队列同构：同 location、不同 kind
     * （如同一章上的一条 highlight 与一条 note）视为两条独立批注，不得互相去重。
     */
    private fun annotationKey(kind: String, location: String, text: String): String =
        "$kind\u0000$location\u0000$text"

    /**
     * 本地 `updatedAt`（epoch millis）→ 服务端可用的 RFC 3339 字符串。
     * `<= 0` 视为未知，返回 `null`：服务端填当前时间并跳过 409 冲突检测。
     */
    private fun mapUpdatedAt(progress: P): String? {
        val millis = mapper.updatedAt(progress)
        return if (millis <= 0L) null else formatRfc3339Millis(millis)
    }

    private companion object {
        /** HTTP 409：服务端进度冲突检测命中（本地 `updated_at` 落后于库内值）。 */
        const val HTTP_CONFLICT = 409

        /**
         * 409 后重发时相对服务端 `updated_at` 的最小前进量（毫秒）。
         *
         * 服务端时间戳是 RFC 3339 **秒精度**（[formatRfc3339Millis] 截断到秒），因此
         * 「严格大于」在秒粒度上至少要加 1 秒；+1000ms 再截断必然得到 ≥ 服务端秒 + 1，
         * 保证不会再被判 409。取 `maxOf(本地, 服务端 + 1s)` 是为了让重发时间戳既排在服务端
         * 之后、又不倒退本地已有的更晚时间。
         */
        const val RETRY_TIMESTAMP_STEP_MILLIS = 1000L
    }
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

    override fun updateAnnotation(uid: String, annotation: BookAnnotation): Boolean =
        annotationStore.update(annotation.copy(documentId = uid))

    override fun removeAnnotation(uid: String, annotation: BookAnnotation): Boolean {
        if (annotation.id.isNotBlank()) return annotationStore.remove(uid, annotation.id)
        // 本地 id 未分配（理论上只出现在服务端下发对象上）：按 serverId 兜底定位。
        val serverId = annotation.serverId ?: return false
        val target = annotationStore.list(uid).firstOrNull { it.serverId == serverId } ?: return false
        return annotationStore.remove(uid, target.id)
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

    override fun updateAnnotation(uid: String, annotation: PdfAnnotation): Boolean =
        annotationStore.update(annotation.copy(documentId = uid))

    override fun removeAnnotation(uid: String, annotation: PdfAnnotation): Boolean {
        if (annotation.id > 0L) return annotationStore.remove(uid, annotation.id)
        val serverId = annotation.serverId ?: return false
        val target = annotationStore.list(uid).firstOrNull { it.serverId == serverId } ?: return false
        return annotationStore.remove(uid, target.id)
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

    /**
     * epub 批注位置：优先用本地 [BookAnnotation.location]（定稿形态
     * `chapter:<spineIndex>@<start>-<end>`），旧记录该字段为空时回退 `chapter-<chapterIndex>`。
     */
    override fun location(annotation: BookAnnotation): String =
        annotation.location.ifBlank { "chapter-${annotation.chapterIndex}" }

    /** 批注内容取 [BookAnnotation.note]。 */
    override fun text(annotation: BookAnnotation): String = annotation.note

    override fun kind(annotation: BookAnnotation): String = annotation.kind.ifBlank { DEFAULT_KIND }

    override fun selectedText(annotation: BookAnnotation): String = annotation.selectedText

    override fun serverId(annotation: BookAnnotation): Long? = annotation.serverId

    override fun isDirty(annotation: BookAnnotation): Boolean = annotation.dirty

    /**
     * 服务端对象 → 本地模型。
     *
     * 本地 `id` 刻意留空（由 `AnnotationStore.add` 分配 UUID）：服务端 id 只写 [BookAnnotation.serverId]，
     * 否则服务端 id 会污染本地 id 空间，且 `add` 的「id 已存在即原地写」假设被打破。
     */
    override fun fromRemote(remote: Annotation): BookAnnotation = BookAnnotation(
        id = "",
        documentId = remote.uid,
        chapterIndex = chapterIndexOf(remote.location),
        selectedText = remote.selectedText,
        note = remote.text,
        createdAt = parseRfc3339Millis(remote.createdAt),
        location = remote.location,
        kind = remote.kind.ifBlank { DEFAULT_KIND },
        serverId = remote.id,
        dirty = false,
    )

    /** 保留本地 id 与服务端内容合并（服务端为准，`dirty` 由调用方经 [markSynced] 复位）。 */
    override fun mergeRemote(local: BookAnnotation, remote: Annotation): BookAnnotation =
        fromRemote(remote).copy(id = local.id)

    override fun markSynced(annotation: BookAnnotation): BookAnnotation = annotation.copy(dirty = false)

    /**
     * 从 location 推章节序号：先按定稿形态 `chapter:<spineIndex>@<start>-<end>` 解析，
     * 未命中再按旧形态 `chapter-<n>`（存量记录）兜底；都推不出时返回 0（服务端存量脏数据）。
     */
    private fun chapterIndexOf(location: String): Int =
        when (val parsed = LocationCodec.parse(location)) {
            is LocationCodec.Parsed.Chapter -> parsed.spineIndex
            else -> location.removePrefix("chapter-").substringBefore(':').toIntOrNull() ?: 0
        }
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

    /** pdf 批注位置即本地 `location`（`page:<n>` / `page:<n>;rect:...` / `page:<n>;ink:...`）。 */
    override fun location(annotation: PdfAnnotation): String = annotation.location

    override fun text(annotation: PdfAnnotation): String = annotation.text

    override fun kind(annotation: PdfAnnotation): String = annotation.kind.ifBlank { DEFAULT_KIND }

    override fun selectedText(annotation: PdfAnnotation): String = annotation.selectedText

    override fun serverId(annotation: PdfAnnotation): Long? = annotation.serverId

    override fun isDirty(annotation: PdfAnnotation): Boolean = annotation.dirty

    /**
     * 服务端对象 → 本地模型。
     *
     * 本地 `id` 刻意置 0（由 `PdfAnnotationStore.add` 分配 `nextId`）：服务端 id 只写
     * [PdfAnnotation.serverId]。本地 id 与服务端 id 混用会让「本地删一条、服务端删另一条」。
     */
    override fun fromRemote(remote: Annotation): PdfAnnotation = PdfAnnotation(
        id = 0L,
        documentId = remote.uid,
        location = remote.location,
        text = remote.text,
        createdAt = parseRfc3339Millis(remote.createdAt),
        updatedAt = parseRfc3339Millis(remote.updatedAt ?: remote.createdAt),
        kind = remote.kind.ifBlank { DEFAULT_KIND },
        selectedText = remote.selectedText,
        serverId = remote.id,
        dirty = false,
    )

    /** 保留本地 id 与服务端内容合并（服务端为准，`dirty` 由调用方经 [markSynced] 复位）。 */
    override fun mergeRemote(local: PdfAnnotation, remote: Annotation): PdfAnnotation =
        fromRemote(remote).copy(id = local.id)

    override fun markSynced(annotation: PdfAnnotation): PdfAnnotation = annotation.copy(dirty = false)
}

/** 服务端 `kind` 的缺省值：旧记录 / 缺键一律按文本批注处理（v8 契约缺省值同为 `note`）。 */
internal const val DEFAULT_KIND = "note"

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
