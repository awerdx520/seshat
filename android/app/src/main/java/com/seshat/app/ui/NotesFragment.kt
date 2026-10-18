package com.seshat.app.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import com.google.android.material.button.MaterialButton
import com.seshat.app.R
import com.seshat.app.gtd.GtdActivity

/**
 * 笔记 tab（M9.1 阶段为占位）。
 *
 * 当前只承载既有 GTD 入口；orgzly 风格的 org 列表 / 搜索 / 展开 / 编辑由 M9.3 接入，
 * 届时本 Fragment 成为 Notes 列表宿主，GTD 作为其子视图。
 */
class NotesFragment : Fragment() {

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = inflater.inflate(R.layout.fragment_notes, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.findViewById<MaterialButton>(R.id.openGtdButton).setOnClickListener {
            startActivity(GtdActivity.intent(requireContext()))
        }
    }
}
