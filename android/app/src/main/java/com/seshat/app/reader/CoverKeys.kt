package com.seshat.app.reader

import java.io.File
import java.security.MessageDigest

/**
 * 封面缓存的纯逻辑部分（无 Android 依赖，可在 JVM 单测中验证）。
 */
internal object CoverKeys {

    /** 缓存键取 SHA-256 摘要的前 [KEY_HEX_LENGTH]/2 字节。 */
    private const val KEY_HEX_LENGTH = 16

    /**
     * 缓存键：`文件名 + "\u0000" + length + "\u0000" + lastModified` 的 SHA-256 前 16 位 hex。
     *
     * 用长度与时间戳参与：文件被替换（内容变化）时键随之变化，避免旧封面残留。
     * 加 `\u0000` 分隔，防止「名字拼接数字」产生撞键（如 `a1.epub`+`23` 与 `a.epub`+`123`）。
     */
    fun keyFor(file: File): String {
        val raw = file.name + "\u0000" + file.length() + "\u0000" + file.lastModified()
        val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
        return buildString(KEY_HEX_LENGTH) {
            for (i in 0 until KEY_HEX_LENGTH / 2) {
                append("%02x".format(digest[i]))
            }
        }
    }

    /**
     * 封面占位显示的首字：取书名第一个非空白字符（转大写），空书名返回 `"?"`。
     *
     * 封面解码失败（损坏/加密/无图）时书架卡片用它代替图片。
     */
    fun initialOf(title: String): String {
        val first = title.firstOrNull { !it.isWhitespace() } ?: return "?"
        return first.uppercaseChar().toString()
    }

    /**
     * BitmapFactory 降采样系数（2 的幂，最小值 1）：
     * 取满足 `src/sample >= req`（两维同时成立）的最大 sample，即「降采样后仍不小于请求尺寸」。
     *
     * 请求尺寸非法（<=0）或源图非法/过小时返回 1（不降采样）。
     */
    fun sampleSize(srcWidth: Int, srcHeight: Int, reqWidth: Int, reqHeight: Int): Int {
        if (srcWidth <= 0 || srcHeight <= 0) return 1
        if (reqWidth <= 0 || reqHeight <= 0) return 1
        var sample = 1
        // 每轮尝试翻倍：两维都必须仍 >= 请求尺寸，否则停止
        while (srcWidth / (sample * 2) >= reqWidth && srcHeight / (sample * 2) >= reqHeight) {
            sample *= 2
        }
        return sample
    }
}
