package com.seshat.app

import android.app.Application
import androidx.appcompat.app.AppCompatDelegate
import com.seshat.app.settings.AppPreferences
import com.seshat.app.settings.AppTheme

/**
 * 应用入口：进程启动时应用持久化的主题偏好。
 *
 * 主题必须在这里设置（早于任何 Activity 创建），否则会先按默认主题渲染再切换、出现闪烁。
 */
class SeshatApp : Application() {

    override fun onCreate() {
        super.onCreate()
        applyTheme(AppPreferences.open(this).themeMode())
    }

    companion object {
        /** 把 [AppTheme] 映射为 AppCompat 的夜间模式常量并应用（Activity 会自动重建）。 */
        fun applyTheme(theme: AppTheme) {
            val mode = when (theme) {
                AppTheme.SYSTEM -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
                AppTheme.LIGHT -> AppCompatDelegate.MODE_NIGHT_NO
                AppTheme.DARK -> AppCompatDelegate.MODE_NIGHT_YES
            }
            AppCompatDelegate.setDefaultNightMode(mode)
        }
    }
}
