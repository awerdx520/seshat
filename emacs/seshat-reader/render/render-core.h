//
// Copyright (C) 2025-2026  Divya Ranjan Pattanaik
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

#ifndef RENDER_CORE_H
#define RENDER_CORE_H

#include "emacs-module.h"
#include <mupdf/fitz.h>
#include <pthread.h>
#include <stdatomic.h>

#define MINRES 18
#define MAXRES 850

extern pthread_mutex_t g_mupdf_mutex[FZ_LOCK_MAX];

/*************************************************************/
/* Representation of the document's page from MuPDF	     */
/* This contains only parsed page data without any	     */
/* knowledge of window, buffer or anything from the	     */
/* frontend. This is to be owned by a document's DocState    */
/* and be shared by all windows that are showing the same    */
/* document. Since it contains directly parsed data from     */
/* the document, it is expensive to be created and should be */
/* reused as much as possible				     */
/*************************************************************/

typedef struct
{
	int page_num;
	fz_display_list *display_list;
	fz_rect bbox;
	bool ready;
	atomic_int refcount;
	pthread_mutex_t mutex;
} DocPage;

/***********************************************************************/
/* A page-anchored decoration, expressed in page coordinates	     */
/* (PDF points, origin at the top-left of the page, y growing down) and */
/* therefore independent of the current zoom and rotation.	     */
/*								     */
/* `page' is stored 0-based, while the Emacs-facing API speaks 1-based  */
/* page numbers; the conversion happens in the module functions which   */
/* own this table (see emacs_add_highlight in render-core.c).	     */
/*								     */
/* Two kinds share one table so that the render thread can paint them   */
/* in a single pass and the Elisp side has a single "clear" entry point:*/
/*								     */
/*   DECORATION_KIND_RECT   — a filled rectangle, geometry in	     */
/*			      x0/y0/x1/y1.  The original highlight,   */
/*			      and still the only thing the 5-argument  */
/*			      `--add-highlight' can produce.	     */
/*   DECORATION_KIND_STROKE — a freehand polyline, geometry in `pts'   */
/*			      (page space, `pt_count' points, at most  */
/*			      DECORATION_MAX_POINTS) drawn with `width'*/
/*			      (page points) round caps and round       */
/*			      joins.				     */
/*								     */
/* `color' is RGB in [0,1], `alpha' in [0,1].  Both kinds carry the same */
/* style fields so that grouping-by-style in the painter needs no       */
/* kind-specific special case.					     */
/*								     */
/* OWNERSHIP: `pts' is owned by whoever holds the Decoration — either   */
/* the DocState table or the per-job snapshot — and is never shared     */
/* between the two.  Every holder must free each non-NULL `pts' before  */
/* dropping its array; free_decoration_table() does exactly that and is */
/* the only sanctioned way to release a run of Decorations.  A RECT     */
/* always has `pts == NULL / pt_count == 0`.			     */
/***********************************************************************/

#define DECORATION_KIND_RECT 0
#define DECORATION_KIND_STROKE 1

/* Per-stroke point ceiling.  A freehand annotation produced by a pointer
 * or a finger is far below this; the cap exists so that a hostile or
 * corrupted `--add-stroke' call cannot make one entry unboundedly large.
 * Points beyond the cap are dropped (the stroke is truncated, never
 * rejected). */
#define DECORATION_MAX_POINTS 1024

typedef struct
{
	int page;
	int kind;

	/* DECORATION_KIND_RECT */
	float x0, y0, x1, y1;

	/* Style, shared by both kinds. */
	float color[3];
	float alpha;

	/* DECORATION_KIND_STROKE */
	float width;
	fz_point *pts;
	int pt_count;
} Decoration;

/************************************************************************/
/* The primary representation of the entire document.  DocState holds     */
/* the DocPages and the MuPDF context of one open document.  It shall     */
/* have the important MuPDF objects such as fz_context and fz_document,   */
/* and for this reason, to follow MuPDF's multi-threading rules, it must  */
/* always be used by one thread at any given time.                        */
/************************************************************************/

typedef struct
{
	fz_context *ctx;
	fz_locks_context locks;
	fz_document *doc;

	DocPage *doc_pages;

	char *path;
	int pagecount;
	fz_outline *outline;
	float frame_scale; // Emacs' frame-scale-factor

	/* Page the document was loaded at.  The module keeps no window state,
	 * so this is the only page number it remembers: `--page-text' falls
	 * back to it when the caller omits PAGE and Elisp cannot report the
	 * page on screen. */
	int current_page_number;

	/* Document-level decoration table (rects and strokes).  Owned by the
	 * Emacs main thread; the worker threads never read it, they get a
	 * per-page snapshot copied into their job argument instead. */
	Decoration *decorations;
	int decoration_count;
	int decoration_cap;

	bool is_reloading;
} DocState;

/* Frees the `pts' of COUNT decorations, then the array itself.  Shared by
 * render-core.c (DocState table) and mupdf-helpers.c (free_doc_state), so
 * that neither translation unit can drift from the other's ownership
 * rule.  NULL/zero-count is a no-op. */
void
free_decoration_table(Decoration *deco, int count);

int
load_page_dl(DocState *state, DocPage *dp);

// Emacs module functions
emacs_value
emacs_load_doc(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_page_text(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_text_in_rect(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_rects_in_rect(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_lines_in_rect(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_search_page(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_add_highlight(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_add_decoration(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_add_stroke(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_clear_highlights(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		       void *data);

emacs_value
emacs_page_image_spec(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
		      void *data);

emacs_value
emacs_page_size(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

emacs_value
emacs_close_doc(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

#endif // RENDER_CORE_H
