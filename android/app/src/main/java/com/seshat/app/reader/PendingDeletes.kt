package com.seshat.app.reader

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * 待删批注队列（离线删除待重试，M10.3 T3）。
 *
 * 队列里只放**服务端 `serverId`**（本地 id 无意义，服务端不认）：
 * 本地删掉一条已上传的批注后，把它的 `serverId` 入队；同步层 flush 时发
 * `DELETE /api/annotations/{id}`（404 视为成功）并把它从队列移除。
 * 从未上传的记录（`serverId == null`）删除时不入队。
 *
 * 删除与 `dirty` 完全分离：`dirty` 只表示「新增/修改待上行」，避免「脏」与「待删」两种
 * 语义在同一布尔位上打架。
 *
 * 键为 `pending_deletes_<uid>`（uid 维度，与 per-docId 的批注数据键隔离）；
 * 存储格式为 JSON 长整型数组，与仓库其它 store 的 JSON 落盘风格一致。
 *
 * @param prefs 承载队列的 SharedPreferences（JVM 单测可注入内存实现）。
 * @param json  JSON 编解码器（默认忽略未知字段）。
 */
class PendingDeletes(
    private val prefs: SharedPreferences,
    private val json: Json = defaultJson(),
) {
    /** 生产构造入口：与 [AnnotationStore] 共用同一 prefs 文件。 */
    constructor(context: Context) :
        this(context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE))

    /**
     * 某 uid 的待删 serverId 列表（按入队顺序）；无记录或 JSON 损坏时返回空列表。
     *
     * **返回副本**：每次调用都从 JSON 重新解码，调用方修改返回值不影响存储。
     * 与写方法共用同一把锁（`@Synchronized`），因此读到的必然是某一完整写入之后的状态。
     */
    @Synchronized
    fun list(uid: String): List<Long> {
        val raw = prefs.getString(key(uid), null) ?: return emptyList()
        return runCatching { json.decodeFromString(ListSerializer(Long.serializer()), raw) }
            .getOrDefault(emptyList())
    }

    /**
     * 入队（幂等：已在队列中则不写，不改变顺序）。
     *
     * **`@Synchronized` 是正确性要求**：删除在主线程写（同步层 `deleteAnnotation`）、
     * flush 在同步线程写（同步层 `pushDeletes`）——两侧都是「读列表 → 追加/过滤 → 整键回写」
     * 的 read-modify-write。无锁时后写覆盖先写，会丢掉 `serverId`：服务端记录永不删除，
     * 下次 pull 又把它复现成幽灵批注。
     */
    @Synchronized
    fun add(uid: String, serverId: Long) {
        val current = list(uid)
        if (current.contains(serverId)) return
        write(uid, current + serverId)
    }

    /** 出队（不存在时为无操作，幂等）。与 [add] 共用同一把锁，避免 read-modify-write 丢条目。 */
    @Synchronized
    fun remove(uid: String, serverId: Long) {
        val current = list(uid)
        if (!current.contains(serverId)) return
        write(uid, current.filterNot { it == serverId })
    }

    /** 清空某 uid 的待删队列（整键删除）。与 [add]/[remove] 共用同一把锁。 */
    @Synchronized
    fun clear(uid: String) {
        prefs.edit().remove(key(uid)).apply()
    }

    private fun write(uid: String, ids: List<Long>) {
        prefs.edit()
            .putString(key(uid), json.encodeToString(ListSerializer(Long.serializer()), ids))
            .apply()
    }

    companion object {
        /** 与 [AnnotationStore] 共用 prefs 文件（键空间由前缀隔离）。 */
        const val PREFS_NAME = AnnotationStore.PREFS_NAME

        /** 队列键前缀。 */
        private const val PREFIX = "pending_deletes_"

        /** 存储键：`pending_deletes_<uid>`。 */
        fun key(uid: String): String = "$PREFIX$uid"

        fun defaultJson(): Json = Json {
            ignoreUnknownKeys = true
        }
    }
}
