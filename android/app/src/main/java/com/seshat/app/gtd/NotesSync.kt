package com.seshat.app.gtd

import android.content.Context
import com.seshat.app.settings.AppPreferences
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SeshatConfig
import com.seshat.app.sync.WebDavClient
import java.io.File

/** org 文件上传结果。 */
sealed interface NotesSyncResult {
    /** 上传成功：服务端返回 [httpCode]，落到 [remotePath]（相对 WebDAV 根）。 */
    data class Ok(val httpCode: Int, val remotePath: String) : NotesSyncResult

    /** 服务端未配置（地址或令牌缺失）。 */
    data object NotConfigured : NotesSyncResult

    /** 上传失败（读取本地文件失败、网络异常或非 2xx）。 */
    data class Failed(val message: String) : NotesSyncResult
}

/**
 * org 文件上传（M10.6 B4d）：把本地 org 文件 `PUT` 到 WebDAV 服务端。
 *
 * 只做阻塞逻辑——不弹 Toast、不自建线程，调用方负责放到后台线程并在主线程提示结果，
 * 因此可脱离 Activity 单独复用（Notes 的 Agenda 段与 [GtdActivity] 共用同一实现，消除重复）。
 *
 * 配置读取与既有 GTD 行为一致：经 [SecurePrefs] 取 `server_url` 与 `auth_token`；
 * 异常消息与日志**不包含**令牌（[SeshatConfig.toString] 已脱敏，异常消息只含 URL 与状态码）。
 */
object NotesSync {

    /** 远端目录下的子目录（与既有 GTD 上传保持一致）。 */
    const val REMOTE_SUBDIR = "seshat"

    /** org 上传的 Content-Type（取值与既有 GTD 实现一致）。 */
    const val CONTENT_TYPE = "text/plain; charset=utf-8"

    /**
     * 把 [file] 的内容上传到 `remoteDir/`[REMOTE_SUBDIR]`/<文件名>`。
     *
     * **阻塞调用**，调用方负责后台线程。
     *
     * @param context 任意 Context（仅用于读偏好与应用私有目录，不持有）
     * @param file    待上传的本地 org 文件
     * @return [NotesSyncResult.Ok] / [NotesSyncResult.NotConfigured] / [NotesSyncResult.Failed]
     */
    fun upload(context: Context, file: File): NotesSyncResult {
        val prefs = SecurePrefs.open(context)
        val serverUrl = prefs.getString(SecurePrefs.KEY_SERVER_URL)?.trim().orEmpty()
        val token = prefs.getString(SecurePrefs.KEY_AUTH_TOKEN)?.trim().orEmpty()
        if (serverUrl.isEmpty() || token.isEmpty()) return NotesSyncResult.NotConfigured

        val bytes = try {
            file.readBytes()
        } catch (e: Exception) {
            return NotesSyncResult.Failed(e.message ?: e.javaClass.simpleName)
        }

        val remotePath = joinPath(AppPreferences.open(context).remoteDir(), "$REMOTE_SUBDIR/${file.name}")
        return try {
            val code = WebDavClient(SeshatConfig(serverUrl = serverUrl, token = token))
                .put(remotePath, bytes, CONTENT_TYPE)
            NotesSyncResult.Ok(code, remotePath)
        } catch (e: Exception) {
            NotesSyncResult.Failed(e.message ?: e.javaClass.simpleName)
        }
    }

    /** 拼接远程目录与相对路径（抽自 `GtdActivity.joinPath`，去掉重复斜杠）。 */
    fun joinPath(remoteDir: String, relative: String): String {
        val left = remoteDir.trim().trim('/')
        val right = relative.trim().trim('/')
        return when {
            left.isEmpty() -> right
            right.isEmpty() -> left
            else -> "$left/$right"
        }
    }
}
