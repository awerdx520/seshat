// Helper functions that complement the C API of the Emacs Module

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

#include "elisp-helpers.h"
#include "emacs-module.h"
#include "render-core.h"

#include <stdio.h>
#include <string.h>

/* Upper bound on one outline title, in bytes.  MuPDF reads the title
 * straight out of the PDF and nothing upstream validates it, so a
 * corrupted or hostile document could hand us a title of unbounded
 * length; the bytes then get copied twice more (unibyte string +
 * decoded multibyte string).  8 KiB is far beyond any real bookmark
 * label.  Truncation is by byte, which may split a multi-byte UTF-8
 * sequence — `decode-coding-string' keeps the incomplete tail as raw
 * bytes instead of signalling, so this stays safe. */
#define OUTLINE_TITLE_MAX 8192

/**
 * elisp_2_c_str - Convert an Elisp string to a C string.
 * @env: Pointer (of type `emacs_env') to the environment of the Emacs runtime
 * @value: The value of the Elisp string that is to be converted.  It will only
 * return the value (in Elisp, (symbol-value str)) of the string, not the
 * symbol.
 * @buffer: The C character array that is going to store the converted string.
 * @size: Pointer to the length of the string after being converted, as
 * type size_t.
 *
 * Return: true on success, false on error
 */

bool
elisp_2_c_str(emacs_env *env, emacs_value value, char **buffer, size_t *size)
{
	ptrdiff_t buffer_size;
	if (!env->copy_string_contents(env, value, NULL, &buffer_size))
		return false;
	assert(env->non_local_exit_check(env) == emacs_funcall_exit_return);
	assert(buffer_size > 0);
	*buffer = malloc((size_t)buffer_size);
	if (*buffer == NULL)
	{
		env->non_local_exit_signal(env, env->intern(env, "memory-full"),
					   env->intern(env, "nil"));
		return false;
	}
	ptrdiff_t old_buffer_size = buffer_size;
	if (!env->copy_string_contents(env, value, *buffer, &buffer_size))
	{
		free(*buffer);
		*buffer = NULL;
		return false;
	}
	assert(env->non_local_exit_check(env) == emacs_funcall_exit_return);
	assert(buffer_size == old_buffer_size);
	*size = (size_t)(buffer_size - 1);
	return true;
}

/**
 * provide - Calls the Elisp (provide) function to provide a feature to the
 * module.
 * @env: Pointer (of type `emacs_env') to the environment of the Emacs runtime
 * @value: String of the symbol that is to be provid-ed.
 *
 * It doesn’t store the symbol or value of the feature anywhere, only calls the
 * provide function with the symbol from the string.
 *
 * It’s equivalent to doing the following in Elisp:
 * (provide 'feature)
 */

void
provide(emacs_env *env, const char *value)
{
	emacs_value Qvalue = env->intern(env, value);
	emacs_value Qprovide = env->intern(env, "provide");
	emacs_value args[] = { Qvalue };

	env->funcall(env, Qprovide, 1, args);
}

/**
 * register_module_func - Register a function from the dynamic module into the
 * Emacs environment.  It makes the function available to be directly usable
 * from Emacs as any other Elisp function.
 * @env: Pointer to the Emacs environment for the runtime (emacs_env).
 * @module_func: Pointer to the function (emacs_value) that needs to be
registered.
 * @symbol: The symbol for which the function is to be registered.
 * @min_args: The minimum number of arguments this function must be provided
 * with.
 * @max_args: The maximum number of arguments this function can take.
 * @docstring: The string which would act as the docstring for the module
 * function. Equivalent to the docstring in Elisp functions, and visible from
 * C-h f.
 *
 * The @module_func must be not only compile-able but also it must respect the
 * Elisp runtime of Emacs, any sort of undefined or unpredictable behavior would
 * not be found during compile-time, but rather would result in a segfault of
 * Emacs.
 *
 * Returns: nothing
 */

void
register_module_func(emacs_env *env,
		     emacs_value (*module_func)(emacs_env *env, ptrdiff_t nargs,
						emacs_value *args, void *data),
		     char *symbol, int min_args, int max_args, char *docstring)
{

	emacs_value elisp_func_symbol = env->intern(env, symbol);
	emacs_value elisp_func = env->make_function(
	    env, min_args, max_args, module_func, docstring, NULL);

	emacs_value elisp_func_args[2] = { elisp_func_symbol, elisp_func };
	env->funcall(env, env->intern(env, "fset"), 2, elisp_func_args);
}

/**
 * data2elisp_canvas - Create an Elisp `canvas' image spec and fill it.
 *
 * 历史实现把像素塞进 Lisp 字符串（多一份常驻副本）；现在改成让 Emacs
 * 自己的 canvas 缓冲持有像素——spec 里没有
 * `:data'，像素在 C 侧直接写进 canvas，再 `canvas-refresh'。
 *
 * 尺寸双轨制（务必区分）：
 *   - `:data-width' / `:data-height' = 设备像素（= MuPDF pixmap 尺寸），
 *     决定 canvas 缓冲大小，只在建 spec 时设一次，之后任何路径都不得改写
 *     （改写会让 Emacs 重建缓冲并清零 → 残影/花屏）。
 *   - `:width' / `:height' = 逻辑像素（= pixmap ÷ frame_scale），供显示层
 *     缩放，可在 Elisp 侧随时 `setf'。
 *
 * BGRA 是 canvas 的原生格式（ARGB32，小端字节序 B,G,R,A），无需重排；
 * 传入的 BGRA 必须已是逐行紧凑布局（行宽 data_w*4），源数据的 stride
 * 已在渲染侧消化。
 *
 * @param env        Emacs module environment.
 * @param data_w     Canvas width in device pixels.
 * @param data_h     Canvas height in device pixels.
 * @param logical_w  Logical width in unscaled pixels (`:width`).
 * @param logical_h  Logical height in unscaled pixels (`:height`).
 * @param bgra       Tightly packed BGRA block of data_w*data_h pixels.
 * @param bgra_size  Size of BGRA in bytes.
 * Return:           The canvas image spec, or nil (never a fake spec).
 */

emacs_value
data2elisp_canvas(emacs_env *env, int data_w, int data_h, int logical_w,
		  int logical_h, const unsigned char *bgra, size_t bgra_size)
{
	if (!bgra || data_w <= 0 || data_h <= 0 || logical_w <= 0
	    || logical_h <= 0)
		return EMACS_NIL;

	size_t need = (size_t)data_w * (size_t)data_h * 4u;

	if (bgra_size < need)
		{
			fprintf(stderr,
				"seshat: BGRA block too small (%zu < %zu bytes)\n",
				bgra_size, need);
			return EMACS_NIL;
		}

	/* 只有 Emacs ≥ 32 的环境才带 `canvas_data' 槽位；这里先按 env->size
	 * 探一下，避免在旧运行时上读越界（T8 会再加硬门禁）。 */
	size_t canvas_slot_end = offsetof(emacs_env, canvas_data)
				 + sizeof(env->canvas_data);

	if ((size_t)env->size < canvas_slot_end)
		{
			fprintf(stderr,
				"seshat: Emacs module environment too old for "
				"canvas (size %zu < %zu)\n",
				(size_t)env->size, canvas_slot_end);
			return EMACS_NIL;
		}

	/* `:data' 不传 → 缓冲惰性分配（Lisp 侧零常驻）；`:id' 一律省略
	 * （实测传非符号会静默产出假 spec）。 */
	emacs_value create_args[11]
	    = { EMACS_NIL,
		env->intern(env, "canvas"),
		EMACS_T,
		env->intern(env, ":data-width"),
		env->make_integer(env, data_w),
		env->intern(env, ":data-height"),
		env->make_integer(env, data_h),
		env->intern(env, ":width"),
		env->make_integer(env, logical_w),
		env->intern(env, ":height"),
		env->make_integer(env, logical_h) };

	emacs_value img = env->funcall(env, env->intern(env, "create-image"), 11,
				       create_args);

	/* 双自检之一：`create-image' 失败时会返回非 image（或已经 signal）。 */
	emacs_value imagep
	    = env->funcall(env, env->intern(env, "imagep"), 1, &img);

	if (!env->eq(env, imagep, EMACS_T))
		{
			fprintf(stderr,
				"seshat: create-image returned a non-image for "
				"the canvas spec\n");
			/* `create-image' 失败时通常已经挂了 pending
			 * non-local exit（signal）。带着它做后续调用
			 * （`env->intern' / `funcall'）是 UB，故返回前清掉。 */
			if (env->non_local_exit_check(env)
			    != emacs_funcall_exit_return)
				env->non_local_exit_clear(env);

			return EMACS_NIL;
		}

	/* `canvas_data' 每次必须重取：改写 `:data-width'/`:data-height' 会
	 * 重建并清零缓冲，旧指针随即悬空。用完即弃，不跨调用缓存。 */
	uint32_t *canvas = env->canvas_data(env, img);

	/* 双自检之二：缓冲必须可写。任一自检失败都不得静默返回假 spec。 */
	if (!canvas)
		{
			fprintf(stderr,
				"seshat: canvas_data returned NULL "
				"(canvas buffer unavailable)\n");
			/* 同上一处自检：失败前清掉 pending non-local exit，
			 * 否则后续 `env->intern' 在待处理异常下是 UB。 */
			if (env->non_local_exit_check(env)
			    != emacs_funcall_exit_return)
				env->non_local_exit_clear(env);

			return EMACS_NIL;
		}

	/* 逐行拷贝。canvas 缓冲按 Emacs 文档是 row major、尺寸
	 * width*height、格式 ARGB32，行宽即 data_w*4（紧凑）。源块同样紧凑，
	 * 因此只需要逐行 memcpy，不做任何像素重排。 */
	for (int y = 0; y < data_h; ++y)
		{
			size_t row_off = (size_t)y * (size_t)data_w * 4u;

			memcpy((unsigned char *)canvas + row_off, bgra + row_off,
			       (size_t)data_w * 4u);
		}

	/* 刷新：第二参 nil 表示不重新加载 `:data'（像素已由模块直写）。
	 * 不得与 `reload-data' 混用，否则会用空/旧 :data 覆盖缓冲。 */
	emacs_value refresh_args[2] = { img, EMACS_NIL };
	env->funcall(env, env->intern(env, "canvas-refresh"), 2, refresh_args);

	return img;
}

/**
 * init_doc_state_ptr - Initialize the DocState and expose it to Elisp.
 * @env:    The Emacs environment pointer.
 *
 * Return: A pointer to the current `docstate` (or null if the symbol is unbound
 * or not a valid user pointer.).
 */

DocState *
init_doc_state_ptr(emacs_env *env)
{
	DocState *state = malloc(sizeof(DocState));

	state->is_reloading = false;

	// Create a user pointer and expose it to Emacs in a buffer-local
	emacs_value user_ptr = env->make_user_ptr(env, NULL, state);
	emacs_value doc_state_ptr_sym
	    = env->intern(env, "seshat-reader-current-doc-state-ptr");
	env->funcall(env, env->intern(env, "set"), 2,
		     (emacs_value[]){ doc_state_ptr_sym, user_ptr });
	return state;
}

/**
 * get_doc_state_ptr - Retrieve the DocState pointer stored in Elisp.
 * @env:    The Emacs environment pointer.
 *
 * Return: A pointer to the current `DocState` (or NULL if the symbol is
 * unbound or not a valid user pointer.).
 */

DocState *
get_doc_state_ptr(emacs_env *env)
{
	emacs_value ptr_sym = env->intern(env, "seshat-reader-current-doc-state-ptr");
	emacs_value ptr
	    = env->funcall(env, env->intern(env, "symbol-value"), 1, &ptr_sym);

	if (env->eq(env, ptr, EMACS_NIL))
		return NULL;

	DocState *state = env->get_user_ptr(env, ptr);
	return state;
}

void
clear_doc_state_ptr(emacs_env *env)
{
	emacs_value sym = env->intern(env, "seshat-reader-current-doc-state-ptr");
	env->funcall(env, env->intern(env, "set"), 2,
		     (emacs_value[]){ sym, EMACS_NIL });
}

void
set_current_page_number(emacs_env *env, int page)
{
	page += 1; // Exposed number shouldn't be 0-indexed
	emacs_value curr_win = EMACS_CURR_WIN;
	env->funcall(env, env->intern(env, "set-window-parameter"), 3,
		     (emacs_value[]){ curr_win, env->intern(env, "page"),
				      env->make_integer(env, page) });
	env->funcall(env, env->intern(env, "set"), 2,
		     (emacs_value[]){
			 env->intern(env, "seshat-reader--recent-pagenumber-fallback"),
			 env->make_integer(env, page) });
}

/**
 * set_current_render_status - Mark the buffer’s render status as true.
 * @env:    The Emacs environment pointer.
 *
 * Sets the Elisp variable `doc-render-status` to `t` in the current buffer,
 * indicating that the image rendering is up to date.
 */

void
set_current_render_status(emacs_env *env)
{
	emacs_value render_status_var
	    = env->intern(env, "seshat-reader-current-doc-render-status");
	env->funcall(
	    env, env->intern(env, "set"), 2,
	    (emacs_value[]){ render_status_var, env->intern(env, "t") });
}

/**
 * set_current_pagecount - Expose the document’s total page count to Elisp.
 * @env:    The Emacs environment pointer.
 * @state:  Pointer to the `DocState` containing the pagecount.
 *
 * Sets the Elisp variable `current-doc-pagecount` in the current buffer to the
 * number of pages the document has.
 */

void
set_current_pagecount(emacs_env *env, DocState *state)
{
	emacs_value pagecount_args[2]
	    = { env->intern(env, "seshat-reader-current-doc-pagecount"),
		env->make_integer(env, state->pagecount) };
	env->funcall(env, env->intern(env, "set"), 2, pagecount_args);
}

/**
 * emacs_message - Print a message in Emacs with the given string
 * @env:    The Emacs environment pointer.
 * @str:    Null-terminated C string containing the message.
 */

void
emacs_message(emacs_env *env, char *str)
{
	emacs_value el_string = env->make_string(env, str, strlen(str));
	env->funcall(env, env->intern(env, "message"), 1, &el_string);
}

/**
 * permanent_buffer_local_var: Sets a buffer local variable and makes it
 * permanently local so that it doesn’t get overridden
 * @env: The Emacs environment pointer.
 * @symbol: The symbol of the variable to be set
 */

void
permanent_buffer_local_var(emacs_env *env, char *symbol)
{
	emacs_value el_symbol = env->intern(env, symbol);
	env->funcall(env, env->intern(env, "make-variable-buffer-local"), 1,
		     &el_symbol);
	env->funcall(env, env->intern(env, "set"), 2,
		     (emacs_value[]){ el_symbol, EMACS_NIL });

	env->funcall(env, env->intern(env, "put"), 3,
		     (emacs_value[]){ el_symbol,
				      env->intern(env, "permanent-local"),
				      EMACS_T });
}

/**
 * Convert a fz_outline tree to an Emacs plist structure.
 *
 * Recursively traverses the outline linked list and builds a nested
 * plist representation for Emacs: each node becomes a plist with
 * `:title`, `:page`, and optionally `:children` keys.
 *
 * Stores the result in `seshat-reader-current-doc-outline` and returns it.
 *
 * @param env    Emacs module environment.
 * @param node   Root of the fz_outline tree (from MuPDF).
 * Return:       Emacs Lisp list of plists representing the outline.
 */

static emacs_value
outline2plist_nodes(emacs_env *env, DocState *state, fz_outline *node,
		    emacs_value Qdecode, emacs_value Qutf8)
{
	emacs_value outline_plist = EMACS_NIL;

	while (node)
	{
		if (!node->title)
		{
			node = node->next;
			continue;
		}

		/* Build the base plist: (:title TITLE :page PAGE).
		 * MuPDF hands out UTF-8 bytes, so wrap them in a unibyte
		 * string first and let Emacs decode them; otherwise
		 * non-ASCII titles reach elisp as unibyte strings and show
		 * up as octal escapes ("\346\226\207").  decode-coding-string
		 * keeps invalid bytes as raw bytes instead of signalling, so
		 * a malformed outline cannot abort `emacs-load-doc'.
		 * The byte length is capped first: nothing in the PDF
		 * guarantees a bounded title, and every byte is copied
		 * again by the decoder below. */
		size_t title_len = strlen(node->title);
		if (title_len > OUTLINE_TITLE_MAX)
			title_len = OUTLINE_TITLE_MAX;
		emacs_value node_title = env->make_unibyte_string(
		    env, node->title, (ptrdiff_t)title_len);
		emacs_value decoded_title = env->funcall(
		    env, Qdecode, 2, (emacs_value[]){ node_title, Qutf8 });
		if (env->non_local_exit_check(env) == emacs_funcall_exit_return)
		{
			node_title = decoded_title;
		}
		else
		{
			/* Last line of defence: fall back to the raw bytes. */
			env->non_local_exit_clear(env);
		}
		fz_location page_location = fz_resolve_link(
		    state->ctx, state->doc, node->uri, &node->x, &node->y);
		int page_num = fz_page_number_from_location(
		    state->ctx, state->doc, page_location);
		emacs_value node_page = env->make_integer(env, page_num);
		emacs_value base_args[]
		    = { env->intern(env, ":title"), node_title,
			env->intern(env, ":page"), node_page };
		emacs_value node_plist
		    = env->funcall(env, env->intern(env, "list"), 4, base_args);

		/* If there are children, recurse and append as :children key */
		if (node->down)
		{
			emacs_value children
			    = outline2plist_nodes(env, state, node->down,
						  Qdecode, Qutf8);
			emacs_value child_pair_args[]
			    = { env->intern(env, ":children"), children };
			emacs_value children_pair = env->funcall(
			    env, env->intern(env, "list"), 2, child_pair_args);
			/* Append the (:children CHILDREN) onto this node's
			 * plist */
			node_plist = env->funcall(
			    env, env->intern(env, "append"), 2,
			    (emacs_value[]){ node_plist, children_pair });
		}

		/* Cons this node_plist onto our accumulator */
		outline_plist = env->funcall(
		    env, env->intern(env, "cons"), 2,
		    (emacs_value[]){ node_plist, outline_plist });
		node = node->next;
	}

	/* Reverse to preserve original document order */
	outline_plist = env->funcall(env, env->intern(env, "nreverse"), 1,
				     &outline_plist);

	/* Store in seshat-reader-current-doc-outline and return */
	env->funcall(
	    env, env->intern(env, "set"), 2,
	    (emacs_value[]){ env->intern(env, "seshat-reader-current-doc-outline"),
			     outline_plist });
	return outline_plist;
}

/**
 * outline2plist - Entry point of the outline walk.
 *
 * Resolves the two coding symbols once and delegates to
 * `outline2plist_nodes', so a document with N outline nodes pays for
 * two `intern' calls instead of 2*N.  Only the main thread reaches this
 * (from `emacs-load-doc'), hence the values are plain locals rather than
 * anything shared.
 *
 * @param env    Emacs module environment.
 * @param state  DocState owning the MuPDF context and document.
 * @param node   Root of the fz_outline tree (from MuPDF).
 * Return:       Emacs Lisp list of plists representing the outline.
 */

emacs_value
outline2plist(emacs_env *env, DocState *state, fz_outline *node)
{
	if (!node)
		return EMACS_NIL;

	emacs_value Qdecode = env->intern(env, "decode-coding-string");
	emacs_value Qutf8 = env->intern(env, "utf-8");

	return outline2plist_nodes(env, state, node, Qdecode, Qutf8);
}

float
get_frame_scale_factor(emacs_env *env)
{
	emacs_value factor = env->funcall(
	    env, env->intern(env, "frame-scale-factor"), 0, NULL);
	return env->extract_float(env, factor);
}

/* Fetch the current DocState.  To be used when operating on the current */
/* state, e.g. reading the text of a page or querying its rectangles. */
/* Return false if invalid. */

bool
get_reader_current_state(emacs_env *env, DocState **doc_state_out)
{
	DocState *doc_state = get_doc_state_ptr(env);

	if (!doc_state)
		{
			emacs_message(env, "No valid DocState user pointer found.");
			return false;
		}

	/* Bail out during reload to avoid use-after-free. */
	if (doc_state->is_reloading)
		return false;

	if (doc_state_out)
		*doc_state_out = doc_state;

	return true;
}
