//
// Copyright (C) 2025-2026  Divya Ranjan Pattanaik
// Copyright (C) 2025-2026  Tushar
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#include "render-core.h"
#include "elisp-helpers.h"
#include "emacs-module.h"
#include <ctype.h>
#include <limits.h>
#include <math.h>
#include "mupdf-helpers.h"
#include "render-theme.h"

int plugin_is_GPL_compatible;

/* Forward declaration.  `extract_float_coerced' is defined further down
 * in this file, next to the decoration entry points that first needed it,
 * but `search_page_limit' uses it as well.  Declaring it here keeps the
 * search entry point next to its geometric sibling instead of forcing one
 * of them to move. */
static bool
extract_float_coerced(emacs_env *env, emacs_value value, float *out);

/* Forward declaration, same reason: `resolve_page_arg' is defined next to
 * the decoration entry points further down, but the search entry point
 * needs it as well — every page-addressed function must read PAGE the same
 * way (1-based, validated, decremented once). */
static bool
resolve_page_arg(emacs_env *env, emacs_value value, int pagecount, int *out);

pthread_mutex_t g_mupdf_mutex[FZ_LOCK_MAX];

/* Default decoration style: a yellow wash at ~35% opacity, i.e. exactly
 * what the 5-argument `--add-highlight' has always painted.  Decorations
 * are composited onto the page pixmap *after* the optional luminance
 * inversion, so one colour works on light and dark pages alike. */
#define DECORATION_DEFAULT_COLOR_R 1.0f
#define DECORATION_DEFAULT_COLOR_G 0.85f
#define DECORATION_DEFAULT_COLOR_B 0.0f
#define DECORATION_DEFAULT_ALPHA 0.35f

/* Hard ceilings on what one document may accumulate.  They exist so that
 * a hostile or corrupted annotation source cannot exhaust memory: the
 * table is fed in bulk from Elisp, one decoration per call, and nothing
 * upstream bounds the number of calls.  Both limits are silent — a
 * rejected entry is simply not stored, because aborting a bulk feed over
 * one bogus annotation would also lose all the valid ones.
 *
 * DECORATION_MAX_COUNT keeps the historical highlight ceiling of 100000
 * entries per document; adding strokes does not raise it. */
#define DECORATION_MAX_COUNT 100000	   /* entries per document */
#define DECORATION_MAX_ABS_COORD 1000000.0f /* PDF points, per corner */

/* Upper bound on how many distinct rect styles are painted as one path.
 * Grouping exists so that overlapping rects of the *same* colour keep a
 * uniform alpha instead of stacking up.  Capping the group count keeps
 * the painter's work bounded when a hostile caller feeds thousands of
 * distinct colours: styles beyond the cap are still painted, one fill
 * each, they simply do not get merged with later rects. */
#define DECORATION_MAX_STYLE_GROUPS 64

/* Ceiling on the number of quads `--rects-in-rect' will collect for one
 * call.  Same rationale as DECORATION_MAX_COUNT: the result travels to
 * Elisp as a list, so it must not be unbounded. */
#define RECTS_IN_RECT_MAX_COUNT 100000

/* Ceiling on the number of *lines* `--lines-in-rect' will collect for one
 * call.  Deliberately far below RECTS_IN_RECT_MAX_COUNT: that function
 * reports one rectangle per character (thousands per page), while this one
 * reports one rectangle per whole text line, so a page holds tens of lines,
 * not thousands.  4096 lines is more than an entire book page can carry and
 * still bounds the Elisp list handed back.  Exceeding it TRUNCATES the
 * result (the first 4096 lines are returned, in reading order) instead of
 * throwing, exactly like the quad collector above — a partial answer is
 * useful for a highlight, a failed call is not. */
#define LINES_IN_RECT_MAX_COUNT 4096

/**
 * Convert an Emacs-facing rectangle into ordered MuPDF page space.
 *
 * The API contract (docs/api.md) says rect corners are page coordinates
 * (PDF points) whose origin is the top-left corner of the page with the
 * y axis growing downwards.  MuPDF's page space — the space of
 * `fz_bound_page', of display lists and of structured-text quads — uses
 * that same orientation, and `fz_transform_page' maps it onto the (also
 * y-down) pixmap space.  No axis flip is therefore needed: painting a
 * highlight with the very ctm that rasterized the page aligns it by
 * construction.  This helper only rejects non-finite corners and
 * normalises the corner order, and it is shared by
 * `emacs_text_in_rect' and `draw_page_thread' so the two entry points
 * cannot drift apart.
 *
 * @param x0, y0, x1, y1  Corners as received from Elisp.
 * @param out             Receives the normalised rectangle on success.
 * Return:                true when the rectangle is usable.
 */

static bool
rect_to_page_space(float x0, float y0, float x1, float y1, fz_rect *out)
{
	if (!out)
		return false;

	/* Reject non-finite corners first: fz_is_valid_rect() only compares
	 * coordinates and treats NaN comparisons as false, so an infinity
	 * would otherwise be accepted (see <mupdf/fitz/geometry.h>). */
	if (!isfinite(x0) || !isfinite(y0) || !isfinite(x1) || !isfinite(y1))
		return false;

	/* Bound the absolute magnitude as well.  Non-finite values are gone
	 * at this point, but a finite-yet-absurd corner (1e30) would still
	 * reach MuPDF, whose internal clipping for such rectangles is not
	 * guaranteed.  No real page comes close: even an A0 poster is about
	 * 3400 points across, so 1e6 leaves three orders of magnitude of
	 * headroom while keeping every intermediate product in float range. */
	if (fabsf(x0) > DECORATION_MAX_ABS_COORD
	    || fabsf(y0) > DECORATION_MAX_ABS_COORD
	    || fabsf(x1) > DECORATION_MAX_ABS_COORD
	    || fabsf(y1) > DECORATION_MAX_ABS_COORD)
		return false;

	/* Normalise the diagonal *before* validating it: callers may hand us
	 * the bottom-right corner first, and fz_is_valid_rect() rejects such
	 * a pair (it requires x0 <= x1 && y0 <= y1 — see
	 * <mupdf/fitz/geometry.h>), which would make a reversed rule or a
	 * reversed annotation rect silently unusable.  Zero-area rects stay
	 * "valid" here on purpose; each caller drops them separately. */
	fz_rect corners;
	corners.x0 = x0 < x1 ? x0 : x1;
	corners.y0 = y0 < y1 ? y0 : y1;
	corners.x1 = x0 < x1 ? x1 : x0;
	corners.y1 = y0 < y1 ? y1 : y0;

	if (!fz_is_valid_rect(corners))
		return false;

	out->x0 = corners.x0;
	out->y0 = corners.y0;
	out->x1 = corners.x1;
	out->y1 = corners.y1;

	return true;
}

/**
 * free_decoration_table - Release a run of decorations and the array.
 *
 * A Decoration may own a heap block (`pts', for DECORATION_KIND_STROKE),
 * so dropping the array with a bare free() would leak every stroke.  This
 * is the only sanctioned release path and it is used by both owners: the
 * DocState table (via emacs_clear_highlights / free_doc_state) and the
 * per-job snapshot (via free_draw_thread_args).
 *
 * Truncating COUNT is safe: entries past it are not inspected, and the
 * caller is always the owner of the exact count it stored.
 *
 * @param deco   Decoration array, may be NULL.
 * @param count  Number of initialised entries in DECO.
 */

void
free_decoration_table(Decoration *deco, int count)
{
	if (!deco)
		return;

	for (int i = 0; i < count; ++i)
		free(deco[i].pts);

	free(deco);
}

/**
 * Load and cache the display list for a page.
 *
 * If the page is empty, sets its status to rendering, loads the page,
 * computes its bounding box, and generates a display list. Uses a
 * cloned MuPDF context for thread safety.
 *
 */

int
load_page_dl(DocState *state, DocPage *dp)
{
	if (!state || !dp)
		return EXIT_FAILURE;
	if (dp->ready)
		return EXIT_SUCCESS;

	pthread_mutex_lock(&dp->mutex);

	/* Another thread may have loaded it while we waited */
	if (dp->ready)
		{
			pthread_mutex_unlock(&dp->mutex);
			return EXIT_SUCCESS;
		}

	fz_context *ctx = fz_clone_context(state->ctx);
	if (!ctx)
		{
			pthread_mutex_unlock(&dp->mutex);
			return EXIT_FAILURE;
		}

	/* volatile：见 MuPDF context.h 的说明——fz_try 基于 setjmp/longjmp，
	 * 在 fz_try 内赋值、在 fz_always/fz_catch（或块之后）读取的局部变量必须
	 * 声明为 volatile，否则 longjmp 恢复寄存器后读到的是调用 setjmp 时的旧值
	 * （未定义值）。`loaded_page' 在 fz_try 内赋值、在 fz_always 内 drop，
	 * 若不加 volatile，-O2 下可能 drop 到 NULL（泄漏）或旧值（重复释放）。 */
	fz_page *volatile loaded_page = NULL;
	volatile bool success = false;

	fz_try(ctx)
		{
			loaded_page = fz_load_page(ctx, state->doc, dp->page_num);
			dp->bbox = fz_bound_page(ctx, loaded_page);
			dp->display_list =
				fz_new_display_list_from_page(ctx, loaded_page);
			dp->ready = true;
			success = true;
		}
	fz_always(ctx)
		{
			if (loaded_page)
				fz_drop_page(ctx, loaded_page);
		}
	fz_catch(ctx)
		{
			success = false;
		}

	fz_drop_context(ctx);
	pthread_mutex_unlock(&dp->mutex);

	return success ? EXIT_SUCCESS : EXIT_FAILURE;
}

/**
 * render_page_to_buffer - Rasterize one page and export it as BGRA bytes.
 *
 * This is the rendering core that used to live inline in
 * `draw_page_thread'.  It was extracted unchanged so that a second,
 * purely additive entry point (`emacs_page_image_spec') can reuse it
 * without duplicating the painter: the ordering below — rasterize,
 * optional pixel transform (tint, or luminance invert + gamma),
 * decoration wash, BGRA export — is load bearing and must not be
 * rearranged.
 *
 * Every render parameter is an argument, so the caller decides them.
 * The document-level state that is deliberately still read from DOC_STATE is
 * `frame_scale', because it is a property of the frame rather than of a
 * page.  Dark mode is deliberately *not* document state:
 * whether it is on and which colours it uses come from the process-wide
 * preference exposed by render-theme.c (`theme_dark_enabled' /
 * `theme_tint_set' / `theme_tint_colors'), so reloading a document or
 * opening a second one keeps the user's chosen theme.  Those readers run
 * on whichever thread rasterizes the page -- possibly a worker -- so
 * render-theme.c stores them in atomics and hands the two endpoints out
 * as one pair (`theme_tint_colors'), never as two independent loads.
 *
 * The rasterization runs on a cloned MuPDF context (shared lock set), so
 * it is safe to call from the Emacs main thread while worker jobs are in
 * flight.
 *
 * @param doc_state  Document the page belongs to.
 * @param dp         Page to render; its display list must be loaded.
 * @param resolution Resolution in dpi (72 dpi == scale 1.0).
 * @param rotate     Rotation in degrees, 0 / 90 / 180 / 270.
 * @param deco       Decoration snapshot to paint over the page, may be NULL.
 * @param deco_count Number of entries in DECO.
 * @param out_w        Receives the image width in logical (unscaled) pixels.
 * @param out_h        Receives the image height in logical (unscaled) pixels.
 * @param out_data_w   Receives the pixmap width in device pixels.
 * @param out_data_h   Receives the pixmap height in device pixels.
 * @param out_data     Receives a malloc'ed BGRA byte block owned by the caller.
 * @param out_size     Receives the size of OUT_DATA in bytes (data_w*data_h*4).
 * Return:             true on success; false leaves every OUT_* zeroed/NULL.
 */

static bool
render_page_to_buffer(DocState *doc_state, DocPage *dp, float resolution,
		      int rotate, Decoration *deco, int deco_count, int *out_w,
		      int *out_h, int *out_data_w, int *out_data_h,
		      unsigned char **out_data, size_t *out_size)
{
	if (!doc_state || !dp || !dp->display_list || !out_w || !out_h
	    || !out_data_w || !out_data_h || !out_data || !out_size)
		return false;

	*out_w = 0;
	*out_h = 0;
	*out_data_w = 0;
	*out_data_h = 0;
	*out_data = NULL;
	*out_size = 0;

	fz_context *ctx = fz_clone_context(doc_state->ctx);

	if (!ctx)
		return false;

	fz_matrix ctm = fz_transform_page(dp->bbox, resolution, rotate);
	/* volatile：`pixmap' 在 fz_try 内赋值、在 fz_always 内 drop，
	 * `local_bgra' 在 fz_try 内赋值、在块之后（含失败清理路径）被 free，
	 * 两者都跨 setjmp/longjmp 边界，故必须 volatile（同 MuPDF context.h
	 * 对 fz_var 的说明）。局部整型尺寸只在块后做守卫判断，且失败路径由
	 * render_ok 短路，不参与指针释放，故保持非 volatile。 */
	fz_pixmap *volatile pixmap = NULL;
	int local_imgw = 0;
	int local_imgh = 0;
	int local_data_w = 0;
	int local_data_h = 0;
	unsigned char *volatile local_bgra = NULL;
	size_t local_size = 0;

	volatile bool render_ok = false;
	float frame_scale = doc_state->frame_scale;
	/* Read the process-wide dark-mode preference once, so the two
	 * branches below can never disagree about whether it is on. */
	bool dark_on = theme_dark_enabled();

	/* `frame_scale' 是逻辑像素的除数，必须夹在合理区间：非正值按 1.0
	 * 处理，极小的正值（< 0.01）同理——否则 `width / frame_scale'
	 * 会放大到 int 溢出，逻辑尺寸变成无意义的巨大值。 */
	if (!(frame_scale > 0.01f))
		frame_scale = 1.0f;

	fz_try(ctx)
		{
			/* colorspace 用 fz_device_bgr：canvas 缓冲是 ARGB32
			 * （小端字节序 B,G,R,A），BGR 设备产出的通道序天然
			 * 吻合，导出时零重排。
			 *
			 * alpha 保持 0（不分配 A 通道）：MuPDF 会把页面直接
			 * 合成到不透明背景上，初始像素为 0（黑），与旧 PNM
			 * 路径的语义完全一致。若改成 alpha=1 则得到预乘
			 * alpha 像素、且 MuPDF 无反预乘 API，颜色会偏。 */
			pixmap = fz_new_pixmap_from_display_list(ctx, dp->display_list,
								 ctm, fz_device_bgr(ctx), 0);

			/* Dark mode has exactly two pixel transforms.
			 * Without a tint it is the historical full-range
			 * inversion plus gamma, which preserves the
			 * chrominance of coloured artwork; with one, the
			 * luminance is mapped onto the two colours the
			 * caller supplied, which is what makes a
			 * lower-contrast preset possible (and what flattens
			 * colour, by construction).  `graphite' takes the
			 * second branch, so it stays bit-for-bit what dark
			 * mode rendered before presets existed. */
			if (dark_on && theme_tint_set())
				{
					unsigned tint_bg;
					unsigned tint_fg;

					/* 一次 acquire 读出整对端点色：bg/fg
					 * 打包成单个 64 位原子量，避免切预设
					 * 落在两次独立 load 之间时出现「bg
					 * 来自旧档、fg 来自新档」的撕裂。 */
					theme_tint_colors(&tint_bg, &tint_fg);

					/* fz_tint_pixmap 的形参顺序是
					 * (black, white)：第一个参数是「黑」
					 * 映射到的颜色，第二个是「白」映射到
					 * 的颜色。页面栅格化后是白底黑字，暗
					 * 色模式要「白底→BG、黑字→FG」，故此
					 * 处必须反着传：先 FG（黑字去处）后
					 * BG（白底去处）。与 Elisp API 的
					 * `--doc-tint BG FG' 顺序相反，是为
					 * 了让 elisp 侧与文档保持「背景在前」
					 * 的自然语序。 */
					fz_tint_pixmap(ctx, pixmap, (int) tint_fg,
						       (int) tint_bg);
				}
			else if (dark_on)
				{
					fz_invert_pixmap_luminance(ctx, pixmap);
					fz_gamma_pixmap(ctx, pixmap, 1 / 1.4f);
				}

			/* Wash this page's decorations over the
			 * rasterized page.  The order matters: the
			 * pixel transform above must already be done,
			 * otherwise the decoration colours would be
			 * tinted or inverted too, and
			 * the PNM encoding below must see the result.
			 * Rectangles are grouped by style and each group is
			 * filled once, so overlapping highlights keep a
			 * uniform alpha instead of stacking up. */
			if (deco_count > 0)
				{
					/* volatile：`dev' 与 `path' 都在
					 * fz_try 内赋值、在 fz_always 内
					 * drop（path 还会在循环里反复重建），
					 * 跨 setjmp/longjmp 边界，必须
					 * volatile，否则 -O2 下 longjmp
					 * 后读到调用 setjmp 时的旧值
					 * （-Wclobbered 报的正是这两条）。 */
					fz_device *volatile dev = NULL;
					fz_path *volatile path = NULL;

					/* One flag per decoration: a rect is
					 * emitted by exactly one style group,
					 * and styles beyond the group cap are
					 * filled individually (see below).  A
					 * failed allocation simply leaves every
					 * flag false, which degrades to
					 * "paint each rect on its own". */
					bool *assigned
						= calloc((size_t)deco_count,
							 sizeof(bool));

					fz_try(ctx)
						{
							dev = fz_new_draw_device(
								ctx, ctm, pixmap);

							/* Discover the distinct
							 * rect styles present. */
							float groups[DECORATION_MAX_STYLE_GROUPS]
								   [4];
							int group_count = 0;

							if (assigned)
								{
									for (int i = 0;
									     i
									     < deco_count;
									     ++i)
										{
											if (deco[i].kind
											    != DECORATION_KIND_RECT)
												continue;

											int g;
											for (g = 0;
											     g < group_count;
											     ++g)
												{
													if (groups[g][0]
														== deco[i].color[0]
														&& groups[g][1]
														== deco[i].color[1]
														&& groups[g][2]
														== deco[i].color[2]
														&& groups[g][3]
														== deco[i].alpha)
														break;
												}

											if (g < group_count)
												assigned[i] = true;
											else if (group_count
												 < DECORATION_MAX_STYLE_GROUPS)
												{
													groups[group_count][0]
														= deco[i].color[0];
													groups[group_count][1]
														= deco[i].color[1];
													groups[group_count][2]
														= deco[i].color[2];
													groups[group_count][3]
														= deco[i].alpha;
													++group_count;
													assigned[i] = true;
												}
											/* else: over the
											 * cap, painted
											 * individually. */
										}
								}

							/* One path + one fill per style
							 * group. */
							for (int g = 0; g < group_count; ++g)
								{
									path = fz_new_path(ctx);

									for (int i = 0;
									     i < deco_count;
									     ++i)
										{
											if (!assigned[i]
											    || deco[i].kind
												   != DECORATION_KIND_RECT)
												continue;
											if (deco[i].color[0]
												    != groups[g][0]
											    || deco[i].color[1]
												    != groups[g][1]
											    || deco[i].color[2]
												    != groups[g][2]
											    || deco[i].alpha
												    != groups[g][3])
												continue;

											fz_rectto(
												ctx, path,
												deco[i].x0,
												deco[i].y0,
												deco[i].x1,
												deco[i].y1);
										}

									float color[3]
										= { groups[g][0],
										    groups[g][1],
										    groups[g][2] };

									/* 这里必须传 fz_identity，不能传 ctm。
									 * device 已经在 fz_new_draw_device(ctx, ctm, pixmap)
									 * 处持有了 user→device（页面空间→像素）的变换，
									 * 这与 fz_new_pixmap_from_display_list 的惯例一致：
									 * device 拿 ctm，往它上面绘制时方法自带 ctm 传 identity。
									 *
									 * 若此处再传 ctm，会被与 device 持有的变换复合两次，
									 * 高亮坐标按 scale² 放大（实测 scale≈1.574 → 约 2.48 倍），
									 * 矩形被画到页面外右下方，用户完全看不到。
									 *
									 * fz_rectto 传入的仍是 page space（页面空间）坐标，
									 * 无需在 Lisp 侧做任何坐标变换。 */
									fz_fill_path(
										ctx, dev, path,
										0 /* non-zero winding */,
										fz_identity,
										fz_device_rgb(ctx),
										color,
										groups[g][3],
										fz_default_color_params);

									fz_drop_path(ctx, path);
									path = NULL;
								}

							/* Rects whose style fell past
							 * the group cap: one fill each,
							 * so they still show up. */
							if (assigned)
								{
									for (int i = 0;
									     i < deco_count;
									     ++i)
										{
											if (assigned[i]
											    || deco[i].kind
												   != DECORATION_KIND_RECT)
												continue;

											path = fz_new_path(ctx);
											fz_rectto(
												ctx, path,
												deco[i].x0,
												deco[i].y0,
												deco[i].x1,
												deco[i].y1);
											fz_fill_path(
												ctx, dev, path, 0,
												fz_identity,
												fz_device_rgb(ctx),
												deco[i].color,
												deco[i].alpha,
												fz_default_color_params);
											fz_drop_path(ctx, path);
											path = NULL;
										}
								}

							/* Strokes: one path each,
							 * round caps and round joins
							 * so a freehand polyline has
							 * no visible corners. */
							for (int i = 0;
							     i < deco_count; ++i)
								{
									const Decoration *d
										= &deco[i];

									if (d->kind
										    != DECORATION_KIND_STROKE
									    || !d->pts
									    || d->pt_count < 2)
										continue;

									path = fz_new_path(ctx);
									fz_moveto(ctx, path,
										  d->pts[0].x,
										  d->pts[0].y);

									for (int p = 1;
									     p < d->pt_count; ++p)
										fz_lineto(ctx, path,
											  d->pts[p].x,
											  d->pts[p].y);

									/* A stack copy of the
									 * default state is safe:
									 * fz_stroke_path() only
									 * reads it, and dash_len
									 * is 0 so the flexible
									 * dash_list[] is never
									 * touched. */
									fz_stroke_state ss
										= fz_default_stroke_state;
									ss.dash_len = 0;
									ss.start_cap
										= FZ_LINECAP_ROUND;
									ss.dash_cap
										= FZ_LINECAP_ROUND;
									ss.end_cap
										= FZ_LINECAP_ROUND;
									ss.linejoin
										= FZ_LINEJOIN_ROUND;
									ss.linewidth
										= d->width > 0.0f
											  ? d->width
											  : 1.0f;

									fz_stroke_path(
										ctx, dev, path, &ss,
										fz_identity,
										fz_device_rgb(ctx),
										d->color, d->alpha,
										fz_default_color_params);

									fz_drop_path(ctx, path);
									path = NULL;
								}

							fz_close_device(ctx, dev);
						}
					fz_always(ctx)
						{
							fz_drop_path(ctx, path);
							fz_drop_device(ctx, dev);
							free(assigned);
						}
					fz_catch(ctx)
						{
							/* 装饰绝不让整页渲染失败。但也别让
							 * 失败彻底无声——同类变换错误（如 ctm
							 * 被应用两次）曾让高亮整体偏移却
							 * 毫无线索。用原子标志把告警限制
							 * 为每进程一次，避免每帧刷屏。 */
							static atomic_bool warned = false;

							if (!atomic_exchange(&warned, true))
								fz_warn(
									ctx,
									"decoration painting failed: %s",
									fz_caught_message(ctx));
						}
				}

			/* 尺寸双轨制：逻辑像素（÷ frame_scale）供 Elisp 的
			 * :width/:height 做显示层缩放；设备像素（pixmap
			 * 尺寸）供 canvas 的 :data-width/:data-height 定缓冲
			 * 尺寸。两者不可互换——把逻辑像素写进 data-* 会让
			 * Emacs 重建缓冲并清零（残影/花屏）。 */
			local_imgh = (int)(fz_pixmap_height(ctx, pixmap) / frame_scale);
			local_imgw = (int)(fz_pixmap_width(ctx, pixmap) / frame_scale);
			local_data_h = (int)fz_pixmap_height(ctx, pixmap);
			local_data_w = (int)fz_pixmap_width(ctx, pixmap);

			/* 导出成 canvas 的 ARGB32 缓冲格式（小端字节序
			 * B,G,R,A）。MuPDF 侧 alpha=0 故只有 3 分量，这里
			 * 补 A=255（不透明）。
			 *
			 * 源行必须按 fz_pixmap_stride 推进，不能假设紧凑布局
			 * （stride 可能因行对齐大于 w*3）；目标行宽固定为
			 * w*4，与 canvas 缓冲的隐式行宽一致。 */
			int ncomp = fz_pixmap_components(ctx, pixmap);

			if (ncomp != 3)
				{
					fz_warn(ctx,
						"unexpected pixmap components %d "
						"(expected 3: BGR without alpha)",
						ncomp);
					fz_throw(ctx, FZ_ERROR_ARGUMENT,
						 "pixmap is not 3-component BGR");
				}

			if (local_data_w <= 0 || local_data_h <= 0)
				fz_throw(ctx, FZ_ERROR_ARGUMENT,
					 "pixmap has zero size");

			unsigned char *samples = fz_pixmap_samples(ctx, pixmap);
			int stride = fz_pixmap_stride(ctx, pixmap);
			size_t out_bytes = (size_t)local_data_w
					   * (size_t)local_data_h * 4u;

			if (!samples || stride < local_data_w * 3)
				fz_throw(ctx, FZ_ERROR_ARGUMENT,
					 "pixmap samples/stride unusable");

			local_bgra = malloc(out_bytes);

			if (!local_bgra)
				fz_throw(ctx, FZ_ERROR_LIMIT,
					 "out of memory for the BGRA export");

			for (int y = 0; y < local_data_h; ++y)
				{
					const unsigned char *src
						= samples + (size_t)y
								    * (size_t)stride;
					unsigned char *dst
						= local_bgra
						  + (size_t)y
							    * (size_t)local_data_w
						    * 4u;

					for (int x = 0; x < local_data_w; ++x)
						{
							/* 单次 32 位写（memcpy 会被
							 * 编译成一条 store）：小端
							 * ARGB32 = 字节 B,G,R,A。 */
							uint32_t px
								= 0xFF000000u
								  | ((uint32_t)src[2]
								     << 16) /* R */
								  | ((uint32_t)src[1]
								     << 8) /* G */
								  | (uint32_t)src[0]; /* B */

							memcpy(dst, &px, 4);
							src += 3;
							dst += 4;
						}
				}

			local_size = out_bytes;
			render_ok = true;
		}
	fz_always(ctx)
		{
			if (pixmap)
				fz_drop_pixmap(ctx, pixmap);
		}
	fz_catch(ctx)
		{
			render_ok = false;
		}

	if (!render_ok || !local_bgra || local_size == 0 || local_imgw <= 0
	    || local_imgh <= 0)
		{
			free(local_bgra);
			fz_drop_context(ctx);
			return false;
		}

	fz_drop_context(ctx);

	*out_w = local_imgw;
	*out_h = local_imgh;
	*out_data_w = local_data_w;
	*out_data_h = local_data_h;
	*out_data = local_bgra;
	*out_size = local_size;

	return true;
}

/**
 * Build a sliding cache window around the given page.
 *
 * Determines a window of pages centered around page `n', clears any
 * previously rendered pages, loads display lists for empty ones, and
 * submits rendering jobs. Waits for the current page to be fully cached.
 *
 * @param state  Pointer to the current DocState.
 * @param n      Page number to center the cache window around.
 */

/**
 * Reset `seshat-reader-current-doc-render-status' to nil in the current
 * buffer.
 *
 * The variable is permanent buffer-local (see `permanent_buffer_local_var')
 * and means "a page image has been handed to Lisp for this document".  It
 * must therefore drop back to nil whenever the document it describes goes
 * away — on a successful `--close-doc' and on every `--load-doc' failure
 * path — otherwise a stale t survives the failed load and the reader skips
 * the initial render (`seshat-reader-mode' only renders when the variable is
 * unset).
 *
 * Writes the same symbol through the same `set' mechanism as
 * `set_current_render_status' (elisp-helpers.c), which is `t'-only; the
 * reset lives here because adding a parameter there would change a shared
 * header instead of this file.
 *
 * @param env  The Emacs environment pointer.
 */

static void
reset_current_render_status(emacs_env *env)
{
	emacs_value render_status_var
	    = env->intern(env, "seshat-reader-current-doc-render-status");

	env->funcall(env, env->intern(env, "set"), 2,
		     (emacs_value[]){ render_status_var, EMACS_NIL });
}

/**
 * emacs_load_doc - Load a document from Emacs, initialize state, and render
 * first page.
 * @env:   The Emacs environment pointer.
 * @nargs: Number of arguments passed from Elisp (should be 1).
 * @args:  Array of Elisp argument values; args[0] is the file path string.
 * @data:  User-supplied callback data (ignored).
 *
 * Return: Elisp `t` on completion (`nil` otherwise).
 */

emacs_value
emacs_load_doc(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    (void)data;

    size_t str_length = 0;
    int start_page = 0;

    if (nargs >= 2)
    {
        start_page = env->extract_integer(env, args[1]);

        if (start_page < 0)
            start_page = 0;
    }

    DocState *old_state = get_doc_state_ptr(env);

    if (old_state)
    {
        old_state->is_reloading = true;

        clear_doc_state_ptr(env);
        free_doc_state(old_state);
    }

    DocState *doc_state = NULL;

    doc_state = init_doc_state_ptr(env);

    if (!doc_state)
    {
        emacs_message(env, "Document cannot be loaded into memory.");
        goto cleanup;
    }

    reset_doc_state(doc_state);

    if (!elisp_2_c_str(env, args[0], &doc_state->path, &str_length))
    {
        emacs_message(env,
                      "Failed to convert Emacs string to C string.");
        goto cleanup;
    }

    if (init_main_ctx(doc_state) == EXIT_FAILURE)
    {
        emacs_message(env, "Failed to initialize MuPDF context.");
        goto cleanup;
    }

    if (load_mupdf_doc(doc_state) == EXIT_FAILURE)
    {
        emacs_message(env,
                      "The document could not be loaded by MuPDF.");
        goto cleanup;
    }

    if (doc_state->pagecount <= 0)
    {
        emacs_message(env, "The document has no pages.");
        goto cleanup;
    }

    outline2plist(env, doc_state, doc_state->outline);

    doc_state->frame_scale = get_frame_scale_factor(env);

    /* 与 `render_page_to_buffer' 同一口径：极小正值同样视为 1.0，
     * 免得逻辑像素（device / frame_scale）溢出。 */
    if (!(doc_state->frame_scale > 0.01f))
        doc_state->frame_scale = 1.0f;

    /*
     * Allocate DocPage array.
     *
     * doc_state->pagecount is temporarily used as the number of
     * successfully initialized DocPages so cleanup can destroy only valid
     * mutexes.
     */
    int total_pages = doc_state->pagecount;

    doc_state->pagecount = 0;
    doc_state->doc_pages = calloc(total_pages, sizeof(DocPage));

    if (!doc_state->doc_pages)
    {
        emacs_message(env, "Failed to allocate DocPage array.");
        goto cleanup;
    }

    for (int i = 0; i < total_pages; ++i)
    {
        DocPage *dp = &doc_state->doc_pages[i];

        dp->page_num = i;
        dp->display_list = NULL;
        dp->ready = false;
        atomic_init(&dp->refcount, 0);

        if (pthread_mutex_init(&dp->mutex, NULL) != 0)
        {
            emacs_message(env, "Failed to initialize DocPage mutex.");
            goto cleanup;
        }

        doc_state->pagecount = i + 1;
    }

    if (start_page >= doc_state->pagecount)
        start_page = doc_state->pagecount - 1;

    /* 只记录起始页：多页布局经 `--page-image-spec' 逐页取图，C 侧不再持有
     * 任何窗口状态，也不在加载时把任何页面渲染到 overlay。 */
    doc_state->current_page_number = start_page;

    set_current_pagecount(env, doc_state);
    set_current_page_number(env, start_page);
    /* 加载本身不再渲染任何页面，故这里**不**置渲染状态：状态只表示
     * “已经出过一页图像”，由 `--page-image-spec' 成功返回时置位。
     * buffer-local 变量已 permanent 化，默认即 nil（未渲染）。 */

    return EMACS_T;

cleanup:
    if (doc_state)
    {
        free_doc_state(doc_state);
    }

    clear_doc_state_ptr(env);

    /* 加载失败后不能把上一份文档留下的渲染状态带下去：状态为 t 时
     * `seshat-reader-mode' 会跳过首次渲染，画面将永远空白。 */
    reset_current_render_status(env);

    return EMACS_NIL;
}

/**
 * Close the currently loaded document and free all resources.
 *
 * Frees the cache window and cached pages pool, drops the outline,
 * document, and MuPDF context, resets the DocState, and frees it.
 *
 * @param env    Emacs module environment.
 * @param nargs  Argument count (unused).
 * @param args   Argument values (unused).
 * @param data   Additional data (unused).
 * Return:       EMACS_T after successful cleanup.
 */

emacs_value
emacs_close_doc(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
	(void)nargs;
	(void)args;
	(void)data;

	DocState *state = get_doc_state_ptr(env);
	if (!state)
		{
			emacs_message(env, "No valid DocState user pointer found.");
			/* 文档已经不在了，渲染状态也必须随之归零，否则
			 * 残留的 t 会让下一次 `seshat-reader-mode' 跳过渲染。 */
			reset_current_render_status(env);
			return EMACS_NIL;
		}

	state->is_reloading = true;

	clear_doc_state_ptr(env);

	free_doc_state(state);

	/* 位图随文档一起释放，故「已经出过一页图像」不再成立。 */
	reset_current_render_status(env);

	return EMACS_T;
}

/**
 * current_page_from_elisp - Resolve the page to use when PAGE is omitted.
 *
 * The C side keeps no window state any more, so the current page is asked
 * from Elisp: `seshat-reader-current-doc-pagenumber' reports the 1-based
 * number of the page at the top of the window.  Its value is converted to
 * the 0-based index the module speaks.  When that function is not
 * available (a bare `emacs -Q --batch' loading the module, or a buffer
 * that holds no page row yet) the page recorded by `--load-doc' is used.
 *
 * @param env    Emacs module environment.
 * @param state  The current DocState, for the fallback page.
 * Return:       A 0-based page index.
 */

static int
current_page_from_elisp(emacs_env *env, DocState *state)
{
	emacs_value sym = env->intern(env, "seshat-reader-current-doc-pagenumber");
	emacs_value bound = env->funcall(env, env->intern(env, "fboundp"), 1, &sym);

	if (!env->eq(env, bound, EMACS_NIL))
		{
			emacs_value value = env->funcall(env, sym, 0, NULL);

			if (env->eq(env, env->funcall(env, env->intern(env, "integerp"),
						      1, &value), EMACS_T))
				{
					int page = (int)env->extract_integer(env, value) - 1;

					return page < 0 ? 0 : page;
				}
		}

	return state ? state->current_page_number : 0;
}

/**
 * emacs_page_text - Extract the plain text of a page.
 *
 * Loads PAGE (or the current page when PAGE is omitted), builds a
 * structured-text representation and serializes it to plain text. The
 * extraction runs on a cloned MuPDF context so that concurrent render
 * jobs keep working. Returns an Elisp string with the UTF-8 encoded
 * text, or nil if the state is unavailable, the page is out of range,
 * or the page has no text layer (e.g. a scanned document).
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (0 or 1).
 * @param args   Array of Elisp argument values; args[0] is the page index.
 * @param data   Additional data (unused).
 * Return:       Elisp string, or nil on failure.
 */

emacs_value
emacs_page_text(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void)data;

	DocState *doc_state = NULL;

	if (!get_reader_current_state(env, &doc_state))
		return EMACS_NIL;

	int page_number = (nargs >= 1)
		? (int)env->extract_integer(env, args[0])
		: current_page_from_elisp(env, doc_state);

	if (page_number < 0 || page_number >= doc_state->pagecount)
		{
			emacs_message(env, "Page number is out of range.");
			return EMACS_NIL;
		}

	/* The clone shares the same lock set as the original context,
	 * which is exactly MuPDF's multi-threading model. */
	fz_context *ctx = fz_clone_context(doc_state->ctx);
	if (!ctx)
		return EMACS_NIL;

	fz_page *volatile page = NULL;
	fz_stext_page *volatile stext = NULL;
	fz_buffer *volatile buf = NULL;
	fz_output *volatile out = NULL;
	volatile bool ok = false;

	fz_try(ctx)
		{
			page = fz_load_page(ctx, doc_state->doc, page_number);
			stext = fz_new_stext_page_from_page(ctx, page, NULL);
			buf = fz_new_buffer(ctx, 1024);
			out = fz_new_output_with_buffer(ctx, buf);
			fz_print_stext_page_as_text(ctx, out, stext);
			ok = true;
		}
	fz_always(ctx)
		{
			if (stext)
				fz_drop_stext_page(ctx, stext);
			if (out)
				fz_close_output(ctx, out);
			if (out)
				fz_drop_output(ctx, out);
			if (page)
				fz_drop_page(ctx, page);
		}
	fz_catch(ctx)
		{
			ok = false;
		}

	/* The buffer is dropped only after its bytes have been copied into
	 * an Emacs string, hence outside the fz_try/fz_catch block above. */
	if (!ok || !buf)
		{
			if (buf)
				fz_drop_buffer(ctx, buf);

			fz_drop_context(ctx);
			emacs_message(env, "Failed to extract the page text.");
			return EMACS_NIL;
		}

	size_t len = buf->len;
	emacs_value result = EMACS_NIL;

	if (len > 0)
		result = env->make_string(env, (const char *)buf->data, len);

	fz_drop_buffer(ctx, buf);
	fz_drop_context(ctx);

	if (len == 0)
		{
			emacs_message(env, "No text layer found (scanned document?).");
			return EMACS_NIL;
		}

	return result;
}

/**
 * StextQuery - Which output the shared rect walk should produce.
 */
typedef enum
{
	STEXT_QUERY_TEXT,
	STEXT_QUERY_RECTS
} StextQuery;

/**
 * stext_query_in_rect - Shared structured-text walk for the rect queries.
 *
 * Loads PAGE, builds its structured-text representation and visits every
 * character whose bounding quad intersects RECT (in unrotated page
 * coordinates, reading order).  Both public entry points go through this
 * one walk so their notions of "which characters are inside" can never
 * drift apart; only the shape of the answer differs:
 *
 *   - STEXT_QUERY_TEXT  → Elisp string of the hit characters as UTF-8
 *			   bytes, without preserving line breaks
 *			   (`--text-in-rect'; the historical behaviour).
 *   - STEXT_QUERY_RECTS → Elisp list of `(X0 Y0 X1 Y1)' floats, one per
 *			   hit character (`--rects-in-rect').
 *
 * Both run on a cloned MuPDF context, which shares the original lock set —
 * exactly MuPDF's multi-threading model.  Everything that touches `env' is
 * deliberately done AFTER the fz_try/fz_catch block: an Emacs non-local
 * exit raised inside a MuPDF exception frame would unwind it abnormally.
 *
 * @param env            Emacs module environment.
 * @param doc_state      Document owning the page.
 * @param page_number    0-based page index (already range-checked).
 * @param rect           Validated rectangle in page coordinates.
 * @param query          Which answer to build.
 * Return:               Elisp string / list, or nil.
 */

static emacs_value
stext_query_in_rect(emacs_env *env, DocState *doc_state, int page_number,
		    fz_rect rect, StextQuery query)
{
	fz_context *ctx = fz_clone_context(doc_state->ctx);

	if (!ctx)
		return EMACS_NIL;

	/* volatile：与上面各函数同理，fz_try 内赋值、fz_always / 块之后
	 * 使用的局部变量跨 setjmp/longjmp 边界，必须 volatile
	 * （`quads' 在 fz_try 内被 realloc、在失败路径上被 free）。 */
	fz_page *volatile page = NULL;
	fz_stext_page *volatile stext = NULL;
	fz_buffer *volatile buf = NULL;

	/* Collected quads: plain malloc, so a failure truncates the result
	 * instead of throwing.  Freed on every path below. */
	fz_quad *volatile quads = NULL;
	int quad_count = 0;
	int quad_cap = 0;

	bool want_text = (query == STEXT_QUERY_TEXT);
	bool ok = false;

	fz_try(ctx)
		{
			page = fz_load_page(ctx, doc_state->doc, page_number);
			stext = fz_new_stext_page_from_page(ctx, page, NULL);

			if (want_text)
				buf = fz_new_buffer(ctx, 1024);

			for (fz_stext_block *block = stext->first_block; block;
			     block = block->next)
				{
					if (block->type != FZ_STEXT_BLOCK_TEXT)
						continue;

					for (fz_stext_line *line = block->u.t.first_line;
					     line; line = line->next)
						{
							for (fz_stext_char *ch = line->first_char;
							     ch; ch = ch->next)
								{
									fz_rect quad =
										fz_rect_from_quad(ch->quad);
									fz_rect hit =
										fz_intersect_rect(quad, rect);

									if (fz_is_empty_rect(hit))
										continue;

									if (buf)
										{
											char rune[8];
											int rune_len =
												fz_runetochar(rune, ch->c);

											if (rune_len > 0)
												fz_append_data(ctx, buf,
													       rune,
													       (size_t)rune_len);
										}
									else if (quad_count
										 < RECTS_IN_RECT_MAX_COUNT)
										{
											if (quad_count
											    == quad_cap)
												{
													int new_cap
														= quad_cap
														  ? quad_cap * 2
														  : 64;

													if (new_cap
													    > RECTS_IN_RECT_MAX_COUNT)
														new_cap
															= RECTS_IN_RECT_MAX_COUNT;

													fz_quad *grown
														= realloc(
															quads,
															(size_t)new_cap
																* sizeof(
																	fz_quad));

													if (!grown)
														break;

													quads = grown;
													quad_cap = new_cap;
												}

											quads[quad_count++]
												= ch->quad;
										}
								}
						}
				}

			ok = true;
		}
	fz_always(ctx)
		{
			if (stext)
				fz_drop_stext_page(ctx, stext);
			if (page)
				fz_drop_page(ctx, page);
		}
	fz_catch(ctx)
		{
			ok = false;
		}

	if (!ok)
		{
			if (buf)
				fz_drop_buffer(ctx, buf);

			free(quads);
			fz_drop_context(ctx);

			emacs_message(env, want_text
						  ? "Failed to extract the text in the rectangle."
						  : "Failed to extract the rectangles in the rectangle.");
			return EMACS_NIL;
		}

	emacs_value result = EMACS_NIL;

	if (want_text)
		{
			size_t len = buf ? buf->len : 0;

			if (len > 0)
				result = env->make_string(env, (const char *)buf->data,
							  len);

			if (buf)
				fz_drop_buffer(ctx, buf);

			fz_drop_context(ctx);

			if (len == 0)
				{
					emacs_message(
						env,
						"No text found inside the rectangle.");
					return EMACS_NIL;
				}

			return result;
		}

	/* Rects: build the list back to front with cons so the result comes
	 * out in reading order without a reverse pass. */
	if (quad_count > 0 && quads)
		{
			emacs_value Qlist = env->intern(env, "list");
			emacs_value Qcons = env->intern(env, "cons");

			for (int i = quad_count - 1; i >= 0; --i)
				{
					fz_rect q = fz_rect_from_quad(quads[i]);
					emacs_value corners[4]
						= { env->make_float(env, q.x0),
						    env->make_float(env, q.y0),
						    env->make_float(env, q.x1),
						    env->make_float(env, q.y1) };
					emacs_value one
						= env->funcall(env, Qlist, 4, corners);
					emacs_value cell_args[2] = { one, result };

					result = env->funcall(env, Qcons, 2, cell_args);
				}
		}

	free(quads);
	fz_drop_context(ctx);

	return result;
}

/**
 * prepare_rect_query - Shared argument handling for the rect queries.
 *
 * The three rect-query entry points (`--text-in-rect', `--rects-in-rect'
 * and `--lines-in-rect') differ only in the shape of their answer, so the
 * whole front half of each call — reader state lookup, the reload
 * early-out, page-number range check and the coordinate validation — is
 * factored out here.  Keeping it in one place is what makes "the same
 * rectangle means the same thing" true across all three: they share one
 * notion of page space (`rect_to_page_space') and one set of messages.
 *
 * All failures return false with no result to build; some of them emit a
 * message (out-of-range page, non-finite coordinates) and some are
 * deliberately silent (no reader state, reload in progress — the caller
 * is in the middle of a redisplay and a message would be noise).
 *
 * The document is resolved from the *buffer-local* state pointer only
 * (`get_doc_state_ptr'), never from the selected window's overlay.  A rect
 * query reads the document, not the display: the multi-page layout draws
 * every visible page into its own overlay-less region and a drag therefore
 * runs with an arbitrary selected window (the drag deliberately never calls
 * `select-window', see `seshat-reader-select-drag').  Requiring a valid
 * overlay here made every rect query fail — silently, since this helper
 * stays quiet — which is exactly the "selection copies nothing" symptom.
 *
 * @param env             Emacs module environment.
 * @param args            Elisp args: page, x0, y0, x1, y1 (0-based page).
 * @param doc_state_out   Receives the document on success.
 * @param page_number_out Receives the 0-based, range-checked page index.
 * @param rect_out        Receives the rectangle in MuPDF page space.
 * Return:                true when the query may proceed.
 */

static bool
prepare_rect_query(emacs_env *env, emacs_value *args, DocState **doc_state_out,
		   int *page_number_out, fz_rect *rect_out)
{
	DocState *doc_state = get_doc_state_ptr(env);

	/* Silent: no reader state means this buffer is not a live reader (or
	 * the module's user pointer is gone), and the caller may be inside a
	 * redisplay where a message would only echo on every keystroke. */
	if (!doc_state)
		return false;

	/* Bail out during reload to avoid use-after-free.  The module holds no
	 * window state, so the document's own reload flag is the only guard
	 * needed here. */
	if (doc_state->is_reloading)
		return false;

	int page_number = (int)env->extract_integer(env, args[0]);
	float ax = env->extract_float(env, args[1]);
	float ay = env->extract_float(env, args[2]);
	float bx = env->extract_float(env, args[3]);
	float by = env->extract_float(env, args[4]);

	if (page_number < 0 || page_number >= doc_state->pagecount)
		{
			emacs_message(env, "Page number is out of range.");
			return false;
		}

	/* Validate and normalize the rectangle through the same helper the
	 * highlight painter uses, so both entry points share one notion of
	 * page space (see rect_to_page_space).
	 *
	 * Rejecting non-finite corners matters here: fz_is_empty_rect()
	 * treats every comparison against a NaN as false, so a NaN
	 * rectangle would otherwise be classified as non-empty and would
	 * wrongly match every character on the page. */
	fz_rect rect;

	if (!rect_to_page_space(ax, ay, bx, by, &rect))
		{
			emacs_message(env,
				      "Invalid rectangle: coordinates must be finite.");
			return false;
		}

	if (doc_state_out)
		*doc_state_out = doc_state;
	if (page_number_out)
		*page_number_out = page_number;
	if (rect_out)
		*rect_out = rect;

	return true;
}

/**
 * stext_lines_in_rect - Return whole text lines that touch a rectangle.
 *
 * The line-snapped sibling of `stext_query_in_rect': same page/coordinate
 * validation (its caller goes through `prepare_rect_query'), same
 * cloned-context discipline, same "build the Elisp list AFTER the
 * fz_try/fz_catch block" rule, but a different traversal.
 *
 * For every TEXT line the walk runs twice over that line's characters: the
 * first pass asks whether ANY character quad intersects RECT (the very
 * `fz_intersect_rect' + `fz_is_empty_rect' test the character query uses,
 * so "touched" means exactly the same thing in both functions); only if it
 * answers yes does the second pass union every character quad of that line
 * and emit one rectangle.  A line the rectangle does not touch contributes
 * nothing at all.
 *
 * Why line granularity works for a two-column layout: MuPDF's structured
 * text already separates the left and right column into distinct lines, so
 * the "does this line itself get touched" test keeps a rectangle over the
 * left column from dragging the right column's lines along — they are
 * different lines and nobody touched them.  (Should a build ever put both
 * columns into one line, the columns would merge; that is a property of the
 * stext tree, not something this walk could decide.)
 *
 * Emitted is the union of the line's char quads, i.e. the line's full
 * extent in reading order — not just the part the rectangle covered.
 *
 * @param env         Emacs module environment.
 * @param doc_state   Document owning the page.
 * @param page_number 0-based page index (already range-checked).
 * @param rect        Validated rectangle in page coordinates.
 * Return:           Elisp list of (X0 Y0 X1 Y1) floats, or nil.
 */

static emacs_value
stext_lines_in_rect(emacs_env *env, DocState *doc_state, int page_number,
		    fz_rect rect)
{
	fz_context *ctx = fz_clone_context(doc_state->ctx);

	if (!ctx)
		return EMACS_NIL;

	/* volatile：同 stext_query_in_rect——fz_try 内赋值、fz_always /
	 * 块之后使用的局部变量跨 setjmp/longjmp 边界，必须 volatile。 */
	fz_page *volatile page = NULL;
	fz_stext_page *volatile stext = NULL;

	/* Collected line unions: plain malloc, so a failure truncates the
	 * result instead of throwing.  Freed on every path below. */
	fz_rect *volatile lines = NULL;
	int line_count = 0;
	int line_cap = 0;

	bool ok = false;

	fz_try(ctx)
		{
			page = fz_load_page(ctx, doc_state->doc, page_number);
			stext = fz_new_stext_page_from_page(ctx, page, NULL);

			for (fz_stext_block *block = stext->first_block; block;
			     block = block->next)
				{
					if (block->type != FZ_STEXT_BLOCK_TEXT)
						continue;

					for (fz_stext_line *line = block->u.t.first_line;
					     line; line = line->next)
						{
							fz_stext_char *first
								= line->first_char;
							fz_rect union_rect;
							bool touched = false;

							if (!first)
								continue;

							/* First pass: does any character of
							 * this line touch the selection? */
							for (fz_stext_char *scan = first; scan;
							     scan = scan->next)
								{
									fz_rect quad
										= fz_rect_from_quad(
											scan->quad);
									fz_rect hit
										= fz_intersect_rect(
											quad, rect);

									if (!fz_is_empty_rect(hit))
										{
											touched = true;
											break;
										}
								}

							if (!touched)
								continue;

							/* Second pass: the whole line.
							 * Seeded with the first char so
							 * the union never picks up the
							 * origin (fz_empty_rect is a
							 * zero-area rect at (0, 0), not
							 * an absorbing empty value). */
							union_rect
								= fz_rect_from_quad(first->quad);

							for (fz_stext_char *scan = first->next;
							     scan; scan = scan->next)
								union_rect = fz_union_rect(
									union_rect,
									fz_rect_from_quad(
										scan->quad));

							if (line_count
							    >= LINES_IN_RECT_MAX_COUNT)
								break;

							if (fz_is_empty_rect(union_rect))
								continue;

							if (line_count == line_cap)
								{
									int new_cap;
									fz_rect *grown;

									new_cap = line_cap
														  ? line_cap * 2
														  : 32;
									if (new_cap
									    > LINES_IN_RECT_MAX_COUNT)
										new_cap
														  = LINES_IN_RECT_MAX_COUNT;

									grown = realloc(
										lines,
										(size_t)new_cap
														  * sizeof(
															  fz_rect));

									if (!grown)
										break;

									lines = grown;
									line_cap = new_cap;
								}

							lines[line_count++]
								= union_rect;
						}
				}

			ok = true;
		}
	fz_always(ctx)
		{
			if (stext)
				fz_drop_stext_page(ctx, stext);
			if (page)
				fz_drop_page(ctx, page);
		}
	fz_catch(ctx)
		{
			ok = false;
		}

	if (!ok)
		{
			free(lines);
			fz_drop_context(ctx);

			emacs_message(
				env,
				"Failed to extract the lines in the rectangle.");
			return EMACS_NIL;
		}

	emacs_value result = EMACS_NIL;

	/* Build the list back to front with cons so the result comes out in
	 * reading order without a reverse pass. */
	if (line_count > 0 && lines)
		{
			emacs_value Qlist = env->intern(env, "list");
			emacs_value Qcons = env->intern(env, "cons");

			for (int i = line_count - 1; i >= 0; --i)
				{
					emacs_value corners[4]
						= { env->make_float(env, lines[i].x0),
						    env->make_float(env, lines[i].y0),
						    env->make_float(env, lines[i].x1),
						    env->make_float(env, lines[i].y1) };
					emacs_value one
						= env->funcall(env, Qlist, 4, corners);
					emacs_value cell_args[2] = { one, result };

					result = env->funcall(env, Qcons, 2, cell_args);
				}
		}

	free(lines);
	fz_drop_context(ctx);

	return result;
}

/**
 * emacs_text_in_rect - Extract the text intersecting a page rectangle.
 *
 * Loads PAGE, builds its structured-text representation and collects
 * every character whose bounding quad intersects the given rectangle
 * (in unrotated page coordinates). Hit characters are concatenated in
 * reading order as UTF-8 bytes, without preserving line breaks. The
 * extraction runs on a cloned MuPDF context. Returns an Elisp string,
 * or nil if the state is unavailable, the page is out of range, or no
 * character falls inside the rectangle.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (5).
 * @param args   Elisp arguments: page, x0, y0, x1, y1.
 * @param data   Additional data (unused).
 * Return:       Elisp string, or nil on failure.
 */

emacs_value
emacs_text_in_rect(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		   void *data)
{
	(void)nargs;
	(void)data;

	DocState *doc_state = NULL;
	int page_number = 0;
	fz_rect rect;

	if (!prepare_rect_query(env, args, &doc_state, &page_number, &rect))
		return EMACS_NIL;

	return stext_query_in_rect(env, doc_state, page_number, rect,
				   STEXT_QUERY_TEXT);
}

/**
 * emacs_rects_in_rect - Return the text quads intersecting a rectangle.
 *
 * The geometric sibling of `--text-in-rect': same page/coordinate
 * validation, same reload early-out, same
 * `rect_to_page_space' notion of page space (so a rect handed to
 * `--add-highlight' lines up with the quads this returns), and the very
 * same stext traversal (see stext_query_in_rect).  Instead of
 * concatenating the characters it reports where they are: a list of
 * `(X0 Y0 X1 Y1)' float quadruples, one per hit character, in reading
 * order.
 *
 * An empty result is `nil' — a rectangle with no text is an ordinary
 * answer here, not an error, so no message is emitted.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (5).
 * @param args   Elisp arguments: page, x0, y0, x1, y1.
 * @param data   Additional data (unused).
 * Return:       Elisp list of quadruples, or nil.
 */

emacs_value
emacs_rects_in_rect(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		    void *data)
{
	(void)nargs;
	(void)data;

	DocState *doc_state = NULL;
	int page_number = 0;
	fz_rect rect;

	if (!prepare_rect_query(env, args, &doc_state, &page_number, &rect))
		return EMACS_NIL;

	return stext_query_in_rect(env, doc_state, page_number, rect,
				   STEXT_QUERY_RECTS);
}

/**
 * emacs_lines_in_rect - Return the whole text lines a rectangle touches.
 *
 * "Line snapping" for the selection highlight: a rectangle that covers any
 * character of a line selects that entire line.  Same page-number base as
 * `--rects-in-rect' and `--text-in-rect' (0-based, they serve the same
 * selection path), same page-space notion, same early-outs and messages
 * (all shared through `prepare_rect_query'), same list shape — a list of
 * `(X0 Y0 X1 Y1)' float quadruples in reading order, one per line.
 *
 * Differences from `--rects-in-rect': one rectangle per line instead of one
 * per character, and a rectangle that no line touches yields `nil'
 * silently — a selection over a blank area is an ordinary answer, not an
 * error, so no message is emitted.
 *
 * The result is NOT merged by the caller: every rectangle already spans its
 * whole line, so re-merging could only bridge neighbouring lines.  Vertical
 * shrinking is still applied on the Lisp side.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (5).
 * @param args   Elisp arguments: page, x0, y0, x1, y1.
 * @param data   Additional data (unused).
 * Return:       Elisp list of quadruples, or nil.
 */

emacs_value
emacs_lines_in_rect(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		    void *data)
{
	(void)nargs;
	(void)data;

	DocState *doc_state = NULL;
	int page_number = 0;
	fz_rect rect;

	if (!prepare_rect_query(env, args, &doc_state, &page_number, &rect))
		return EMACS_NIL;

	return stext_lines_in_rect(env, doc_state, page_number, rect);
}

/* Hit-count policy for `--search-page'.  LIMIT is an Elisp-facing knob
 * (how many hits to report); SEARCH_PAGE_MAX_QUADS is the hard ceiling on
 * how many quads one call can collect, because the array below is a
 * fixed-size block.  A caller asking for more hits than that receives the
 * first MAX_QUADS of them — never a bigger allocation. */
#define SEARCH_PAGE_DEFAULT_LIMIT 1000
#define SEARCH_PAGE_MAX_LIMIT 10000
#define SEARCH_PAGE_MAX_QUADS 1024

/* Longest needle accepted, in UTF-8 bytes.  A real search term is a few
 * dozen bytes, so this bound only exists to keep an unbounded Elisp string
 * from reaching MuPDF's matcher.  Over-long input is refused with a
 * message instead of being truncated: a truncated needle would answer a
 * different question than the one asked. */
#define SEARCH_PAGE_MAX_NEEDLE_BYTES 4096

/**
 * search_needle_is_blank - True when NEEDLE holds only ASCII whitespace.
 *
 * Used to decide whether a needle is a meaningful search term or just the
 * caller's empty placeholder.  The bytes are inspected as POINTERS TO
 * UNSIGNED CHAR because `isspace' is only defined for the unsigned-char
 * range plus EOF; passing a sign-extended byte from a UTF-8 sequence
 * would be undefined behaviour and could report a Chinese character as
 * whitespace on some platforms.  Multi-byte sequences are therefore never
 * blank, which is what we want: any Chinese needle is a real needle.
 *
 * @param needle  NUL-terminated needle bytes, may be NULL when SIZE is 0.
 * @param size    Length of NEEDLE in bytes, excluding the NUL.
 * Return:        true when every byte is ASCII whitespace (or SIZE is 0).
 */

static bool
search_needle_is_blank(const char *needle, size_t size)
{
	if (!needle || size == 0)
		return true;

	for (size_t i = 0; i < size; ++i)
		{
			if (!isspace((unsigned char)needle[i]))
				return false;
		}

	return true;
}

/**
 * search_page_limit - Normalise the LIMIT argument of `--search-page'.
 *
 * Clamping happens in float space so that NaN, infinities and absurd
 * magnitudes are handled before any integer cast:
 *
 *   - `nil' and every non-number fall back to SEARCH_PAGE_DEFAULT_LIMIT
 *     (the coercion helper clears the pending Emacs error, so asking for
 *     a default never leaves a signal behind);
 *   - zero, negative and non-finite values are treated as "unspecified"
 *     and also take the default — a caller passing 0 has not asked for
 *     "no hits", it has failed to express an intent;
 *   - anything at or above SEARCH_PAGE_MAX_LIMIT is clamped down to it;
 *   - otherwise the value is truncated and floored at 1.
 *
 * The result is a positive hit count.  It is still an upper bound on what
 * this call may return, not a promise: the actual array handed to MuPDF is
 * capped separately by SEARCH_PAGE_MAX_QUADS.
 *
 * @param env    Emacs module environment.
 * @param value  Elisp argument holding the limit.
 * Return:       Effective hit limit, always >= 1.
 */

static int
search_page_limit(emacs_env *env, emacs_value value)
{
	float limit = 0.0f;

	if (!extract_float_coerced(env, value, &limit))
		return SEARCH_PAGE_DEFAULT_LIMIT;

	if (!isfinite(limit) || limit <= 0.0f)
		return SEARCH_PAGE_DEFAULT_LIMIT;

	if (limit >= (float)SEARCH_PAGE_MAX_LIMIT)
		return SEARCH_PAGE_MAX_LIMIT;

	int hits = (int)limit;

	return hits > 0 ? hits : 1;
}

/**
 * emacs_search_page - Search one page's text layer for a needle.
 *
 * The geometric twin of `--rects-in-rect': same page space, same
 * early-outs during reload/close, same page-range message, and the
 * same answer shape — a list of `(X0 Y0 X1 Y1)' float quadruples in page
 * coordinates, in the order MuPDF reports the hits (reading order).  The
 * quads come from MuPDF's own page search over the page's structured-text
 * layer (see fz_search_page in <mupdf/fitz/util.h>), i.e. from the very
 * same stext character quads that `stext_query_in_rect' walks for
 * `--rects-in-rect', and they are converted with the same
 * `fz_rect_from_quad' call.  The two entry points therefore agree on page
 * space by construction, and a hit rect fed to `--add-highlight' or
 * `--add-decoration' lands exactly where the text was found.
 *
 * Deliberately NOT re-implemented here: a second stext walk.  MuPDF's
 * matcher already does the case/ligature/whitespace normalisation and the
 * multi-character hit grouping; hand-rolling a normalising walk would give
 * this function a second, subtly different notion of "the page's text" and
 * drift from `--text-in-rect' (see stext_query_in_rect).
 *
 * An empty answer is `nil' and silent.  Two very different situations land
 * there — a page without a text layer (a scan) and a page whose text does
 * not contain NEEDLE — and telling them apart would cost a second stext
 * build for no caller benefit, so neither is reported.  The page-range
 * message is the only one this function emits, matching
 * `--text-in-rect' / `--rects-in-rect' there.
 *
 * PAGE is 1-based, like the three decoration entry points
 * (`--add-highlight' / `--add-decoration' / `--add-stroke'): the Elisp
 * caller always holds the 1-based page number the user sees, so the
 * boundary that decrements must be the module's, not the caller's.  The
 * text-query pair (`--text-in-rect' / `--rects-in-rect') keeps its
 * historical 0-based PAGE — it is fed from the low-level selection code,
 * which already works in page indexes — so the two conventions coexist
 * and every entry point now states its base in this comment.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (3).
 * @param args   Elisp arguments: page, needle, limit.
 * @param data   Additional data (unused).
 * Return:       Elisp list of quadruples, or nil.
 */

emacs_value
emacs_search_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;

	DocState *doc_state = NULL;

	if (!get_reader_current_state(env, &doc_state))
		return EMACS_NIL;

	/* PAGE is 1-based here, exactly like the three decoration entry
	 * points: `resolve_page_arg' validates the range (and rejects
	 * non-integral values) and performs the single decrement to the
	 * 0-based index `fz_load_page' expects. */
	int page_number = 0;

	if (!resolve_page_arg(env, args[0], doc_state->pagecount, &page_number))
		{
			emacs_message(env, "Page number is out of range.");
			return EMACS_NIL;
		}

	char *needle = NULL;
	size_t needle_size = 0;

	if (!elisp_2_c_str(env, args[1], &needle, &needle_size))
		return EMACS_NIL;

	/* An empty or whitespace-only needle is a placeholder, not an
	 * error: answer nil and stay silent. */
	if (search_needle_is_blank(needle, needle_size))
		{
			free(needle);
			return EMACS_NIL;
		}

	if (needle_size > SEARCH_PAGE_MAX_NEEDLE_BYTES)
		{
			free(needle);
			emacs_message(env, "Search string is too long.");
			return EMACS_NIL;
		}

	int hit_max = search_page_limit(env, args[2]);

	if (hit_max > SEARCH_PAGE_MAX_QUADS)
		hit_max = SEARCH_PAGE_MAX_QUADS;

	/* The search runs on a cloned MuPDF context, which shares the
	 * original lock set — exactly MuPDF's multi-threading model (see
	 * stext_query_in_rect). */
	fz_context *ctx = fz_clone_context(doc_state->ctx);

	if (!ctx)
		{
			free(needle);
			return EMACS_NIL;
		}

	/* volatile：`page' 在 fz_try 内赋值、在 fz_always 内 drop，跨
	 * setjmp/longjmp 边界，必须 volatile。`quads' / `marks' 在
	 * fz_try 之前就已赋值，longjmp 不会改变它们的值，故保持非 volatile。 */
	fz_page *volatile page = NULL;

	/* Fixed-size plain malloc blocks, not fz_malloc: an allocation
	 * failure must not turn into an fz_throw.  MuPDF never writes more
	 * than HIT_MAX entries, so a huge LIMIT cannot grow these arrays. */
	fz_quad *quads = malloc((size_t)SEARCH_PAGE_MAX_QUADS * sizeof(fz_quad));
	int *marks = malloc((size_t)SEARCH_PAGE_MAX_QUADS * sizeof(int));

	int hit_count = 0;
	bool ok = false;

	if (!quads || !marks)
		{
			free(quads);
			free(marks);
			free(needle);
			fz_drop_context(ctx);
			emacs_message(env,
				      "Failed to allocate the search buffers.");
			return EMACS_NIL;
		}

	fz_try(ctx)
		{
			page = fz_load_page(ctx, doc_state->doc, page_number);
			hit_count = fz_search_page(ctx, page, needle, marks, quads,
						   hit_max);
			ok = true;
		}
	fz_always(ctx)
		{
			if (page)
				fz_drop_page(ctx, page);
		}
	fz_catch(ctx)
		{
			ok = false;
		}

	free(needle);

	if (!ok)
		{
			free(quads);
			free(marks);
			fz_drop_context(ctx);
			emacs_message(env, "Failed to search the page.");
			return EMACS_NIL;
		}

	/* Defensive: HIT_MAX already bounds this, but an out-of-contract
	 * MuPDF must not be able to read past the arrays below. */
	if (hit_count > hit_max)
		hit_count = hit_max;

	if (hit_count <= 0)
		{
			free(quads);
			free(marks);
			fz_drop_context(ctx);
			return EMACS_NIL;
		}

	/* Everything that touches `env' happens AFTER the fz_try/fz_catch
	 * block: an Emacs non-local exit raised inside a MuPDF exception
	 * frame would unwind it abnormally (see stext_query_in_rect).  The
	 * list is built back to front with cons so the result comes out in
	 * MuPDF's hit order without a reverse pass. */
	emacs_value Qlist = env->intern(env, "list");
	emacs_value Qcons = env->intern(env, "cons");
	emacs_value result = EMACS_NIL;

	for (int i = hit_count - 1; i >= 0; --i)
		{
			fz_rect q = fz_rect_from_quad(quads[i]);
			emacs_value corners[4] = { env->make_float(env, q.x0),
						   env->make_float(env, q.y0),
						   env->make_float(env, q.x1),
						   env->make_float(env, q.y1) };
			emacs_value one = env->funcall(env, Qlist, 4, corners);
			emacs_value cell_args[2] = { one, result };

			result = env->funcall(env, Qcons, 2, cell_args);
		}

	free(quads);
	free(marks);
	fz_drop_context(ctx);

	return result;
}

/**
 * grow_decoration_table - Make room for at least NEED decoration entries.
 *
 * Doubles the capacity (starting from 16) so that feeding a whole
 * document's annotations costs amortised constant time per entry.
 *
 * `realloc' is safe on this array even though Decoration owns `pts': the
 * reallocation moves the structs, and each `pts' keeps pointing at its
 * own separately allocated block.
 *
 * @param doc_state  DocState owning the table.
 * @param need       Required number of entries.
 * Return:           true when the table can hold NEED entries.
 */

static bool
grow_decoration_table(DocState *doc_state, int need)
{
	if (!doc_state || need <= 0)
		return false;

	if (need <= doc_state->decoration_cap)
		return true;

	int cap = doc_state->decoration_cap > 0 ? doc_state->decoration_cap : 16;

	/* Grow by doubling, but stop the doubling before it can overflow an
	 * int: past INT_MAX / 2 one more `cap *= 2' would be undefined
	 * behaviour.  Jumping straight to NEED keeps the table usable (a
	 * caller that lands here is already at the practical ceiling, since
	 * DECORATION_MAX_COUNT keeps NEED far below it). */
	while (cap < need)
		{
			if (cap > INT_MAX / 2)
				{
					cap = need;
					break;
				}

			cap *= 2;
		}

	Decoration *grown = realloc(doc_state->decorations,
				    (size_t)cap * sizeof(Decoration));

	if (!grown)
		return false;

	doc_state->decorations = grown;
	doc_state->decoration_cap = cap;

	return true;
}

/**
 * extract_float_coerced - Read an Elisp number as a float.
 *
 * `extract_float' only accepts floats and signals on integers, while the
 * Elisp side naturally writes `(add-highlight 1 10 10 100 40)' with
 * integer literals.  Coerce through the `float' builtin instead of
 * forcing every caller to spell out `10.0'.  A non-numeric argument is
 * swallowed (the pending signal is cleared) so that one bogus annotation
 * cannot abort a bulk feed.
 *
 * @param env    Emacs module environment.
 * @param value  Elisp value to read.
 * @param out    Receives the float value on success.
 * Return:       true when VALUE was a number.
 */

static bool
extract_float_coerced(emacs_env *env, emacs_value value, float *out)
{
	if (!env || !out)
		return false;

	emacs_value coerced
		= env->funcall(env, env->intern(env, "float"), 1, &value);

	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		{
			env->non_local_exit_clear(env);
			return false;
		}

	*out = env->extract_float(env, coerced);

	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		{
			env->non_local_exit_clear(env);
			return false;
		}

	return true;
}

/**
 * resolve_page_arg - Read and validate the 1-based PAGE argument.
 *
 * Elisp speaks 1-based page numbers, DocState stores 0-based ones.  The
 * range check happens in float space so that NaN, infinities and absurd
 * values are rejected before the integer cast, and a non-integral value
 * is refused rather than silently truncated onto the page before it.
 *
 * @param env        Emacs module environment.
 * @param value      Elisp argument holding the page number.
 * @param pagecount  Document page count (> 0).
 * @param out        Receives the 0-based page index.
 * Return:           true when VALUE is a usable page number.
 */

static bool
resolve_page_arg(emacs_env *env, emacs_value value, int pagecount, int *out)
{
	float page_f = 0.0f;

	if (!extract_float_coerced(env, value, &page_f))
		return false;

	if (!(page_f >= 1.0f && page_f <= (float)pagecount))
		return false;

	if (page_f != floorf(page_f))
		return false;

	*out = (int)page_f - 1;

	return true;
}

/**
 * append_decoration - Reserve the next table slot and zero it.
 *
 * Shared by all three entry points so that the grow + initialise + dirty
 * sequence exists once.  The returned slot is fully zeroed: `pts' is NULL
 * and `pt_count' is 0, which is the valid state for a RECT.
 *
 * @param doc_state  DocState owning the table.
 * Return:           NULL when out of memory or at the hard ceiling.
 */

static Decoration *
append_decoration(DocState *doc_state)
{
	/* Refuse to grow without bound.  Storing nothing is the friendlier
	 * failure here: the entries already held stay valid, and the caller
	 * keeps its document rather than getting an error mid-feed. */
	if (doc_state->decoration_count >= DECORATION_MAX_COUNT)
		return NULL;

	if (!grow_decoration_table(doc_state, doc_state->decoration_count + 1))
		return NULL;

	Decoration *d = &doc_state->decorations[doc_state->decoration_count];

	memset(d, 0, sizeof *d);

	return d;
}

/**
 * clamp_style_component - Clamp one colour/alpha component into [0, 1].
 *
 * Colours come from Elisp and are ultimately derived from a stored
 * annotation, so they are untrusted: a NaN or an out-of-range value would
 * otherwise reach MuPDF's blender.
 */

static float
clamp_style_component(float v, float fallback)
{
	if (!isfinite(v))
		return fallback;
	if (v < 0.0f)
		return 0.0f;
	if (v > 1.0f)
		return 1.0f;
	return v;
}

/**
 * emacs_add_highlight - Record one highlight rectangle for a page.
 *
 * This is the original 5-argument entry point and its behaviour is frozen:
 * it maps onto a DECORATION_KIND_RECT entry with the historical yellow
 * 1.0/0.85/0.0 at alpha 0.35, so every existing caller (annotation feed,
 * selection flash) keeps painting exactly what it painted before.  New
 * callers that need a colour, an alpha or a stroke must use
 * `seshat-reader-dyn--add-decoration' / `--add-stroke' instead — the
 * arity here must not change.
 *
 * PAGE is 1-based, matching the elisp side; DocState keeps pages 0-based,
 * hence the decrement below.  Out-of-range pages and unusable rectangles
 * are ignored silently — a stale or half-parsed annotation must not abort
 * a bulk feed.  Storing a rectangle only marks the document dirty: the
 * bitmap is not re-rendered here, the caller batches its updates and
 * `seshat-reader-dyn--page-image-spec' then paints them.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (5).
 * @param args   Elisp arguments: page, x0, y0, x1, y1.
 * @param data   Additional data (unused).
 * Return:       Elisp `t' when the rectangle was stored, `nil' otherwise.
 */

emacs_value
emacs_add_highlight(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		    void *data)
{
	(void)data;

	DocState *doc_state = get_doc_state_ptr(env);

	if (!doc_state || doc_state->is_reloading || nargs < 5)
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	float x0 = 0.0f, y0 = 0.0f, x1 = 0.0f, y1 = 0.0f;
	int page = 0;

	if (!resolve_page_arg(env, args[0], doc_state->pagecount, &page)
	    || !extract_float_coerced(env, args[1], &x0)
	    || !extract_float_coerced(env, args[2], &y0)
	    || !extract_float_coerced(env, args[3], &x1)
	    || !extract_float_coerced(env, args[4], &y1))
		return EMACS_NIL;

	fz_rect rect;

	if (!rect_to_page_space(x0, y0, x1, y1, &rect))
		return EMACS_NIL;

	/* A zero-area rectangle would be invisible; drop it. */
	if (rect.x1 <= rect.x0 || rect.y1 <= rect.y0)
		return EMACS_NIL;

	Decoration *d = append_decoration(doc_state);

	if (!d)
		return EMACS_NIL;

	d->page = page;
	d->kind = DECORATION_KIND_RECT;
	d->x0 = rect.x0;
	d->y0 = rect.y0;
	d->x1 = rect.x1;
	d->y1 = rect.y1;
	d->color[0] = DECORATION_DEFAULT_COLOR_R;
	d->color[1] = DECORATION_DEFAULT_COLOR_G;
	d->color[2] = DECORATION_DEFAULT_COLOR_B;
	d->alpha = DECORATION_DEFAULT_ALPHA;

	doc_state->decoration_count += 1;

	return EMACS_T;
}

/**
 * emacs_add_decoration - Record one coloured rectangle for a page.
 *
 * The style-carrying sibling of `emacs_add_highlight': identical geometry
 * handling and identical failure policy (silent nil), but the colour and
 * the alpha are supplied by the caller.  Components are clamped into
 * [0, 1]; a non-finite component falls back to the default style so that
 * a damaged annotation cannot poison the blender.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (9).
 * @param args   Elisp arguments: page, x0, y0, x1, y1, r, g, b, alpha.
 * @param data   Additional data (unused).
 * Return:       Elisp `t' when the rectangle was stored, `nil' otherwise.
 */

emacs_value
emacs_add_decoration(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		     void *data)
{
	(void)data;

	DocState *doc_state = get_doc_state_ptr(env);

	if (!doc_state || doc_state->is_reloading || nargs < 9)
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	float x0 = 0.0f, y0 = 0.0f, x1 = 0.0f, y1 = 0.0f;
	float r = 0.0f, g = 0.0f, b = 0.0f, alpha = 0.0f;
	int page = 0;

	if (!resolve_page_arg(env, args[0], doc_state->pagecount, &page)
	    || !extract_float_coerced(env, args[1], &x0)
	    || !extract_float_coerced(env, args[2], &y0)
	    || !extract_float_coerced(env, args[3], &x1)
	    || !extract_float_coerced(env, args[4], &y1)
	    || !extract_float_coerced(env, args[5], &r)
	    || !extract_float_coerced(env, args[6], &g)
	    || !extract_float_coerced(env, args[7], &b)
	    || !extract_float_coerced(env, args[8], &alpha))
		return EMACS_NIL;

	fz_rect rect;

	if (!rect_to_page_space(x0, y0, x1, y1, &rect))
		return EMACS_NIL;

	if (rect.x1 <= rect.x0 || rect.y1 <= rect.y0)
		return EMACS_NIL;

	Decoration *d = append_decoration(doc_state);

	if (!d)
		return EMACS_NIL;

	d->page = page;
	d->kind = DECORATION_KIND_RECT;
	d->x0 = rect.x0;
	d->y0 = rect.y0;
	d->x1 = rect.x1;
	d->y1 = rect.y1;
	d->color[0] = clamp_style_component(r, DECORATION_DEFAULT_COLOR_R);
	d->color[1] = clamp_style_component(g, DECORATION_DEFAULT_COLOR_G);
	d->color[2] = clamp_style_component(b, DECORATION_DEFAULT_COLOR_B);
	d->alpha = clamp_style_component(alpha, DECORATION_DEFAULT_ALPHA);

	doc_state->decoration_count += 1;

	return EMACS_T;
}

/**
 * emacs_add_stroke - Record one freehand polyline for a page.
 *
 * POINTS is a flat Elisp list of page-space coordinates, `(x0 y0 x1 y1
 * ...)'.  Points are copied into the table, so the caller may reuse its
 * list immediately.  At most DECORATION_MAX_POINTS points are kept — the
 * stroke is truncated, not rejected, because losing the tail of a long
 * freehand line is far better than losing the whole annotation.  Parsing
 * stops the moment that budget is spent: the rest of the list is never
 * walked, so an oversized list costs a bounded number of module calls
 * (~7 per kept point) instead of one set per point in the whole input.
 *
 * Fewer than two usable points draws nothing, so such a call is refused
 * (returns nil) rather than stored.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (7).
 * @param args   Elisp arguments: page, r, g, b, alpha, width, points.
 * @param data   Additional data (unused).
 * Return:       Elisp `t' when the stroke was stored, `nil' otherwise.
 */

emacs_value
emacs_add_stroke(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void)data;

	DocState *doc_state = get_doc_state_ptr(env);

	if (!doc_state || doc_state->is_reloading || nargs < 7)
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	float r = 0.0f, g = 0.0f, b = 0.0f, alpha = 0.0f, width = 0.0f;
	int page = 0;

	if (!resolve_page_arg(env, args[0], doc_state->pagecount, &page)
	    || !extract_float_coerced(env, args[1], &r)
	    || !extract_float_coerced(env, args[2], &g)
	    || !extract_float_coerced(env, args[3], &b)
	    || !extract_float_coerced(env, args[4], &alpha)
	    || !extract_float_coerced(env, args[5], &width))
		return EMACS_NIL;

	/* Width is a page-space length, not a 0..1 component: clamp it to the
	 * same absolute ceiling the coordinates use. */
	if (!isfinite(width))
		return EMACS_NIL;
	if (width < 0.0f)
		width = 0.0f;
	if (width > DECORATION_MAX_ABS_COORD)
		width = DECORATION_MAX_ABS_COORD;

	/* Walk the flat list.  `nth'/'cdr' are the only list primitives
	 * needed; both are interned once. */
	emacs_value Qcdr = env->intern(env, "cdr");
	emacs_value Qcar = env->intern(env, "car");
	emacs_value Qnumberp = env->intern(env, "numberp");
	emacs_value Qlistp = env->intern(env, "listp");

	fz_point pts[DECORATION_MAX_POINTS];
	int pt_count = 0;
	bool truncated = false;

	emacs_value tail = args[6];

	while (true)
		{
			if (env->eq(env, tail, EMACS_NIL))
				break;

			/* Stop parsing once the point budget is spent: every
			 * further point would be discarded anyway, so walking the
			 * rest of the list only burns CPU (a million-point list
			 * cost ~7 module funcalls per point, ~40e6 in total,
			 * with no effect whatsoever).
			 *
			 * The `listp' probe still runs first, so a non-list tail
			 * — the shape that signals a broken caller — keeps being
			 * rejected.  What is no longer validated past the cap is
			 * the point data itself: checking values that will never
			 * be drawn buys nothing, and rejecting the whole stroke
			 * over a tail we were going to drop anyway would lose a
			 * legitimate annotation, which is exactly what the
			 * "truncate, do not reject" rule forbids. */
			if (pt_count >= DECORATION_MAX_POINTS)
				{
					emacs_value tail_is_list =
						env->funcall(env, Qlistp, 1, &tail);

					if (env->eq(env, tail_is_list, EMACS_NIL))
						{
							env->non_local_exit_clear(env);
							return EMACS_NIL;
						}

					truncated = true;
					break;
				}

			emacs_value is_list = env->funcall(env, Qlistp, 1, &tail);

			if (env->eq(env, is_list, EMACS_NIL))
				{
					env->non_local_exit_clear(env);
					return EMACS_NIL;
				}

			emacs_value xv = env->funcall(env, Qcar, 1, &tail);
			emacs_value rest = env->funcall(env, Qcdr, 1, &tail);

			if (env->non_local_exit_check(env)
			    != emacs_funcall_exit_return)
				{
					env->non_local_exit_clear(env);
					return EMACS_NIL;
				}

			if (env->eq(env, rest, EMACS_NIL))
				/* Odd number of coordinates: the trailing
				 * value has no partner, drop it. */
				break;

			emacs_value yv = env->funcall(env, Qcar, 1, &rest);
			emacs_value rest2 = env->funcall(env, Qcdr, 1, &rest);

			if (env->non_local_exit_check(env)
			    != emacs_funcall_exit_return)
				{
					env->non_local_exit_clear(env);
					return EMACS_NIL;
				}

			emacs_value xn = env->funcall(env, Qnumberp, 1, &xv);
			emacs_value yn = env->funcall(env, Qnumberp, 1, &yv);

			if (env->eq(env, xn, EMACS_NIL) || env->eq(env, yn, EMACS_NIL))
				{
					env->non_local_exit_clear(env);
					return EMACS_NIL;
				}

			float px = 0.0f, py = 0.0f;

			if (!extract_float_coerced(env, xv, &px)
			    || !extract_float_coerced(env, yv, &py))
				return EMACS_NIL;

			if (!isfinite(px) || !isfinite(py)
			    || fabsf(px) > DECORATION_MAX_ABS_COORD
			    || fabsf(py) > DECORATION_MAX_ABS_COORD)
				return EMACS_NIL;

			/* No budget check needed here: the guard at the top of
			 * the loop keeps pt_count below DECORATION_MAX_POINTS. */
			pts[pt_count].x = px;
			pts[pt_count].y = py;
			++pt_count;

			tail = rest2;
		}

	/* `truncated' is deliberately never read: the stroke is stored with
	 * the points it did fit (truncate rather than reject), so the flag
	 * only documents *why* the loop stopped early. */
	(void)truncated;

	if (pt_count < 2)
		return EMACS_NIL;

	fz_point *copy = malloc((size_t)pt_count * sizeof(fz_point));

	if (!copy)
		return EMACS_NIL;

	memcpy(copy, pts, (size_t)pt_count * sizeof(fz_point));

	Decoration *d = append_decoration(doc_state);

	if (!d)
		{
			free(copy);
			return EMACS_NIL;
		}

	d->page = page;
	d->kind = DECORATION_KIND_STROKE;
	d->color[0] = clamp_style_component(r, DECORATION_DEFAULT_COLOR_R);
	d->color[1] = clamp_style_component(g, DECORATION_DEFAULT_COLOR_G);
	d->color[2] = clamp_style_component(b, DECORATION_DEFAULT_COLOR_B);
	d->alpha = clamp_style_component(alpha, DECORATION_DEFAULT_ALPHA);
	d->width = width;
	d->pts = copy;
	d->pt_count = pt_count;

	doc_state->decoration_count += 1;

	return EMACS_T;
}

/**
 * emacs_clear_highlights - Drop every highlight of the current document.
 *
 * Frees the table and marks the document dirty; like
 * `seshat-reader-dyn--add-highlight' it does not re-render anything, the
 * next `seshat-reader-dyn--page-image-spec' call paints without them.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (ignored).
 * @param args   Elisp arguments (ignored).
 * @param data   Additional data (unused).
 * Return:       Elisp `t' on success, `nil' when no document is loaded.
 */

emacs_value
emacs_clear_highlights(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		       void *data)
{
	(void)nargs;
	(void)args;
	(void)data;

	DocState *doc_state = get_doc_state_ptr(env);

	if (!doc_state)
		return EMACS_NIL;

	free_decoration_table(doc_state->decorations, doc_state->decoration_count);
	doc_state->decorations = NULL;
	doc_state->decoration_count = 0;
	doc_state->decoration_cap = 0;

	return EMACS_T;
}

/**
 * snapshot_page_decorations - Deep-copy the decorations of one page.
 *
 * The Emacs main thread owns `DocState->decorations', while the entry
 * point below rasterizes a page synchronously on that same thread; a
 * snapshot is nonetheless taken, for two reasons: the painter signature
 * takes a plain array (no DocState walk), and the copy makes the
 * ownership rule of `free_decoration_table' the single release path for
 * this call as well.
 *
 * DECORATION_KIND_STROKE entries own a heap block (`pts'), so a struct
 * copy alone would alias it with the DocState table and the two owners
 * would free the same pointer.  Every stroke's points are therefore DEEP
 * COPIED, exactly like `submit_render_job' does for the worker path.
 * RECT entries have `pts == NULL' and need no copy.
 *
 * A failed allocation is not an error: the page renders without the
 * decoration that could not be copied, and the partially built snapshot
 * is still fully owned (every not-yet-filled slot is zeroed up front).
 *
 * @param doc_state  Document owning the table.
 * @param page_num   0-based page index to copy.
 * @param out_count  Receives the number of entries in the returned array.
 * Return:          The snapshot, or NULL when the page has no decoration.
 */

static Decoration *
snapshot_page_decorations(DocState *doc_state, int page_num, int *out_count)
{
	if (out_count)
		*out_count = 0;

	if (!doc_state || !doc_state->decorations || doc_state->decoration_count <= 0)
		return NULL;

	int count = 0;

	for (int i = 0; i < doc_state->decoration_count; ++i)
		if (doc_state->decorations[i].page == page_num)
			++count;

	if (count <= 0)
		return NULL;

	Decoration *snap = calloc((size_t)count, sizeof(Decoration));

	if (!snap)
		return NULL;

	int j = 0;

	for (int i = 0; i < doc_state->decoration_count; ++i)
		{
			const Decoration *src = &doc_state->decorations[i];

			if (src->page != page_num)
				continue;

			snap[j] = *src;
			snap[j].pts = NULL;
			snap[j].pt_count = 0;

			if (src->kind == DECORATION_KIND_STROKE && src->pts
			    && src->pt_count > 0)
				{
					fz_point *copy
						= malloc((size_t)src->pt_count
							 * sizeof(fz_point));

					if (copy)
						{
							memcpy(copy, src->pts,
							       (size_t)src->pt_count
								   * sizeof(fz_point));
							snap[j].pts = copy;
							snap[j].pt_count
								= src->pt_count;
						}
					/* else: leave pts NULL — this stroke
					 * is skipped, nothing to free. */
				}

			++j;
		}

	if (out_count)
		*out_count = j;

	return snap;
}

/**
 * emacs_page_image_spec - Render one page and return its image spec.
 *
 * The read-only counterpart of the display path: it rasterizes PAGE at an
 * explicit SCALE and hands the result back as the very spec
 * `create-image' builds for a page row, so the caller can put the image
 * anywhere it likes.  It exists so that a multi-page view can ask for a
 * page without going through a window: nothing here reads or writes a
 * window parameter, a cache slot or an overlay.
 *
 * PAGE is 1-based, like every other page-addressed entry point, and is
 * validated by `resolve_page_arg'.  SCALE is a multiple of 72 dpi and is
 * clamped to MINRES/72 .. MAXRES/72.  ROTATE defaults to 0 and must be 0,
 * 90, 180 or 270 — anything else is refused rather than snapped to the
 * nearest quarter turn, because a silent snap would let the caller
 * believe a rotation happened.  Every refusal is silent nil (no message):
 * an out-of-range or non-integral page, a non-numeric/non-finite scale, an
 * unsupported rotation, and a document that is being reloaded.
 *
 * The page's decorations are painted onto the bitmap (from a deep-copied
 * snapshot) so that the result matches what the screen shows.
 *
 * Rendering is synchronous on the Emacs main thread; it must not be
 * called from a scrolling or redisplay path.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (2 or 3).
 * @param args   Elisp arguments: page, scale, optional rotate.
 * @param data   Additional data (unused).
 * Return:       The image spec, or nil.
 */

emacs_value
emacs_page_image_spec(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		      void *data)
{
	(void)data;

	DocState *doc_state = get_doc_state_ptr(env);

	/* The module holds no window state, so only the document's own reload
	 * flag guards against freeing the tables under us. */
	if (!doc_state || doc_state->is_reloading)
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	int page = 0;

	if (!resolve_page_arg(env, args[0], doc_state->pagecount, &page))
		return EMACS_NIL;

	float scale = 0.0f;

	if (!extract_float_coerced(env, args[1], &scale) || !isfinite(scale))
		return EMACS_NIL;

	int rotate = 0;

	if (nargs >= 3)
		{
			float rotate_f = 0.0f;

			if (!extract_float_coerced(env, args[2], &rotate_f))
				return EMACS_NIL;

			if (!(rotate_f == 0.0f || rotate_f == 90.0f
			      || rotate_f == 180.0f || rotate_f == 270.0f))
				return EMACS_NIL;

			rotate = (int)rotate_f;
		}

	double resolution = fz_clamp((double)scale * 72.0, MINRES, MAXRES);

	/* `acquire_doc_page' loads the page's display list on first use and
	 * takes a reference; the release below is unconditional so that no
	 * exit path can leak it. */
	DocPage *dp = acquire_doc_page(doc_state, page);

	if (!dp)
		return EMACS_NIL;

	int deco_count = 0;
	Decoration *deco = snapshot_page_decorations(doc_state, page, &deco_count);

	int width = 0;
	int height = 0;
	int data_w = 0;
	int data_h = 0;
	unsigned char *img_data = NULL;
	size_t img_size = 0;

	bool ok = render_page_to_buffer(doc_state, dp, (float)resolution, rotate,
					deco, deco_count, &width, &height,
					&data_w, &data_h, &img_data, &img_size);

	/* This entry point owns both: the worker path frees the snapshot
	 * through `free_draw_thread_args', which does not exist here. */
	free_decoration_table(deco, deco_count);
	release_doc_page(doc_state, dp);

	if (!ok || !img_data)
		return EMACS_NIL;

	/* `data2elisp_canvas' 把 BGRA 字节按行写进 canvas 自己的缓冲，
	 * 返回的 spec 不持有 img_data，故 C 块在用完后即可释放。 */
	emacs_value spec = data2elisp_canvas(env, data_w, data_h, width, height,
					     img_data, img_size);

	free(img_data);

	/* 只有真的产出了 canvas spec 才算“这一页渲染完成”：状态在此置位，
	 * 任何 nil 返回路径（参数非法 / 加载中 / 渲染失败）都不会动它。 */
	if (env->is_not_nil(env, spec))
		set_current_render_status(env);

	return spec;
}

/**
 * emacs_page_size - Report one page's display size without rendering it.
 *
 * The pixel-free counterpart of `emacs_page_image_spec'.  It answers the
 * single question a two-phase multi-page layout asks before anything is
 * rasterized — how many logical pixels does a page occupy at this scale
 * and rotation — and it answers it in exactly the units a rendered spec
 * reports in `:width'/`:height', so a placeholder row can take the
 * image's place without the page height (and with it the scroll extent)
 * moving when the pixels arrive later.
 *
 * The arithmetic is the render path's, step for step:
 *
 *   ctm     = fz_transform_page(page bbox, resolution, rotate)
 *   device  = round(transform(page bbox, ctm))     [== pixmap size]
 *   logical = (int)(device / frame_scale)
 *
 * with `resolution = fz_clamp(scale * 72, MINRES, MAXRES)' and
 * `frame_scale' clamped to 1.0 exactly as `render_page_to_buffer' clamps
 * it — both are load bearing for the equality above.
 *
 * ZERO SIDE EFFECTS, by construction.  It deliberately does NOT go
 * through `acquire_doc_page' / `load_page_dl': that path couples
 * `fz_bound_page' with `fz_new_display_list_from_page' inside one fz_try,
 * so using it would build (and cache) a display list — the expensive half
 * of a render — for every page merely probed for its height.  Here the
 * page is loaded, bounded and dropped within the call, and nothing is
 * written back: no DocPage, no display list, no pixmap, no decoration
 * snapshot, and not even `current_page_number'.
 *
 * The MuPDF work runs on a cloned context, for the same reason
 * `load_page_dl' and `render_page_to_buffer' do: `fz_load_page' parses
 * untrusted page objects and can throw (a corrupt or encrypted document),
 * and such a throw must not leave the document's own context with a
 * pending error or a half-built object.  A clone shares the document's
 * lock set, so this stays safe alongside any other reader of the same
 * document, and `fz_drop_context' releases it on every exit path.
 *
 * PAGE is 1-based and validated by `resolve_page_arg'; SCALE goes through
 * `extract_float_coerced' and must be finite; ROTATE, when given, must be
 * 0, 90, 180 or 270.  Every refusal — including a document that is being
 * reloaded — is a silent nil, exactly as in `emacs_page_image_spec'.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (2 or 3).
 * @param args   Elisp arguments: page, scale, optional rotate.
 * @param data   Additional data (unused).
 * Return:       A two-element list (WIDTH HEIGHT) in logical pixels, or nil.
 */

emacs_value
emacs_page_size(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void)data;

	DocState *doc_state = get_doc_state_ptr(env);

	/* Same guards as `emacs_page_image_spec': the reload flag is the only
	 * thing standing between us and a freed document, and a document with
	 * no pages cannot answer a page question. */
	if (!doc_state || doc_state->is_reloading)
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	int page = 0;

	if (!resolve_page_arg(env, args[0], doc_state->pagecount, &page))
		return EMACS_NIL;

	float scale = 0.0f;

	if (!extract_float_coerced(env, args[1], &scale) || !isfinite(scale))
		return EMACS_NIL;

	int rotate = 0;

	if (nargs >= 3)
		{
			float rotate_f = 0.0f;

			if (!extract_float_coerced(env, args[2], &rotate_f))
				return EMACS_NIL;

			if (!(rotate_f == 0.0f || rotate_f == 90.0f
			      || rotate_f == 180.0f || rotate_f == 270.0f))
				return EMACS_NIL;

			rotate = (int)rotate_f;
		}

	/* Identical resolution policy to the render path: SCALE is a multiple
	 * of 72 dpi, clamped into MINRES..MAXRES. */
	double resolution = fz_clamp((double)scale * 72.0, MINRES, MAXRES);

	/* Identical clamping to `render_page_to_buffer': a non-positive or
	 * tiny `frame_scale' would blow the logical size up past int range. */
	float frame_scale = doc_state->frame_scale;

	if (!(frame_scale > 0.01f))
		frame_scale = 1.0f;

	fz_context *ctx = fz_clone_context(doc_state->ctx);

	if (!ctx)
		return EMACS_NIL;

	/* volatile for the same reason as in `load_page_dl': fz_try is
	 * setjmp/longjmp based, so anything assigned inside it and read after
	 * the block (or dropped in fz_always) must not live only in a register
	 * that longjmp restores.  `bbox' is read after the block, but every read
	 * is short-circuited by `ok', which is only set on the success path.
	 * `bbox' itself is volatile too: -Wclobbered flags any non-volatile
	 * object written between setjmp and longjmp, and the copy below is the
	 * single place where it is read back into a calm local. */
	fz_page *volatile loaded_page = NULL;
	volatile fz_rect bbox = { 0, 0, 0, 0 };
	volatile bool ok = false;

	fz_try(ctx)
		{
			loaded_page = fz_load_page(ctx, doc_state->doc, page);
			bbox = fz_bound_page(ctx, loaded_page);
			ok = true;
		}
	fz_always(ctx)
		{
			if (loaded_page)
				fz_drop_page(ctx, loaded_page);
		}
	fz_catch(ctx)
		{
			ok = false;
		}

	fz_drop_context(ctx);

	if (!ok)
		return EMACS_NIL;

	/* Local copy so the value cannot be aliased to a clobbered register
	 * slot, and so the geometry helpers get a calm, non-volatile input. */
	fz_rect page_bbox = bbox;

	if (!fz_is_valid_rect(page_bbox))
		return EMACS_NIL;

	/* Pure arithmetic from here on — no MuPDF objects, so nothing to drop
	 * and nothing that can throw.  This is the same two steps
	 * `fz_new_pixmap_from_display_list' performs internally to size its
	 * pixmap (a page's display list is created with `fz_bound_page' as its
	 * mediabox, which is why bounding the page and bounding its display
	 * list agree). */
	fz_matrix ctm = fz_transform_page(page_bbox, (float)resolution, rotate);
	fz_irect device = fz_round_rect(fz_transform_rect(page_bbox, ctm));

	int device_w = device.x1 - device.x0;
	int device_h = device.y1 - device.y0;

	/* A degenerate box (whole-page clip, or a throwaway MediaBox) has no
	 * meaningful size; report it as "unknown" rather than as 0 x 0. */
	if (device_w <= 0 || device_h <= 0)
		return EMACS_NIL;

	/* `(int)(int / float)' — integer division by a float, truncated, is
	 * exactly what `render_page_to_buffer' does to the pixmap dimensions. */
	int logical_w = (int)(device_w / frame_scale);
	int logical_h = (int)(device_h / frame_scale);

	if (logical_w <= 0 || logical_h <= 0)
		return EMACS_NIL;

	/* A plain two-element list (not a dotted pair), so the caller can use
	 * `nth' 0/1 or `destructuring-bind' interchangeably. */
	emacs_value dims[2] = { env->make_integer(env, logical_w),
				env->make_integer(env, logical_h) };

	return env->funcall(env, env->intern(env, "list"), 2, dims);
}

// Entrypoint for the dynamic module
int
emacs_module_init(struct emacs_runtime *runtime)
{
	emacs_env *env = runtime->get_environment(runtime);

	if (!env)
		{
			fprintf(stderr, "Failed to get Emacs environment.\n");
			return 1;
		}

	// Initialize global MuPDF mutexes
	for (int i = 0; i < FZ_LOCK_MAX; ++i)
		{
			pthread_mutex_init(&g_mupdf_mutex[i], NULL);
		}

	// Module function registrations
	register_module_func(env, emacs_load_doc,
			     "seshat-reader-dyn--load-doc", 1, 2,
			     "Loads a DOC to be rendered in Emacs.");

	register_module_func(env, emacs_close_doc,
			     "seshat-reader-dyn--close-doc", 0, 0,
			     "Frees the DocState in memory and all other "
			     "artifacts related to the current document.");

	register_module_func(env, emacs_doc_invert,
			     "seshat-reader-dyn--doc-invert", 1, 1,
			     "Toggles the process-wide dark mode flag that "
			     "every document in this Emacs renders with; the "
			     "colours come from "
			     "seshat-reader-dyn--doc-tint. No page is "
			     "re-rendered here, so call "
			     "seshat-reader--redisplay-all-windows "
			     "afterwards.");

	register_module_func(env, emacs_doc_tint,
			     "seshat-reader-dyn--doc-tint", 2, 2,
			     "Sets the process-wide dark mode colours: BG "
			     "and FG are 0xRRGGBB integers, and every "
			     "pixel's luminance is mapped between them. "
			     "Negative values clear the tint and restore "
			     "the plain invert + gamma rendering. Only the "
			     "process-wide state changes here, so the "
			     "caller has to redraw the visible pages "
			     "afterwards.");

	register_module_func(env, emacs_page_text,
			     "seshat-reader-dyn--page-text", 0, 1,
			     "Extracts the plain text of PAGE, or of the "
			     "current page when PAGE is omitted.");

	register_module_func(env, emacs_text_in_rect,
			     "seshat-reader-dyn--text-in-rect", 5, 5,
			     "Extracts the text intersecting the rectangle "
			     "(X0 Y0 X1 Y1) on PAGE, in page coordinates.");

	register_module_func(env, emacs_rects_in_rect,
			     "seshat-reader-dyn--rects-in-rect", 5, 5,
			     "Returns the text quads intersecting the "
			     "rectangle (X0 Y0 X1 Y1) on PAGE, in page "
			     "coordinates, as a list of (X0 Y0 X1 Y1) "
			     "float quadruples in reading order; nil when "
			     "no character falls inside.");

	register_module_func(env, emacs_lines_in_rect,
			     "seshat-reader-dyn--lines-in-rect", 5, 5,
			     "Returns the whole text lines that the "
			     "rectangle (X0 Y0 X1 Y1) on PAGE touches, in "
			     "page coordinates, as a list of (X0 Y0 X1 Y1) "
			     "float quadruples in reading order. A line "
			     "the rectangle does not touch is omitted; a "
			     "touched line is reported in full. nil when "
			     "nothing is touched.");

	register_module_func(env, emacs_search_page,
			     "seshat-reader-dyn--search-page", 3, 3,
			     "Searches the text layer of PAGE (1-based) for "
			     "NEEDLE (UTF-8) and returns at most LIMIT hit "
			     "rectangles as a list of (X0 Y0 X1 Y1) float "
			     "quadruples in page coordinates, in reading "
			     "order; nil when nothing matches. LIMIT is "
			     "clamped to 1..10000, with nil, zero and "
			     "non-numbers meaning 1000, but one page never "
			     "returns more than SEARCH_PAGE_MAX_QUADS (1024) "
			     "hits however large LIMIT is.");

	register_module_func(env, emacs_add_highlight,
			     "seshat-reader-dyn--add-highlight", 5, 5,
			     "Adds a highlight rectangle (X0 Y0 X1 Y1) on "
			     "PAGE (1-based), in page coordinates. The next "
			     "`seshat-reader-dyn--page-image-spec' paints it.");

	register_module_func(env, emacs_add_decoration,
			     "seshat-reader-dyn--add-decoration", 9, 9,
			     "Adds a rectangle (X0 Y0 X1 Y1) on PAGE "
			     "(1-based) in page coordinates, painted in "
			     "colour (R G B, each 0..1) at ALPHA (0..1). The "
			     "next `seshat-reader-dyn--page-image-spec' paints "
			     "it.");

	register_module_func(env, emacs_add_stroke,
			     "seshat-reader-dyn--add-stroke", 7, 7,
			     "Adds a freehand polyline on PAGE (1-based): "
			     "colour (R G B, each 0..1), ALPHA (0..1), "
			     "WIDTH in page points, and POINTS as a flat "
			     "list (X0 Y0 X1 Y1 ...) in page coordinates. The "
			     "next `seshat-reader-dyn--page-image-spec' paints "
			     "it.");

	register_module_func(env, emacs_clear_highlights,
			     "seshat-reader-dyn--clear-highlights", 0, 0,
			     "Removes every highlight of the current document. "
			     "The next `seshat-reader-dyn--page-image-spec' "
			     "paints the page without them.");

	register_module_func(env, emacs_page_image_spec,
			     "seshat-reader-dyn--page-image-spec", 2, 3,
			     "Renders PAGE (1-based) at SCALE, a multiple of "
			     "72 dpi clamped to MINRES/72 .. MAXRES/72, and "
			     "returns the image spec `create-image' builds for "
			     "the page overlay, decorations included, without "
			     "touching any window. Optional ROTATE must be 0, "
			     "90, 180 or 270 and defaults to 0. An out-of-range "
			     "or non-integral PAGE, a non-numeric or non-finite "
			     "SCALE, any other ROTATE value and a document that "
			     "is being reloaded all return nil silently. The "
			     "current page, the window state, the page cache "
			     "and every overlay are left unchanged.");

	register_module_func(env, emacs_page_size,
			     "seshat-reader-dyn--page-size", 2, 3,
			     "Returns the display size of PAGE (1-based) at "
			     "SCALE, a multiple of 72 dpi clamped to MINRES/72 "
			     ".. MAXRES/72, as a two-element list (WIDTH "
			     "HEIGHT) in logical pixels — the very units "
			     "`seshat-reader-dyn--page-image-spec' reports in "
			     "the spec's :width and :height, so a placeholder "
			     "can take an image's place without the page "
			     "height changing. Optional ROTATE must be 0, 90, "
			     "180 or 270 and defaults to 0. Nothing is "
			     "rasterized: no display list is built, no pixmap "
			     "is allocated and no page cache entry is touched, "
			     "which keeps this a microsecond-scale query. An "
			     "out-of-range or non-integral PAGE, a non-numeric "
			     "or non-finite SCALE, any other ROTATE value and "
			     "a document that is being reloaded all return nil "
			     "silently.");

	// Register buffer-local variables.
	permanent_buffer_local_var(env, "seshat-reader-current-doc-pagecount");
	permanent_buffer_local_var(env, "seshat-reader-current-doc-render-status");
	permanent_buffer_local_var(env, "seshat-reader-current-doc-state-ptr");
	permanent_buffer_local_var(env, "seshat-reader-current-doc-outline");
	permanent_buffer_local_var(env, "seshat-reader--recent-pagenumber-fallback");

	// Provide the current dynamic module as a feature to Emacs
	provide(env, "seshat-render-core");

	fprintf(stderr,
		"seshat-reader: dynamic module has been loaded successfully.\n");
	return 0;
}
