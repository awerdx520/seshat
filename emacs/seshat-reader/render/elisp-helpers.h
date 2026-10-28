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

#ifndef EMACS_HELPERS_H
#define EMACS_HELPERS_H

#include "emacs-module.h"
#include "mupdf-helpers.h"
#include "render-core.h"
#include <stdbool.h>
#include <stddef.h>

#define EMACS_NIL env->intern(env, "nil")
#define EMACS_T env->intern(env, "t")
#define EMACS_CURR_WIN                                                         \
	env->funcall(env, env->intern(env, "selected-window"), 0, NULL);

bool
elisp_2_c_str(emacs_env *env, emacs_value value, char **buffer, size_t *size);
void
provide(emacs_env *env, const char *value);
void
register_module_func(emacs_env *env,
		     emacs_value (*module_func)(emacs_env *env, ptrdiff_t nargs,
						emacs_value *args, void *data),
		     char *symbol, int min_args, int max_args, char *docstring);
emacs_value
data2elisp_canvas(emacs_env *env, int data_w, int data_h, int logical_w,
		  int logical_h, const unsigned char *bgra, size_t bgra_size);

DocState *
init_doc_state_ptr(emacs_env *env);
DocState *
get_doc_state_ptr(emacs_env *env);
bool
get_reader_current_state(emacs_env *env, DocState **doc_state_out);
void
clear_doc_state_ptr(emacs_env *env);
void
set_current_page_number(emacs_env *env, int page);
void
set_current_render_status(emacs_env *env);
void
set_current_pagecount(emacs_env *env, DocState *state);
float
get_frame_scale_factor(emacs_env *env);
void
emacs_message(emacs_env *env, char *str);
void
permanent_buffer_local_var(emacs_env *env, char *symbol);
emacs_value
outline2plist(emacs_env *env, DocState *state, fz_outline *node);
#endif
