package com.seshat.app

import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.seshat.app.settings.SettingsActivity
import com.seshat.app.ui.MainTab
import com.seshat.app.ui.NotesFragment
import com.seshat.app.ui.ReaderFragment

/**
 * 应用入口 Activity（M9.1 三区骨架）。
 *
 * 结构：顶部工具栏（[MaterialToolbar]）+ 中部内容区（FrameLayout 容器）+
 * 底部双 tab（[BottomNavigationView]）。两个 tab 分别承载 [NotesFragment] 与
 * [ReaderFragment]，用 show/hide 切换以保留各自状态；epub/pdf 阅读器仍是独立全屏
 * Activity，由 [ReaderFragment] 的入口启动。
 *
 * tab 选择在 `onSaveInstanceState` 中持久化，进程重建后经 [MainTab.restore] 恢复。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var toolbar: MaterialToolbar
    private lateinit var bottomNav: BottomNavigationView
    private var selectedTab: MainTab = MainTab.NOTES

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        toolbar = findViewById(R.id.mainToolbar)
        bottomNav = findViewById(R.id.bottomNav)
        setSupportActionBar(toolbar)

        selectedTab = MainTab.restore(savedInstanceState?.getInt(STATE_TAB))
        ensureFragments()
        // 先同步选中项（此时尚未挂监听，不会触发切换），再挂监听。
        bottomNav.selectedItemId = menuIdOf(selectedTab)
        bottomNav.setOnItemSelectedListener { item -> onTabSelected(item.itemId) }
        showTab(selectedTab)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(STATE_TAB, MainTab.indexOf(selectedTab))
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.menu_main_toolbar, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.action_settings -> {
            startActivity(SettingsActivity.intent(this))
            true
        }

        else -> super.onOptionsItemSelected(item)
    }

    /** 首次创建时添加两个 Fragment；进程重建后复用 FragmentManager 已恢复的实例。 */
    private fun ensureFragments() {
        val fm = supportFragmentManager
        if (fm.findFragmentByTag(TAG_NOTES) != null) return
        // 用 commitNow 保证后续 findFragmentByTag 能立即取到实例（onCreate 内调用是安全的）。
        fm.beginTransaction()
            .add(R.id.fragmentContainer, NotesFragment(), TAG_NOTES)
            .add(R.id.fragmentContainer, ReaderFragment(), TAG_READER)
            .commitNow()
    }

    /** 按 tab 显示对应 Fragment 并更新标题。 */
    private fun showTab(tab: MainTab) {
        val fm = supportFragmentManager
        val notes = fm.findFragmentByTag(TAG_NOTES)
        val reader = fm.findFragmentByTag(TAG_READER)
        if (notes == null || reader == null) return
        fm.beginTransaction().apply {
            if (tab == MainTab.NOTES) {
                show(notes)
                hide(reader)
            } else {
                show(reader)
                hide(notes)
            }
            commitNow()
        }
        selectedTab = tab
        supportActionBar?.title = getString(titleOf(tab))
    }

    private fun onTabSelected(menuId: Int): Boolean {
        val tab = when (menuId) {
            R.id.nav_notes -> MainTab.NOTES
            R.id.nav_reader -> MainTab.READER
            else -> return false
        }
        showTab(tab)
        return true
    }

    private fun menuIdOf(tab: MainTab): Int = when (tab) {
        MainTab.NOTES -> R.id.nav_notes
        MainTab.READER -> R.id.nav_reader
    }

    private fun titleOf(tab: MainTab): Int = when (tab) {
        MainTab.NOTES -> R.string.tab_notes
        MainTab.READER -> R.string.tab_reader
    }

    private companion object {
        /** `savedInstanceState` 中保存的 tab 索引键。 */
        const val STATE_TAB = "state_selected_tab"

        const val TAG_NOTES = "tag_notes"
        const val TAG_READER = "tag_reader"
    }
}
