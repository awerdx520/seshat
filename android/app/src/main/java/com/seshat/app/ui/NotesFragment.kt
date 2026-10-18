package com.seshat.app.ui

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.button.MaterialButtonToggleGroup
import com.seshat.app.R
import com.seshat.app.gtd.GtdSorter
import com.seshat.app.gtd.NotesSync
import com.seshat.app.gtd.NotesSyncResult
import com.seshat.app.gtd.OrgEditor
import com.seshat.app.gtd.OrgDocument
import com.seshat.app.gtd.OrgEntry
import com.seshat.app.gtd.OrgNode
import com.seshat.app.gtd.OrgParser
import com.seshat.app.gtd.OrgSearchMatcher
import com.seshat.app.gtd.OrgTreeBuilder
import com.seshat.app.gtd.VisibleRow
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 笔记 tab（M10.6 B4b）：org 列表宿主，取代 M9.1 的占位视图。
 *
 * 功能：
 * - **阶层缩进 + 折叠**：`filesDir/notes` 目录下的 `*.org` 文件经 [OrgParser] 解析 → [OrgTreeBuilder] 建树，
 *   扁平化为 [VisibleRow] 展示；有子节点的行可点箭头折叠/展开。
 * - **状态 + 标题 + 标签同行 + 正文摘要**：见 `item_note_entry`。
 * - **全文搜索**：标题 + 正文（[OrgSearchMatcher]），保留命中节点的祖先链、强制展开。
 * - **笔记 / Agenda 分段**：Agenda 段按「最早日期」排序（[GtdSorter.byEarliestDate]），并对无过滤
 *   的全量条目展示；Agenda 段的同步按钮经 [NotesSync] 上传当前 org 文件。
 *
 * 数据落点：`filesDir/notes/sample.org`（首次从 `assets/sample.org` 复制）。
 * M10.6 B4d 起 GTD 页（`GtdActivity`）改为读同一路径，数据分叉已消除；
 * 旧版本的 `filesDir/sample.org` **保留但不再读取**，作为迁移回滚点。
 */
class NotesFragment : Fragment() {

    /** 文档全部条目（Agenda 段的排序输入）。 */
    private var entries: List<OrgEntry> = emptyList()

    /** 条目构建出的树（笔记段展示与搜索的输入）。 */
    private var roots: List<OrgNode> = emptyList()

    /** 已折叠节点的 [OrgNode.index] 集合；每次重新解析后按当前树裁剪（与 entries 同源）。 */
    private val collapsed: MutableSet<Int> = mutableSetOf()

    /** 当前分段。 */
    private var mode: Segment = Segment.NOTES

    /** 当前搜索词（原样保存，去空白判断由匹配器负责）。 */
    private var query: String = ""

    /** 最近一次 rebuild 产出的可见行（供调试/断言）。 */
    private var allRows: List<VisibleRow> = emptyList()

    /** 当前读取的 org 文件与全文（Agenda 段切换 TODO 状态时作为改写基准）。 */
    private var localOrgFile: File? = null
    private var currentText: String = ""

    /** 解析失败 / 读取失败信息（用于空态文案）。 */
    private var parseFailure: String? = null
    private var readFailure: Boolean = false

    /** 后台 IO 线程；随视图生命周期创建/销毁（Fragment 实例可跨视图重建复用，故不设为 val）。 */
    private var executor: ExecutorService? = null

    /** 是否正在加载（空态文案在加载期间保持隐藏，避免闪一下「还没有笔记」）。 */
    private var loading: Boolean = false

    private lateinit var adapter: NotesListAdapter
    private lateinit var notesList: RecyclerView
    private lateinit var notesEmpty: TextView
    private lateinit var notesLoading: ProgressBar
    private lateinit var notesSearch: EditText
    private lateinit var notesSyncButton: MaterialButton

    /** 编辑页返回后重新加载（编辑页写入文件成功时置 `RESULT_OK`）。 */
    private val editLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) loadNotes()
    }

    /** 搜索防抖任务（250ms）。 */
    private val searchRunnable = Runnable { rebuild() }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = inflater.inflate(R.layout.fragment_notes, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        executor = Executors.newSingleThreadExecutor()

        adapter = NotesListAdapter(
            onRowClick = { row -> onRowClicked(row) },
            onCollapseToggle = { row -> toggleCollapse(row) },
        )
        notesList = view.findViewById(R.id.notesList)
        notesEmpty = view.findViewById(R.id.notesEmpty)
        notesLoading = view.findViewById(R.id.notesLoading)
        notesSearch = view.findViewById(R.id.notesSearch)
        notesSyncButton = view.findViewById(R.id.notesSyncButton)

        notesList.layoutManager = LinearLayoutManager(requireContext())
        notesList.adapter = adapter

        // Agenda 段同步按钮：经 NotesSync 上传当前 org 文件（后台线程 + 主线程 Toast）
        notesSyncButton.setOnClickListener { syncToServer() }

        // 恢复上次的分段与搜索词（视图重建时 Fragment 实例仍在，成员变量保留）
        val group = view.findViewById<MaterialButtonToggleGroup>(R.id.notesSegmentGroup)
        group.check(if (mode == Segment.AGENDA) R.id.segmentAgenda else R.id.segmentNotes)
        notesSearch.setText(query)
        notesSearch.setSelection(notesSearch.text.length)

        setUpSegmentGroup(group)
        setUpSearch()

        // 初始状态：无数据时不显示空态文案，避免加载中闪一下「还没有笔记」
        setLoading(true)
    }

    override fun onResume() {
        super.onResume()
        // 返回本页时重新读取文件（可能在 GTD 页改过 TODO 状态）
        loadNotes()
    }

    override fun onDestroyView() {
        super.onDestroyView()
        notesSearch.removeCallbacks(searchRunnable)
        // 取消未完成的后台任务，避免回调访问已销毁的视图
        executor?.shutdownNow()
        executor = null
    }

    // ---------------------------------------------------------------- 分段与搜索

    /** 绑定 笔记 / Agenda 分段按钮。 */
    private fun setUpSegmentGroup(group: MaterialButtonToggleGroup) {
        group.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            mode = if (checkedId == R.id.segmentAgenda) Segment.AGENDA else Segment.NOTES
            rebuild()
        }
    }

    /**
     * 绑定搜索框。
     *
     * 项目此前未使用 `androidx.core.widget.doAfterTextChanged`，此处按任务约定手写 [TextWatcher]。
     *
     * 两条路径（B4 真机验收缺陷 2 修复）：
     * - **有内容**：250ms 防抖后再重建，避免逐字重建整棵树；
     * - **清空**（文本为空或纯空白）：**立即**重建恢复全量，不等防抖 —— 输入才需要防抖，
     *   恢复全量没有这个负担；而若清空也挂防抖，IME 在清空后继续发出的文本事件会不断
     *   `removeCallbacks` + 重投，定时器被反复重置，列表恢复被无限推迟（真机现象：清空后
     *   仍停在「没有匹配的条目」，必须再按 ENTER）。
     *
     * 另：`imeOptions=actionSearch` 的 ENTER 也立即过滤（单独的快捷路径，不再是唯一路径）。
     */
    private fun setUpSearch() {
        notesSearch.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

            override fun afterTextChanged(s: Editable?) {
                val text = s?.toString().orEmpty()
                notesSearch.removeCallbacks(searchRunnable)
                if (text.isBlank()) {
                    // 清空 → 立即恢复全量（query 归零，rebuild 走非搜索分支）
                    query = ""
                    rebuild()
                } else {
                    query = text
                    notesSearch.postDelayed(searchRunnable, SEARCH_DEBOUNCE_MS)
                }
            }
        })

        // ENTER（IME 搜索键 / 物理回车）立即过滤，跳过 250ms 防抖
        notesSearch.setOnEditorActionListener { _, actionId, event ->
            val byAction = actionId == EditorInfo.IME_ACTION_SEARCH
            val byEnter = event?.keyCode == KeyEvent.KEYCODE_ENTER &&
                event.action == KeyEvent.ACTION_DOWN
            if (byAction || byEnter) {
                notesSearch.removeCallbacks(searchRunnable)
                query = notesSearch.text?.toString().orEmpty()
                rebuild()
                true
            } else {
                false
            }
        }
    }

    // ---------------------------------------------------------------- 加载

    /**
     * 保证 `filesDir/notes` 存在，并在缺失时把 `assets/sample.org` 复制进去。
     *
     * 旧 `filesDir/sample.org`（GTD 使用）**保留但不再读取**：作为迁移回滚点。
     * 本方法在后台线程执行，故通过传入的 [context]（applicationContext）访问资源与目录。
     *
     * @return 笔记目录；创建/复制失败返回 `null`。
     */
    private fun ensureNotesDir(context: Context): File? = try {
        val dir = File(context.filesDir, NOTES_DIR_NAME)
        if (!dir.exists()) dir.mkdirs()
        val target = File(dir, SAMPLE_ASSET)
        if (!target.exists() || target.length() == 0L) {
            context.assets.open(SAMPLE_ASSET).use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
        }
        dir
    } catch (e: Exception) {
        null
    }

    /**
     * 后台读取并解析笔记，主线程刷新。
     *
     * 当前只读取目录下**第一个** .org 文件（按文件名排序），多文件切换留后续阶段。
     */
    private fun loadNotes() {
        val exec = executor ?: return
        val context = requireContext().applicationContext
        setLoading(true)
        exec.execute {
            val dir = ensureNotesDir(context)
            val files = dir?.listFiles { f -> f.isFile && f.extension.equals("org", true) }
                ?.sortedBy { it.name } ?: emptyList()
            // 只取第一个文件（列表顶部显示当前文件；多文件切换留后续阶段）
            val file = files.firstOrNull()
            val text = file?.let { runCatching { it.readText() }.getOrNull() }
            val parsed = text?.let { runCatching { OrgParser().parse(it) } }
            activity?.runOnUiThread {
                if (view == null) return@runOnUiThread
                applyLoaded(file, text, parsed)
            }
        }
    }

    /** 主线程落盘加载结果：单一赋值点，保证 entries / roots / 折叠记录 / 文案状态同步更新。 */
    private fun applyLoaded(file: File?, text: String?, parsed: Result<OrgDocument>?) {
        localOrgFile = file
        currentText = text.orEmpty()
        entries = parsed?.getOrNull()?.entries ?: emptyList()
        parseFailure = parsed?.exceptionOrNull()?.message
        readFailure = file != null && text == null
        roots = OrgTreeBuilder.build(entries)
        // 重新解析后条目下标可能变化，裁剪掉失效的折叠记录
        pruneCollapsed()
        setLoading(false)
        rebuild()
    }

    /**
     * 裁剪 [collapsed]：只保留当前树中仍存在的 [OrgNode.index]。
     *
     * 这是「折叠状态与 entries 同源」的保障：折叠记录以条目在**当前解析结果**中的下标为键，
     * 每次重新解析（[loadNotes]）后清理失效下标，避免下标复用导致意外折叠。
     */
    private fun pruneCollapsed() {
        val valid = mutableSetOf<Int>()
        fun walk(nodes: List<OrgNode>) {
            for (node in nodes) {
                valid += node.index
                walk(node.children)
            }
        }
        walk(roots)
        collapsed.retainAll(valid)
    }

    // ---------------------------------------------------------------- 渲染

    /**
     * 按当前分段与搜索词重建可见行并刷新列表/空态/同步按钮（主线程）。
     */
    private fun rebuild() {
        allRows = when {
            mode == Segment.NOTES && query.isNotBlank() -> {
                val matched = OrgSearchMatcher.match(roots, query)
                OrgTreeBuilder.flattenFiltered(roots, matched, collapsed)
            }
            mode == Segment.NOTES -> OrgTreeBuilder.flatten(roots, collapsed)
            else -> agendaRows()
        }
        adapter.submit(allRows)
        notesEmpty.visibility = if (allRows.isEmpty() && !loading) View.VISIBLE else View.GONE
        notesEmpty.text = when {
            mode == Segment.AGENDA -> getString(R.string.notes_agenda_empty)
            query.isNotBlank() -> getString(R.string.notes_search_empty)
            parseFailure != null -> getString(R.string.notes_parse_failed, parseFailure)
            readFailure -> getString(R.string.notes_load_failed)
            else -> getString(R.string.notes_empty)
        }
        notesSyncButton.visibility = if (mode == Segment.AGENDA) View.VISIBLE else View.GONE
    }

    /**
     * Agenda 段的行：全量条目按「最早日期」升序，每条一行、无层级无折叠。
     *
     * `index` 取排序后的下标，仅作适配器内部标识，**不用于回写**（写回需用 [entries] 中的引用相等定位）。
     */
    private fun agendaRows(): List<VisibleRow> =
        GtdSorter.byEarliestDate(entries).mapIndexed { i, entry ->
            VisibleRow(OrgNode(entry, i, emptyList()), 0, false, false)
        }

    private fun setLoading(loading: Boolean) {
        this.loading = loading
        notesLoading.visibility = if (loading) View.VISIBLE else View.GONE
        if (loading) notesEmpty.visibility = View.GONE
    }

    // ---------------------------------------------------------------- 交互

    /** 折叠/展开：更新 [collapsed] 后重建列表。 */
    private fun toggleCollapse(row: VisibleRow) {
        val index = row.node.index
        if (!collapsed.remove(index)) collapsed.add(index)
        rebuild()
    }

    /**
     * 行点击。
     *
     * - 笔记段：进入 [NotesEditActivity] 编辑该条目（标题 / 正文 / TODO 状态）。
     * - Agenda 段：沿用既有语义 —— 切换 TODO 状态（`TODO→DONE`、`DONE→TODO`、无状态→`TODO`、
     *   其余→`DONE`），经 [OrgEditor] 改写全文并写回本地文件后重新加载。
     */
    private fun onRowClicked(row: VisibleRow) {
        if (mode == Segment.NOTES) {
            openEditor(row)
            return
        }
        toggleAgendaEntry(row.node.entry)
    }

    /** 打开编辑页：[row] 的 [OrgNode.index] 即该条目在 `parse().entries` 中的下标。 */
    private fun openEditor(row: VisibleRow) {
        val file = localOrgFile
        if (file == null) {
            Toast.makeText(requireContext(), R.string.notes_load_failed, Toast.LENGTH_SHORT).show()
            return
        }
        editLauncher.launch(NotesEditActivity.intent(requireContext(), file, row.node.index))
    }

    /**
     * Agenda 段点击条目：切换 TODO 状态并写回 org 文件（照抄 [GtdActivity] 的既有实现）。
     *
     * 定位方式：用引用相等把点击项映射回 [entries] 的下标（[OrgEditor.toggleTodoState] 需要条目序号）。
     */
    private fun toggleAgendaEntry(entry: OrgEntry) {
        val file = localOrgFile ?: return
        val index = entries.indexOfFirst { it === entry }
        if (index < 0) return
        val nextState = when (entry.todoState) {
            null -> STATE_TODO
            STATE_DONE -> STATE_TODO
            else -> STATE_DONE
        }
        try {
            val updated = OrgEditor.toggleTodoState(currentText, index, nextState)
            file.writeText(updated)
        } catch (e: Exception) {
            Toast.makeText(
                requireContext(),
                getString(R.string.gtd_toggle_failed, e.message ?: ""),
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        loadNotes()
    }

    /**
     * Agenda 段同步：后台线程经 [NotesSync.upload] 把当前 org 文件上传到 `remoteDir/seshat/<文件名>`。
     *
     * 结果映射：成功 → [R.string.notes_sync_success]（远端路径 + HTTP 码）；
     * 未配置 → [R.string.gtd_sync_not_configured]；失败 → [R.string.notes_sync_failed]。
     * 与 [GtdActivity] 共用同一份阻塞实现，UI 责任（线程 / Toast）留在本类。
     */
    private fun syncToServer() {
        val file = localOrgFile
        if (file == null) {
            Toast.makeText(requireContext(), R.string.notes_load_failed, Toast.LENGTH_SHORT).show()
            return
        }
        val exec = executor ?: return
        val context = requireContext().applicationContext
        Toast.makeText(requireContext(), R.string.gtd_syncing, Toast.LENGTH_SHORT).show()
        exec.execute {
            val result = NotesSync.upload(context, file)
            activity?.runOnUiThread {
                if (view == null) return@runOnUiThread
                val message = when (result) {
                    is NotesSyncResult.Ok ->
                        context.getString(R.string.notes_sync_success, result.remotePath, result.httpCode)
                    NotesSyncResult.NotConfigured -> context.getString(R.string.gtd_sync_not_configured)
                    is NotesSyncResult.Failed ->
                        context.getString(R.string.notes_sync_failed, result.message)
                }
                Toast.makeText(context, message, Toast.LENGTH_LONG).show()
            }
        }
    }

    /** 分段模式。 */
    private enum class Segment { NOTES, AGENDA }

    private companion object {
        /** 笔记目录（`filesDir/notes`）。 */
        const val NOTES_DIR_NAME = "notes"

        /** 示例文档名（assets 与目标文件同名）。 */
        const val SAMPLE_ASSET = "sample.org"

        /** 搜索防抖窗口。 */
        const val SEARCH_DEBOUNCE_MS = 250L

        const val STATE_TODO = "TODO"
        const val STATE_DONE = "DONE"
    }
}
