package com.seshat.app.reader

import kotlinx.serialization.Serializable

/** 归一化坐标点（相对图片显示矩形的 0..1，横向/竖向/缩放无关）。 */
@Serializable
data class InkPoint(val x: Float, val y: Float)

/**
 * 一笔手写笔迹。
 *
 * @property color ARGB 颜色。
 * @property width 归一化线宽（相对显示矩形宽度，0..1），绘制时再乘像素宽度。
 * @property points 归一化点序列（至少 2 点）。
 */
@Serializable
data class InkStroke(val color: Int, val width: Float, val points: List<InkPoint>)

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
