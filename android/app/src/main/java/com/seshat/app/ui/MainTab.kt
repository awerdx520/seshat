package com.seshat.app.ui

/**
 * 底部导航的两个 tab。
 *
 * [ordinal] 同时用作内部稳定索引，用于进程重建后从 `savedInstanceState` 恢复当前 tab。
 */
enum class MainTab {
    NOTES,
    READER,
    ;

    companion object {
        /** 从保存的索引恢复 tab；索引缺失或越界时回退到 [NOTES]。 */
        fun restore(savedIndex: Int?): MainTab =
            values().firstOrNull { it.ordinal == savedIndex } ?: NOTES

        /** tab 的稳定索引（用于 `onSaveInstanceState`）。 */
        fun indexOf(tab: MainTab): Int = tab.ordinal
    }
}
