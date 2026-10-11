package com.notes.app.gtd

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.notes.app.R
import com.notes.app.sync.NotesConfig
import com.notes.app.sync.WebDavClient
import java.io.File

/**
 * GTD agenda / TODO 视图（M4.2 展示 + 过滤，M4.3 读写 org + WebDAV 同步）。
 *
 * 数据来源：应用私有目录 `filesDir/sample.org`（首次启动从 assets 复制样例）。
 * 用 [OrgParser] 解析为 [OrgDocument]，在 [RecyclerView] 中展示全部条目；
 * 顶部提供三个 [Spinner] 过滤栏：TODO 状态、优先级、标签，三者组合过滤（见 [GtdFilter]）。
 *
 * 交互（M4.3）：
 * - **点击条目**：按 `TODO→DONE、DONE→TODO、无状态→TODO` 切换 TODO 状态，经 [OrgEditor]
 *   改写 org 文本并写回本地文件，随后重新解析刷新列表与过滤栏。
 * - **同步按钮**：后台线程把本地 org 文件 `PUT` 到 WebDAV 服务端（远端相对路径
 *   [REMOTE_PATH]），主线程 Toast 结果；服务器配置见 [readSyncConfig]。
 *
 * 入口：[intent] 静态工厂方法（应用内启动，exported=false）。
 */
class GtdActivity : AppCompatActivity() {

    private lateinit var adapter: GtdEntryAdapter
    private lateinit var emptyText: TextView
    private lateinit var syncButton: Button

    private lateinit var stateSpinner: Spinner
    private lateinit var prioritySpinner: Spinner
    private lateinit var tagSpinner: Spinner

    /** 本地可读写 org 文件（`filesDir/sample.org`）。 */
    private lateinit var localOrgFile: File

    /** 当前本地 org 文本（改写时以它为输入基准）。 */
    private var currentText: String = ""

    /** 文档全部条目（过滤的输入基准）。 */
    private var allEntries: List<OrgEntry> = emptyList()

    /** Spinner 位置 → 过滤值映射；索引 0 恒为「全部」（`null` 值）。 */
    private var stateValues: List<String?> = listOf(null)
    private var priorityValues: List<Char?> = listOf(null)
    private var tagValues: List<String?> = listOf(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_gtd)

        adapter = GtdEntryAdapter()
        val list = findViewById<RecyclerView>(R.id.gtdList)
        list.layoutManager = LinearLayoutManager(this)
        list.adapter = adapter
        adapter.onItemClick = { entry -> onEntryClicked(entry) }

        emptyText = findViewById(R.id.gtdEmptyText)
        // 先完成全部 findViewById，任何 Spinner 回调都能安全访问兄弟视图。
        stateSpinner = findViewById(R.id.filterTodoState)
        prioritySpinner = findViewById(R.id.filterPriority)
        tagSpinner = findViewById(R.id.filterTag)
        syncButton = findViewById(R.id.gtdSyncButton)
        syncButton.setOnClickListener { syncToServer() }

        val local = ensureLocalOrg()
        if (local == null) {
            // 本地文件不可用时禁用同步，避免访问未初始化的 localOrgFile。
            syncButton.isEnabled = false
            emptyText.visibility = View.VISIBLE
            return
        }
        localOrgFile = local
        reloadDocument()
    }

    /**
     * 保证 `filesDir/sample.org` 存在且非空：首次启动从 assets 复制。
     *
     * @return 本地 org 文件；复制失败返回 `null`（并 Toast 提示）。
     */
    private fun ensureLocalOrg(): File? = try {
        val target = File(filesDir, SAMPLE_ASSET)
        if (!target.exists() || target.length() == 0L) {
            assets.open(SAMPLE_ASSET).use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
        }
        target
    } catch (e: Exception) {
        Toast.makeText(
            this,
            getString(R.string.gtd_load_failed, e.message ?: SAMPLE_ASSET),
            Toast.LENGTH_LONG,
        ).show()
        null
    }

    /** 从本地 org 文件读取文本、解析并刷新过滤栏与列表。 */
    private fun reloadDocument() {
        currentText = try {
            localOrgFile.readText()
        } catch (e: Exception) {
            Toast.makeText(
                this,
                getString(R.string.gtd_load_failed, e.message ?: SAMPLE_ASSET),
                Toast.LENGTH_LONG,
            ).show()
            emptyText.visibility = View.VISIBLE
            return
        }
        allEntries = OrgParser().parse(currentText).entries
        setUpFilterBar()
        applyFilter()
    }

    /**
     * 点击条目：切换 TODO 状态（`TODO→DONE`、`DONE→TODO`、无状态→`TODO`，其余状态→`DONE`），
     * 经 [OrgEditor] 改写 org 文本后写回本地文件并刷新。
     *
     * 定位方式：过滤后的列表由 [GtdFilter] 从 [allEntries] 派生（元素为同一对象实例），
     * 因此用引用相等即可把点击项映射回全文档条目序号（[OrgEditor.headlineLineOf] 需要它）。
     */
    private fun onEntryClicked(entry: OrgEntry) {
        val index = allEntries.indexOfFirst { it === entry }
        if (index < 0) return
        val nextState = when (entry.todoState) {
            null -> STATE_TODO
            STATE_DONE -> STATE_TODO
            else -> STATE_DONE
        }
        try {
            val updated = OrgEditor.toggleTodoState(currentText, index, nextState)
            localOrgFile.writeText(updated)
        } catch (e: Exception) {
            Toast.makeText(
                this,
                getString(R.string.gtd_toggle_failed, e.message ?: ""),
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        reloadDocument()
    }

    /** 后台线程把本地 org 文件 PUT 到 WebDAV 服务端；主线程 Toast 结果。 */
    private fun syncToServer() {
        if (!::localOrgFile.isInitialized) return
        val config = readSyncConfig()
        if (config == null) {
            Toast.makeText(this, getString(R.string.gtd_sync_not_configured), Toast.LENGTH_LONG).show()
            return
        }
        val content: ByteArray = try {
            localOrgFile.readBytes()
        } catch (e: Exception) {
            Toast.makeText(
                this,
                getString(R.string.gtd_sync_failed, e.message ?: ""),
                Toast.LENGTH_LONG,
            ).show()
            return
        }

        Toast.makeText(this, getString(R.string.gtd_syncing), Toast.LENGTH_SHORT).show()
        // 网络请求必须离开主线程，避免 NetworkOnMainThreadException / ANR。
        Thread {
            val message = try {
                val code = WebDavClient(config).put(REMOTE_PATH, content, ORG_CONTENT_TYPE)
                getString(R.string.gtd_sync_success, code)
            } catch (e: Exception) {
                getString(R.string.gtd_sync_failed, e.message ?: e.javaClass.simpleName)
            }
            runOnUiThread { Toast.makeText(this, message, Toast.LENGTH_LONG).show() }
        }.start()
    }

    /**
     * 读取同步服务器配置。
     *
     * MVP 约定：从 SharedPreferences [SYNC_PREFS] 读取 `server_url`（服务端根地址）与
     * `auth_token`（即服务端 `NOTES_AUTH_TOKEN`，WebDAV 用作 Basic 密码）。
     * 任一项缺失或为空时返回 `null`，由调用方提示用户「未配置同步服务器」。
     */
    private fun readSyncConfig(): NotesConfig? {
        val prefs = getSharedPreferences(SYNC_PREFS, MODE_PRIVATE)
        val serverUrl = prefs.getString(KEY_SERVER_URL, null)?.trim().orEmpty()
        val token = prefs.getString(KEY_AUTH_TOKEN, null)?.trim().orEmpty()
        if (serverUrl.isEmpty() || token.isEmpty()) return null
        return NotesConfig(serverUrl = serverUrl, token = token, remoteDir = REMOTE_DIR)
    }

    /** 依据文档内容动态构建三个过滤 Spinner（首项恒为「全部」）并挂载监听。 */
    private fun setUpFilterBar() {
        val allLabel = getString(R.string.gtd_filter_all)

        val states = allEntries.mapNotNull { it.todoState }.distinct()
        stateValues = listOf(null) + states
        bindFilterSpinner(stateSpinner, listOf(allLabel) + states)

        val priorities = allEntries.mapNotNull { it.priority }.distinct().sorted()
        priorityValues = listOf(null) + priorities
        bindFilterSpinner(prioritySpinner, listOf(allLabel) + priorities.map { it.toString() })

        val tags = allEntries.flatMap { it.tags }.distinct().sorted()
        tagValues = listOf(null) + tags
        bindFilterSpinner(tagSpinner, listOf(allLabel) + tags)
    }

    /** 把 [display] 绑定为 [spinner] 的选项；选中变化时触发 [applyFilter]。 */
    private fun bindFilterSpinner(spinner: Spinner, display: List<String>) {
        val spinnerAdapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_item, display)
        spinnerAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        spinner.adapter = spinnerAdapter
        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                applyFilter()
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    /** 读取当前三个 Spinner 选择，组合过滤后刷新列表与空态。 */
    private fun applyFilter() {
        val state = stateValues.getOrNull(stateSpinner.selectedItemPosition)
        val priority = priorityValues.getOrNull(prioritySpinner.selectedItemPosition)
        val tag = tagValues.getOrNull(tagSpinner.selectedItemPosition)

        val filtered = GtdFilter.filter(
            entries = allEntries,
            todoState = state,
            priority = priority,
            tag = tag,
        )
        adapter.submit(filtered)
        emptyText.visibility = if (filtered.isEmpty()) View.VISIBLE else View.GONE
    }

    companion object {
        /** 本地 org 文件名（与 assets 同名，首次复制到 filesDir）。 */
        private const val SAMPLE_ASSET = "sample.org"

        /** WebDAV 远端相对路径（拼接为 `<serverUrl>/dav/notes/sample.org`）。 */
        private const val REMOTE_PATH = "notes/sample.org"

        /** WebDAV 笔记目录（相对服务端 `/dav`）。 */
        private const val REMOTE_DIR = "/"

        /** org 文件上传时的 Content-Type。 */
        private const val ORG_CONTENT_TYPE = "text/plain; charset=utf-8"

        /** 同步配置的 SharedPreferences 名称与键（MVP 约定）。 */
        private const val SYNC_PREFS = "notes_sync"
        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_AUTH_TOKEN = "auth_token"

        private const val STATE_TODO = "TODO"
        private const val STATE_DONE = "DONE"

        /** 构造进入 GTD 视图的 Intent。 */
        fun intent(context: Context): Intent = Intent(context, GtdActivity::class.java)
    }
}
