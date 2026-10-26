# `emacs/tests` — Seshat Reader 的 ERT 基线

本目录是**整个仓库的 ERT 测试**（reader 之外还有 library / merge / sync / transport 等）。
入口由同目录的 `Makefile` 提供，不必再手抄一长串 `-L`。

## 怎么跑

```sh
make -C emacs/tests ert      # 全部测试；退出码非 0 即失败
make -C emacs/tests          # 等同 ert
make -C emacs/tests clean    # 删掉 /tmp/seshat-reader-ert 下的日志
```

单个文件调试（任一文件都能单独跑）：

```sh
make -C emacs/tests ert                       # 先跑一遍留日志
less /tmp/seshat-reader-ert/seshat-reader-multipage-test.log
# 或手动：
emacs --batch -Q -L emacs -L emacs/seshat-reader $(LIBS) \
  -l ert -l emacs/tests/seshat-reader-multipage-test.el \
  -f ert-run-tests-batch-and-exit
```

## 判据（tech-debt「ERT 假绿判据」）

**两个条件同时满足才算绿**：

1. 每个文件的 ERT 汇总行是 `… , 0 unexpected`；
2. 该汇总行**不含** `skipped`。

只看退出码是不够的：`ert-run-tests-batch-and-exit` 在「0 个用例」或「用例全被
`skip-unless` 跳过」时同样返回 0 —— 那是假绿。本项目的纪律是 **skipped 恒为 0**，
所以用例里不使用 `skip-unless` / `ert-skip`（需要条件分支时用 `if` + `should`）。

`Makefile` 的 `ert` 目标按上述两条 grep 汇总行判定，任一文件不满足即非零退出，
并打印 `FAIL` / `SKIP` / `NORAN`（后者表示该文件连 `Ran N tests` 都没有，通常是
load 失败，日志在 `/tmp/seshat-reader-ert/<文件>.log`）。

### 判据实现与自检（`ert-judge.sh` + `check-criteria`）

判定逻辑单独放在同目录的 `ert-judge.sh` 里（`ert` 与自检共用同一段代码，避免
「自检用一套、真实运行用另一套」）。三条判据：行以 `Ran ` 开头、`unexpected`
**数值**为 0、行内不含 `skipped`。

**注意不要用子串匹配**：`grep "0 unexpected"` 会把 `10 unexpected` 判成通过
（`10 unexpected` 里含 `0 unexpected`）。这正是 M2 修掉的缺陷 —— 现在用
`sed -n 's/.* \([0-9][0-9]*\) unexpected.*/\1/p'` 取出数字后做 `-eq 0`。

自检入口（`all` 也会跑它）：

```sh
make -C emacs/tests check-criteria
# 期望输出：
#   [期望通过→通过] Ran 3 tests, 3 results as expected, 0 unexpected (...)
#   [期望失败→失败] Ran 20 tests, 10 results as expected, 10 unexpected (...)
#   [期望失败→失败] Ran 3 tests, 2 results as expected, 0 unexpected, 1 skipped (...)
#   check-criteria: PASS
```

三条假汇总行的期望都成立才 EXIT 0；改判据（或换 shell）后先跑它，再信 `ert` 的绿。

## 为什么必须 `-Q` 与这些 `-L`

- **`-Q`**：用户配置会加载 evil、主题、全局 minor mode，改变按键与窗口行为，
  让用例偶发失败或静默跳过；真机上 `seshat-reader` 还是从
  `~/.local/straight/build-*/seshat-reader/`（软链回本仓库）加载的。`-Q` 保证跑的
  是**本仓库源码**。
- **`-L emacs -L emacs/seshat-reader`**：本项目自身模块。
- **straight build 目录**（`gt` / `pdd` / `posframe` / `etaf` / `etaf-ui` / `ecss` /
  `ebox` / `visual-fill-column`）：`seshat-reader-etaf` 等模块软依赖它们；少一条
  `-L` 就会 load 失败、整文件 0 用例（也是假绿）。`Makefile` 里只把**存在**的目录
  加进 `-L`，换机器 / 未装某个包时不报错。

## 当前基线（P1 批次 8 / T9 固化）

| 项 | 值 |
|---|---|
| 测试文件数 | **31** |
| 用例总数 | **1213** |
| unexpected / skipped | **0 / 0** |
| `make -C emacs/seshat-reader clean all` | **EXIT 0**，`Warning` **24** 行（零新增基线） |
| 生产代码 checkdoc | **0** 诊断（`make all` 自带 checkdoc 步骤无输出） |

基线变化时请同时更新本表，并在 `CHANGELOG` / 计划文件里记一句。

## 教训：batch 不等于屏幕

`--batch` 没有真实 redisplay：`window-vscroll` 永远读回 0、`window-end` 等于
buffer 末尾、`line-pixel-height` 在页行上给出整页高度、`posn-*` 拿不到真实事件。
所以：

- **几何 / 居中 / 装饰（高亮、批注、闪现）/ 滚轮**这类改动，批量测试只能钉住
  「算出来的值」与「调用了哪个函数」；**必须再真机验收**（GUI 帧、真实文档）。
- 需要窗口上下文的用例，请用既有的助手桩（`--window-pixels`、`--with-scroll-stubs`、
  `--with-single-page-viewport`、`--geometry-buffer` 等），不要依赖真实 redisplay。
- `posn-window` / `posn-object` / `posn-object-x-y` 在 Emacs 31 里是可内联函数，
  `.elc` 会把调用内联进调用方，`cl-letf` 改 `symbol-function` 拦不住 —— 需要桩
  它们时先 `(load "<同目录>/seshat-reader-select.el" nil t t)` 载源码（见
  `seshat-reader-periphery-test--load-select-source`）。
- 想用 `with-timeout` 防死循环要小心：batch 里没有命令循环，定时器不会触发。
  判据应当设计成「调用能返回」而不是「超时能兜住」。
