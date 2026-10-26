#!/bin/sh
# ert-judge.sh --- 判定一条 ERT 汇总行是否「真绿」（P1 批次 9 / M2）
#
# 用法：ert-judge.sh '<ERT 汇总行>'
# 退出码：0 = 通过；1 = 不通过。
#
# 判据（三条缺一不可）：
#   ① 行非空且形如 `Ran <n> tests` 且 **n ≥ 1**（`Ran [1-9][0-9]*`）——「0 用例」
#      的汇总行同样是假绿（`ert-run-tests-batch-and-exit` 对它返回 0），必须排除；
#   ② 行里的 `unexpected` 数量**数值上等于 0** —— 不能用 `grep "0 unexpected"`
#      这种子串匹配：`10 unexpected` 里也包含 `0 unexpected`（前一位是 1 的十位
#      数字），会把 10 例失败判成通过；
#   ③ 行里不含 `skipped`（ERT 只在确实有 skip 时才输出该词）——「没跑」不等于
#      「通过」。
#
# 为什么单独成脚本：`ert` 与 `check-criteria` 必须共用同一段判定逻辑，否则
# 自检通过而真实运行用另一套判据，等于没自检。Make 里内联多行 shell 函数被
# 空白/续行规则折腾过一轮，脚本比宏更不容易写错。

line=$1

[ -n "$line" ] || exit 1
printf '%s\n' "$line" | grep -qE '^Ran [1-9][0-9]* tests' || exit 1

unexpected=$(printf '%s\n' "$line" | sed -n 's/.* \([0-9][0-9]*\) unexpected.*/\1/p')
[ -n "$unexpected" ] || exit 1
[ "$unexpected" -eq 0 ] || exit 1

printf '%s\n' "$line" | grep -q 'skipped' && exit 1

exit 0
