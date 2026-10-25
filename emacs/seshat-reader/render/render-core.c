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
#include "render-threads.h"

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
 * Free a render job's argument block together with the per-page
 * decoration snapshot it owns.  Every exit path of `draw_page_thread'
 * must release both through this helper.
 *
 * The snapshot owns its own copies of every stroke's point array (see
 * submit_render_job), so freeing it here cannot touch the DocState table.
 */

static void
free_draw_thread_args(DrawThreadArgs *args)
{
	if (!args)
		return;

	free_decoration_table(args->deco, args->deco_count);
	free(args);
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

	fz_page *loaded_page = NULL;
	bool success = false;

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
 * Thread function to render a page and encode it as a PNM image.
 *
 * Uses the page's display list to generate a pixmap, optionally inverts
 * and gamma-corrects it, then encodes it to PNM and stores it in
 * `cp->img_data'. Updates image dimensions and status, and signals
 * completion via a condition variable.
 *
 * @param arg  Pointer to DrawThreadArgs (contains DocState and CachedPage).
 * Return:     NULL (result is stored in CachedPage).
 */

void *
draw_page_thread(void *arg)
{
	DrawThreadArgs *args = (DrawThreadArgs *)arg;
	if (!args)
		return NULL;

	DocState *doc_state = args->doc_state;
	EmacsWinState *win_state = args->win_state;
	CachedPage *cp = args->cp;
	DocPage *dp = args->dp;

	if (!doc_state || !win_state || !cp || !dp)
		{
			free_draw_thread_args(args);
			return NULL;
		}

	 /* If the document is being reloaded/closed, or the window is closing, */
	 /* abort this job safely. */
	if (doc_state->is_reloading || win_state->closing)
		{
			mark_cp_error_if_rendering(cp);
			release_doc_page(doc_state, dp);

			atomic_fetch_sub(&doc_state->active_jobs, 1);
			atomic_fetch_sub(&win_state->active_jobs, 1);

			free_draw_thread_args(args);
			return NULL;
		}

	// If the page isn't ready then parse/load it
	if (!dp->ready)
		load_page_dl(doc_state, dp);
	if (!dp->ready || !dp->display_list)
		{
			mark_cp_error_if_rendering(cp);
			release_doc_page(doc_state, dp);
			atomic_fetch_sub(&doc_state->active_jobs, 1);
			atomic_fetch_sub(&win_state->active_jobs, 1);
			free_draw_thread_args(args);
			return NULL;
		}

	fz_context *ctx = fz_clone_context(doc_state->ctx);
	if (!ctx)
		{
			mark_cp_error_if_rendering(cp);
			release_doc_page(doc_state, dp);
			atomic_fetch_sub(&doc_state->active_jobs, 1);
			atomic_fetch_sub(&win_state->active_jobs, 1);
			free_draw_thread_args(args);
			return NULL;
		}

	fz_matrix ctm = fz_transform_page(dp->bbox,
					  win_state->resolution,
					  win_state->rotate);
	fz_pixmap *pixmap = NULL;
	fz_buffer *buf = NULL;
	fz_output *out = NULL;
	int local_imgw = 0;
	int local_imgh = 0;

	bool render_ok = false;
	float frame_scale = doc_state->frame_scale;

	if (frame_scale <= 0.0f)
		frame_scale = 1.0f;

	fz_try(ctx)
		{
			pixmap = fz_new_pixmap_from_display_list(ctx, dp->display_list,
								 ctm, fz_device_rgb(ctx), 0);

			if (doc_state->invert)
				{
					fz_invert_pixmap_luminance(ctx, pixmap);
					fz_gamma_pixmap(ctx, pixmap, 1 / 1.4f);
				}

			/* Wash this page's decorations over the
			 * rasterized page.  The order matters: the
			 * inversion above must already be done, otherwise
			 * the decoration colours would be inverted too, and
			 * the PNM encoding below must see the result.
			 * Rectangles are grouped by style and each group is
			 * filled once, so overlapping highlights keep a
			 * uniform alpha instead of stacking up. */
			if (args->deco_count > 0)
				{
					fz_device *dev = NULL;
					fz_path *path = NULL;

					/* One flag per decoration: a rect is
					 * emitted by exactly one style group,
					 * and styles beyond the group cap are
					 * filled individually (see below).  A
					 * failed allocation simply leaves every
					 * flag false, which degrades to
					 * "paint each rect on its own". */
					bool *assigned
						= calloc((size_t)args->deco_count,
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
									     < args->deco_count;
									     ++i)
										{
											if (args->deco[i].kind
											    != DECORATION_KIND_RECT)
												continue;

											int g;
											for (g = 0;
											     g < group_count;
											     ++g)
												{
													if (groups[g][0]
														== args->deco[i].color[0]
														&& groups[g][1]
														== args->deco[i].color[1]
														&& groups[g][2]
														== args->deco[i].color[2]
														&& groups[g][3]
														== args->deco[i].alpha)
														break;
												}

											if (g < group_count)
												assigned[i] = true;
											else if (group_count
												 < DECORATION_MAX_STYLE_GROUPS)
												{
													groups[group_count][0]
														= args->deco[i].color[0];
													groups[group_count][1]
														= args->deco[i].color[1];
													groups[group_count][2]
														= args->deco[i].color[2];
													groups[group_count][3]
														= args->deco[i].alpha;
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
									     i < args->deco_count;
									     ++i)
										{
											if (!assigned[i]
											    || args->deco[i].kind
												   != DECORATION_KIND_RECT)
												continue;
											if (args->deco[i].color[0]
												    != groups[g][0]
											    || args->deco[i].color[1]
												    != groups[g][1]
											    || args->deco[i].color[2]
												    != groups[g][2]
											    || args->deco[i].alpha
												    != groups[g][3])
												continue;

											fz_rectto(
												ctx, path,
												args->deco[i].x0,
												args->deco[i].y0,
												args->deco[i].x1,
												args->deco[i].y1);
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
									     i < args->deco_count;
									     ++i)
										{
											if (assigned[i]
											    || args->deco[i].kind
												   != DECORATION_KIND_RECT)
												continue;

											path = fz_new_path(ctx);
											fz_rectto(
												ctx, path,
												args->deco[i].x0,
												args->deco[i].y0,
												args->deco[i].x1,
												args->deco[i].y1);
											fz_fill_path(
												ctx, dev, path, 0,
												fz_identity,
												fz_device_rgb(ctx),
												args->deco[i].color,
												args->deco[i].alpha,
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
							     i < args->deco_count; ++i)
								{
									const Decoration *d
										= &args->deco[i];

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

			local_imgh = (int)(fz_pixmap_height(ctx, pixmap) / frame_scale);
			local_imgw = (int)(fz_pixmap_width(ctx, pixmap) / frame_scale);
			buf = fz_new_buffer(ctx, 1024);
			out = fz_new_output_with_buffer(ctx, buf);
			fz_write_pixmap_as_pnm(ctx, out, pixmap);
			render_ok = true;
		}
	fz_always(ctx)
		{
			if (pixmap)
				fz_drop_pixmap(ctx, pixmap);

			if (out)
				{
					fz_close_output(ctx, out);
					fz_drop_output(ctx, out);
				}
		}
	fz_catch(ctx)
		{
			render_ok = false;
		}

	if (!render_ok || !buf || local_imgw <= 0 || local_imgh <= 0)
		{
			if (buf)
				fz_drop_buffer(ctx, buf);

			fz_drop_context(ctx);
			mark_cp_error_if_rendering(cp);
			release_doc_page(doc_state, dp);
			atomic_fetch_sub(&doc_state->active_jobs, 1);
			atomic_fetch_sub(&win_state->active_jobs, 1);
			free_draw_thread_args(args);
			return NULL;
		}

	size_t local_img_size = buf->len;
	char *local_img_data = malloc(local_img_size);

	if (!local_img_data)
		{
			fz_drop_buffer(ctx, buf);
			fz_drop_context(ctx);
			mark_cp_error_if_rendering(cp);
			release_doc_page(doc_state, dp);
			atomic_fetch_sub(&doc_state->active_jobs, 1);
			atomic_fetch_sub(&win_state->active_jobs, 1);
			free_draw_thread_args(args);
			return NULL;
		}

	memcpy(local_img_data, buf->data, local_img_size);
	fz_drop_buffer(ctx, buf);
	fz_drop_context(ctx);

	/* If the slot was invalidated while we were rendering, its status will */
	/* no longer be PAGE_STATUS_RENDERING. In that case, discard the result. */

	pthread_mutex_lock(&cp->mutex);
	if (cp->status == PAGE_STATUS_RENDERING)
		{
			free(cp->img_data);
			cp->img_data = local_img_data;
			cp->img_size = local_img_size;
			cp->imgw = local_imgw;
			cp->imgh = local_imgh;
			cp->status = PAGE_STATUS_READY;
			pthread_cond_signal(&cp->cond);
		}
	else
		free(local_img_data);
	pthread_mutex_unlock(&cp->mutex);

	release_doc_page(doc_state, dp);
	atomic_fetch_sub(&doc_state->active_jobs, 1);
	atomic_fetch_sub(&win_state->active_jobs, 1);

	free_draw_thread_args(args);
	return NULL;
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
 * Build a sliding cache window around the given page.
 *
 * This function assumes that there are no active render jobs for this
 * window. Callers should call wait_for_win_jobs() first.
 */

void
build_cache_window(DocState *doc_state, EmacsWinState *win_state, int n)
{
	if (!doc_state || !win_state)
		return;
	if (!doc_state->doc_pages || doc_state->pagecount <= 0)
		return;

	int pagecount = doc_state->pagecount;
	if (n < 0)
		n = 0;
	if (n >= pagecount)
		n = pagecount - 1;

	int start, end;
	if (n < MAX_CACHE_WINDOW_SIZE)
		{
			start = 0;
			end = n + MAX_CACHE_WINDOW_SIZE;
			if (end >= pagecount)
				end = pagecount - 1;
		}
	else if (n > (pagecount - 1) - MAX_CACHE_WINDOW_SIZE)
		{
			end = pagecount - 1;
			start = n - MAX_CACHE_WINDOW_SIZE;
			if (start < 0)
				start = 0;
		}
	else
		{
			start = n - MAX_CACHE_WINDOW_SIZE;
			end = n + MAX_CACHE_WINDOW_SIZE;
		}

	win_state->current_page_number = n;
	win_state->current_window_index = n - start;

	for (int i = 0; i < MAX_CACHE_SIZE; ++i)
		{
			int idx = start + i;
			CachedPage *cp = win_state->cache_window[i];
			if (!cp)
				continue;

			if (idx < pagecount && idx <= end)
				{
					/* Check if we can reuse the existing CachedPage */
					pthread_mutex_lock(&cp->mutex);
					int old_page_num = cp->page_num;
					bool reusable = (old_page_num == idx &&
							 cp->status == PAGE_STATUS_READY &&
							 cp->img_data != NULL);
					pthread_mutex_unlock(&cp->mutex);

					if (reusable)
						continue;

					if (old_page_num == idx)
						{
							/* Clear the slot, but keep DocPage reference. */
							clear_cp(cp);
							DocPage *dp = &doc_state->doc_pages[idx];
							if (!dp->ready)
								load_page_dl(doc_state, dp);
							if (!dp->ready)
								{
									mark_cp_error(cp);
									continue;
								}

							if (!submit_render_job(doc_state, win_state, cp, dp))
								mark_cp_error(cp);
						}
					else
						{
							/* Now we acquire a new DocPage and release the last one. */
							clear_cp_and_release(doc_state, cp);
							DocPage *dp = acquire_doc_page(doc_state, idx);
							if (!dp)
								{
									mark_cp_error(cp);
									continue;
								}

							pthread_mutex_lock(&cp->mutex);
							cp->page_num = idx;
							pthread_mutex_unlock(&cp->mutex);

							if (!submit_render_job(doc_state, win_state, cp, dp))
								mark_cp_error(cp);
						}
				}
			else
				{
					/* Outside new window. Clear and release. */
					clear_cp_and_release(doc_state, cp);
				}
		}

	win_state->current_cached_page =
		win_state->cache_window[win_state->current_window_index];
}

/**
 * Slide the cache window forward by one page.
 *
 * Advances to the next page, shifts the cache window if within bounds,
 * reuses or frees cached pages, and spawns rendering jobs as needed.
 * Falls back to full rebuild if near document edges. Waits until the
 * new current page is ready.
 *
 * @param state  Pointer to the current DocState.
 * Return:       true if sliding succeeded, false if at end of document.
 */

void
slide_cache_window_forward(DocState *doc_state, EmacsWinState *win_state)
{
    if (!doc_state || !win_state)
        return;

    if (doc_state->pagecount <= 0)
        return;

    wait_for_win_jobs(win_state);
    int n = win_state->current_page_number + 1;
    if (n < doc_state->pagecount)
        build_cache_window(doc_state, win_state, n);
}

/**
 * Slide the cache window backward by one page.
 *
 * Moves to the previous page, shifts the cache window if within bounds,
 * frees or reuses cached pages, and triggers rendering if needed.
 * Falls back to a full rebuild near document start. Waits until the
 * new current page is ready.
 *
 * @param state  Pointer to the current DocState.
 * Return:       true if sliding succeeded, false if at start of document.
 */

void
slide_cache_window_backward(DocState *doc_state, EmacsWinState *win_state)
{
    if (!doc_state || !win_state)
        return;

    if (doc_state->pagecount <= 0)
        return;

    wait_for_win_jobs(win_state);
    int n = win_state->current_page_number - 1;
    if (n >= 0)
        build_cache_window(doc_state, win_state, n);
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

        clear_all_overlays(env);

        clear_doc_state_ptr(env);
        wait_for_doc_jobs(old_state);
        free_doc_state(old_state);
    }

    emacs_value curr_win = EMACS_CURR_WIN;
    emacs_value current_doc_overlay = EMACS_NIL;

    DocState *doc_state = NULL;
    EmacsWinState *win_state = NULL;

    current_doc_overlay = init_overlay(env, curr_win);

    if (env->eq(env, current_doc_overlay, EMACS_NIL))
    {
        emacs_message(env, "Failed to create seshat-reader overlay.");
        return EMACS_NIL;
    }

    doc_state = init_doc_state_ptr(env);

    if (!doc_state)
    {
        emacs_message(env, "Document cannot be loaded into memory.");
        goto cleanup;
    }

    reset_doc_state(doc_state);

    win_state = init_win_state_ptr(env, doc_state, curr_win);

    if (!win_state)
    {
        emacs_message(env, "Window state couldn't be initialized.");
        goto cleanup;
    }

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

    if (doc_state->frame_scale <= 0.0f)
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

    win_state->current_page_number = start_page;

    build_cache_window(doc_state, win_state, start_page);

    set_current_pagecount(env, doc_state);
    set_current_page_number(env, win_state->current_page_number);

    CachedPage *cp = win_state->current_cached_page;

    if (!wait_for_cached_page(cp))
    {
        emacs_message(env, "Failed to render the current page.");
        goto cleanup;
    }

    if (!display_cached_page(env, cp, current_doc_overlay))
    {
        emacs_message(env, "Failed to display the rendered page.");
        goto cleanup;
    }

    set_current_render_status(env);

    return EMACS_T;

cleanup:
    if (!env->eq(env, current_doc_overlay, EMACS_NIL))
    {
        if (win_state)
        {
            clear_overlay_and_win_state(env, current_doc_overlay);
        }
        else
        {
            emacs_value clear_window_args[3] = {
                curr_win,
                env->intern(env, "overlay"),
                EMACS_NIL
            };

            env->funcall(env,
                         env->intern(env, "set-window-parameter"),
                         3,
                         clear_window_args);

            env->funcall(env,
                         env->intern(env, "delete-overlay"),
                         1,
                         &current_doc_overlay);
        }
    }
    else if (win_state)
    {
        win_state->closing = true;
        wait_for_win_jobs(win_state);
        free_cache_window(win_state);
        free(win_state);
    }

    if (doc_state)
    {
        wait_for_doc_jobs(doc_state);
        free_doc_state(doc_state);
    }

    clear_doc_state_ptr(env);

    return EMACS_NIL;
}

/**
 * Redisplay the current document page in Emacs.
 *
 * Resets visual state (no rotation/inversion), re-renders the current
 * cached page in a background thread, waits for completion, and updates
 * the image in the associated Emacs overlay.
 *
 * @param env    Emacs module environment.
 * @param nargs  Argument count (unused).
 * @param args   Argument values (unused).
 * @param data   Additional data (unused).
 * Return:       EMACS_T on success, EMACS_NIL if state is not available.
 */

emacs_value
emacs_redisplay_doc(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                    void *data)
{
	(void)nargs;
	(void)args;
	(void)data;

	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	wait_for_win_jobs(win_state);
	nullify_window_cache(win_state);
	build_cache_window(doc_state,
			   win_state,
			   win_state->current_page_number);

	CachedPage *cp = win_state->current_cached_page;

	if (!wait_for_cached_page(cp))
		{
			emacs_message(env, "Failed to render the page.");
			return EMACS_NIL;
		}
	if (!display_cached_page(env, cp, overlay))
		{
			emacs_message(env, "Failed to display the rendered page.");
			return EMACS_NIL;
		}

	set_current_render_status(env);
	return EMACS_T;
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
			return EMACS_NIL;
		}

	state->is_reloading = true;

	clear_all_overlays(env);

	clear_doc_state_ptr(env);

	wait_for_doc_jobs(state);
	free_doc_state(state);

	return EMACS_T;
}

/**
 * emacs_next_page - Move to and display the next page in the overlay.
 * @env:   The Emacs environment pointer.
 * @nargs: (ignored).
 * @args:  (ignored).
 * @data:  (ignored).
 *
 * Return: Elisp `t` on completion, `nil` otherwise.
 */

emacs_value
emacs_next_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
    (void)nargs;
    (void)args;
    (void)data;

    DocState *doc_state = NULL;
    EmacsWinState *win_state = NULL;
    emacs_value overlay = EMACS_NIL;

    if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
        return EMACS_NIL;

    if (win_state->current_page_number >= doc_state->pagecount - 1)
    {
        emacs_message(env, "Already last page!");
        return EMACS_NIL;
    }

    return render_and_display_page(env, doc_state, win_state, overlay, win_state->current_page_number + 1);
}

/**
 * emacs_prev_page - Move to and display the previous page in the overlay.
 * @env:   The Emacs environment pointer.
 * @nargs: (ignored).
 * @args:  (ignored).
 * @data:  (ignored).
 *
 * Return: Elisp `t` if page moved, `nil` if already at first page (and warn).
 */

emacs_value
emacs_prev_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
	(void)nargs;
	(void)args;
	(void)data;

	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	if (win_state->current_page_number <= 0)
		{
			emacs_message(env, "Already first page!");
			return EMACS_NIL;
		}

	return render_and_display_page(env,
			 doc_state,
			 win_state,
			 overlay,
			 win_state->current_page_number - 1);
}

/**
 * emacs_first_page - Jump to and display the first page of the document.
 * @env:   The Emacs environment pointer.
 * @nargs: (ignored).
 * @args:  (ignored).
 * @data:  (ignored).
 *
 * Return: Elisp `t` on success, `nil` if already at the first page (and warn).
 */

emacs_value
emacs_first_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                 void *data)
{
	(void)nargs;
	(void)args;
	(void)data;

	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	if (win_state->current_page_number == 0)
		{
			emacs_message(env, "Already first page!");
			return EMACS_NIL;
		}

	return render_and_display_page(env, doc_state, win_state, overlay, 0);
}

/**
 * emacs_last_page - Jump to and display the last page of the document.
 * @env:   The Emacs environment pointer.
 * @nargs: (ignored).
 * @args:  (ignored).
 * @data:  (ignored).
 *
 * Return: Elisp `t` on success, `nil` if already at the last page (and warn).
 */

emacs_value
emacs_last_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
    (void)nargs;
    (void)args;
    (void)data;

    DocState *doc_state = NULL;
    EmacsWinState *win_state = NULL;
    emacs_value overlay = EMACS_NIL;

    if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
        return EMACS_NIL;

    if (win_state->current_page_number >= doc_state->pagecount - 1)
    {
        emacs_message(env, "Already the last page!");
        return EMACS_NIL;
    }

    return render_and_display_page(env,
                     doc_state,
                     win_state,
                     overlay,
                     doc_state->pagecount - 1);
}

/**
 * emacs_goto_page - Jump to a specific page number and display it.
 * @env:   The Emacs environment pointer.
 * @nargs: Number of Elisp args (should be 1).
 * @args:  Array of Elisp argument values; args[0] is desired page index.
 * @data:  (ignored).
 *
 * Return: Elisp `t` on success or out-of-bounds (always `t`), otherwise emits a
 * bounds warning.
 */

emacs_value
emacs_goto_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                void *data)
{
	(void)nargs;
	(void)data;

	int page_number = env->extract_integer(env, args[0]);

	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	return render_and_display_page(env, doc_state, win_state, overlay, page_number);
}

/**
 * emacs_doc_change_page_size - Scale the displayed image to a new size.
 * @env:   The Emacs environment pointer.
 * @nargs: Number of Elisp args (should be 1).
 * @args:  Array of Elisp argument values; args[0] is the float scale factor.
 * @data:  (ignored).
 *
 * Return: Elisp float of new clamped scale on completion, `nil` otherwise.
 */

emacs_value
emacs_doc_scale_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		     void *data)
{
	(void)nargs;
	(void)data;
	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;
	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;
	if (doc_state->pagecount <= 0)
		return EMACS_NIL;
	float scale_factor = env->extract_float(env, args[0]);
	double new_res = fz_clamp(scale_factor * 72.0, MINRES, MAXRES);

	// Calculate the clamped scale factor to return to Elisp
	double scale_clamped = new_res / 72.0;

	wait_for_win_jobs(win_state);
	if (win_state->resolution != new_res)
		{
			win_state->resolution = new_res;
			nullify_window_cache(win_state);
		}
	build_cache_window(doc_state,
			   win_state,
			   win_state->current_page_number);
	CachedPage *cp = win_state->current_cached_page;
	if (!wait_for_cached_page(cp))
		{
			emacs_message(env, "Failed to render the page.");
			return EMACS_NIL;
		}
	if (!display_cached_page(env, cp, overlay))
		{
			emacs_message(env, "Failed to display the rendered page.");
			return EMACS_NIL;
		}
	set_current_render_status(env);

	return env->make_float(env, scale_clamped);
}

/**
 * emacs_doc_rotate - rotate the displayed image by rotation angle.
 * @env:   The Emacs environment pointer.
 * @nargs: Number of Elisp args (should be 1).
 * @args:  Array of Elisp argument values, args[0] is the angle (in degrees).
 * @data:  (ignored).
 *
 * Return: Elisp `t` on completion, `nil` otherwise.
 */

emacs_value
emacs_doc_rotate(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
	(void)nargs;
	(void)data;

	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;
	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	int rotation_deg = env->extract_integer(env, args[0]);
	wait_for_win_jobs(win_state);

	int new_rotate = (win_state->rotate + rotation_deg) % 360;
	if (new_rotate < 0)
		new_rotate += 360;

	if (win_state->rotate != new_rotate)
	{
		win_state->rotate = new_rotate;
		nullify_window_cache(win_state);
	}

	build_cache_window(doc_state, win_state, win_state->current_page_number);
	CachedPage *cp = win_state->current_cached_page;

	if (!wait_for_cached_page(cp))
		{
			emacs_message(env, "Failed to render the page.");
			return EMACS_NIL;
		}

	if (!display_cached_page(env, cp, overlay))
		{
			emacs_message(env, "Failed to display the rendered page.");
			return EMACS_NIL;
		}

	set_current_render_status(env);
	return EMACS_T;
}

emacs_value
emacs_doc_window_create(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                        void *data)
{
	(void)nargs;
	(void)data;

	emacs_value win = args[0];
	DocState *doc_state = get_doc_state_ptr(env);

	if (!doc_state)
		{
			emacs_message(env, "No valid DocState user pointer found.");
			return EMACS_NIL;
		}

	emacs_value overlay = init_overlay(env, win);
	if (env->eq(env, overlay, EMACS_NIL))
		{
			emacs_message(env, "Failed to create seshat-reader overlay.");
			return EMACS_NIL;
		}

	EmacsWinState *win_state = init_win_state_ptr(env, doc_state, win);
	if (!win_state)
		{
			emacs_message(env, "Window state couldn't be initialized.");
			emacs_value clear_window_args[3] = {
				win,
				env->intern(env, "overlay"),
				EMACS_NIL
			};
			env->funcall(env, env->intern(env, "set-window-parameter"), 3,
				     clear_window_args);

			env->funcall(env, env->intern(env, "delete-overlay"), 1,
				     &overlay);
			return EMACS_NIL;
		}

	return EMACS_T;
}

emacs_value
emacs_doc_window_close(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                       void *data)
{
	(void)nargs;
	(void)data;

	emacs_value overlay = args[0];

	clear_overlay_and_win_state(env, overlay);

	/* If `clear_overlay_and_win_state' did not delete the overlay because */
	/* the win-state property was already missing, delete it here as a */
	/* fallback. */
	emacs_value overlayp =
		env->funcall(env, env->intern(env, "overlayp"), 1, &overlay);

	if (env->eq(env, overlayp, EMACS_T))
		{
			emacs_value window_sym = env->intern(env, "window");
			emacs_value overlay_window_args[2] = {
				overlay,
				window_sym
			};
			emacs_value win =
				env->funcall(env, env->intern(env, "overlay-get"), 2,
					     overlay_window_args);
			if (!env->eq(env, win, EMACS_NIL))
				{
					emacs_value window_overlay_args[2] = {
						win,
						env->intern(env, "overlay")
					};
					emacs_value window_overlay =
						env->funcall(env, env->intern(env, "window-parameter"), 2,
							     window_overlay_args);

					if (env->eq(env, window_overlay, overlay))
						{
							emacs_value set_args[3] = {
								win,
								env->intern(env, "overlay"),
								EMACS_NIL
							};

							env->funcall(env, env->intern(env, "set-window-parameter"), 3,
								     set_args);
						}
				}

			env->funcall(env, env->intern(env, "delete-overlay"), 1,
				     &overlay);
		}

	return EMACS_T;
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
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	/* Bail out during reload/close windows to avoid use-after-free. */
	if (doc_state->is_reloading || win_state->closing)
		return EMACS_NIL;

	int page_number = (nargs >= 1) ? (int)env->extract_integer(env, args[0])
		: win_state->current_page_number;

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

	fz_page *page = NULL;
	fz_stext_page *stext = NULL;
	fz_buffer *buf = NULL;
	fz_output *out = NULL;
	bool ok = false;

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

	fz_page *page = NULL;
	fz_stext_page *stext = NULL;
	fz_buffer *buf = NULL;

	/* Collected quads: plain malloc, so a failure truncates the result
	 * instead of throwing.  Freed on every path below. */
	fz_quad *quads = NULL;
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
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	/* Bail out during reload/close windows to avoid use-after-free. */
	if (doc_state->is_reloading || win_state->closing)
		return EMACS_NIL;

	int page_number = (int)env->extract_integer(env, args[0]);
	float ax = env->extract_float(env, args[1]);
	float ay = env->extract_float(env, args[2]);
	float bx = env->extract_float(env, args[3]);
	float by = env->extract_float(env, args[4]);

	if (page_number < 0 || page_number >= doc_state->pagecount)
		{
			emacs_message(env, "Page number is out of range.");
			return EMACS_NIL;
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
			return EMACS_NIL;
		}

	return stext_query_in_rect(env, doc_state, page_number, rect,
				   STEXT_QUERY_TEXT);
}

/**
 * emacs_rects_in_rect - Return the text quads intersecting a rectangle.
 *
 * The geometric sibling of `--text-in-rect': same page/coordinate
 * validation, same early-outs during reload/close, same
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
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	/* Bail out during reload/close windows to avoid use-after-free. */
	if (doc_state->is_reloading || win_state->closing)
		return EMACS_NIL;

	int page_number = (int)env->extract_integer(env, args[0]);
	float ax = env->extract_float(env, args[1]);
	float ay = env->extract_float(env, args[2]);
	float bx = env->extract_float(env, args[3]);
	float by = env->extract_float(env, args[4]);

	if (page_number < 0 || page_number >= doc_state->pagecount)
		{
			emacs_message(env, "Page number is out of range.");
			return EMACS_NIL;
		}

	fz_rect rect;

	if (!rect_to_page_space(ax, ay, bx, by, &rect))
		{
			emacs_message(env,
				      "Invalid rectangle: coordinates must be finite.");
			return EMACS_NIL;
		}

	return stext_query_in_rect(env, doc_state, page_number, rect,
				   STEXT_QUERY_RECTS);
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
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	/* Bail out during reload/close windows to avoid use-after-free. */
	if (doc_state->is_reloading || win_state->closing)
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

	fz_page *page = NULL;

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
 * bitmap is not re-rendered here, the caller is expected to batch its
 * updates and then call `seshat-reader-dyn--refresh-highlights'.
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
	doc_state->decorations_dirty = true;

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
	doc_state->decorations_dirty = true;

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
	doc_state->decorations_dirty = true;

	return EMACS_T;
}

/**
 * emacs_clear_highlights - Drop every highlight of the current document.
 *
 * Frees the table and marks the document dirty; like
 * `seshat-reader-dyn--add-highlight' it does not re-render anything, the
 * caller triggers that through `seshat-reader-dyn--refresh-highlights'.
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
	doc_state->decorations_dirty = true;

	return EMACS_T;
}

/**
 * emacs_refresh_highlights - Re-render the page with the current
 * highlights.
 *
 * Adding or clearing highlights deliberately does not repaint: those
 * functions receive one rectangle at a time and can be called in bulk,
 * while every repaint re-rasterizes the whole ±5 page cache window.  The
 * caller therefore batches its mutations and asks for a single refresh.
 *
 * The sequence mirrors `emacs_redisplay_doc' step by step — wait for this
 * window's in-flight render jobs, nullify the cache window, rebuild it
 * around the current page and display the result — which is known to be
 * safe to invoke from Elisp: it runs on the Emacs main thread and never
 * runs concurrently with a render job of the same window.
 *
 * @param env    Emacs module environment.
 * @param nargs  Number of Elisp args (ignored).
 * @param args   Elisp arguments (ignored).
 * @param data   Additional data (unused).
 * Return:       Elisp `t' on success, `nil' on failure.
 */

emacs_value
emacs_refresh_highlights(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
			 void *data)
{
	(void)nargs;
	(void)args;
	(void)data;

	DocState *doc_state = NULL;
	EmacsWinState *win_state = NULL;
	emacs_value overlay = EMACS_NIL;

	if (!get_reader_current_state(env, &doc_state, &win_state, &overlay))
		return EMACS_NIL;

	if (doc_state->pagecount <= 0)
		return EMACS_NIL;

	/* Nothing changed since the last refresh: skip the re-render. */
	if (!doc_state->decorations_dirty)
		return EMACS_T;

	wait_for_win_jobs(win_state);
	nullify_window_cache(win_state);
	build_cache_window(doc_state, win_state,
			   win_state->current_page_number);

	CachedPage *cp = win_state->current_cached_page;

	if (!wait_for_cached_page(cp))
		{
			emacs_message(env, "Failed to render the page.");
			return EMACS_NIL;
		}

	if (!display_cached_page(env, cp, overlay))
		{
			emacs_message(env, "Failed to display the rendered page.");
			return EMACS_NIL;
		}

	doc_state->decorations_dirty = false;
	set_current_render_status(env);

	return EMACS_T;
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

	register_module_func(env, emacs_redisplay_doc,
			     "seshat-reader-dyn--redisplay-doc", 0, 0,
			     "Redisplays the document at the current page and scale.");

	register_module_func(env, emacs_close_doc,
			     "seshat-reader-dyn--close-doc", 0, 0,
			     "Frees the DocState in memory and all other "
			     "artifacts related to the current document.");

	register_module_func(env, emacs_next_page,
			     "seshat-reader-dyn--next-page", 0, 0,
			     "Loads and renders the next page of the document.");

	register_module_func(env, emacs_prev_page,
			     "seshat-reader-dyn--prev-page", 0, 0,
			     "Loads and renders the previous page of the document.");

	register_module_func(env, emacs_first_page,
			     "seshat-reader-dyn--first-page", 0, 0,
			     "Loads and renders the first page of the document.");

	register_module_func(env, emacs_last_page,
			     "seshat-reader-dyn--last-page", 0, 0,
			     "Loads and renders the last page of the document.");

	register_module_func(env, emacs_goto_page,
			     "seshat-reader-dyn--goto-page", 1, 1,
			     "Loads and renders the N page number.");

	register_module_func(env, emacs_doc_scale_page,
			     "seshat-reader-dyn--scale-page", 1, 1,
			     "Scales the current page of the document by a given FACTOR.");

	register_module_func(env, emacs_doc_invert,
			     "seshat-reader-dyn--doc-invert", 1, 1,
			     "Sets the document-local invert state for dark mode.");

	register_module_func(env, emacs_doc_rotate,
			     "seshat-reader-dyn--rotate-page", 1, 1,
			     "Rotates the page by the given DEGREE.");

	register_module_func(env, emacs_doc_window_create,
			     "seshat-reader-dyn--window-create", 1, 1,
			     "Initializes window parameters for EmacsWinState.");

	register_module_func(env, emacs_doc_window_close,
			     "seshat-reader-dyn--window-close", 1, 1,
			     "Frees EmacsWinState.");

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
			     "PAGE (1-based), in page coordinates. Call "
			     "seshat-reader-dyn--refresh-highlights to make "
			     "it visible.");

	register_module_func(env, emacs_add_decoration,
			     "seshat-reader-dyn--add-decoration", 9, 9,
			     "Adds a rectangle (X0 Y0 X1 Y1) on PAGE "
			     "(1-based) in page coordinates, painted in "
			     "colour (R G B, each 0..1) at ALPHA (0..1). "
			     "Call seshat-reader-dyn--refresh-highlights "
			     "to make it visible.");

	register_module_func(env, emacs_add_stroke,
			     "seshat-reader-dyn--add-stroke", 7, 7,
			     "Adds a freehand polyline on PAGE (1-based): "
			     "colour (R G B, each 0..1), ALPHA (0..1), "
			     "WIDTH in page points, and POINTS as a flat "
			     "list (X0 Y0 X1 Y1 ...) in page coordinates. "
			     "Call seshat-reader-dyn--refresh-highlights "
			     "to make it visible.");

	register_module_func(env, emacs_clear_highlights,
			     "seshat-reader-dyn--clear-highlights", 0, 0,
			     "Removes every highlight of the current document. "
			     "Call seshat-reader-dyn--refresh-highlights to "
			     "repaint.");

	register_module_func(env, emacs_refresh_highlights,
			     "seshat-reader-dyn--refresh-highlights", 0, 0,
			     "Re-renders the cache window of the current "
			     "window so that pending highlight changes become "
			     "visible.");

	// Register buffer-local variables.
	permanent_buffer_local_var(env, "seshat-reader-current-doc-pagecount");
	permanent_buffer_local_var(env, "seshat-reader-current-doc-render-status");
	permanent_buffer_local_var(env, "seshat-reader-current-doc-state-ptr");
	permanent_buffer_local_var(env, "seshat-reader-current-doc-outline");
	permanent_buffer_local_var(env, "seshat-reader--recent-pagenumber-fallback");

	// Provide the current dynamic module as a feature to Emacs
	provide(env, "seshat-render-core");

	// Initialize the global thread pool
	threadpool_init(&g_thread_pool);

	fprintf(stderr, "seshat-reader: %d threads have been initialized.\n",
		MAX_POOL_SIZE);
	fprintf(stderr,
		"seshat-reader: dynamic module has been loaded successfully.\n");
	return 0;
}
