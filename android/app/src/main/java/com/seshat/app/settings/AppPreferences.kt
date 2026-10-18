package com.seshat.app.settings

import android.content.Context

/** 应用主题模式。 */
enum class AppTheme {
    /** 跟随系统。 */
    SYSTEM,

    /** 强制浅色。 */
    LIGHT,

    /** 强制深色。 */
    DARK,
}

/** 阅读器翻页模式。 */
enum class ReaderPageMode {
    /** 横向翻页（整页/整章吸附）。 */
    HORIZONTAL,

    /** 竖向连续滚动（页/章间零间隙）。 */
    VERTICAL,
}

/**
 * 应用偏好（**非机密**）。
 *
 * 与 [SettingsStore]（机密 + 同步配置）分离：这里的内容不加密、参与系统备份，
 * 因此**不得存放访问令牌**。读写函数注入使核心逻辑可在 JVM 单测中验证。
 *
 * 偏好变更的生效时机：主题立即生效（由 `SeshatApp` 应用）；远程目录下次同步生效；
 * 字号与翻页模式在**下次打开阅读器**时生效。
 */
class AppPreferences(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
) {

    /** WebDAV 远程目录；返回以 `/` 开头、不含重复斜杠、无尾斜杠的形式（根目录为 `/`）。 */
    fun remoteDir(): String = normalizeRemoteDir(read(KEY_REMOTE_DIR))

    /** 保存远程目录（写入前规范化）。 */
    fun setRemoteDir(value: String) {
        write(KEY_REMOTE_DIR, normalizeRemoteDir(value))
    }

    /** 主题模式；非法或缺失时回退 [AppTheme.SYSTEM]。 */
    fun themeMode(): AppTheme = when (read(KEY_APP_THEME)?.trim()?.lowercase()) {
        "light" -> AppTheme.LIGHT
        "dark" -> AppTheme.DARK
        else -> AppTheme.SYSTEM
    }

    /** 保存主题模式。 */
    fun setThemeMode(mode: AppTheme) {
        write(KEY_APP_THEME, mode.name.lowercase())
    }

    /** EPUB 正文字号（百分比），夹紧到 [MIN_TEXT_ZOOM]..[MAX_TEXT_ZOOM]。 */
    fun textZoom(): Int = clampTextZoom(read(KEY_TEXT_ZOOM)?.trim()?.toIntOrNull() ?: DEFAULT_TEXT_ZOOM)

    /** 保存正文字号（写入前夹紧）。 */
    fun setTextZoom(percent: Int) {
        write(KEY_TEXT_ZOOM, clampTextZoom(percent).toString())
    }

    /** 翻页模式；缺失或非法时回退 [ReaderPageMode.HORIZONTAL]。 */
    fun pageMode(): ReaderPageMode =
        if (read(KEY_PAGE_MODE)?.trim()?.lowercase() == "vertical") {
            ReaderPageMode.VERTICAL
        } else {
            ReaderPageMode.HORIZONTAL
        }

    /** 保存翻页模式。 */
    fun setPageMode(mode: ReaderPageMode) {
        write(KEY_PAGE_MODE, mode.name.lowercase())
    }

    /**
     * 笔记外部目录（SAF tree URI 字符串）；空串表示未设置。
     *
     * 只存 URI 字符串本身（不含路径明文），持久读权限由设置页在询问目录时
     * `takePersistableUriPermission` 单独持有；URI 失效时上层按「无外部目录」处理。
     */
    fun notesExternalDir(): String = read(KEY_NOTES_EXTERNAL_DIR).orEmpty()

    /** 保存笔记外部目录（空串表示清除；持久授权由设置页负责释放）。 */
    fun setNotesExternalDir(uri: String) {
        write(KEY_NOTES_EXTERNAL_DIR, uri)
    }

    /** 清空全部非机密偏好（恢复默认：远程目录 `/`、主题跟随系统、字号 100、横向翻页）。 */
    fun clear() {
        write(KEY_REMOTE_DIR, "")
        write(KEY_APP_THEME, "")
        write(KEY_TEXT_ZOOM, "")
        write(KEY_PAGE_MODE, "")
    }

    companion object {
        /** 非机密偏好的 prefs 文件名（与同步/机密的 `seshat_sync*` 分离）。 */
        const val PREFS_NAME = "seshat_app_prefs"

        const val KEY_REMOTE_DIR = "remote_dir"
        const val KEY_APP_THEME = "app_theme"
        const val KEY_TEXT_ZOOM = "reader_text_zoom"
        const val KEY_PAGE_MODE = "reader_page_mode"

        /** 笔记外部目录（SAF tree URI 字符串）；空串表示未设置。 */
        const val KEY_NOTES_EXTERNAL_DIR = "notes_external_dir"

        const val DEFAULT_TEXT_ZOOM = 100
        const val MIN_TEXT_ZOOM = 80
        const val MAX_TEXT_ZOOM = 200

        /** 根目录。 */
        const val DEFAULT_REMOTE_DIR = "/"

        /** 远程目录长度上限。 */
        const val MAX_REMOTE_DIR_LENGTH = 512

        /**
         * 规范化远程目录：去首尾空白、合并重复斜杠、统一以 `/` 开头且无尾斜杠（根目录保留 `/`）。
         *
         * **安全**：含点段（`.` / `..`）、percent-encoded 点段（`%2e` / `%2e%2e`）、
         * 会改变 URL 结构的字符（`?` `#` `\`）或超长时，一律回退根目录 `/`——
         * 否则 OkHttp 的 `HttpUrl.push()` 会解析 `..` 并让请求逃出 `/dav` 前缀。
         */
        fun normalizeRemoteDir(raw: String?): String {
            val trimmed = raw?.trim().orEmpty()
            if (trimmed.isEmpty() || trimmed.length > MAX_REMOTE_DIR_LENGTH) {
                return DEFAULT_REMOTE_DIR
            }
            val segments = trimmed.split('/').filter { it.isNotEmpty() }
            if (segments.isEmpty()) return DEFAULT_REMOTE_DIR
            val unsafe = segments.any { seg ->
                seg == "." || seg == ".." ||
                    seg.equals("%2e", ignoreCase = true) ||
                    seg.equals("%2e%2e", ignoreCase = true) ||
                    seg.any { it == '?' || it == '#' || it == '\\' }
            }
            if (unsafe) return DEFAULT_REMOTE_DIR
            return "/" + segments.joinToString("/")
        }

        /** 把字号夹紧到允许区间。 */
        fun clampTextZoom(value: Int): Int = value.coerceIn(MIN_TEXT_ZOOM, MAX_TEXT_ZOOM)

        /** 打开应用偏好存储（普通 SharedPreferences，不加密）。 */
        fun open(context: Context): AppPreferences {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return AppPreferences(
                read = { key -> prefs.getString(key, null) },
                write = { key, value -> prefs.edit().putString(key, value).apply() },
            )
        }
    }
}
