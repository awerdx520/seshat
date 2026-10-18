package com.seshat.app.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import com.seshat.app.R
import com.seshat.app.gtd.OrgEntry
import com.seshat.app.gtd.OrgEntryDisplay
import com.seshat.app.gtd.OrgEditor
import com.seshat.app.gtd.OrgParser
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 笔记条目编辑页（M10.6 B4c）。
 *
 * 可编辑：标题、正文、TODO 状态。
 * 只读展示：面包屑（文件名 • 上级标题链）、原标题、优先级 / 计划 / 截止 / 标签
 *（改写这些需要重写 headline 与计划行，风险高于收益，见 tech-debt）。
 *
 * 数据流：进入时后台读取 [EXTRA_FILE] → [OrgParser] 解析 → 取 [EXTRA_ENTRY_INDEX] 条目填充；
 * 保存时按「TODO 状态 → 标题 → 正文」顺序经 [OrgEditor] 改写全文并写回同一文件，
 * 成功后 `setResult(RESULT_OK)` 让 [NotesFragment] 重新加载。
 *
 * @see intent 静态工厂（应用内启动，exported=false）。
 */
class NotesEditActivity : AppCompatActivity() {

    private lateinit var breadcrumb: TextView
    private lateinit var entryTitleView: TextView
    private lateinit var todoStateButton: MaterialButton
    private lateinit var metaSummary: TextView
    private lateinit var titleEdit: EditText
    private lateinit var bodyEdit: EditText
    private lateinit var saveButton: MaterialButton
    private lateinit var cancelButton: MaterialButton

    /** 目标文件（进入时由 [EXTRA_FILE] 还原）。 */
    private lateinit var file: File

    /** 目标条目在扁平列表中的下标（与 `OrgTreeBuilder.build` 的 index 一致）。 */
    private var entryIndex: Int = -1

    /** 页面加载时的全文快照（保存时作为改写基准）。 */
    private var currentText: String = ""

    /** 页面加载时的条目快照（保存时提供行区间与原状态）。 */
    private var entry: OrgEntry? = null

    /** TODO 状态按钮的待保存值（`null` 表示清除状态）。 */
    private var pendingState: String? = null

    /** 文件 IO 线程（所有读写都在后台执行）。 */
    private var executor: ExecutorService? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_notes_edit)

        breadcrumb = findViewById(R.id.breadcrumb)
        entryTitleView = findViewById(R.id.entryTitleView)
        todoStateButton = findViewById(R.id.todoStateButton)
        metaSummary = findViewById(R.id.metaSummary)
        titleEdit = findViewById(R.id.titleEdit)
        bodyEdit = findViewById(R.id.bodyEdit)
        saveButton = findViewById(R.id.saveButton)
        cancelButton = findViewById(R.id.cancelButton)

        val path = intent.getStringExtra(EXTRA_FILE)
        entryIndex = intent.getIntExtra(EXTRA_ENTRY_INDEX, -1)
        if (path.isNullOrEmpty() || entryIndex < 0) {
            Toast.makeText(this, getString(R.string.notes_edit_load_failed, ""), Toast.LENGTH_LONG).show()
            finish()
            return
        }
        file = File(path)

        saveButton.setOnClickListener { save() }
        cancelButton.setOnClickListener { finish() }
        todoStateButton.setOnClickListener { cycleTodoState() }
        setBusy(true)

        executor = Executors.newSingleThreadExecutor()
        load()
    }

    override fun onDestroy() {
        super.onDestroy()
        executor?.shutdownNow()
        executor = null
    }

    // ---------------------------------------------------------------- 加载

    /** 后台读取文件并解析，主线程填充界面。 */
    private fun load() {
        executor?.execute {
            val result = runCatching {
                val text = file.readText()
                text to OrgParser().parse(text).entries
            }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess { (text, entries) -> applyLoaded(text, entries) }
                    .onFailure { e ->
                        Toast.makeText(
                            this,
                            getString(R.string.notes_edit_load_failed, reasonOf(e)),
                            Toast.LENGTH_LONG,
                        ).show()
                        finish()
                    }
            }
        }
    }

    /** 主线程填充：面包屑 / 只读元信息 / 标题与正文输入框 / TODO 状态按钮。 */
    private fun applyLoaded(text: String, entries: List<OrgEntry>) {
        val target = entries.getOrNull(entryIndex)
        if (target == null) {
            Toast.makeText(
                this,
                getString(R.string.notes_edit_load_failed, getString(R.string.notes_empty)),
                Toast.LENGTH_LONG,
            ).show()
            finish()
            return
        }
        currentText = text
        entry = target
        pendingState = target.todoState

        breadcrumb.text = breadcrumbText(entries, entryIndex)
        entryTitleView.text = target.title.ifEmpty { getString(R.string.notes_no_title) }
        metaSummary.text = metaText(target)
        titleEdit.setText(target.title)
        bodyEdit.setText(target.body)
        renderTodoState()
        setBusy(false)
    }

    /** 面包屑：`文件名 • 上级标题链`；无上级时只显示文件名。 */
    private fun breadcrumbText(entries: List<OrgEntry>, index: Int): String {
        val ancestors = ancestorTitles(entries, index)
        return if (ancestors.isEmpty()) {
            file.name
        } else {
            getString(R.string.notes_edit_breadcrumb, file.name, ancestors.joinToString(SEPARATOR))
        }
    }

    /** 上级标题链（从根到直接父级）：依据 level 逐级上溯最近的更高级标题。 */
    private fun ancestorTitles(entries: List<OrgEntry>, index: Int): List<String> {
        val chain = ArrayDeque<String>()
        var level = entries[index].level
        var i = index - 1
        while (i >= 0 && level > 1) {
            val candidate = entries[i]
            if (candidate.level < level) {
                chain.addFirst(candidate.title.ifEmpty { getString(R.string.notes_no_title) })
                level = candidate.level
            }
            i--
        }
        return chain.toList()
    }

    /** 只读元信息：优先级 / 计划 / 截止 / 标签，以 ` · ` 连接；全无时显示占位文案。 */
    private fun metaText(target: OrgEntry): String {
        val parts = mutableListOf<String>()
        target.priority?.let { parts += getString(R.string.notes_meta_priority, it.toString()) }
        target.scheduled?.let { parts += getString(R.string.notes_meta_scheduled, it) }
        target.deadline?.let { parts += getString(R.string.notes_meta_deadline, it) }
        OrgEntryDisplay.tagText(target.tags)?.let { parts += it }
        return if (parts.isEmpty()) getString(R.string.notes_meta_empty) else parts.joinToString(SEPARATOR)
    }

    // ---------------------------------------------------------------- 交互

    /**
     * TODO 状态按钮循环：`null → TODO → DONE → null`（编辑页三态循环，便于清除状态）。
     *
     * 注：`GtdActivity.onEntryClicked` 是二态切换（无状态/DONE/其它 → 非 TODO 即 DONE），
     * 编辑页需要「清除状态」这一目标，故按 B4c 任务约定采用三态循环。
     */
    private fun cycleTodoState() {
        pendingState = when (pendingState) {
            null -> STATE_TODO
            STATE_DONE -> null
            else -> STATE_DONE
        }
        renderTodoState()
    }

    /** 刷新状态按钮文案：无状态时显示「设为 TODO」。 */
    private fun renderTodoState() {
        todoStateButton.text = pendingState ?: getString(R.string.notes_todo_set)
    }

    /**
     * 保存：后台按「TODO 状态 → 标题 → 正文」改写全文并写回，主线程提示结果。
     *
     * 顺序安全性：前两步只改 headline 同一行（行数不变），因此 [OrgEntry.startLine] /
     * [OrgEntry.endLine] 仍然有效；[OrgEditor.setBody] 可能增删行，故放最后执行。
     */
    private fun save() {
        val target = entry ?: return
        val newTitle = titleEdit.text.toString()
        val newBody = bodyEdit.text.toString()
        setBusy(true)
        executor?.execute {
            val result = runCatching {
                var updated = currentText
                if (pendingState != target.todoState) {
                    updated = OrgEditor.setTodoState(updated, target.startLine, pendingState)
                }
                updated = OrgEditor.setTitle(updated, target, newTitle)
                updated = OrgEditor.setBody(updated, target, newBody)
                file.writeText(updated)
            }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess {
                    Toast.makeText(this, R.string.notes_edit_saved, Toast.LENGTH_SHORT).show()
                    setResult(Activity.RESULT_OK)
                    finish()
                }.onFailure { e ->
                    setBusy(false)
                    Toast.makeText(
                        this,
                        getString(R.string.notes_edit_save_failed, reasonOf(e)),
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }
    }

    /** 忙碌状态：禁用全部可交互控件（[entry] 未加载完成时保存/状态按钮保持禁用）。 */
    private fun setBusy(busy: Boolean) {
        val ready = !busy && entry != null
        saveButton.isEnabled = ready
        todoStateButton.isEnabled = ready
        cancelButton.isEnabled = !busy
        titleEdit.isEnabled = !busy
        bodyEdit.isEnabled = !busy
    }

    /** 异常信息（优先 message，其次类名），用于 Toast 文案。 */
    private fun reasonOf(e: Throwable): String = e.message ?: e.javaClass.simpleName

    companion object {
        /** 目标文件绝对路径（String）。 */
        const val EXTRA_FILE = "extra_file"

        /** 目标条目在扁平列表中的下标（Int）。 */
        const val EXTRA_ENTRY_INDEX = "extra_entry_index"

        private const val STATE_TODO = "TODO"
        private const val STATE_DONE = "DONE"

        /** 只读元信息与面包屑的分隔符。 */
        private const val SEPARATOR = " · "

        /**
         * 构造进入编辑页的 Intent。
         *
         * @param file       目标 org 文件。
         * @param entryIndex 条目在扁平列表中的下标（与 `OrgTreeBuilder.build` 的 index 一致）。
         */
        fun intent(context: Context, file: File, entryIndex: Int): Intent =
            Intent(context, NotesEditActivity::class.java)
                .putExtra(EXTRA_FILE, file.absolutePath)
                .putExtra(EXTRA_ENTRY_INDEX, entryIndex)
    }
}
