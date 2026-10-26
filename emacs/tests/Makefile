# emacs/tests/Makefile --- ERT 入口（P1 批次 8 / T9；判据锚定于 M2 修复）
#
# 判据（缺一不可，实现见同目录 `ert-judge.sh`）：
#   ① 每个文件的汇总行存在且以 `Ran <n> tests` 开头；
#   ② 汇总行里的 unexpected 数量**数值上等于 0**（不是字符串包含 "0 unexpected"
#      —— 那样会把 "10 unexpected" 误判为通过）；
#   ③ 汇总行不含 `skipped`（ERT 只在有 skip 时才输出该词，故「无该词」= 0 skipped）。
# 为什么不能只看退出码：`ert-run-tests-batch-and-exit` 在「0 个用例」或「用例全
# 被 `skip-unless` 跳过」时同样返回 0，那是**假绿**（tech-debt「ERT 假绿判据」）。
# `check-criteria` 目标喂三条假汇总行自检判定器，防止判据本身回归。
#
# 为什么必须 `-Q`：用户配置会加载 evil / 主题 / 全局 minor mode，改掉按键与窗口
# 行为，让用例偶发失败或静默跳过；而且真机上 `seshat-reader` 是从 straight build
# 目录（软链回本仓库）加载的。`-Q` 保证跑的是**本仓库源码**。
#
# 为什么这些 `-L`：`seshat-reader-etaf` 等模块软依赖 etaf / ecss / ebox / pdd /
# posframe / gt / visual-fill-column。少一条 `-L` 就会 load 失败、整文件 0 用例，
# 同样是假绿。目录不存在时自动跳过（换机器 / 未装某个包时不报错）。
#
# 用法：
#   make -C emacs/tests ert              # 跑全部；退出码非 0 即失败
#   make -C emacs/tests check-criteria   # 只跑判据自检（喂假汇总行）
#   make -C emacs/tests                  # all = ert + check-criteria
#   make -C emacs/tests clean            # 清掉 /tmp 下的日志
#
# 注意：`--batch` 没有真实 redisplay，几何 / 居中 / 装饰这类改动必须真机验收，
# 批量绿了不等于屏幕对了（教训见 emacs/tests/README.md）。

EMACS      ?= emacs
TESTS_DIR  := $(CURDIR)
EMACS_ROOT := $(abspath $(CURDIR)/..)
READER_DIR := $(abspath $(CURDIR)/../seshat-reader)
BUILD_ROOT := $(HOME)/thomas-emacs/.local/straight/build-31.1
LOG_DIR    := /tmp/seshat-reader-ert
JUDGE      := sh $(TESTS_DIR)/ert-judge.sh

# 只把**存在**的 straight build 目录加进 -L
PKGS := gt pdd posframe etaf etaf-ui ecss ebox visual-fill-column
LIBS := $(foreach pkg,$(PKGS),$(if $(wildcard $(BUILD_ROOT)/$(pkg)),-L $(BUILD_ROOT)/$(pkg)))

TEST_FILES := $(sort $(wildcard $(TESTS_DIR)/*.el))

.PHONY: all ert check-criteria clean

all: ert check-criteria

ert:
	@mkdir -p $(LOG_DIR)
	@files=0; total=0; bad=0; \
	for f in $(TEST_FILES); do \
	  b=$$(basename $$f .el); \
	  $(EMACS) --batch -Q -L $(EMACS_ROOT) -L $(READER_DIR) $(LIBS) \
	    -l ert -l $$f -f ert-run-tests-batch-and-exit \
	    > $(LOG_DIR)/$$b.log 2>&1; \
	  line=$$(grep -E "^Ran [0-9]+ tests" $(LOG_DIR)/$$b.log | tail -1); \
	  n=$$(printf '%s\n' "$$line" | sed -n 's/^Ran \([0-9]*\) tests.*/\1/p'); \
	  files=$$((files + 1)); \
	  total=$$((total + $${n:-0})); \
	  if [ -z "$$line" ]; then \
	    bad=$$((bad + 1)); echo "NORAN  $$b (见 $(LOG_DIR)/$$b.log)"; \
	  elif $(JUDGE) "$$line"; then \
	    :; \
	  else \
	    bad=$$((bad + 1)); echo "FAIL   $$b: $$line"; \
	  fi; \
	done; \
	echo "FILES=$$files TOTAL=$$total UNEXPECTED=$$bad"; \
	[ $$bad -eq 0 ]

# 判据自检：喂四条**假汇总行**，检查判定器是否按预期工作。
# 四条都符合预期才 EXIT 0（含「0 用例」这条假绿） —— 这条目标本身是「判据不会假绿」的回归测试。
check-criteria:
	@echo "check-criteria: 判据自检（不跑 ERT）"; fail=0; \
	one="Ran 3 tests, 3 results as expected, 0 unexpected (2026-10-27 12:00:00+0800, 0.10 sec)"; \
	two="Ran 20 tests, 10 results as expected, 10 unexpected (2026-10-27 12:00:00+0800, 0.20 sec)"; \
	three="Ran 3 tests, 2 results as expected, 0 unexpected, 1 skipped (2026-10-27 12:00:00+0800, 0.10 sec)"; \
	four="Ran 0 tests, 0 results as expected, 0 unexpected (2026-10-27 12:00:00+0800, 0.10 sec)"; \
	if $(JUDGE) "$$one";   then echo "  [期望通过→通过] $$one";   else echo "  [期望通过→失败] $$one";   fail=1; fi; \
	if $(JUDGE) "$$two";   then echo "  [期望失败→通过] $$two";   fail=1; else echo "  [期望失败→失败] $$two"; fi; \
	if $(JUDGE) "$$three"; then echo "  [期望失败→通过] $$three"; fail=1; else echo "  [期望失败→失败] $$three"; fi; \
	if $(JUDGE) "$$four";  then echo "  [期望失败→通过] $$four";  fail=1; else echo "  [期望失败→失败] $$four"; fi; \
	if [ $$fail -eq 0 ]; then echo "check-criteria: PASS"; else echo "check-criteria: FAIL"; fi; \
	exit $$fail

clean:
	@rm -rf $(LOG_DIR)
	@echo "cleaned $(LOG_DIR)"
