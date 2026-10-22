package com.seshat.app.reader

import android.webkit.WebView

/**
 * EPUB 章内滚动定位（M10.3 / T5）：按**章内字符偏移**把正文滚到可见处。
 *
 * ## 为什么单独一个文件
 *
 * 与 [SelectionPayload]（**采集**选区偏移）方向相反：这里是**消费**一个已知偏移去定位。
 * 塞进现有脚本会让「采集」与「定位」互相牵制（改一侧就担心破坏另一侧），故独立成文件，
 * 与采集脚本同级、互不引用。
 *
 * ## 偏移口径
 *
 * 与 [SelectionPayload] 的前提一致：`document.body` 文本流的**前缀长度**（UTF-16 code unit）。
 * 因此走到「累计字符数首次 >= 目标偏移」的那个文本节点，在该节点内取 `target - acc`
 * 作为落点，量它的 `getBoundingClientRect()` 再 `window.scrollTo` 到其上方 8px。
 *
 * `SCRIPT` / `STYLE` 的子文本节点被跳过：`Range.toString()` 不包含它们，若不跳过会与采集口径错位。
 *
 * ## 失败语义（**静默降级**）
 *
 * 脚本自身包了 `try/catch` 且**恒返回字符串**；页面尚未加载完、偏移超出文本流、
 * `evaluateJavascript` 回调被系统丢弃 —— 全部表现为「没滚动」，**不抛异常、不提示用户**。
 * 调用方跳章已成功，定位失败只是回到「跳到章首」，属计划允许的降级。
 */
internal object LocationScroll {

    /** 偏移上限（防御异常数据把字符串撑大；超出按上限夹紧）。 */
    const val MAX_OFFSET = 10_000_000

    /** 定位落点上方预留的空白（像素）：让被定位的那一行不贴屏幕顶边。 */
    private const val TOP_MARGIN = 8

    /**
     * 生成注入脚本（自执行函数，参数为目标字符偏移）。
     *
     * @param startOffset 章内字符偏移（0-based）；负数按 0 处理
     */
    fun script(startOffset: Int): String =
        SCRIPT_TEMPLATE.replace("__TARGET__", startOffset.coerceIn(0, MAX_OFFSET).toString())

    /**
     * 在指定 WebView 上执行定位（`null` WebView / 负偏移为无操作）。
     *
     * 回调结果被忽略：本方法只负责「尝试滚动」，成败由视觉体现，不需要调用方分支。
     */
    fun scrollTo(web: WebView?, startOffset: Int) {
        if (web == null || startOffset < 0) return
        runCatching { web.evaluateJavascript(script(startOffset)) { } }
    }

    /** 脚本模板：`__TARGET__` 由 [script] 替换成数字字面量（避免字符串拼接注入）。 */
    private val SCRIPT_TEMPLATE: String = """
        (function (target) {
          try {
            var root = document.body;
            if (!root) return "0";
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
            var acc = 0, node;
            while ((node = walker.nextNode())) {
              var parent = node.parentNode ? node.parentNode.nodeName : "";
              if (parent === "SCRIPT" || parent === "STYLE") continue;
              var len = node.nodeValue ? node.nodeValue.length : 0;
              if (acc + len >= target) {
                var offset = Math.max(0, Math.min(len, target - acc));
                var range = document.createRange();
                range.setStart(node, offset);
                range.setEnd(node, offset);
                var rect = range.getBoundingClientRect();
                var y = rect.top + (window.pageYOffset || 0) - TOP_MARGIN;
                window.scrollTo(0, Math.max(0, y));
                return "1";
              }
              acc += len;
            }
            return "0";
          } catch (e) {
            return "0";
          }
        })(__TARGET__)
    """.trimIndent().replace("TOP_MARGIN", TOP_MARGIN.toString())
}
