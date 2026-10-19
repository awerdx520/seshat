package com.seshat.app.reader

import kotlinx.serialization.Serializable

/** 归一化坐标点（相对图片显示矩形的 0..1，横向/竖向/缩放无关）。 */
@Serializable
data class InkPoint(val x: Float, val y: Float)

/**
 * 笔型（M10.8）。
 *
 * - [PEN]：钢笔，实线、常规粗细（默认值，兼容 M10.5 的旧数据）；
 * - [MARKER]：马克笔，半透明、偏粗；
 * - [HIGHLIGHTER]：荧光笔，更宽、低透明度（叠加时近似高亮）。
 *
 * 只影响**渲染**（见 `InkOverlayView`），不改变归一化坐标的语义。
 */
@Serializable
enum class InkStyle { PEN, MARKER, HIGHLIGHTER }

/**
 * 一笔手写笔迹。
 *
 * @property color ARGB 颜色。
 * @property width 归一化线宽（相对显示矩形宽度，0..1），绘制时再乘像素宽度。
 * @property points 归一化点序列（至少 2 点）。
 * @property style 笔型；新字段（M10.8），默认 [InkStyle.PEN]，保证旧数据（M10.5）缺该字段时
 *   仍可反序列化，无需迁移。
 */
@Serializable
data class InkStroke(
    val color: Int,
    val width: Float,
    val points: List<InkPoint>,
    /** 笔型；旧数据（M10.5）没有该字段，反序列化时落为 [InkStyle.PEN]。 */
    val style: InkStyle = InkStyle.PEN,
)

/** 单页的笔迹集合（[page] 为 0-based，与 [PdfProgress.page] 一致）。 */
@Serializable
data class PdfInkPage(val page: Int, val strokes: List<InkStroke>)

/** 单个文档的全部手写笔迹（按页组织）。 */
@Serializable
data class PdfInkDocument(
    val documentId: String,
    val pages: List<PdfInkPage> = emptyList(),
    val updatedAt: Long = 0L,
)
