package com.seshat.app.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.button.MaterialButtonToggleGroup
import com.google.android.material.slider.Slider
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.seshat.app.R
import com.seshat.app.SeshatApp
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SeshatConfig
import kotlin.math.roundToInt

/**
 * 同步设置页（M9.1 建立，M9.2 扩展）。
 *
 * 配置分两层：
 * - **机密 + 同步配置**（服务端地址、访问令牌）经 [SettingsStore] + [SecurePrefs]
 *   （EncryptedSharedPreferences）加密保存，**不回填明文**：页面只显示「已配置 / 未配置」，
 *   输入框留空表示保留原值。
 * - **非机密偏好**（远程目录、主题、正文字号、翻页模式）经 [AppPreferences] 存普通
 *   SharedPreferences，不经过加密层，因此不受加密不可用影响。
 *
 * 安全加固（M9.1 安全审查）：
 * - 加密存储不可用（`isEncrypted = false` 或读写异常）时**禁用保存与清除令牌**并显示常驻告警，
 *   机密绝不降级写入明文（[showStorageUnavailable]）。
 * - 提供「重置本地配置」与「清除访问令牌」两条自救/撤销路径。
 * - `FLAG_SECURE` 防截屏；令牌输入框禁用 Autofill 与实例状态保存；离开页面清空输入框。
 *
 * M9.2 新增：远程目录输入、主题切换（点击即生效）、EPUB 字号滑杆、翻页模式、
 * 连通性测试（后台线程，用当前输入的地址与令牌）与「关于」区。
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var serverUrlLayout: TextInputLayout
    private lateinit var serverUrlInput: TextInputEditText
    private lateinit var authTokenLayout: TextInputLayout
    private lateinit var authTokenInput: TextInputEditText
    private lateinit var tokenStatusText: TextView
    private lateinit var storageWarningText: TextView
    private lateinit var clearTokenButton: MaterialButton
    private lateinit var resetPrefsButton: MaterialButton

    /** 远程目录输入容器（仅用于清除错误提示）。 */
    private lateinit var remoteDirLayout: TextInputLayout
    private lateinit var remoteDirInput: TextInputEditText
    private lateinit var textZoomSlider: Slider
    private lateinit var textZoomValue: TextView
    private lateinit var connectionResultText: TextView
    private lateinit var aboutText: TextView

    /** 笔记外部目录当前值（未设置显示「未设置」）。 */
    private lateinit var notesDirValue: TextView

    /**
     * 选择笔记外部目录（SAF 目录树）。
     *
     * 回调里立即申请**持久读权限**：`ACTION_OPEN_DOCUMENT_TREE` 的授权默认只在本次
     * 进程生命周期内有效，不 `takePersistableUriPermission` 的话重启后 URI 就不可读。
     * 申请失败（provider 不支持）不阻断保存，只是下次启动需要重新选择。
     */
    private val pickNotesDir = registerForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        if (uri == null) return@registerForActivityResult
        runCatching {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        appPreferences.setNotesExternalDir(uri.toString())
        refreshNotesDir()
    }

    /** 非机密偏好（不加密，不受 [showStorageUnavailable] 影响）。 */
    private lateinit var appPreferences: AppPreferences

    /** 加密存储只打开一次（`EncryptedSharedPreferences.create` 有解密开销）。 */
    private lateinit var securePrefs: SecurePrefs
    private lateinit var store: SettingsStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        // 防截屏与最近任务缩略图泄露令牌
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )

        val toolbar = findViewById<MaterialToolbar>(R.id.settingsToolbar)
        setSupportActionBar(toolbar)
        toolbar.setNavigationOnClickListener { finish() }

        serverUrlLayout = findViewById(R.id.serverUrlLayout)
        serverUrlInput = findViewById(R.id.serverUrlInput)
        authTokenLayout = findViewById(R.id.authTokenLayout)
        authTokenInput = findViewById(R.id.authTokenInput)
        tokenStatusText = findViewById(R.id.tokenStatusText)
        storageWarningText = findViewById(R.id.storageWarningText)
        clearTokenButton = findViewById(R.id.clearTokenButton)
        resetPrefsButton = findViewById(R.id.resetPrefsButton)

        securePrefs = SecurePrefs.open(this) { showStorageUnavailable() }
        store = SettingsStore(
            read = { key -> securePrefs.getString(key) },
            write = { key, value -> securePrefs.putString(key, value) },
            writeSecret = { key, value -> securePrefs.putSecret(key, value) },
        )

        // ---- M9.2：非机密偏好与扩展控件 ----
        appPreferences = AppPreferences.open(this)
        remoteDirLayout = findViewById(R.id.remoteDirLayout)
        remoteDirInput = findViewById(R.id.remoteDirInput)
        textZoomSlider = findViewById(R.id.textZoomSlider)
        textZoomValue = findViewById(R.id.textZoomValue)
        connectionResultText = findViewById(R.id.connectionResultText)
        aboutText = findViewById(R.id.aboutText)

        remoteDirInput.setText(appPreferences.remoteDir())
        val zoom = snapZoomToStep(appPreferences.textZoom())
        textZoomSlider.value = zoom
        textZoomValue.text = getString(R.string.settings_text_zoom_value, zoom.toInt())
        bindThemeGroup()
        bindPageModeGroup()
        bindTextZoomSlider()
        findViewById<MaterialButton>(R.id.testConnectionButton).setOnClickListener { testConnection() }
        updateAbout()

        // 笔记外部目录（SAF）：选择 / 清除都立即落盘（无需点「保存」）
        notesDirValue = findViewById(R.id.notesDirValue)
        refreshNotesDir()
        findViewById<MaterialButton>(R.id.pickNotesDirButton).setOnClickListener {
            pickNotesDir.launch(null)
        }
        findViewById<MaterialButton>(R.id.clearNotesDirButton).setOnClickListener {
            clearNotesDir()
        }

        store.loadServerUrl()?.let { serverUrlInput.setText(it) }
        updateTokenStatus()

        // 加密存储不可用时立即告警（历史数据可能读不出来，需要用户重置）
        if (!securePrefs.isEncrypted) showStorageUnavailable()

        findViewById<MaterialButton>(R.id.saveSettingsButton).setOnClickListener { save() }
        clearTokenButton.setOnClickListener {
            if (store.clearAuthToken()) {
                authTokenInput.text?.clear()
                updateTokenStatus()
                toast(getString(R.string.settings_token_cleared))
            } else {
                toast(getString(R.string.settings_token_clear_failed))
            }
        }
        resetPrefsButton.setOnClickListener {
            securePrefs.clear()
            serverUrlInput.text?.clear()
            authTokenInput.text?.clear()
            // 非机密偏好也要恢复默认，否则「重置」只清了机密、远程目录/字号/主题仍是旧值
            appPreferences.clear()
            remoteDirInput.setText(appPreferences.remoteDir())
            val resetZoom = snapZoomToStep(appPreferences.textZoom())
            textZoomSlider.value = resetZoom
            textZoomValue.text = getString(R.string.settings_text_zoom_value, resetZoom.toInt())
            bindThemeGroupSafely()
            bindPageModeGroup()
            storageWarningText.visibility = View.GONE
            updateTokenStatus()
            updateAbout()
            toast(getString(R.string.settings_reset_done))
        }
    }

    override fun onPause() {
        super.onPause()
        // 避免令牌明文驻留在 View 中（返回栈、最近任务快照）
        authTokenInput.text?.clear()
    }

    /** 刷新令牌状态提示与撤销入口（不显示令牌本身）。 */
    private fun updateTokenStatus() {
        val configured = store.hasAuthToken()
        tokenStatusText.text = getString(
            if (configured) R.string.settings_token_configured else R.string.settings_token_missing,
        )
        clearTokenButton.visibility = if (configured) View.VISIBLE else View.GONE
        // 令牌状态变化后同步「关于」区
        updateAbout()
    }

    /** 绑定主题切换：点击即保存并立即应用（Activity 会按新主题重建）。 */
    private fun bindThemeGroup() {
        bindThemeGroupSafely()
        // 顺序敏感：必须先 check 再注册监听，否则初始 check 会触发监听 →
        // 写入 prefs + setDefaultNightMode → Activity 重建 → 再次 check → 递归。
        val group = findViewById<MaterialButtonToggleGroup>(R.id.themeToggleGroup)
        group.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val theme = when (checkedId) {
                R.id.themeLightButton -> AppTheme.LIGHT
                R.id.themeDarkButton -> AppTheme.DARK
                else -> AppTheme.SYSTEM
            }
            appPreferences.setThemeMode(theme)
            SeshatApp.applyTheme(theme)
            toast(getString(R.string.settings_theme_changed))
        }
    }

    /**
     * 仅把主题组的选中态同步为 prefs 中的值，**不注册 listener**。
     *
     * 用于「重置本地配置」后刷新 UI：重复调用 [bindThemeGroup] 会叠加监听器
     * （每次点击都写多次 prefs、弹多次提示）。
     */
    private fun bindThemeGroupSafely() {
        val group = findViewById<MaterialButtonToggleGroup>(R.id.themeToggleGroup)
        group.check(
            when (appPreferences.themeMode()) {
                AppTheme.SYSTEM -> R.id.themeSystemButton
                AppTheme.LIGHT -> R.id.themeLightButton
                AppTheme.DARK -> R.id.themeDarkButton
            },
        )
    }

    /** 绑定翻页模式组：只在「保存」时写入，不立即切换（阅读器下次打开时生效）。 */
    private fun bindPageModeGroup() {
        val group = findViewById<MaterialButtonToggleGroup>(R.id.pageModeToggleGroup)
        group.check(
            if (appPreferences.pageMode() == ReaderPageMode.VERTICAL) {
                R.id.pageModeVerticalButton
            } else {
                R.id.pageModeHorizontalButton
            },
        )
    }

    /** 当前选中的翻页模式。 */
    private fun selectedPageMode(): ReaderPageMode =
        if (findViewById<MaterialButtonToggleGroup>(R.id.pageModeToggleGroup).checkedButtonId ==
            R.id.pageModeVerticalButton
        ) {
            ReaderPageMode.VERTICAL
        } else {
            ReaderPageMode.HORIZONTAL
        }

    /** 字号滑杆：拖动时实时刷新百分比文案（保存时才落盘）。 */
    private fun bindTextZoomSlider() {
        textZoomSlider.addOnChangeListener { _, value, _ ->
            textZoomValue.text = getString(R.string.settings_text_zoom_value, value.toInt())
        }
    }

    /**
     * 把字号对齐到滑杆步长。
     *
     * `Slider` 要求 `value == valueFrom + n*stepSize`，越界或不对齐时赋值会抛
     * `IllegalStateException`；[AppPreferences.textZoom] 只夹紧范围、不对齐步长，
     * 因此历史或外部写入的异常值（如 105）必须先对齐再赋给滑杆。
     */
    private fun snapZoomToStep(percent: Int): Float {
        val clamped = AppPreferences.clampTextZoom(percent)
        val steps = ((clamped - AppPreferences.MIN_TEXT_ZOOM).toFloat() / ZOOM_STEP).roundToInt()
        return (AppPreferences.MIN_TEXT_ZOOM + steps * ZOOM_STEP).toFloat()
    }

    /**
     * 校验并保存：服务端为可选，地址与令牌都可留空。
     *
     * - 地址留空 → 只保存本地偏好（远程目录 / 字号 / 翻页模式）；令牌若填了就单独写入。
     * - 地址有效 → 写服务端配置（令牌可留空，缺令牌时同步不可用但允许保存）。
     * - 令牌含非法字符 → 一律拦截（会崩请求头）。
     */
    private fun save() {
        serverUrlLayout.error = null
        authTokenLayout.error = null
        remoteDirLayout.error = null

        // 令牌是可选的（服务端可选）：只有非法字符（会让请求头构造崩溃）才拦截
        val tokenResult = SettingsValidator.validateToken(
            authTokenInput.text?.toString(),
            store.hasAuthToken(),
        )
        if (tokenResult is TokenValidation.Error &&
            tokenResult.reason == TokenError.ILLEGAL_CHARS
        ) {
            authTokenLayout.error = getString(tokenErrorText(tokenResult.reason))
            return
        }
        val newToken = (tokenResult as? TokenValidation.Replace)?.token

        when (val urlResult = SettingsValidator.validateServerUrl(serverUrlInput.text?.toString())) {
            is UrlValidation.Error -> {
                serverUrlLayout.error = getString(urlErrorText(urlResult.reason))
            }

            UrlValidation.Empty -> {
                // 地址留空：不写服务端配置；令牌若填了就单独写入（失败仅告警，不阻断本地偏好保存）
                if (newToken != null && !store.saveTokenOnly(newToken)) {
                    showStorageUnavailable()
                }
                applyLocalPreferences()
                finishWithToast()
            }

            is UrlValidation.Ok -> when (store.save(urlResult.normalized, newToken)) {
                SaveResult.Ok -> {
                    applyLocalPreferences()
                    finishWithToast()
                }

                SaveResult.EncryptionUnavailable -> showStorageUnavailable()
                SaveResult.EmptyToken ->
                    authTokenLayout.error = getString(R.string.settings_err_token_empty)
            }
        }
    }

    /** 写入本地偏好（远程目录 / 字号 / 翻页模式）；与是否配置服务端无关。 */
    private fun applyLocalPreferences() {
        // 主题已在点击时写入；这里写远程目录 / 字号 / 翻页模式
        val remoteDir = AppPreferences.normalizeRemoteDir(remoteDirInput.text?.toString())
        appPreferences.setRemoteDir(remoteDir)
        remoteDirInput.setText(remoteDir)
        appPreferences.setTextZoom(textZoomSlider.value.toInt())
        appPreferences.setPageMode(selectedPageMode())
    }

    /**
     * 用当前输入的地址与令牌做一次连通性探测（后台线程，不阻塞 UI）。
     *
     * 令牌输入框在 `onPause` 会被清空、且本地令牌**不回填明文**（设计如此），
     * 因此测试连接要求用户重新输入令牌；为空时在结果区给出明确提示。
     */
    private fun testConnection() {
        // 服务端可选：地址留空时没有探测目标，直接给出提示（不能再按 Ok 强转）
        val normalizedUrl = when (val urlResult = SettingsValidator.validateServerUrl(serverUrlInput.text?.toString())) {
            is UrlValidation.Error -> {
                serverUrlLayout.error = getString(urlErrorText(urlResult.reason))
                return
            }
            UrlValidation.Empty -> {
                connectionResultText.setText(R.string.settings_test_need_server)
                return
            }
            is UrlValidation.Ok -> urlResult.normalized
        }
        val token = authTokenInput.text?.toString()?.trim().orEmpty()
        if (token.isEmpty()) {
            // 本地虽有已保存令牌，但没有「读回明文」的 API（安全设计），只能要求重新输入
            connectionResultText.setText(R.string.settings_test_need_token)
            return
        }

        val tester = ConnectivityTester(SeshatConfig(serverUrl = normalizedUrl, token = token))
        connectionResultText.setText(R.string.settings_testing)
        Thread({
            val result = tester.test()
            runOnUiThread {
                // Activity 可能已在探测期间被销毁（主题切换重建等）
                if (!isFinishing && !isDestroyed) showConnectionResult(result)
            }
        }, "connectivity-test").start()
    }

    /** 把探测结果映射为文案。 */
    private fun showConnectionResult(result: ConnectivityResult) {
        connectionResultText.text = when (result) {
            ConnectivityResult.Ok -> getString(R.string.settings_connect_ok)
            ConnectivityResult.Unauthorized -> getString(R.string.settings_connect_unauthorized)
            is ConnectivityResult.ServerError ->
                getString(R.string.settings_connect_server_error, result.code)
            is ConnectivityResult.Unreachable ->
                getString(R.string.settings_connect_unreachable, result.message)
        }
    }

    /** 刷新「关于」区：版本号 + 配置状态（机密只显示「已配置 / 未配置」，不显示值）。 */
    private fun updateAbout() {
        val version = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: "-"
        } catch (e: Exception) {
            "-"
        }
        val server = getString(
            if (store.loadServerUrl() != null) R.string.settings_value_configured else R.string.settings_value_missing,
        )
        val token = getString(
            if (store.hasAuthToken()) R.string.settings_value_configured else R.string.settings_value_missing,
        )
        aboutText.text = buildString {
            append(getString(R.string.settings_about_version, version))
            append('\n')
            append(getString(R.string.settings_about_server, server))
            append('\n')
            append(getString(R.string.settings_about_token, token))
            append('\n')
            append(getString(R.string.settings_about_remote_dir, appPreferences.remoteDir()))
        }
    }

    /**
     * 刷新笔记外部目录的显示文案。
     *
     * 未设置 → 「未设置」；已设置 → 目录末段（SAF tree URI 的末段形如 `primary:notes`），
     * 取不到时退回完整 URI 字符串。**不写日志**：URI 里可能含用户目录名。
     */
    private fun refreshNotesDir() {
        val dir = appPreferences.notesExternalDir()
        notesDirValue.text = if (dir.isBlank()) {
            getString(R.string.settings_notes_dir_none)
        } else {
            runCatching { Uri.parse(dir).lastPathSegment }.getOrNull() ?: dir
        }
    }

    /**
     * 清除笔记外部目录：先释放持久读权限，再清空偏好（顺序不可反）。
     *
     * 释放失败不算错误（权限可能早已被系统回收），因此一律 `runCatching` 后继续清空。
     */
    private fun clearNotesDir() {
        val old = appPreferences.notesExternalDir()
        if (old.isNotBlank()) {
            runCatching {
                contentResolver.releasePersistableUriPermission(
                    Uri.parse(old),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
        }
        appPreferences.setNotesExternalDir("")
        refreshNotesDir()
    }

    /**
     * 加密存储不可用：禁用保存与清除令牌，并显示常驻告警（B1）。
     *
     * 主题 / 字号 / 翻页模式走普通 SharedPreferences，**不**因此禁用——这是分层设计的目的。
     */
    private fun showStorageUnavailable() {
        storageWarningText.setText(R.string.settings_encryption_unavailable)
        storageWarningText.visibility = View.VISIBLE
        findViewById<MaterialButton>(R.id.saveSettingsButton).isEnabled = false
        clearTokenButton.isEnabled = false
    }

    /** 地址校验失败原因 → 文案资源。 */
    private fun urlErrorText(reason: UrlError): Int = when (reason) {
        UrlError.TOO_LONG -> R.string.settings_err_url_too_long
        UrlError.MALFORMED -> R.string.settings_err_url_malformed
        UrlError.UNSUPPORTED_SCHEME -> R.string.settings_err_url_scheme
        UrlError.MISSING_HOST -> R.string.settings_err_url_host
        UrlError.USER_INFO_NOT_ALLOWED -> R.string.settings_err_url_userinfo
        UrlError.QUERY_NOT_ALLOWED -> R.string.settings_err_url_query
    }

    /** 令牌校验失败原因 → 文案资源。 */
    private fun tokenErrorText(reason: TokenError): Int = when (reason) {
        TokenError.EMPTY -> R.string.settings_err_token_empty
        TokenError.ILLEGAL_CHARS -> R.string.settings_err_token_chars
    }

    private fun finishWithToast() {
        toast(getString(R.string.settings_saved))
        finish()
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        /** 字号滑杆步长（与 `activity_settings.xml` 中 `android:stepSize` 保持一致）。 */
        private const val ZOOM_STEP = 10

        /** 构建设置页 Intent。 */
        fun intent(context: Context): Intent = Intent(context, SettingsActivity::class.java)
    }
}
