package com.seshat.app.reader

import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.destination.PDPageDestination
import com.tom_roush.pdfbox.pdmodel.interactive.documentnavigation.outline.PDOutlineItem
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.IdentityHashMap

/**
 * PDF 书签（outline）读取。
 *
 * `PdfRenderer`（系统内置）**不提供** outline API，故引入 `pdfbox-android` 解析。
 * 该依赖体积约 +10 MB，是用户明确授权的唯一新增依赖，**只允许在 [com.seshat.app.reader]
 * 包内使用**，不得扩散到其它模块。
 *
 * 注意：pdfbox-android 2.0.x 把 Apache PDFBox 的包名整体重定位为 `com.tom_roush.pdfbox.*`
 * （避免与桌面版 PDFBox 冲突），故 import 前缀不是 `org.apache.pdfbox`。
 *
 * 设计要点：
 * - [read] 是阻塞 + 高内存操作，**调用方必须放到后台线程**；
 * - 大文件（超过 [MAX_OUTLINE_BYTES]）直接跳过解析，返回空表（避免 96 MB 级 PDF OOM）；
 * - 节点总数超过 [MAX_NODES] 即截断（防海量兄弟书签撑爆内存），递归深度超 [MAX_DEPTH] 即截断
 *   （防栈溢出）；
 * - 加密/损坏/无 outline 一律返回空表，**不抛异常**（调用方回退页码目录）；
 * - [flatten] / [pageDirectory] 是纯函数，与 Android 运行时无关，可纯 JVM 单测；
 * - 本类**不引用任何 Android 日志 API**（纯 JVM 单测里 android.jar 是 `Stub!` 空壳，
 *   调用即抛），需要日志由调用方打。
 */
internal object PdfOutlineReader {
    /** 单个书签节点。 */
    data class PdfOutlineItem(
        val title: String,
        val pageIndex: Int,
        val children: List<PdfOutlineItem> = emptyList(),
    )

    /** 拍平后的目录项（供对话框直接展示）。 */
    data class FlatOutlineItem(
        val title: String,
        val pageIndex: Int,
        val depth: Int,
    )

    /** 超过该大小（50 MiB）不解析 outline，直接回退页码目录。 */
    const val MAX_OUTLINE_BYTES: Long = 50L * 1024 * 1024

    /** 单份文档的 outline 节点总数上限：超出即截断（目录是辅助功能，截断优于失败）。 */
    const val MAX_NODES: Int = 5_000

    /** 无法解析出目标页时的页码占位值（调用方应保持当前页）。 */
    const val UNKNOWN_PAGE_INDEX: Int = -1

    /** 书签树递归深度上限：防畸形 PDF 造成栈溢出（`StackOverflowError` 不属于 `RuntimeException`）。 */
    private const val MAX_DEPTH: Int = 64

    /**
     * 节点预算：一次 [read] 内所有分支共享的可变计数（DFS 顺序扣减）。
     *
     * 只限深度不够——50 MiB 内的 PDF 可以塞进数十万个**兄弟**书签（层级为 0，深度上限管不到），
     * 转成数据类树后会撑爆内存，并把单线程 `ioExecutor` 长时间占死（后续目录/复制全部排队）。
     *
     * 已知残余风险：`/Next` 环由 PdfBox 内部 `PDOutlineItem.children()` 遍历，应用层无法中断
     * （见 tech-debt，建议后续改为独立进程解析以便 kill）。
     */
    private class NodeBudget(var remaining: Int = MAX_NODES)

    /**
     * 读取 PDF outline。
     *
     * 复杂度：一次 [PDDocument.getPages] 遍历建「页字典 → 页索引」身份表 O(n)，之后每本书签
     * O(1) 查表；仅当身份查表未命中时才回退 `PDPageDestination.retrievePageNumber()`（其内部
     * 遍历页表为 O(n)），正常 PDF 不会走到该分支。
     *
     * @return 书签树；无 outline / 文件过大 / 加密 / 解析失败 → **空表**（调用方回退页码目录）
     */
    fun read(file: File): List<PdfOutlineItem> {
        // 必须放在最前面：不存在 / 超大文件不触达任何 PdfBox 类（避免 OOM，也便于纯 JVM 单测覆盖）
        if (!file.exists() || file.length() > MAX_OUTLINE_BYTES) return emptyList()
        return try {
            PDDocument.load(file).use { doc -> convert(doc) }
        } catch (_: IOException) {
            // 损坏 / 加密（InvalidPasswordException 是 IOException 子类）→ 回退页码目录
            emptyList()
        } catch (_: RuntimeException) {
            // PdfBox 对畸形结构的兜底；不打印路径，避免把本地文件路径写进日志
            emptyList()
        }
    }

    /**
     * 从输入流读 outline（`content://` 场景，拿不到 [File]）。
     *
     * @param sizeHint 预估字节数；`> [MAX_OUTLINE_BYTES]` 直接返回空表（**不读流**，防 OOM）；
     *   未知时传 `-1` 表示不做大小预检
     * @return 书签树；无 outline / 过大 / 加密 / 解析失败 → **空表**（调用方回退页码目录）
     *
     * 注意：[sizeHint] 来自 `openAssetFileDescriptor().length`，即 **provider 自报值**，可被谎报成
     * 0/-1 而绕过这里的预检。真正的上限由调用方用 [BoundedInputStream] 包住流传入来保证——
     * [sizeHint] 只是「不读流就早退」的优化，**不是唯一防线**。
     */
    fun read(input: InputStream, sizeHint: Long = -1L): List<PdfOutlineItem> {
        // 必须放在最前面：超大文件不触达任何 PdfBox 类，也绝不从流里读一个字节
        if (sizeHint > MAX_OUTLINE_BYTES) return emptyList()
        val doc = try {
            PDDocument.load(input)
        } catch (_: IOException) {
            // 损坏 / 加密（InvalidPasswordException 是 IOException 子类）→ 回退页码目录
            return emptyList()
        } catch (_: RuntimeException) {
            return emptyList()
        }
        // 用 try/finally 而非 use：与 read(File) 的转换逻辑完全共用 convert(doc)。
        // 注意 PDDocument.close() 不会关闭调用方传入的流（所有权在调用方的 use {}）。
        return try {
            convert(doc)
        } catch (_: RuntimeException) {
            emptyList()
        } finally {
            runCatching { doc.close() }
        }
    }

    /**
     * 深度优先拍平（父项在子项之前，[FlatOutlineItem.depth] 从 0 递增）。
     *
     * @param depth 根节点起始层级（便于把子树嵌进已有目录）
     * @param limit 最多产出多少项；超出即停止追加（目录是辅助功能，截断优于让对话框卡死/OOM）
     */
    fun flatten(
        items: List<PdfOutlineItem>,
        depth: Int = 0,
        limit: Int = MAX_NODES,
    ): List<FlatOutlineItem> {
        val out = ArrayList<FlatOutlineItem>()
        fun visit(nodes: List<PdfOutlineItem>, level: Int) {
            for (node in nodes) {
                if (out.size >= limit) return
                out.add(FlatOutlineItem(node.title, node.pageIndex, level))
                visit(node.children, level + 1)
            }
        }
        visit(items, depth)
        return out
    }

    /** 页码目录回退：每页一行「第 N 页」（1-based 文案、pageIndex 0-based）。 */
    fun pageDirectory(pageCount: Int): List<FlatOutlineItem> {
        if (pageCount <= 0) return emptyList()
        return (0 until pageCount).map { FlatOutlineItem("第 ${it + 1} 页", it, 0) }
    }

    // ---------------------------------------------------------------- 内部实现

    /**
     * 从已打开的文档读出书签树——[read] 两个入口（[File] / [InputStream]）共用的唯一转换段。
     *
     * 异常不在此处收敛（由各入口的 try/catch 负责），故仅做转换。
     */
    private fun convert(doc: PDDocument): List<PdfOutlineItem> {
        val outline = doc.documentCatalog?.documentOutline ?: return emptyList()
        val roots = outline.children().toList()
        if (roots.isEmpty()) return emptyList()
        val pageIndex = buildPageIndex(doc)
        val budget = NodeBudget()
        return roots.mapNotNull { convertItem(it, pageIndex, 0, budget) }
    }

    /**
     * 建「页字典 → 0-based 页索引」身份表。
     *
     * 用 [IdentityHashMap] 而非普通 map：`COSDictionary` 未重写 `equals`/`hashCode`（即身份语义），
     * 且 PDF 间接对象经 `COSDocument` 缓存后是同一实例，身份查表既正确又是 O(1)。
     */
    private fun buildPageIndex(doc: PDDocument): Map<COSDictionary, Int> {
        val map = IdentityHashMap<COSDictionary, Int>(maxOf(16, doc.numberOfPages * 2))
        doc.pages.forEachIndexed { index, page -> map[page.cosObject] = index }
        return map
    }

    /**
     * 把 PDF 书签节点递归转换为 [PdfOutlineItem]。
     *
     * @param budget 全局节点预算（深度优先顺序扣减）；耗尽后返回 `null`（父项保留，子树被截断）
     */
    private fun convertItem(
        item: PDOutlineItem,
        pageIndex: Map<COSDictionary, Int>,
        depth: Int,
        budget: NodeBudget,
    ): PdfOutlineItem? {
        // 超深层级直接截断（父项仍保留），避免栈溢出
        if (depth > MAX_DEPTH) return null
        // 节点预算耗尽：截断剩余子树，避免海量书签撑爆内存
        if (budget.remaining <= 0) return null
        budget.remaining--
        val children = item.children().mapNotNull { convertItem(it, pageIndex, depth + 1, budget) }
        return PdfOutlineItem(
            title = item.title ?: "",
            pageIndex = resolvePageIndex(item, pageIndex),
            children = children,
        )
    }

    /**
     * 解析书签目标页码；非页目标（URI 链接、命名目标）或解析失败 → [UNKNOWN_PAGE_INDEX]。
     *
     * `PDOutlineItem.getDestination()` 声明 `throws IOException`（目标可能是命名目标），
     * 单个书签失败不应毁掉整棵树，故用 [runCatching] 局部收敛。
     */
    private fun resolvePageIndex(
        item: PDOutlineItem,
        pageIndex: Map<COSDictionary, Int>,
    ): Int {
        val destination = runCatching { item.destination as? PDPageDestination }.getOrNull()
            ?: return UNKNOWN_PAGE_INDEX
        val page = runCatching { destination.page }.getOrNull() ?: return UNKNOWN_PAGE_INDEX
        pageIndex[page.cosObject]?.let { return it }
        // 身份表未命中（极少见）：退回 PdfBox 原生查找，代价 O(n)
        return runCatching { destination.retrievePageNumber() }.getOrDefault(UNKNOWN_PAGE_INDEX)
    }
}
