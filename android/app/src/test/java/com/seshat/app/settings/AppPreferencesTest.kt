package com.seshat.app.settings

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [AppPreferences] 默认值、解析与规范化单测。
 *
 * 用 [store]（普通 Map）注入读写函数，因此无需 Android 环境即可在 JVM 上验证全部逻辑。
 */
class AppPreferencesTest {

    /** 模拟 SharedPreferences 的键值存储。 */
    private val store = mutableMapOf<String, String>()

    /** 被测对象：读写直接落到 [store]。 */
    private val prefs = AppPreferences(
        read = { key -> store[key] },
        write = { key, value -> store[key] = value },
    )

    // ---- remoteDir ----

    @Test
    fun remoteDirDefaultsToRoot() {
        assertEquals("/", prefs.remoteDir())
    }

    @Test
    fun emptyRemoteDirFallsBackToRoot() {
        store[AppPreferences.KEY_REMOTE_DIR] = ""
        assertEquals("/", prefs.remoteDir())
    }

    @Test
    fun rootRemoteDirKeepsRoot() {
        store[AppPreferences.KEY_REMOTE_DIR] = "/"
        assertEquals("/", prefs.remoteDir())
    }

    @Test
    fun relativeRemoteDirGetsLeadingSlash() {
        store[AppPreferences.KEY_REMOTE_DIR] = "a/b/"
        assertEquals("/a/b", prefs.remoteDir())
    }

    @Test
    fun duplicatedSlashesCollapsed() {
        store[AppPreferences.KEY_REMOTE_DIR] = "/a//b/"
        assertEquals("/a/b", prefs.remoteDir())
    }

    @Test
    fun setRemoteDirNormalizes() {
        prefs.setRemoteDir(" x//y ")
        assertEquals("/x/y", prefs.remoteDir())
        assertEquals("/x/y", store[AppPreferences.KEY_REMOTE_DIR])
    }

    @Test
    fun remoteDirDotDotFallsBackToRoot() {
        // 路径穿越：`..` 会让 OkHttp 的 HttpUrl 解析后逃出 /dav 前缀
        store[AppPreferences.KEY_REMOTE_DIR] = "/../etc"
        assertEquals("/", prefs.remoteDir())
    }

    @Test
    fun remoteDirEncodedDotDotFallsBackToRoot() {
        // percent-encoded 的点段同样具有穿越语义，一律拒绝
        store[AppPreferences.KEY_REMOTE_DIR] = "/%2e%2e/x"
        assertEquals("/", prefs.remoteDir())
    }

    @Test
    fun remoteDirWithQueryFallsBackToRoot() {
        // `?` / `#` 会改变拼接后 URL 的结构
        store[AppPreferences.KEY_REMOTE_DIR] = "/notes?x=1"
        assertEquals("/", prefs.remoteDir())
    }

    @Test
    fun remoteDirTooLongFallsBackToRoot() {
        store[AppPreferences.KEY_REMOTE_DIR] = "/" + "a".repeat(600)
        assertEquals("/", prefs.remoteDir())
    }

    // ---- themeMode ----

    @Test
    fun themeDefaultsToSystem() {
        assertEquals(AppTheme.SYSTEM, prefs.themeMode())
    }

    @Test
    fun themeLightParsed() {
        store[AppPreferences.KEY_APP_THEME] = "light"
        assertEquals(AppTheme.LIGHT, prefs.themeMode())
    }

    @Test
    fun themeDarkParsed() {
        store[AppPreferences.KEY_APP_THEME] = "dark"
        assertEquals(AppTheme.DARK, prefs.themeMode())
    }

    @Test
    fun themeInvalidFallsBackToSystem() {
        store[AppPreferences.KEY_APP_THEME] = "weird"
        assertEquals(AppTheme.SYSTEM, prefs.themeMode())
    }

    // ---- textZoom ----

    @Test
    fun textZoomDefaultsTo100() {
        assertEquals(100, prefs.textZoom())
    }

    @Test
    fun textZoomBelowMinClampedTo80() {
        store[AppPreferences.KEY_TEXT_ZOOM] = "79"
        assertEquals(AppPreferences.MIN_TEXT_ZOOM, prefs.textZoom())
    }

    @Test
    fun textZoomAboveMaxClampedTo200() {
        store[AppPreferences.KEY_TEXT_ZOOM] = "201"
        assertEquals(AppPreferences.MAX_TEXT_ZOOM, prefs.textZoom())
    }

    @Test
    fun textZoomInvalidFallsBackTo100() {
        store[AppPreferences.KEY_TEXT_ZOOM] = "abc"
        assertEquals(AppPreferences.DEFAULT_TEXT_ZOOM, prefs.textZoom())
    }

    @Test
    fun setTextZoomClamps() {
        prefs.setTextZoom(10)
        assertEquals(AppPreferences.MIN_TEXT_ZOOM, prefs.textZoom())
        assertEquals("80", store[AppPreferences.KEY_TEXT_ZOOM])
    }

    // ---- pageMode ----

    @Test
    fun pageModeDefaultsToHorizontal() {
        assertEquals(ReaderPageMode.HORIZONTAL, prefs.pageMode())
    }

    @Test
    fun pageModeVerticalParsed() {
        store[AppPreferences.KEY_PAGE_MODE] = "vertical"
        assertEquals(ReaderPageMode.VERTICAL, prefs.pageMode())
    }

    @Test
    fun pageModeInvalidFallsBackToHorizontal() {
        store[AppPreferences.KEY_PAGE_MODE] = "weird"
        assertEquals(ReaderPageMode.HORIZONTAL, prefs.pageMode())
    }

    // ---- 分层约束 ----

    @Test
    fun prefsKeysContainNoSecrets() {
        // 写入全部 4 个非机密偏好后，落盘的键必须恰为这 4 个：
        // 该层不加密、参与系统备份，因此绝不能出现 token 之类机密键。
        prefs.setRemoteDir("/notes")
        prefs.setThemeMode(AppTheme.DARK)
        prefs.setTextZoom(120)
        prefs.setPageMode(ReaderPageMode.VERTICAL)
        assertEquals(
            setOf("remote_dir", "app_theme", "reader_text_zoom", "reader_page_mode"),
            store.keys,
        )
    }

    @Test
    fun clearRestoresAllDefaults() {
        // 四项偏好全部改为非默认值后 clear()，四个 getter 都必须回退默认。
        // clear() 写入的是空串，因此回退能力依赖各 getter 对空串的处理。
        prefs.setRemoteDir("/a/b")
        prefs.setThemeMode(AppTheme.DARK)
        prefs.setTextZoom(150)
        prefs.setPageMode(ReaderPageMode.VERTICAL)

        prefs.clear()

        assertEquals("/", prefs.remoteDir())
        assertEquals(AppTheme.SYSTEM, prefs.themeMode())
        assertEquals(100, prefs.textZoom())
        assertEquals(ReaderPageMode.HORIZONTAL, prefs.pageMode())
    }
}
