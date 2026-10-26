# emacs/tests/Makefile --- ERT 入口（P1 批次 8 / T9）
#
# 判据（缺一不可）：每个测试文件的 ERT 汇总行必须是 `…, 0 unexpected`，
# 且该汇总行**不得**出现 `skipped`。为什么不能只看退出码：
# `ert-run-tests-batch-and-exit` 在「0 个用例」或「用例全被 `skip-unless`
# 跳过」时同样返回 0，那是**假绿**；本项目纪律是 skipped 恒为 0（见
# tech-debt「ERT 假绿判据」）。
#
# 为什么必须 `-Q`：用户配置会加载 evil / 主题 / 全局 minor mode，改掉按键与
# 窗口行为，让用例偶发失败或静默跳过；而且真机上 `seshat-reader` 是从
# straight build 目录（`~/.local/straight/build-*/seshat-reader/`，软链回本仓库）
# 加载的。`-Q` 保证跑的是**本仓库源码**，结果与配置无关。
#
# 为什么这些 `-L`：`seshat-reader-etaf` 等模块软依赖 etaf / ecss / ebox /
# pdd / posframe / gt / visual-fill-column。少一条 `-L` 就会 load 失败、整文件
# 0 用例 —— 同样是假绿。目录不存在时自动跳过（换机器 / 未装某个包时不报错）。
#
# 用法：
#   make -C emacs/tests ert      # 跑全部，退出码非 0 即失败
#   make -C emacs/tests clean    # 清掉 /tmp 下的日志
#
# 注意：`--batch` 没有真实 redisplay，几何 / 居中 / 装饰这类改动必须真机验收，
# 批量绿了不等于屏幕对了（教训见 emacs/tests/README.md）。

EMACS      ?= emacs
TESTS_DIR  := $(CURDIR)
EMACS_ROOT := $(abspath $(CURDIR)/..)
READER_DIR := $(abspath $(CURDIR)/../seshat-reader)
BUILD_ROOT := $(HOME)/thomas-emacs/.local/straight/build-31.1
LOG_DIR    := /tmp/seshat-reader-ert

# 只把**存在**的 straight build 目录加进 -L
PKGS := gt pdd posframe etaf etaf-ui ecss ebox visual-fill-column
LIBS := $(foreach pkg,$(PKGS),$(if $(wildcard $(BUILD_ROOT)/$(pkg)),-L $(BUILD_ROOT)/$(pkg)))

TEST_FILES := $(sort $(wildcard $(TESTS_DIR)/*.el))

.PHONY: all ert clean

all: ert

ert:
	@mkdir -p $(LOG_DIR)
	@files=0; total=0; bad=0; \
	for f in $(TEST_FILES); do \
	  b=$$(basename $$f .el); \
	  $(EMACS) --batch -Q -L $(EMACS_ROOT) -L $(READER_DIR) $(LIBS) \
	    -l ert -l $$f -f ert-run-tests-batch-and-exit \
	    > $(LOG_DIR)/$$b.log 2>&1; \
	  line=$$(grep -E "^Ran [0-9]+ tests" $(LOG_DIR)/$$b.log | tail -1); \
	  n=$$(echo "$$line" | sed -n 's/^Ran \([0-9]*\) tests.*/\1/p'); \
	  files=$$((files + 1)); \
	  total=$$((total + $${n:-0})); \
	  if [ -z "$$line" ]; then \
	    bad=$$((bad + 1)); echo "NORAN  $$b (见 $(LOG_DIR)/$$b.log)"; \
	  else \
	    echo "$$line" | grep -q "0 unexpected" || { bad=$$((bad + 1)); echo "FAIL   $$b: $$line"; }; \
	    echo "$$line" | grep -q "skipped"      && { bad=$$((bad + 1)); echo "SKIP   $$b: $$line"; }; \
	  fi; \
	done; \
	echo "FILES=$$files TOTAL=$$total UNEXPECTED=$$bad"; \
	[ $$bad -eq 0 ]

clean:
	@rm -rf $(LOG_DIR)
	@echo "cleaned $(LOG_DIR)"
