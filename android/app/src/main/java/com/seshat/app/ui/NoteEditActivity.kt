package com.seshat.app.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.EditText
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import com.seshat.app.R
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 笔记源码编辑页（M10.7 T6b）：纯文本编辑 org / markdown 源文件并写回。
 *
 * 与 [NotesEditActivity] 的区别：这里不解析结构，直接编辑整份源码（适合改标签、
 * 属性抽屉、表格等结构化编辑页覆盖不到的内容）。
 *
 * 行尾风格保留：加载时记录原文是否 CRLF；若原文是 CRLF 而用户改完的文本只剩 `\n`
 * （Android 的 EditText 可能把粘贴/换行统一成 `\n`），写回前统一恢复为 CRLF，
 * 避免整文件行尾被改写导致 git diff 全红。
 *
 * 数据流：后台 `readText()` → 主线程 `setText`（光标置 0）→ 保存时后台 `writeText()`
 * → `setResult(RESULT_OK)` + `finish()`，由 [NoteViewActivity] 重新渲染。
 *
 * @see intent 静态工厂（应用内启动，exported=false）。
 */
class NoteEditActivity : AppCompatActivity() {

    private lateinit var sourceEdit: EditText
    private lateinit var saveButton: MaterialButton
    private lateinit var cancelButton: MaterialButton

    /** 目标文件（进入时由 [EXTRA_PATH] 还原）。 */
    private lateinit var file: File

    /** 原文件是否使用 CRLF 行尾（保存时据此恢复）。 */
    private var usesCrlf: Boolean = false

    /** 原文是否已加载完成（未完成时禁用保存，避免空内容覆盖文件）。 */
    private var loaded: Boolean = false

    /** 文件 IO 线程（读写都在后台执行）。 */
    private var executor: ExecutorService? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_note_edit)

        sourceEdit = findViewById(R.id.noteSourceEdit)
        saveButton = findViewById(R.id.saveButton)
        cancelButton = findViewById(R.id.cancelButton)

        val path = intent.getStringExtra(EXTRA_PATH)
        if (path.isNullOrEmpty()) {
            Toast.makeText(this, R.string.note_load_failed, Toast.LENGTH_LONG).show()
            finish()
            return
        }
        file = File(path)
        title = file.name

        saveButton.setOnClickListener { save() }
        cancelButton.setOnClickListener { finish() }
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

    /** 后台读文件，主线程填入编辑框（光标置 0，避免长文档开局停在文末）。 */
    private fun load() {
        executor?.execute {
            val result = runCatching { file.readText() }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess { text ->
                    usesCrlf = text.contains("\r\n")
                    sourceEdit.setText(text)
                    sourceEdit.setSelection(0)
                    loaded = true
                    setBusy(false)
                }.onFailure {
                    // 读取失败：文案不带异常信息（读失败原因对用户无意义）
                    Toast.makeText(this, R.string.note_load_failed, Toast.LENGTH_LONG).show()
                    finish()
                }
            }
        }
    }

    // ---------------------------------------------------------------- 保存

    /**
     * 保存：后台写回（含行尾恢复），成功才 `setResult(RESULT_OK)` 并退出；
     * 失败只 Toast 不退出，避免用户输入丢失。
     */
    private fun save() {
        if (!loaded) return
        val content = restoreLineEndings(sourceEdit.text.toString())
        setBusy(true)
        executor?.execute {
            val result = runCatching { file.writeText(content) }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess {
                    setResult(Activity.RESULT_OK)
                    finish()
                }.onFailure { e ->
                    setBusy(false)
                    Toast.makeText(
                        this,
                        getString(R.string.note_save_failed, reasonOf(e)),
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }
    }

    /**
     * 行尾恢复：原文是 CRLF 且当前文本不含 `\r\n` 时，把 `\n` 统一替换为 `\r\n`。
     *
     * 当前文本已含 `\r\n` 时原样写回（混合行尾也保持用户输入，不做「统一化」）。
     */
    private fun restoreLineEndings(content: String): String {
        if (!usesCrlf) return content
        if (content.contains("\r\n")) return content
        return content.replace("\n", "\r\n")
    }

    /** 忙碌状态：加载中/保存中禁用保存按钮（取消始终可用）。 */
    private fun setBusy(busy: Boolean) {
        saveButton.isEnabled = !busy && loaded
        sourceEdit.isEnabled = !busy
        cancelButton.isEnabled = true
    }

    /** 异常信息（优先 message，其次类名），用于 Toast 文案。 */
    private fun reasonOf(e: Throwable): String = e.message ?: e.javaClass.simpleName

    companion object {
        /** 目标文件绝对路径（String）。 */
        const val EXTRA_PATH = "extra_note_edit_path"

        /** 构造进入源码编辑页的 Intent。 */
        fun intent(context: Context, file: File): Intent =
            Intent(context, NoteEditActivity::class.java)
                .putExtra(EXTRA_PATH, file.absolutePath)
    }
}
