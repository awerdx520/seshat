package com.seshat.app.notes

import android.content.ContentResolver
import java.io.File

/**
 * 按 [NoteRef] 读文本；失败返回 `null`（不抛）。
 *
 * 与 [NoteScanner] 内部的 `readTextOrEmpty` 不同：这里失败必须能被调用方区分出来
 * （UI 需要提示「无法读取」），所以返回 `null` 而不是空串。
 *
 * 编码行为：本地文件走 [File.readText]，SAF 走 `decodeToString()`，两者对非法
 * UTF-8 字节都做替换（U+FFFD）而不是抛异常，因此「读取成功但内容为乱码」不会被
 * 当成失败；只有 IO 失败（文件不存在、授权失效、流为空等）才返回 `null`。
 */
internal object NoteReader {

    /**
     * 读取 [ref] 指向的文本。
     *
     * @param ref 本地文件或 SAF 文档。
     * @param resolver SAF 文档必需；读本地文件时可为 `null`。
     * @return 文件原文（可能为空串）；读取失败或 [NoteRef.SafDocument] 缺 [resolver] 时返回 `null`。
     */
    fun read(ref: NoteRef, resolver: ContentResolver? = null): String? = when (ref) {
        is NoteRef.LocalFile -> runCatching { ref.file.readText() }.getOrNull()
        is NoteRef.SafDocument -> resolver?.let { contentResolver ->
            runCatching {
                contentResolver.openInputStream(ref.uri)?.use { it.readBytes().decodeToString() }
            }.getOrNull()
        }
    }
}
