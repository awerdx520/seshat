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

#include <stdbool.h>

#include "elisp-helpers.h"
#include "render-core.h"

emacs_value emacs_doc_invert(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);
emacs_value emacs_doc_tint(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data);

/* Process-wide dark-mode state, written by the two module entry points above
 * and read by `render_page_to_buffer' in render-core.c.  These describe a
 * user preference, so they deliberately outlive any single document and are
 * not part of `DocState'.
 *
 * The readers may run on a `draw_page_thread' worker rather than on the
 * Emacs main thread, so render-theme.c keeps the state in atomics.  The two
 * endpoint colours are deliberately not exposed as two accessors: callers
 * must take them as one pair through `theme_tint_colors', which reads a
 * single packed 64-bit word, otherwise a preset switch mid-render could mix
 * the old background with the new foreground. */
bool theme_dark_enabled(void);
bool theme_tint_set(void);
void theme_tint_colors(unsigned *bg, unsigned *fg);
