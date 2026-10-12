package com.seshat.app.importer

/**
 * 书籍文件类型。
 *
 * @property extensions      该类型对应的文件扩展名（小写，不含前导点）。
 * @property needsConversion 导入前是否需要格式转换；`true` 表示当前 Android 端无法直接打开，
 *                           需先在桌面端 / 服务端转成 EPUB 后再导入。
 */
enum class BookType(
    val extensions: List<String>,
    val needsConversion: Boolean,
) {
    /** EPUB 电子书，可直接导入阅读库。 */
    EPUB(listOf("epub"), needsConversion = false),

    /** Kindle 系格式（mobi / azw / azw3），需先转换为 EPUB 才能阅读。 */
    MOBI(listOf("mobi", "azw", "azw3"), needsConversion = true),

    /** PDF 文档，可直接导入阅读库。 */
    PDF(listOf("pdf"), needsConversion = false),

    /** 无法识别的格式。 */
    UNKNOWN(emptyList(), needsConversion = false),
}

/**
 * 图书导入结果。
 *
 * @property success      是否已成功导入阅读库（文件复制完成）。需转换 / 不支持 / 出错均为 `false`。
 * @property fileName     原始文件名（用户所选文件的展示名）。
 * @property importedPath 导入到应用私有库后的绝对路径；未导入时为 `null`。
 * @property type         识别出的文件类型。
 * @property message      面向用户的提示信息（成功摘要或引导 / 错误文案）。
 */
data class ImportResult(
    val success: Boolean,
    val fileName: String,
    val importedPath: String?,
    val type: BookType,
    val message: String,
) {
    companion object {
        /** 已成功导入阅读库。 */
        fun imported(fileName: String, importedPath: String, type: BookType, message: String): ImportResult =
            ImportResult(
                success = true,
                fileName = fileName,
                importedPath = importedPath,
                type = type,
                message = message,
            )

        /** 识别为需转换的格式，尚未导入。 */
        fun needsConversion(fileName: String, type: BookType, message: String): ImportResult =
            ImportResult(
                success = false,
                fileName = fileName,
                importedPath = null,
                type = type,
                message = message,
            )

        /** 不支持的格式。 */
        fun unsupported(fileName: String, type: BookType, message: String): ImportResult =
            ImportResult(
                success = false,
                fileName = fileName,
                importedPath = null,
                type = type,
                message = message,
            )

        /** 导入过程出错（读取 / 写入失败等）。 */
        fun failed(fileName: String, type: BookType, message: String): ImportResult =
            ImportResult(
                success = false,
                fileName = fileName,
                importedPath = null,
                type = type,
                message = message,
            )
    }
}
