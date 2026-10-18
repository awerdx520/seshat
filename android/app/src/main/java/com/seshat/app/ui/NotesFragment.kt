package com.seshat.app.ui

import android.content.Context
import android.net.Uri
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
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.button.MaterialButtonToggleGroup
import com.seshat.app.R
import com.seshat.app.gtd.GtdSorter
import com.seshat.app.gtd.OrgEntry
import com.seshat.app.gtd.OrgNode
import com.seshat.app.gtd.OrgParser
import com.seshat.app.gtd.VisibleRow
import com.seshat.app.notes.NoteFormat
import com.seshat.app.notes.NoteItem
import com.seshat.app.notes.NoteReader
import com.seshat.app.notes.NoteRef
import com.seshat.app.notes.NoteScanner
import com.seshat.app.notes.NoteSourceKind
import com.seshat.app.settings.AppPreferences
import com.seshat.app.settings.SettingsActivity
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 笔记 tab（M10.7 T7）：**笔记库列表**宿主（取代 B4 的单文件树视图）。
 *
 * 数据来源（[loadNotes]，后台线程扫描）：
 * - **私有目录** `filesDir/notes`：经笔记扫描器的本地目录扫描，首启从 `assets/sample.org`
 *   复制一份示例笔记（沿用 B4 的 [ensureNotesDir] 逻辑）；
 * - **外部目录**（可选）：设置页选定的 SAF 目录树（经 SAF 目录扫描），
 *   URI 存在 [AppPreferences.notesExternalDir]；未设置或授权失效时按「没有外部笔记」处理。
 *
 * 两个分段：
 * - **笔记**：一个文件一行（[NoteFileAdapter]，标题 + 格式/修改时间 + 标签），
 *   点击按 [NoteRef] 类型分派到 [NoteViewActivity]（本地文件可进源码编辑，SAF 只读）；
 * - **Agenda**：所有 org 笔记的条目合并后按「最早日期」排序（[GtdSorter.byEarliestDate]），
 *   沿用 [NotesListAdapter] 的展示。**只读**（点击给提示）：跨文件写回需要
 *   「条目 → 文件」反查，M10.7 范围内不实现，见 `openspec/tech-debt.md`。
 *
 * 搜索只匹配**标题 + 标签**（不读正文：笔记库扫描时正文未必可用，且外部目录全文搜索成本高）。
 */
class NotesFragment : Fragment() {

    /** 当前笔记库（本地 + 外部，按修改时间倒序）。 */
    private var notes: List<NoteItem> = emptyList()

    /** Agenda 段的可见行（所有 org 笔记的条目合并）。 */
    private var agendaRows: List<VisibleRow> = emptyList()

    /** 当前分段。 */
    private var mode: Segment = Segment.NOTES

    /** 当前搜索词（原样保存，去空白判断在 [filteredNotes] 里）。 */
    private var query: String = ""

    /** 是否正在扫描（加载期间不显示空态，避免闪一下「还没有笔记」）。 */
    private var loading: Boolean = false

    /** 后台扫描线程；随视图生命周期创建/销毁（Fragment 实例可跨视图重建复用，故不设为 val）。 */
    private var scanExecutor: ExecutorService? = null

    private lateinit var noteFileAdapter: NoteFileAdapter
    private lateinit var agendaAdapter: NotesListAdapter
    private lateinit var notesGrid: RecyclerView
    private lateinit var notesEmpty: TextView
    private lateinit var notesLoading: ProgressBar
    private lateinit var notesSearch: EditText

    /** 搜索防抖任务（250ms）。 */
    private val searchRunnable = Runnable { rebuild() }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = inflater.inflate(R.layout.fragment_notes, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        scanExecutor = Executors.newSingleThreadExecutor()

        noteFileAdapter = NoteFileAdapter { item -> openNote(item) }
        // Agenda 段只读：折叠箭头永不出现（行都是 depth=0、无子节点），点击给提示
        agendaAdapter = NotesListAdapter(
            onRowClick = { showAgendaReadonly() },
            onCollapseToggle = { _ -> },
        )

        notesGrid = view.findViewById(R.id.notesList)
        notesEmpty = view.findViewById(R.id.notesEmpty)
        notesLoading = view.findViewById(R.id.notesLoading)
        notesSearch = view.findViewById(R.id.notesSearch)

        notesGrid.layoutManager = LinearLayoutManager(requireContext())
        notesGrid.adapter = noteFileAdapter

        view.findViewById<MaterialButton>(R.id.refreshNotesButton).setOnClickListener { loadNotes() }
        view.findViewById<MaterialButton>(R.id.pickNotesDirButton).setOnClickListener {
            // 外部目录在设置页选择；返回后由 onResume 触发重新扫描
            startActivity(SettingsActivity.intent(requireContext()))
        }

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
        // 从设置页（可能刚选了外部目录）或阅读页返回后重新扫描
        loadNotes()
    }

    override fun onDestroyView() {
        super.onDestroyView()
        notesSearch.removeCallbacks(searchRunnable)
        // 取消未完成的扫描，避免回调访问已销毁的视图
        scanExecutor?.shutdownNow()
        scanExecutor = null
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
     * 绑定搜索框：只过滤「标题 + 标签」。
     *
     * 两条路径（沿用 B4 的真机验收修复）：
     * - **有内容**：250ms 防抖后再过滤，避免逐字整表刷新；
     * - **清空**（文本为空或纯空白）：**立即**恢复全量 —— 若清空也挂防抖，IME 清空后继续发出的
     *   文本事件会不断重置定时器，列表恢复被无限推迟。
     *
     * ENTER（IME 搜索键 / 物理回车）立即过滤，跳过防抖。
     */
    private fun setUpSearch() {
        notesSearch.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

            override fun afterTextChanged(s: Editable?) {
                val text = s?.toString().orEmpty()
                notesSearch.removeCallbacks(searchRunnable)
                if (text.isBlank()) {
                    query = ""
                    rebuild()
                } else {
                    query = text
                    notesSearch.postDelayed(searchRunnable, SEARCH_DEBOUNCE_MS)
                }
            }
        })

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
     * 保证 `filesDir/notes` 存在，并在缺失时把 `assets/sample.org` 复制进去（B4 逻辑保留）。
     *
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
     * 后台扫描本地与外部目录 → 主线程刷新列表。
     *
     * 本地扫描用纯 JVM 的本地目录扫描；外部目录走 SAF 扫描，
     * 失败（授权失效、provider 异常）一律降级为「没有外部笔记」，不阻断本地结果展示。
     */
    private fun loadNotes() {
        val exec = scanExecutor ?: return
        val context = requireContext().applicationContext
        // 偏好读取放主线程，后台只做 IO / 解析
        val externalUri = AppPreferences.open(requireContext())
            .notesExternalDir()
            .takeIf { it.isNotBlank() }
            ?.let { raw -> runCatching { Uri.parse(raw) }.getOrNull() }
        setLoading(true)
        exec.execute {
            val dir = ensureNotesDir(context)
            val local = dir?.let { NoteScanner.scanLocal(it, NoteSourceKind.PRIVATE) }.orEmpty()
            val external = externalUri
                ?.let { uri ->
                    runCatching { NoteScanner.scanSaf(context.contentResolver, uri) }
                        .getOrDefault(emptyList())
                }
                .orEmpty()
            val all = (local + external).sortedByDescending { it.modifiedAt }
            val agenda = buildAgendaRows(context, all)
            activity?.runOnUiThread {
                if (view == null) return@runOnUiThread
                notes = all
                agendaRows = agenda
                setLoading(false)
                rebuild()
            }
        }
    }

    /**
     * 合并所有 org 笔记的条目 → Agenda 行（按「最早日期」升序）。
     *
     * - 只解析前 [MAX_AGENDA_FILES] 个 org 文件（多文件逐个 `read + parse` 是主要耗时项）；
     * - 行的 [OrgNode.index] 用**全局递增计数器**：跨文件用「文件内下标」会互相冲突，
     *   而 [NotesListAdapter] 把它当稳定 id 使用；
     * - 单个文件读取/解析失败只跳过该文件。
     */
    private fun buildAgendaRows(context: Context, items: List<NoteItem>): List<VisibleRow> {
        val entries = mutableListOf<OrgEntry>()
        items.filter { it.format == NoteFormat.ORG }
            .take(MAX_AGENDA_FILES)
            .forEach { item ->
                val text = NoteReader.read(item.ref, context.contentResolver) ?: return@forEach
                runCatching { OrgParser().parse(text) }.getOrNull()?.let { entries += it.entries }
            }
        var seq = 0
        return GtdSorter.byEarliestDate(entries).map { entry ->
            VisibleRow(OrgNode(entry, seq++, emptyList()), 0, false, false)
        }
    }

    // ---------------------------------------------------------------- 渲染

    /** 按当前分段重建列表（笔记段走过滤后的笔记库，Agenda 段走预构建的行）。 */
    private fun rebuild() {
        when (mode) {
            Segment.NOTES -> {
                bindAdapter(noteFileAdapter)
                noteFileAdapter.submit(filteredNotes())
            }

            Segment.AGENDA -> {
                bindAdapter(agendaAdapter)
                agendaAdapter.submit(agendaRows)
            }
        }
        updateEmptyState()
    }

    /** 只在分段切换时真正换 adapter（同一个 adapter 重复 set 会触发多余的重绑）。 */
    private fun bindAdapter(adapter: RecyclerView.Adapter<*>) {
        if (notesGrid.adapter !== adapter) notesGrid.adapter = adapter
    }

    /** 按 [query] 过滤笔记库：只匹配标题与标签（大小写不敏感），不读正文。 */
    private fun filteredNotes(): List<NoteItem> {
        val needle = query.trim()
        if (needle.isEmpty()) return notes
        return notes.filter { item ->
            item.title.contains(needle, ignoreCase = true) ||
                item.tags.any { tag -> tag.contains(needle, ignoreCase = true) }
        }
    }

    /** 空态文案：Agenda 空 / 搜索无结果 / 笔记库为空。 */
    private fun updateEmptyState() {
        val count = when (mode) {
            Segment.NOTES -> noteFileAdapter.itemCount
            Segment.AGENDA -> agendaRows.size
        }
        notesEmpty.visibility = if (count == 0 && !loading) View.VISIBLE else View.GONE
        notesEmpty.text = when {
            mode == Segment.AGENDA -> getString(R.string.notes_agenda_empty)
            query.isNotBlank() -> getString(R.string.notes_search_empty)
            else -> getString(R.string.notes_empty)
        }
    }

    private fun setLoading(loading: Boolean) {
        this.loading = loading
        notesLoading.visibility = if (loading) View.VISIBLE else View.GONE
        if (loading) notesEmpty.visibility = View.GONE
    }

    // ---------------------------------------------------------------- 交互

    /** 点击笔记行：按 [NoteRef] 类型分派到阅读页（SAF 文档只读，无源码编辑入口）。 */
    private fun openNote(item: NoteItem) {
        val context = requireContext()
        val intent = when (val ref = item.ref) {
            is NoteRef.LocalFile -> NoteViewActivity.intentForFile(context, ref.file, item.title)
            is NoteRef.SafDocument -> NoteViewActivity.intentForUri(context, ref.uri, item.title)
        }
        startActivity(intent)
    }

    /**
     * Agenda 段点击：只给提示，不改文件。
     *
     * M10.7 范围收缩：跨文件条目无法用「文件内下标」定位回原文件，直接写回会写错文件，
     * 因此 B4 的「点击切换 TODO 状态」在此降级为只读（改动入口收敛到笔记阅读页的源码编辑）。
     */
    private fun showAgendaReadonly() {
        Toast.makeText(requireContext(), R.string.notes_agenda_readonly, Toast.LENGTH_SHORT).show()
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

        /** Agenda 段最多解析的 org 文件数（多文件逐个解析是主要耗时项）。 */
        const val MAX_AGENDA_FILES = 50
    }
}
