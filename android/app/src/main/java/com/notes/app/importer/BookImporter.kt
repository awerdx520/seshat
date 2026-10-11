package com.notes.app.importer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.notes.app.R
import java.io.File
import java.io.IOException

/**
 * 图书导入器（M3.5）。
 *
 * 职责：
 * 1. 构造基于系统 Storage Access Framework 的文件选择 Intent（[Intent.ACTION_OPEN_DOCUMENT]）；
 * 2. 按扩展名识别文件类型（epub / mobi / pdf）；
 * 3. 将可直接阅读的文件复制到应用私有阅读库目录 `filesDir/books/`；
 * 4. 返回 [ImportResult]（含成功标志、原文件名、导入路径、类型与用户提示）。
 *
 * 说明：MOBI（mobi / azw / azw3）无法在 Android 端转换，本类只做识别与引导，不做转换。
 *
 * @property context 应用上下文（用于解析 ContentResolver 与私有目录）。
 */
class BookImporter(private val context: Context) {

    /**
     * 导入用户通过 SAF 选中的文件。
     *
     * @param uri 由 [Intent.ACTION_OPEN_DOCUMENT] 返回的文档 URI。
     * @return 导入结果；需转换 / 不支持 / 出错时 `success = false` 并携带引导文案。
     */
    fun import(uri: Uri): ImportResult {
        val fileName = queryDisplayName(uri) ?: DEFAULT_FILE_NAME
        val type = detectType(fileName)
        return when {
            type == BookType.UNKNOWN ->
                ImportResult.unsupported(
                    fileName = fileName,
                    type = type,
                    message = context.getString(R.string.import_unsupported_format, fileName),
                )

            type.needsConversion ->
                ImportResult.needsConversion(
                    fileName = fileName,
                    type = type,
                    message = context.getString(R.string.import_needs_conversion_format, fileName),
                )

            else -> {
                val target = try {
                    copyToLibrary(uri, fileName)
                } catch (e: IOException) {
                    return ImportResult.failed(
                        fileName = fileName,
                        type = type,
                        message = context.getString(R.string.import_failed_format, fileName),
                    )
                }
                ImportResult.imported(
                    fileName = fileName,
                    importedPath = target.absolutePath,
                    type = type,
                    message = context.getString(R.string.import_success_format, fileName),
                )
            }
        }
    }

    /** 应用私有阅读库目录 `filesDir/books/`，不存在时创建。 */
    fun booksDir(): File = File(context.filesDir, BOOKS_DIR).apply { if (!exists()) mkdirs() }

    /**
     * 把选中文件复制到阅读库目录，文件名冲突时自动追加 `-1`、`-2` 等序号。
     *
     * @return 复制后的目标文件。
     * @throws IOException 打开输入流或写入失败时抛出。
     */
    fun copyToLibrary(uri: Uri, fileName: String): File {
        val dir = booksDir()
        val target = uniqueFile(dir, sanitizeFileName(fileName))
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IOException("无法打开所选文件的输入流: $uri")
        input.use { source ->
            target.outputStream().use { sink -> source.copyTo(sink) }
        }
        return target
    }

    /**
     * 构造系统文件选择 Intent（Storage Access Framework，[Intent.ACTION_OPEN_DOCUMENT]）。
     *
     * 只做宽松的通配 MIME 过滤（不做具体类型限制），实际类型由 [detectType] 按扩展名判定，
     * 避免部分设备未注册 epub / mobi MIME 导致文件不可选。
     */
    fun openDocumentIntent(): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }

    /** 通过 ContentResolver 查询所选文件的展示名。 */
    private fun queryDisplayName(uri: Uri): String? {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) return cursor.getString(index)
                }
            }
        return uri.lastPathSegment
    }

    companion object {
        /** 阅读库子目录名。 */
        const val BOOKS_DIR = "books"

        /** 无法取得文件名时的占位名。 */
        const val DEFAULT_FILE_NAME = "unknown"

        /**
         * 按扩展名识别文件类型（纯函数，可脱离 Android 上下文做单元测试）。
         *
         * 扩展名大小写不敏感；无扩展名或未收录的扩展名返回 [BookType.UNKNOWN]。
         */
        fun detectType(fileName: String): BookType {
            val ext = fileName.substringAfterLast('.', "").lowercase()
            if (ext.isEmpty()) return BookType.UNKNOWN
            return BookType.entries.firstOrNull { ext in it.extensions } ?: BookType.UNKNOWN
        }

        /** 去掉路径分隔符，仅保留安全的文件名部分。 */
        internal fun sanitizeFileName(fileName: String): String {
            val base = fileName.substringAfterLast('/').substringAfterLast('\\').trim()
            return base.ifEmpty { DEFAULT_FILE_NAME }
        }

        /** 在目录内为 [fileName] 生成不冲突的文件对象。 */
        internal fun uniqueFile(dir: File, fileName: String): File {
            var candidate = File(dir, fileName)
            if (!candidate.exists()) return candidate
            val base = candidate.nameWithoutExtension.ifEmpty { DEFAULT_FILE_NAME }
            val ext = candidate.extension
            var index = 1
            while (candidate.exists()) {
                val name = if (ext.isEmpty()) "$base-$index" else "$base-$index.$ext"
                candidate = File(dir, name)
                index++
            }
            return candidate
        }
    }
}
