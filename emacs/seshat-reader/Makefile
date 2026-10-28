### Makefile for Emacs Reader’s dynamic module
##
## Copyright (C) 2025 Divya Ranjan Pattanaik
## Copyright (C) 2025 prom
## Copyright (C) 2025-2026 Tushar
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Detect platforms
OS_NAME := $(shell uname)
HAVE_GUIX := $(shell command -v guix >/dev/null 2>&1 && echo yes || echo no)
HAVE_NIX  := $(shell command -v nix >/dev/null 2>&1 && echo yes || echo no)
HAVE_DNF  := $(shell command -v dnf >/dev/null 2>&1 && echo yes || echo no)
ifneq ($(filter MINGW%, $(OS_NAME)),)
  HAVE_MINGW64 := yes
else
  HAVE_MINGW64 := no
endif
USE_PKGCONFIG := yes

ifeq ($(HAVE_GUIX),yes)
  $(info Guix detected: skipping pkg-config checks.)
  USE_PKGCONFIG := no
else ifeq ($(HAVE_NIX),yes)
  $(info Nix detected: skipping pkg-config checks.)
  USE_PKGCONFIG := no
else ifeq ($(HAVE_DNF),yes)
  $(info dnf detected: skipping pkg-config checks.)
  USE_PKGCONFIG := no
else ifeq ($(OS_NAME),Darwin)
  $(info macOS detected: skipping pkg-config and using Homebrew for MuPDF paths.)
  USE_PKGCONFIG := no
else ifeq ($(OS_NAME),FreeBSD)
  $(info FreeBSD detected: skipping pkg-config checks.)
  USE_PKGCONFIG := no
else ifeq ($(HAVE_MINGW64), yes)
  $(info MinGW64 detected: assuming dll is located in $(MINGW_PREFIX)/bin.)
endif

ifeq ($(OS_NAME),Darwin)
  SO := dylib
else ifeq ($(HAVE_MINGW64),yes)
  SO := dll
else
  SO := so
endif

# Compiler and base flags
CC := gcc
# -O2 不可省：渲染热路径（逐像素 BGRA 扩展、色彩空间转换）在 -O0 下慢 2~2.5 倍。
# 只加 -O2，不加 -march=native（产物需在其它机器可用）。
# -Wclobbered（-O2 才启用）在 fz_try/fz_always 的跨块局部变量上会告警：MuPDF 的
# fz_try 基于 setjmp/longjmp，跨块变量必须显式声明 volatile，因此这里不抑制任何
# 告警，而是按 MuPDF 惯例在源码中声明 volatile。
CFLAGS += -O2 -Wall -Wextra -fPIC -MMD -MP
LDFLAGS :=
EMACS = emacs --batch -Q --eval '(setq enable-dir-local-variables nil)' -L . -L ..

# --- Emacs 版本门禁 ---
# 本项目已迁移为单后端 canvas（见 openspec/completed/2026-10-28-reader-canvas-backend-migration.md），
# 只走 Emacs 32 的原生 canvas 能力，没有 31 及更早版本的降级路径；低于 32 一律在解析期
# 直接失败，避免「用旧 Emacs 编出一份看似成功、实际跑不起来的模块」。
# 取 `EMACS' 的第一个词作为可执行文件（用户可 `make EMACS=/path/to/emacs' 覆盖），
# 这样后面追加的 `-L' 参数不会被误喂给 --eval。
EMACS_BIN   := $(firstword $(EMACS))
EMACS_MAJOR := $(shell $(EMACS_BIN) --batch -Q --eval '(princ emacs-major-version)' 2>/dev/null)
ifneq ($(shell test "$(EMACS_MAJOR)" -ge 32 2>/dev/null && echo yes),yes)
  $(error Emacs 32 or newer is required for the canvas backend (found major=$(EMACS_MAJOR)))
endif

# --- 可选外部依赖：ETAF（面板 ETAF 渲染层）---
# ETAF 不 vendored 进本仓库（见 openspec/completed/2026-10-17-m11.9-etaf-render.md），
# 只在本地存在时加入 load-path；不存在时 seshat-reader-etaf.el 不参与 .elc 编译
# （运行期由接入点 `(require 'seshat-reader-etaf nil t)` 软加载并降级）。
# 可用 `make ETAF_ROOT=/path/to/emacs-taf` 覆盖位置；未显式给出时按下面的
# 两级探测定位（源码树优先，straight.el build 目录兜底）。
ETAF_ROOT ?= $(firstword $(wildcard $(HOME)/Workspace/emacs-taf \
                                    $(HOME)/WorkSpace/emacs-taf))
# straight.el 的 build 目录（本机 ETAF 只有这种形态：build 下是到
# straight/repos 的软链与 .elc，没有完整源码树）。
ETAF_STRAIGHT_BUILDS ?= $(wildcard $(HOME)/.emacs.d/straight/build-* \
                                    $(HOME)/.config/emacs/straight/build-* \
                                    $(HOME)/thomas-emacs/.local/straight/build-*)
ETAF_LISP_DIRS := $(wildcard $(ETAF_ROOT)/ecss $(ETAF_ROOT)/ecss/lisp \
                              $(ETAF_ROOT)/ebox $(ETAF_ROOT)/ebox/lisp \
                              $(ETAF_ROOT)/etaf $(ETAF_ROOT)/etaf/lisp \
                              $(ETAF_ROOT)/etaf-ui $(ETAF_ROOT)/etaf-ui/lisp)
ifeq ($(ETAF_LISP_DIRS),)
  # 无源码树：回退 straight.el build 目录（取最后一个，仅统计真的含 etaf/ 的）
  ETAF_STRAIGHT_DIRS := $(patsubst %/etaf,%,$(wildcard $(addsuffix /etaf,$(ETAF_STRAIGHT_BUILDS))))
  ETAF_LISP_DIRS := $(foreach b,$(lastword $(ETAF_STRAIGHT_DIRS)),\
                       $(wildcard $(addprefix $(b)/,etaf etaf-ui ecss ebox)))
endif
ifneq ($(ETAF_LISP_DIRS),)
  EMACS += $(foreach dir,$(ETAF_LISP_DIRS),-L $(dir))
endif

ifeq ($(OS_NAME),Darwin)
  CFLAGS += -DMACOS
  LDFLAGS += -dynamiclib
else ifeq ($(HAVE_MINGW64),yes)
  CFLAGS += -DWIN32 -pthread
  LDFLAGS += -shared -lpthread -L$$MINGW_PREFIX/bin
else
  CFLAGS += -DLINUX -pthread
  LDFLAGS += -shared -lpthread
endif

# Required MuPDF version
REQUIRED_VERSION := 1.26.0

# --- MuPDF detection and flags ---
ifeq ($(USE_PKGCONFIG),yes)
  PKG_EXISTS := $(shell pkg-config --exists mupdf && echo yes || echo no)
  ifeq ($(PKG_EXISTS),no)
    $(error "MuPDF not found via pkg-config. Please install it or set PKG_CONFIG_PATH.")
  endif

  MUPDF_VERSION := $(shell pkg-config --modversion mupdf)
  VER_OK := $(shell [ "$$(printf '%s\n' $(REQUIRED_VERSION) $(MUPDF_VERSION) | sort -V | head -n1)" = "$(REQUIRED_VERSION)" ] && echo yes || echo no)
  ifeq ($(VER_OK),no)
    $(error "MuPDF version $(MUPDF_VERSION) too old. Require ≥ $(REQUIRED_VERSION).")
  endif

  CFLAGS += $(shell pkg-config --cflags mupdf)
  LDFLAGS += $(shell pkg-config --libs mupdf)
else ifeq ($(OS_NAME),Darwin)
  # macOS manual detection via brew
  BREW_PREFIX := $(shell brew --prefix mupdf 2>/dev/null)
  ifeq ($(BREW_PREFIX),)
    $(error "MuPDF not found via Homebrew. Run: brew install mupdf")
  endif
  MUPDF_VERSION := $(shell grep -o '[0-9][^"]*' $(BREW_PREFIX)/include/mupdf/fitz/version.h | head -n1)
  VER_OK := $(shell [ "$$(printf '%s\n' $(REQUIRED_VERSION) $(MUPDF_VERSION) | sort -V | head -n1)" = "$(REQUIRED_VERSION)" ] && echo yes || echo no)
  ifeq ($(VER_OK),no)
    $(error "MuPDF version $(MUPDF_VERSION) too old. Require ≥ $(REQUIRED_VERSION).")
  endif
  CFLAGS += -I$(BREW_PREFIX)/include
  LDFLAGS += -L$(BREW_PREFIX)/lib -lmupdf
else
  # Generic fallback for Guix/Nix
  CFLAGS += -DMUPDF_NO_PKGCONFIG
  LDFLAGS += -lmupdf
endif

# --- Build Rules ---
LIB_NAME := seshat-render-core.$(SO)
SRCS := $(wildcard render/*.c)
OBJS := $(SRCS:%.c=%.o)

EL_SRCS := $(filter-out .* seshat-reader-autoloads.el,$(wildcard *.el))
ifeq ($(ETAF_LISP_DIRS),)
  # ETAF 缺失：跳过 ETAF 渲染层（硬依赖 etaf-ui，无法在无 ETAF 环境编译）
  EL_SRCS := $(filter-out seshat-reader-etaf.el,$(EL_SRCS))
endif
ELC := $(EL_SRCS:%.el=%.elc)

.PHONY: all clean checkdoc

all: $(LIB_NAME) seshat-reader-autoloads.el $(ELC) checkdoc

$(LIB_NAME): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.elc: %.el $(LIB_NAME)
	 $(EMACS) -f batch-byte-compile $<

seshat-reader-autoloads.el: $(EL_SRCS)
	rm -f seshat-reader-autoloads.el
	$(EMACS) -f loaddefs-generate-batch $@ .

checkdoc: $(EL_SRCS)
	$(EMACS) $(foreach file, $(EL_SRCS), --eval '(checkdoc-file "$(file)")')

clean:
	rm -f seshat-reader-autoloads.el
	rm -f $(ELC)
	rm -f $(OBJS) $(OBJS:.o=.d) $(LIB_NAME)

# gcc -MMD -MP 在编译每个 .c 的同时生成同名 .d，记录该 .c 依赖的全部头文件。
# 没有这行的话头文件变更不会触发重编（改了 render/*.h 会静默复用旧 .o）。
# `-include'（连字符）保证首次构建、.d 尚未生成时不会报错。
-include $(OBJS:.o=.d)
