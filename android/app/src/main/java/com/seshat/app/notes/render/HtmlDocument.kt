package com.seshat.app.notes.render

/**
 * HTML 外壳：把渲染器产出的**片段**包成完整文档，供 `WebView.loadDataWithBaseURL` 加载。
 *
 * 纯 JVM 实现（**不得**引用任何 Android 框架类）：外壳只是字符串拼接，可用单测断言。
 *
 * 职责边界：渲染器负责转义用户文本（[RenderSupport.escape]），本对象**只拼接**
 * 固定的 DOCTYPE / head / CSS，不读取、不改写也不插入任何用户文本 —— 因此
 * [wrap] 的输出里除 `bodyHtml` 之外不含任何源自笔记内容的字符。
 *
 * 样式约束：亮/暗两套配色由 `prefers-color-scheme` 切换（跟随系统/应用夜间模式），
 * 代码块横向滚动而不换行（org 源码行常较长），正文含内边距与行高保证移动端可读性。
 */
internal object HtmlDocument {

    /** 把 HTML 片段包成完整文档（内联 CSS + `<article>`）。 */
    fun wrap(bodyHtml: String): String = buildString(bodyHtml.length + CSS.length + 160) {
        append("<!DOCTYPE html><html><head>")
        append("<meta charset=\"utf-8\">")
        append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        append("<style>")
        append(CSS)
        append("</style></head><body><article>")
        // 片段已由渲染器转义，此处原样嵌入
        append(bodyHtml)
        append("</article></body></html>")
    }

    /** 固定样式表（不含任何用户文本）。 */
    private val CSS = """
        :root{color-scheme:light dark}
        *{box-sizing:border-box}
        body{margin:0;padding:16px 18px 40px;font-size:16px;line-height:1.65;
        font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue","Noto Sans CJK SC",
        "PingFang SC","Microsoft YaHei",sans-serif;color:#1f2328;background:#ffffff;
        -webkit-text-size-adjust:100%;overflow-wrap:break-word}
        article{max-width:52em;margin:0 auto}
        h1,h2,h3,h4,h5,h6{margin:1.3em 0 .5em;line-height:1.3;font-weight:600}
        h1{font-size:1.6em}
        h2{font-size:1.4em}
        h3{font-size:1.24em}
        h4{font-size:1.1em}
        h5{font-size:1em}
        h6{font-size:.9em}
        p{margin:0 0 .85em}
        ul,ol{margin:0 0 .85em;padding-left:1.4em}
        li{margin:.2em 0}
        pre{margin:0 0 .85em;padding:12px 14px;overflow-x:auto;line-height:1.45;
        border-radius:6px;background:#f3f4f6;-webkit-overflow-scrolling:touch}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Courier New",monospace;
        font-size:.9em;padding:.15em .35em;border-radius:4px;background:#f3f4f6}
        pre code{padding:0;background:none;font-size:.88em;white-space:pre}
        blockquote{margin:0 0 .85em;padding:.15em 0 .15em 12px;border-left:3px solid #d0d7de;
        color:#57606a}
        hr{border:0;border-top:1px solid #d0d7de;margin:1.3em 0}
        a{color:#0b62c4;text-decoration:none}
        details{margin:0 0 .85em}
        summary{cursor:pointer;color:#57606a}
        .todo{display:inline-block;padding:0 .35em;border-radius:4px;
        background:#dbeafe;color:#1e40af;font-size:.85em;font-weight:600}
        .todo-done{background:#dcfce7;color:#166534;text-decoration:none}
        .priority{display:inline-block;padding:0 .35em;border-radius:4px;
        background:#fee2e2;color:#b91c1c;font-size:.85em;font-weight:600}
        .tags{color:#0b62c4;font-size:.85em}
        .planning{color:#8a5a00;background:#fef3c7;padding:.15em .5em;border-radius:4px;
        font-size:.9em}
        .properties{font-size:.85em;color:#57606a}
        @media (prefers-color-scheme:dark){
        body{color:#e6edf3;background:#0d1117}
        a,.tags{color:#6cb6ff}
        pre,code{background:#161b22}
        pre code{background:none}
        blockquote{border-left-color:#30363d;color:#9aa4b2}
        hr{border-top-color:#30363d}
        summary{color:#9aa4b2}
        .todo{background:#1e3a8a;color:#dbeafe}
        .todo-done{background:#14532d;color:#dcfce7}
        .priority{background:#7f1d1d;color:#fee2e2}
        .planning{background:#4a3a10;color:#fde68a}
        .properties{color:#9aa4b2}
        }
    """.trimIndent()
}
