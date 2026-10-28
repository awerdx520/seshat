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

#include <stdint.h>

#include "render-theme.h"
#include "elisp-helpers.h"
#include "render-core.h"

/* Dark mode is a user preference, not a property of the open document:
 * reloading a file, or opening a second one, must keep the chosen colours.
 * The state below therefore lives in process-wide static storage instead
 * of in `DocState', whose fields `reset_doc_state()' wipes on every load.
 *
 * It is written from the Emacs main thread (the module entry points below)
 * and read from whichever thread rasterizes a page -- in the multi-page
 * layout that is a `draw_page_thread' worker, not the main thread.  That
 * is why every field is an atomic: the goal is one consistent theme per
 * frame.  The two endpoint colours are packed into a single 64-bit word
 * (`g_tint_pair', `((uint64_t)BG << 32) | FG') so a frame can never mix
 * the background of one preset with the foreground of another when the
 * user switches palette mid-render; the two flags are written with
 * `memory_order_release' and read with `memory_order_acquire', which is
 * the pairing that makes the pair store visible before the flag that
 * announces it.  A worker that still sees the previous value renders one
 * page with the old theme, and the redisplay the caller triggers right
 * after corrects it. */
static atomic_bool g_dark_enabled;	/* dark mode on/off, default: off */
static atomic_bool g_tint_set;		/* true once a caller supplied colours */
static atomic_uint_fast64_t g_tint_pair;	/* (BG << 32) | FG, 0xRRGGBB each */

/* Largest value a 0xRRGGBB triple can take.  Larger arguments are rejected
 * rather than clamped: a caller that computed its colours wrongly is better
 * off being told than silently getting a nearby one. */
#define TINT_COMPONENT_MAX 0xFFFFFFu

/* Pack / unpack the two endpoint colours.  The split widths are fixed even
 * though the atomic's fast type may be wider than 64 bits.  The helpers
 * return / take a plain uint64_t on purpose: a function returning an
 * `atomic_*' type draws `-Wignored-qualifiers' (the _Atomic qualifier is
 * meaningless on a return type), and the packing is arithmetic on a value,
 * not an atomic operation. */
static uint64_t
tint_pair_pack(unsigned bg, unsigned fg)
{
	return ((uint64_t) bg << 32) | (uint64_t) fg;
}

/* Read-only accessors for `render_page_to_buffer'.  Elisp never sees these;
 * it only ever sets the values through the module entry points below.
 *
 * The two flags are read with `memory_order_acquire' to match the
 * `memory_order_release' stores: on x86 an acquire load costs nothing
 * (`MOV'), so the stronger ordering is free insurance that anything the
 * writer published before flipping the flag is visible to the reader that
 * observes the flip. */
bool
theme_dark_enabled(void)
{
	return atomic_load_explicit(&g_dark_enabled, memory_order_acquire);
}

bool
theme_tint_set(void)
{
	return atomic_load_explicit(&g_tint_set, memory_order_acquire);
}

/**
 * Read both tint endpoint colours in one atomic operation.
 *
 * BG and FG are written as a single packed value, so one call always
 * returns a coherent pair: switching preset mid-render can give the old
 * pair or the new one, never a blend of the two.  Reading the two colours
 * through separate accessors would allow exactly that (bg from the old
 * preset, fg from the new one), which is why no such accessors exist.
 *
 * Either pointer may be NULL if the caller only wants one of the two.
 *
 * @param bg Receives the background 0xRRGGBB, may be NULL.
 * @param fg Receives the foreground 0xRRGGBB, may be NULL.
 */
void
theme_tint_colors(unsigned *bg, unsigned *fg)
{
	uint64_t pair
		= (uint64_t) atomic_load_explicit(&g_tint_pair,
						  memory_order_acquire);

	if (bg)
		*bg = (unsigned) ((pair >> 32) & TINT_COMPONENT_MAX);
	if (fg)
		*fg = (unsigned) (pair & TINT_COMPONENT_MAX);
}

/**
 * Toggle dark mode for every document in this Emacs process.
 *
 * Flips the process-wide flag that `render_page_to_buffer' reads; nothing is
 * re-rendered here.  The caller is responsible for the redisplay (Elisp does
 * it with `seshat-reader--redisplay-all-windows', which also discards the
 * cached page images).
 *
 * Which pixel transform dark mode applies is decided by
 * `emacs_doc_tint': with no tint set the page is inverted and
 * gamma-corrected, with one it is mapped between the two stored colours.
 *
 * @param env    Emacs module environment.
 * @param nargs  Argument count (unused).
 * @param args   Argument values; ARGS[0] is non-zero to enable dark mode.
 * @param data   Additional data (unused).
 * Return:       EMACS_T, always: a process-wide flag has no document that
 *               could be missing.
 */

emacs_value
emacs_doc_invert(emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
	(void)nargs;
	(void)data;

	int invert = env->extract_integer(env, args[0]);

	atomic_store_explicit(&g_dark_enabled, invert ? true : false,
			      memory_order_release);

	return EMACS_T;
}

/**
 * Set the process-wide dark-mode colours (the "tint").
 *
 * BG and FG are hexadecimal 0xRRGGBB integers.  Every pixel's luminance is
 * mapped onto the line between them, so a dark BG with a light FG gives a
 * dark page without the 21:1 contrast that a pure black/white inversion
 * produces; a light BG with a dark FG gives a sepia page.  Both values are
 * stored for the whole process and no page is re-rendered here; the caller
 * must trigger a redisplay for them to become visible.
 *
 * Negative arguments clear the tint and put rendering back on the untinted
 * invert + gamma path: that is how the "graphite" preset asks for the
 * historical look.  Colours above 0xFFFFFF are rejected instead of being
 * clamped.
 *
 * @param env    Emacs module environment.
 * @param nargs  Argument count (unused).
 * @param args   ARGS[0] is the background 0xRRGGBB, ARGS[1] the foreground.
 * @param data   Additional data (unused).
 * Return:       EMACS_T on success, including the negative "clear the tint"
 *               case; EMACS_T as well when an argument is not an integer
 *               (the tint is left untouched and a message explains why —
 *               EMACS_T does *not* mean the colours took effect: a
 *               non-integer argument is silently dropped apart from that
 *               message, so a caller wanting certainty must check what it
 *               passed rather than the return value);
 *               EMACS_NIL when a colour is out of the 0x000000..0xFFFFFF
 *               range (the tint is left untouched).
 */

emacs_value
emacs_doc_tint(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
	(void)nargs;
	(void)data;

	int bg = env->extract_integer(env, args[0]);

	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		{
			env->non_local_exit_clear(env);
			emacs_message(
			    env, "Dark tint ignored: BG is not an integer "
			    "0xRRGGBB.");
			return EMACS_T;
		}

	int fg = env->extract_integer(env, args[1]);

	if (env->non_local_exit_check(env) != emacs_funcall_exit_return)
		{
			env->non_local_exit_clear(env);
			emacs_message(
			    env, "Dark tint ignored: FG is not an integer "
			    "0xRRGGBB.");
			return EMACS_T;
		}

	/* 判定顺序（勿调换）：先看负值，再看上界。
	 *
	 * 负值不是错误，而是「清空 tint」的显式请求——`graphite' 下发的
	 * (-1 . -1) 哨兵就落在这条分支上，所以任一参数为负（含两参同时
	 * 为负的 (-1 . -1)）都直接清空并返回 EMACS_T；只有两参都非负时
	 * 才逐个校验是否超过 0xFFFFFF。把上界校验提到前面会让哨兵被当成
	 * 「超出范围的颜色」拒绝，`graphite' 的回退口就断了。 */
	if (bg < 0 || fg < 0)
		{
			/* 先撤标志再清值：读者若仍看到 g_tint_set 为
			 * true，读到的是一对完整可用的旧颜色；反过来则会
			 * 有「标志为真、颜色全零」的一帧全黑页。 */
			atomic_store_explicit(&g_tint_set, false,
					      memory_order_release);
			atomic_store_explicit(&g_tint_pair, tint_pair_pack(0, 0),
					      memory_order_release);
			return EMACS_T;
		}

	if ((unsigned) bg > TINT_COMPONENT_MAX
	    || (unsigned) fg > TINT_COMPONENT_MAX)
		{
			emacs_message(env,
				      "Dark tint ignored: colours must be "
				      "within 0x000000..0xFFFFFF.");
			return EMACS_NIL;
		}

	/* 先写整对颜色、再置标志（release），读者观察到标志为真时必然
	 * 也能看到这一对颜色。 */
	atomic_store_explicit(&g_tint_pair,
			      tint_pair_pack((unsigned) bg, (unsigned) fg),
			      memory_order_release);
	atomic_store_explicit(&g_tint_set, true, memory_order_release);

	return EMACS_T;
}
