package com.seshat.app.reader

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * EPUB 章内选区（M10.3 T4）：章内字符偏移 + 选中原文。
 *
 * [start] / [end] 为**半开区间** `[start, end)` 的章内字符偏移（0-based），可直接喂给
 * [LocationCodec.encodeChapter] 得到 `chapter:<spineIndex>@<start>-<end>`；[text] 是选中原文。
 */
data class SelectionRange(val start: Int, val end: Int, val text: String)

/**
 * WebView 选区采集载荷：注入脚本 + 返回值解析（纯逻辑，无 Android 依赖，可 JVM 单测）。
 *
 * ## 为什么用 JSON 对象而不是 `"<start>|<end>|<text>"`
 *
 * 分隔符编码必须回答「选中原文自己含分隔符怎么办」——转义会引入一层自定义转义语法
 * （两端都得实现、易错），截断则会静默丢字。改成 JS 侧 `JSON.stringify({s,e,t})` 后，
 * 文本由 JSON 标准转义承载，Kotlin 侧用同一套 JSON 解析还原，不存在自定义语法。
 *
 * ## 解码为什么要两层
 *
 * `WebView.evaluateJavascript` 的回调值是**脚本返回值的 JSON 字面量**；脚本返回字符串时，
 * 拿到的就是「一层 JSON 字符串」（即内部 JSON 文本被整体转义）。因此：
 *
 * 1. 第一层：把回调值当 JSON 解析 → 得到 `JsonPrimitive`（字符串）→ 其内容是内部 JSON 文本；
 * 2. 第二层：把内部 JSON 文本当 JSON 解析 → 得到 `{"s":..,"e":..,"t":..}`。
 *
 * 刻意**不复用** [decodeJsString]：那是手写转义还原（只覆盖常见转义、且替换顺序对 `\\` 等
 * 组合易出错），用于「纯文本」路径尚可；用它去还原需要再解析的 JSON 文本会引入解析歧义。
 * 走标准 JSON 解析两层，文本里的引号、反斜杠、换行、制表符全部由解析器正确处理。
 *
 * ## 偏移口径（与 JS 侧严格同源）
 *
 * - **根节点**：`document.body`（EPUB 章节 HTML 都有 body，正文全在其下）。
 * - **累计方式**：把探针 `Range` 的起点设在 body 内容开头，终点设为选区 start/end 的
 *   `(container, offset)`，取 `Range.toString().length` —— 即「body 文本流的前缀长度」。
 * - **end 也用前缀法**（不是 `start + text.length`）：选区文本经 `Selection.toString()` 可能
 *   因跨块级元素被浏览器规范化空白（折叠成单个空格/换行），而 `body` 文本流是按节点拼接的，
 *   两者长度可能不等；用同一前缀法算两端，保证 `[start, end)` 恰好切在文本流上。
 * - **单位**：JS `String.length` 与 Kotlin `String.length` 都是 UTF-16 code unit 数，两端一致。
 *   BMP 之外的字符（emoji 等）占 2 个 unit，跨端（如按字符数处理的 Emacs）会有 ±1 差异，
 *   见 tech-debt；本任务的消费方（Android 自身跳转、服务端存串）不受影响。
 * - **边界**：无选区 / 折叠选区 / 选区端点不在 body 内 / 脚本异常 → JS 返回空串；
 *   `end < start` 视为异常（防御性交换），空区间（`end == start`）由 [parse] 判为无效。
 * - **跨章**：单章一个 WebView，偏移天然限定在本章；spine 序号由调用方（Activity）给出。
 */
object SelectionPayload {

    /**
     * 注入脚本：返回 `{"s":<start>,"e":<end>,"t":<选中原文>}` 的 JSON 字符串；
     * 取不到选区时返回空串（调用方据此判「无偏移」并降级）。
     */
    val SCRIPT: String = """
        (function () {
          try {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return "";
            var range = sel.getRangeAt(0);
            var root = document.body;
            if (!root) return "";
            var sc = range.startContainer, ec = range.endContainer;
            if (!root.contains(sc) || !root.contains(ec)) return "";
            var probe = document.createRange();
            probe.selectNodeContents(root);
            probe.setEnd(sc, range.startOffset);
            var start = probe.toString().length;
            probe.setEnd(ec, range.endOffset);
            var end = probe.toString().length;
            if (end < start) { var swap = start; start = end; end = swap; }
            return JSON.stringify({ s: start, e: end, t: range.toString() });
          } catch (err) {
            return "";
          }
        })()
    """.trimIndent()

    /**
     * 解析 `evaluateJavascript` 的原始回调值。
     *
     * **任何输入都不抛异常**：空值、`null`、空串、非 JSON、缺字段、负数偏移、`start >= end`
     * 一律返回 `null`（表示「取不到可用偏移」，调用方退回旧行为）。
     *
     * @param raw `evaluateJavascript` 回调拿到的原始字符串（脚本返回值的 JSON 字面量）
     */
    fun parse(raw: String?): SelectionRange? {
        if (raw.isNullOrBlank()) return null
        return runCatching { parseOrNull(raw) }.getOrNull()
    }

    private fun parseOrNull(raw: String): SelectionRange? {
        val outer = Json.parseToJsonElement(raw)
        val body = when (outer) {
            is JsonObject -> outer // 兼容「直接返回对象文本」的实现（规范上会多包一层字符串）
            is JsonPrimitive -> {
                if (!outer.isString) return null // JsonNull 等非字符串形态 → 无偏移
                val inner = outer.content
                if (inner.isBlank()) return null
                Json.parseToJsonElement(inner) as? JsonObject ?: return null
            }
            else -> return null
        }
        val start = body["s"]?.strictInt() ?: return null
        val end = body["e"]?.strictInt() ?: return null
        // t 缺失或为 null 时按空串处理（偏移仍可用于跳转，正文可由调用方另行取舍）；
        // 用 contentOrNull 而非 content：JsonNull.content 是字面量 "null"，会把 null 变成四个字母
        val text = body["t"]?.jsonPrimitive?.contentOrNull ?: ""
        // 空区间与倒序区间都不可用：encodeChapter 会产出 0 长度的 location，无法定位
        if (start < 0 || end < 0 || end <= start) return null
        return SelectionRange(start, end, text)
    }

    /**
     * 严格取整数字段：只接受 JSON **数字字面量**，字符串形态（`"s":"12"`）视为非法。
     *
     * 脚本侧 `JSON.stringify` 对数字必然输出字面量，出现字符串说明载荷并非本脚本产物
     * （或被中间层改写过），此时宁可判无效走降级，也不猜它的口径。
     */
    private fun JsonElement.strictInt(): Int? {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive.isString) return null
        return primitive.intOrNull
    }

    /**
     * 选区 → location。
     *
     * [range] 为 null（JS 失败 / 旧 WebView / 空选区）时退回旧形态 `chapter-<chapterIndex>`，
     * 与 `EpubSyncMapper.location` 的兜底形态一致——保证既有记录与旧实现的行为不变。
     */
    fun locationFor(chapterIndex: Int, range: SelectionRange?): String =
        range?.let { LocationCodec.encodeChapter(chapterIndex, it.start, it.end) }
            ?: "chapter-$chapterIndex"
}
