package com.seshat.app.sync

import android.content.Context
import android.util.Log
import com.seshat.app.importer.BookImporter
import com.seshat.app.settings.SettingsStore
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 全进程唯一的同步装配（M9.2 B 批 T7）。
 *
 * **为什么必须是单实例**：[ResourceIndex] 的线程安全靠 `@Synchronized`，而 Kotlin 的
 * `@Synchronized` 锁的是**实例**（`this`）而不是类。若书架与同步各自 `ResourceIndex.open()`
 * 出一份新实例，两个实例各自的锁互不相干，单线程前提被打破（`SharedPreferences` 跨实例
 * 并发写会丢条目）。因此索引、编排器、客户端统一由本对象持有。
 *
 * ## 生命周期
 * 全部字段进程级存活：不随 Activity/Fragment 销毁而释放。调用方（如 `ReaderFragment`）
 * 在 `onDestroyView` **不得**关闭这里的 executor。
 *
 * ## 线程
 * 所有获取方法都是 `@Synchronized`（对象监视器可重入，`coordinator()` 内调 `index()` 不会死锁），
 * 可被任意线程调用；[SyncCoordinator] 内部的网络与索引写入跑在它自己的单线程 executor 上。
 *
 * ## 未配置语义
 * [restClient] 返回 `null` 表示服务端未配置（`SettingsStore.toConfig() == null`）：此后
 * **不做任何网络调用**，也不重复解密 `SecurePrefs`（缓存「已确认未配置」直到 [invalidate]）。
 */
object SyncHolder {

    @Volatile
    private var indexRef: ResourceIndex? = null

    @Volatile
    private var coordinatorRef: SyncCoordinator? = null

    @Volatile
    private var restRef: RestClient? = null

    /** 是否已确认「服务端未配置」；避免每次刷新都走一遍 [SecurePrefs] 解密。 */
    @Volatile
    private var restResolved = false

    /** 同步编排器专用的单线程 executor（进程级；同步、回填串行执行）。 */
    private val syncExecutor: ExecutorService by lazy { Executors.newSingleThreadExecutor() }

    /** 进程唯一的资源索引（惰性打开）。 */
    @Synchronized
    fun index(context: Context): ResourceIndex {
        indexRef?.let { return it }
        return ResourceIndex.open(context.applicationContext).also { indexRef = it }
    }

    /** 进程唯一的同步编排器（惰性构造；与 [index] 共享同一份索引实例）。 */
    @Synchronized
    fun coordinator(context: Context): SyncCoordinator {
        coordinatorRef?.let { return it }
        val appContext = context.applicationContext
        val coordinator = SyncCoordinator(
            index = index(context),
            apis = { restClient(context)?.let { RestSyncApis(it) } },
            executor = syncExecutor,
            // 本地书籍目录：move 跟随把服务端重命名反映到 filesDir/books/ 下的扁平文件
            booksDir = BookImporter(appContext).booksDir(),
            logger = { Log.w(TAG, it) },
        )
        coordinatorRef = coordinator
        return coordinator
    }

    /**
     * 服务端客户端；未配置（地址或令牌缺失）时返回 `null`。
     *
     * 构造方式照抄 `SettingsActivity`：`SecurePrefs` → `SettingsStore` → `toConfig()`，
     * 保证「书架上看到的服务端配置」与「设置页保存的配置」读写同一份存储。
     * 首次解析成功后缓存 [RestClient]；解析为 `null` 也缓存该结论（`restResolved`）。
     */
    @Synchronized
    fun restClient(context: Context): RestClient? {
        restRef?.let { return it }
        if (restResolved) return null
        val appContext = context.applicationContext
        val securePrefs = SecurePrefs.open(appContext)
        val store = SettingsStore(
            read = { key -> securePrefs.getString(key) },
            write = { key, value -> securePrefs.putString(key, value) },
            writeSecret = { key, value -> securePrefs.putSecret(key, value) },
        )
        val config = store.toConfig()
        if (config == null) {
            restResolved = true
            return null
        }
        return RestClient(config).also { restRef = it }
    }

    /**
     * 设置页保存后调用：丢弃客户端与「未配置」结论缓存，并让编排器重拉根清单。
     *
     * 令牌可能已更换，旧 [RestClient] 必须整体丢弃（否则继续用旧令牌请求）。
     */
    @Synchronized
    fun invalidate(context: Context) {
        restRef = null
        restResolved = false
        coordinator(context).invalidateConfig()
    }

    /** 日志标签。 */
    private const val TAG = "SyncHolder"
}
