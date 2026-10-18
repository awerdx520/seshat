package com.seshat.app.reader

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.LruCache
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * 元数据缓存条目：`<key>.json` 的内容。
 *
 * [fileLength] / [lastModified] 是写入时的文件指纹，读取时与当前文件比对，不一致即视为失效
 * （书籍被替换成同名不同内容时不会返回旧标题）。
 */
@Serializable
data class CachedBookMeta(
    val title: String,
    val author: String?,
    val totalCount: Int,
    val progressKey: String,
    val coverHref: String?,
    val fileLength: Long,
    val lastModified: Long,
)

/**
 * 封面缓存：内存 [LruCache]（按字节计）+ 磁盘 `<dir>/<key>.jpg`，顺带缓存书籍元数据（`<key>.json`）。
 *
 * **所有方法阻塞**，调用方负责放到后台线程（书架扫描线程）。内部用单线程 executor 串行化
 * 封面生成（EPUB 解码 / PDF 首页渲染）与 JPEG 落盘：`PdfRenderer` 非线程安全且同一文件
 * 不能同时被两个实例打开，串行化可把并发竞争降到最低。
 *
 * 失败一律返回 `null`（或静默），书架不能因一本坏书崩溃。
 *
 * @param dir 缓存目录（生产为 `filesDir/covers`），惰性创建。
 */
class CoverCache(
    private val dir: File,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor(),
) {
    /** 内部工作线程（用于识别「已在串行线程上」的调用，避免自锁）。 */
    @Volatile
    private var worker: Thread? = null

    /**
     * 「确认无封面」的键集合（内存级负缓存）。
     *
     * 无封面的 epub 每次 [load] 都要重新 `parse` 一遍才能发现没有 `coverHref`；书架列表反复
     * 复用 item 时这会变成明显卡顿，故把失败结论记住。文件内容变化时缓存键随之变化，不会误判。
     */
    private val noCover: MutableSet<String> = java.util.Collections.synchronizedSet(HashSet())

    /**
     * 内存缓存：按 [Bitmap.byteCount] 计量。
     *
     * 惰性初始化：纯 JVM 单测只验证元数据 JSON 读写，不能触碰 `android.util.LruCache`
     * （JVM 下是抛 `Stub!` 的空壳）。
     */
    private val memory: LruCache<String, Bitmap> by lazy {
        val maxBytes = (Runtime.getRuntime().maxMemory() / MEMORY_FRACTION).toInt()
        object : LruCache<String, Bitmap>(maxBytes) {
            override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
        }
    }

    /** 缓存 JSON 用的序列化配置；容忍未来字段增减。 */
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    /**
     * 取封面：内存 → 磁盘 → 现场生成（EPUB 解压解码 / PDF 首页渲染）。
     *
     * @param reqWidth  期望宽度（像素）；生成 PDF 封面时作为目标宽度。
     * @param reqHeight 期望高度（像素）；仅用于计算降采样系数。
     */
    fun load(file: File, type: BookType, reqWidth: Int, reqHeight: Int): Bitmap? {
        val key = keyOrNull(file) ?: return null
        if (noCover.contains(key)) return null
        memory.get(key)?.let { return it }
        val cached = coverFileOf(key)
        decodeFile(cached, reqWidth, reqHeight)?.let { bitmap ->
            memory.put(key, bitmap)
            return bitmap
        }
        val bitmap = serialized {
            // 二次检查：排队期间可能已被别的调用生成
            memory.get(key) ?: generate(key, file, type, reqWidth, reqHeight)
        } ?: run {
            noCover.add(key)
            return null
        }
        memory.put(key, bitmap)
        return bitmap
    }

    /**
     * 生成（必要时）并返回磁盘封面文件路径；失败返回 `null`。
     *
     * 供需要 `File` 而非 `Bitmap` 的场景（如分享/导出）使用；图片尺寸取 [DEFAULT_COVER_WIDTH]。
     */
    fun coverFile(file: File): File? {
        val key = keyOrNull(file) ?: return null
        if (noCover.contains(key)) return null
        val target = coverFileOf(key)
        if (target.isFile && target.length() > 0L) return target
        val type = typeOf(file) ?: return null
        serialized { generate(key, file, type, DEFAULT_COVER_WIDTH, DEFAULT_COVER_WIDTH) } ?: run {
            noCover.add(key)
            return null
        }
        return if (target.isFile && target.length() > 0L) target else null
    }

    /** 清空磁盘与内存缓存（书籍删除时用）。 */
    fun clearAll() {
        memory.evictAll()
        noCover.clear()
        dir.listFiles()?.forEach { file -> runCatching { file.delete() } }
    }

    /** 关闭 executor（Activity/Fragment 销毁时调用，避免线程泄漏）。 */
    fun shutdown() {
        executor.shutdown()
    }

    /**
     * 读缓存的元数据；缓存缺失、JSON 损坏或文件指纹（长度/时间戳）不匹配时返回 `null`。
     */
    fun readMeta(file: File): BookMeta? {
        val key = keyOrNull(file) ?: return null
        return try {
            val cached = json.decodeFromString(CachedBookMeta.serializer(), metaFileOf(key).readText())
            if (cached.fileLength != file.length() || cached.lastModified != file.lastModified()) {
                null
            } else {
                BookMeta(
                    title = cached.title,
                    author = cached.author,
                    totalCount = cached.totalCount,
                    progressKey = cached.progressKey,
                    coverHref = cached.coverHref,
                )
            }
        } catch (_: Exception) {
            // 无缓存 / 损坏 JSON / IO 失败：都当作未命中
            null
        }
    }

    /** 写元数据缓存；失败静默（缓存不是主流程的必要条件）。 */
    fun writeMeta(file: File, meta: BookMeta) {
        val key = keyOrNull(file) ?: return
        try {
            val cached = CachedBookMeta(
                title = meta.title,
                author = meta.author,
                totalCount = meta.totalCount,
                progressKey = meta.progressKey,
                coverHref = meta.coverHref,
                fileLength = file.length(),
                lastModified = file.lastModified(),
            )
            ensureDir()
            metaFileOf(key).writeText(json.encodeToString(CachedBookMeta.serializer(), cached))
        } catch (_: Exception) {
            // 磁盘满 / 权限异常：忽略
        }
    }

    // ---- 内部实现 ----

    /** 安全取缓存键（文件不可读等极端情况返回 null）。 */
    private fun keyOrNull(file: File): String? = try {
        CoverKeys.keyFor(file)
    } catch (_: Exception) {
        null
    }

    /** 在单线程 executor 上串行执行；异常吞掉返回 null。 */
    private fun <T : Any> serialized(block: () -> T?): T? {
        // 已在内部线程（理论上不会发生）时直接执行，避免自我等待死锁
        if (Thread.currentThread() === worker) return block()
        return try {
            executor.submit(
                Callable {
                    worker = Thread.currentThread()
                    block()
                },
            ).get()
        } catch (_: Exception) {
            null
        }
    }

    /** 生成封面并落盘；任何失败返回 null。 */
    private fun generate(key: String, file: File, type: BookType, reqWidth: Int, reqHeight: Int): Bitmap? {
        val bitmap = try {
            when (type) {
                BookType.EPUB -> epubCover(file, reqWidth, reqHeight)
                BookType.PDF -> pdfCover(file, reqWidth)
            } ?: return null
        } catch (_: Exception) {
            // 损坏 / 加密 / 解析失败
            return null
        }
        writeCover(key, bitmap)
        return bitmap
    }

    /** EPUB 封面：重新解析 OPF 拿 opfDir（[BookMeta] 未存），再读封面条目解码。 */
    private fun epubCover(file: File, reqWidth: Int, reqHeight: Int): Bitmap? {
        val source = zipSourceOf(file)
        val book = EpubParser.parse(source)
        val href = book.coverHref ?: return null
        val bytes = source.read(resolvePathFrom(book.opfDir, href)) ?: return null
        return decodeBytes(bytes, reqWidth, reqHeight)
    }

    /**
     * PDF 首页封面：目标宽 = reqWidth，高按首页宽高比等比。
     *
     * 与阅读器并发时 `PdfRenderer` 构造可能失败（同一文件已被另一实例打开）→ 返回 null 不崩溃。
     */
    private fun pdfCover(file: File, reqWidth: Int): Bitmap? {
        var pfd: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        return try {
            pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(pfd)
            if (renderer.pageCount <= 0) return null
            renderer.openPage(0).use { page ->
                val width = reqWidth.coerceAtLeast(1)
                val height = (page.height.toFloat() / page.width.toFloat() * width)
                    .roundToInt()
                    .coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                // 先铺白底：PDF 默认透明背景
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                bitmap
            }
        } catch (_: Exception) {
            null
        } finally {
            runCatching { renderer?.close() }
            runCatching { pfd?.close() }
        }
    }

    /** 字节 → 位图：先只读尺寸算降采样系数，再真正解码。 */
    private fun decodeBytes(bytes: ByteArray, reqWidth: Int, reqHeight: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val options = BitmapFactory.Options().apply {
            inSampleSize = CoverKeys.sampleSize(bounds.outWidth, bounds.outHeight, reqWidth, reqHeight)
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    /** 磁盘 JPEG → 位图（带降采样）；不存在或损坏返回 null。 */
    private fun decodeFile(file: File, reqWidth: Int, reqHeight: Int): Bitmap? {
        if (!file.isFile || file.length() == 0L) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            val options = BitmapFactory.Options().apply {
                inSampleSize = CoverKeys.sampleSize(bounds.outWidth, bounds.outHeight, reqWidth, reqHeight)
            }
            BitmapFactory.decodeFile(file.absolutePath, options)
        } catch (_: Exception) {
            null
        }
    }

    /** 位图写磁盘（JPEG 质量 85）；失败静默。 */
    private fun writeCover(key: String, bitmap: Bitmap) {
        try {
            ensureDir()
            coverFileOf(key).outputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            }
        } catch (_: Exception) {
            // 磁盘满 / IO 失败：本次仍可返回内存位图
        }
    }

    /** 惰性创建缓存目录。 */
    private fun ensureDir() {
        if (!dir.isDirectory) dir.mkdirs()
    }

    private fun coverFileOf(key: String): File = File(dir, "$key.jpg")

    private fun metaFileOf(key: String): File = File(dir, "$key.json")

    /** 按扩展名判定类型（与 [DefaultBookMetaReader] 一致）。 */
    private fun typeOf(file: File): BookType? = when (file.extension.lowercase()) {
        "epub" -> BookType.EPUB
        "pdf" -> BookType.PDF
        else -> null
    }

    companion object {
        /** `filesDir` 下的缓存目录名。 */
        const val DIR_NAME = "covers"

        /** 内存缓存上限 = `Runtime.maxMemory() / MEMORY_FRACTION`。 */
        const val MEMORY_FRACTION = 8

        /** JPEG 压缩质量。 */
        const val JPEG_QUALITY = 85

        /** [coverFile] 生成封面时的默认宽度（像素）。 */
        const val DEFAULT_COVER_WIDTH = 480

        /** 装配生产用缓存（目录 = `filesDir/covers`）。 */
        fun open(context: Context): CoverCache = CoverCache(File(context.filesDir, DIR_NAME))
    }
}
