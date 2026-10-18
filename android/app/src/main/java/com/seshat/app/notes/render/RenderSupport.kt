package com.seshat.app.notes.render

/**
 * org / markdown 两个渲染器的公共工具：HTML 转义、行内强调、链接 scheme 白名单。
 *
 * 纯 JVM 实现（**不得**引用任何 Android 框架类）：渲染器的输入是文本、输出是 HTML
 * 片段，这样本地单测可以直接断言输出字符串，无需 Robolectric/真机。
 *
 * ## 硬约束的处理顺序（顺序错会互相破坏）
 * 1. 先对**原始文本**做 [escape]（用户文本绝不直接进标签/属性）；
 * 2. 把行内代码抽成占位符（内容只转义、不再解析 —— 避免 `*x*` 在代码里被当强调）；
 * 3. 再把链接抽成占位符（URL 里含 `/`，必须早于 `/斜/` 规则，否则 `http://a/b/` 会被
 *    撕成斜体）；
 * 4. 在剩余文本上依次替换强调标记；
 * 5. 最后还原占位符。
 */
internal object RenderSupport {

    /**
     * 占位符包裹字符。用 `\u0001`（控制字符）而不是 `{{n}}` 之类，是因为它不可能被
     * [escape] 或强调正则匹配到；输入文本里的同名控制字符会先被替换掉。
     */
    private const val SLOT = '\u0001'

    /** 占位符正则（`\u0001` + 序号 + `\u0001`）。 */
    private val SLOT_REGEX = Regex("\u0001(\\d+)\u0001")

    /** 允许渲染为 `<a>` 的 scheme 白名单（比较前统一转小写）。 */
    private val SAFE_SCHEMES = setOf("http", "https", "mailto")

    /**
     * 行内语法的方言。
     *
     * - [ORG]：`~` `=` 为代码，`*` 粗、`/` `_` 斜、`+` 删除；
     * - [MARKDOWN]：`` ` `` 为代码，`**` 粗、`*` 斜、`~~` 删除。
     */
    enum class Flavor { ORG, MARKDOWN }

    /** HTML 转义：`& < > " '` 五个字符；其余字符原样保留。 */
    fun escape(text: String): String {
        val sb = StringBuilder(text.length + 16)
        for (ch in text) {
            when (ch) {
                '&' -> sb.append("&amp;")
                '<' -> sb.append("&lt;")
                '>' -> sb.append("&gt;")
                '"' -> sb.append("&quot;")
                '\'' -> sb.append("&#39;")
                else -> sb.append(ch)
            }
        }
        return sb.toString()
    }

    /** 判断 URL 的 scheme 是否在白名单内（http/https/mailto，大小写不敏感）。 */
    fun isSafeUrl(url: String): Boolean {
        val trimmed = url.trim()
        val colon = trimmed.indexOf(':')
        if (colon <= 0) return false
        val scheme = trimmed.substring(0, colon)
        if (!scheme.first().isAsciiLetter()) return false
        if (!scheme.all { it.isAsciiLetter() || it in '0'..'9' || it == '+' || it == '-' || it == '.' }) {
            return false
        }
        return scheme.lowercase() in SAFE_SCHEMES
    }

    /**
     * 行内渲染（转义 → 代码/链接占位 → 强调 → 还原）。
     *
     * @param text 原始（未转义）文本，可含行内标记。
     * @param flavor 语法方言，决定代码/强调标记的字符集。
     * @return HTML 片段；文本本身已转义，除白名单标签外不含裸 `<`。
     */
    fun inline(text: String, flavor: Flavor): String {
        val slots = ArrayList<String>()
        var s = escape(dropSlotChars(text))
        s = extractCode(s, flavor, slots)
        s = extractLinks(s, flavor, slots)
        s = emphasis(s, flavor)
        return restore(s, slots)
    }

    /**
     * 链接渲染：scheme 白名单外的 URL **降级为纯文本**（保留可见文字，不生成 `<a>`）。
     *
     * @param url 原始 URL（未转义）。
     * @param label 可见文字（原始文本，走行内渲染；为空时用 URL 自身）。
     * @param flavor 链接文字所用的语法方言。
     */
    fun link(url: String, label: String, flavor: Flavor = Flavor.ORG): String = linkHtml(url, label, flavor)

    // ---------- 块级渲染器共用的状态机（org / markdown 共享，避免两份重复实现） ----------

    /** 列表默认每层缩进的空格数（org 与 markdown 约定一致）。 */
    const val DEFAULT_INDENT_PER_LEVEL: Int = 2

    /**
     * 列表栈：`<ul>/<ol>` 的嵌套状态机，按缩进判层级。
     *
     * 行为契约（与 org 渲染器原实现逐字一致，测试已锁定）：
     * 1. 缩进跳跃（`      - x`）只展开一层，不凭空补空列表；
     * 2. 同级无序↔有序切换时先闭合旧列表再开新列表；
     * 3. 嵌套子列表挂在父项的 `<li>` **内部**（父项延迟闭合）；
     * 4. 列表必须以 [closeAll] 终止，否则后续 `<p>` 会落进 `<li>`。
     *
     * @param out 输出缓冲（与渲染器主循环共享，保证标签顺序正确）。
     * @param indentPerLevel 每层缩进的空格数。
     */
    class ListStack(
        private val out: StringBuilder,
        private val indentPerLevel: Int = DEFAULT_INDENT_PER_LEVEL,
    ) {

        /** 一层的状态：[ordered] 决定标签名，[openItem] 表示当前层有未闭合的 `<li>`。 */
        private class Level(val ordered: Boolean) {
            var openItem: Boolean = false
        }

        private val stack = ArrayList<Level>()

        /** 是否有未闭合的列表。 */
        val isOpen: Boolean get() = stack.isNotEmpty()

        /**
         * 追加一个列表项。
         *
         * @param ordered 有序列（`<ol>`）还是无序列（`<ul>`）。
         * @param indent 该项行首缩进的空格数（层级 = indent / [indentPerLevel]）。
         * @param itemHtml 已渲染好的项内容（**不再**转义/解析）。
         */
        fun append(ordered: Boolean, indent: Int, itemHtml: String) {
            val depth = indent / indentPerLevel
            val current = stack.size - 1
            if (stack.isEmpty() || depth > current) {
                out.append(if (ordered) "<ol>" else "<ul>")
                stack.add(Level(ordered))
            } else {
                while (stack.size - 1 > depth) closeLevel()
                if (stack.last().ordered != ordered) {
                    closeLevel()
                    out.append(if (ordered) "<ol>" else "<ul>")
                    stack.add(Level(ordered))
                }
            }
            val level = stack.last()
            if (level.openItem) out.append("</li>")
            out.append("<li>").append(itemHtml)
            level.openItem = true
        }

        /** 从最内层向外闭合所有列表（块边界必须调用）。 */
        fun closeAll() {
            while (stack.isNotEmpty()) closeLevel()
        }

        private fun closeLevel() {
            val level = stack.removeAt(stack.lastIndex)
            if (level.openItem) out.append("</li>")
            out.append(if (level.ordered) "</ol>" else "</ul>")
        }
    }

    /**
     * 段落累积器：连续非空行合并为一个 `<p>`，行间用 `<br>`；空行/块边界调用 [flush]。
     *
     * @param out 输出缓冲。
     * @param flavor 行内解析所用方言。
     */
    class ParagraphBuffer(
        private val out: StringBuilder,
        private val flavor: Flavor,
    ) {

        private val lines = ArrayList<String>()

        /** 累积一行（调用方负责去掉行尾空白）。 */
        fun add(line: String) {
            lines.add(line)
        }

        /** 输出并清空当前段落；无内容时不输出（避免空 `<p>`）。 */
        fun flush() {
            if (lines.isEmpty()) return
            out.append("<p>")
            out.append(lines.joinToString("<br>") { inline(it, flavor) })
            out.append("</p>")
            lines.clear()
        }
    }

    // ---------- 内部实现 ----------

    /** 行内渲染但不解析链接：供链接文字复用，避免 `[[u][[[v]]]]` 之类递归。 */
    private fun inlineNoLinks(text: String, flavor: Flavor): String {
        val slots = ArrayList<String>()
        var s = escape(dropSlotChars(text))
        s = extractCode(s, flavor, slots)
        s = emphasis(s, flavor)
        return restore(s, slots)
    }

    /** 输入里若出现占位符字符，先替换掉，防止伪造占位符。 */
    private fun dropSlotChars(text: String): String = text.replace(SLOT, ' ')

    private fun linkHtml(url: String, label: String, flavor: Flavor): String {
        val visible = inlineNoLinks(label.ifEmpty { url }, flavor)
        if (!isSafeUrl(url)) return visible
        return "<a href=\"${escape(url.trim())}\">$visible</a>"
    }

    /** 把行内代码抽成占位符：内容已转义（入参是 [escape] 后的文本），不再参与后续解析。 */
    private fun extractCode(s: String, flavor: Flavor, slots: MutableList<String>): String {
        val patterns = when (flavor) {
            Flavor.ORG -> listOf(ORG_CODE_TILDE, ORG_CODE_EQUALS)
            Flavor.MARKDOWN -> listOf(MD_CODE)
        }
        var out = s
        for (pattern in patterns) {
            out = pattern.replace(out) { m -> slot(slots, "<code>${m.groupValues[1]}</code>") }
        }
        return out
    }

    /**
     * 把链接抽成占位符，避免 URL 内的 `/` `*` 被强调规则命中。
     *
     * - [Flavor.ORG]：`[[url][label]]` / `[[url]]`；
     * - [Flavor.MARKDOWN]：`[label](url)`，URL 允许一层配对括号 —— `javascript:alert(1)`
     *   必须整体识别，才能正确降级为纯文本，而不是被撕成半截留下残余字符。
     */
    private fun extractLinks(s: String, flavor: Flavor, slots: MutableList<String>): String = when (flavor) {
        Flavor.ORG -> LINK.replace(s) { m ->
            slot(slots, linkHtml(m.groupValues[1], m.groupValues[2], flavor))
        }
        Flavor.MARKDOWN -> MD_LINK.replace(s) { m ->
            slot(slots, linkHtml(m.groupValues[2], m.groupValues[1], flavor))
        }
    }

    private fun slot(slots: MutableList<String>, html: String): String {
        slots.add(html)
        return "$SLOT${slots.lastIndex}$SLOT"
    }

    private fun restore(s: String, slots: List<String>): String {
        if (slots.isEmpty()) return s
        return SLOT_REGEX.replace(s) { m -> slots.getOrElse(m.groupValues[1].toInt()) { "" } }
    }

    /** 按方言依次替换强调标记（顺序见各正则注释）。 */
    private fun emphasis(s: String, flavor: Flavor): String {
        var out = s
        when (flavor) {
            Flavor.ORG -> {
                // 先粗后斜：`*` 只认单个星，`**` 视为字面量（避免与 markdown 混淆）
                out = ORG_BOLD.replace(out) { m -> "<strong>${m.groupValues[1]}</strong>" }
                out = ORG_ITALIC_SLASH.replace(out) { m -> "<em>${m.groupValues[1]}</em>" }
                out = ORG_ITALIC_UNDERSCORE.replace(out) { m -> "<em>${m.groupValues[1]}</em>" }
                out = ORG_STRIKE.replace(out) { m -> "<del>${m.groupValues[1]}</del>" }
            }
            Flavor.MARKDOWN -> {
                // 先 `**` 后 `*`：粗体的星号先被吃掉，单星规则才不会误配
                out = MD_BOLD.replace(out) { m -> "<strong>${m.groupValues[1]}</strong>" }
                out = MD_ITALIC.replace(out) { m -> "<em>${m.groupValues[1]}</em>" }
                out = MD_STRIKE.replace(out) { m -> "<del>${m.groupValues[1]}</del>" }
            }
        }
        return out
    }

    private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'

    // ---------- 正则 ----------

    /**
     * 行内标记的内容片段：首尾非空白、**整体不含闭标记字符**、不跨行。
     *
     * @param close 闭标记字符（`*` `/` `_` `+` `~`），用正则字符类内的形式传入。
     */
    private fun body(close: String): String =
        "[^\\s$close\\n](?:[^\\n$close]*[^\\s$close\\n])?"

    private val ORG_CODE_TILDE = Regex("~(${body("~")})~")
    private val ORG_CODE_EQUALS = Regex("=(${body("=")})=")
    private val MD_CODE = Regex("`([^`\\n]+)`")

    private val LINK = Regex("\\[\\[([^\\[\\]\\n]+)\\](?:\\[([^\\[\\]\\n]*)\\])?\\]")

    /** markdown 行内链接 `[文字](url)`：url 不含空白，允许一层配对括号。 */
    private val MD_LINK = Regex("\\[([^\\[\\]\\n]*)\\]\\(((?:[^\\s()]|\\([^\\s()]*\\))+)\\)")

    /** `*粗*`：前后不得是字母/数字/`*`，故 `**x**` 保持字面量（org 里没有 `**`）。 */
    private val ORG_BOLD =
        Regex("(?<![\\p{L}\\p{N}*])\\*(${body("*")})\\*(?![\\p{L}\\p{N}*])")

    /** `/斜/`：前后不得是字母/数字/`:`/`/`，这样 `http://a/b/` 不匹配。 */
    private val ORG_ITALIC_SLASH =
        Regex("(?<![\\p{L}\\p{N}:/])/(${body("/")})/(?![\\p{L}\\p{N}:/])")

    /** `_下_`：前后不得是字母/数字/`_`，这样 `snake_case` 不被命中。 */
    private val ORG_ITALIC_UNDERSCORE =
        Regex("(?<![\\p{L}\\p{N}_])_(${body("_")})_(?![\\p{L}\\p{N}_])")

    /** `+删除+`：前后不得是字母/数字/`+`。 */
    private val ORG_STRIKE = Regex("(?<![\\p{L}\\p{N}+])\\+(${body("+")})\\+(?![\\p{L}\\p{N}+])")

    /** `**粗**`：先于单星处理，星号先被吃掉。 */
    private val MD_BOLD = Regex("(?<!\\*)\\*\\*(${body("*")})\\*\\*(?!\\*)")

    /** `*斜*`：前后不得是 `*`，故 `**x**` 不会被误配。 */
    private val MD_ITALIC = Regex("(?<!\\*)\\*(?!\\*)(${body("*")})\\*(?!\\*)")

    /** `~~删除~~`。 */
    private val MD_STRIKE = Regex("~~(${body("~")})~~")
}
