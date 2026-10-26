# 修复：evil 重启用导致阅读器键位与鼠标选区失效

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅、计划 ✅、执行 ✅、验证 ✅
- 结果：T1–T6 完成；L1 `make all` EXIT 0 / warning 33（基线不变）/ checkdoc 0；L2 该测试文件 9/9 全绿；L3 主实例实测 `evil-local-mode` → nil、`<down-mouse-1>` → `seshat-reader-select-drag`、`j` / `C-v` / `g g` 均回到 seshat 命令。`seshat-reader-select-copy-to-kill-ring` 的 `t` 需重启 Emacs 后生效（`:custom` 启动期写入）。

## 目标

修复 2026-10-26「阅读器关闭 evil」计划的回归：

1. 阅读 buffer 内 `[down-mouse-1]` 被解析到 `evil-mouse-drag-region`，鼠标拖拽选区取文失效（`mouse-1` / `drag-mouse-1` 又被 remap 成 `ignore`，故静默无反应）。
2. `j` / `k` / `C-v` / `g g` 被 evil normal state 抢走，vim preset 形同虚设。
3. `seshat-reader-select-copy-to-kill-ring` 默认 nil，选中后不进 kill ring。

**非目标**：不改 C 模块、不改选区几何、不动面板既有的显式关闭路径、不引新依赖。

## 根因

| 事实 | 实测值 |
|---|---|
| local map 里 `[down-mouse-1]` | `seshat-reader-select-drag`（绑定完好） |
| `(key-binding [down-mouse-1])` | `evil-mouse-drag-region` |
| 命中顺序 | `evil-motion-state-map` 早于 local map（经 `emulation-mode-map-alists`） |
| buffer 内 evil | `evil-local-mode` t（buffer-local，default nil）/ `evil-state` normal |
| mode body 是否执行 | 是（`next-screen-context-lines` buffer-local = 1） |
| `(let ((evil-mode-map-alist nil)) (key-binding [down-mouse-1]))` | `seshat-reader-select-drag` |

因果：evil 是 `define-globalized-minor-mode`，启用函数 `evil-mode-enable-in-buffer` 挂在 `after-change-major-mode-hook`，运行在 mode body **之后**，把 `evil-local-mode` 重新打开；`evil-initial-state-alist` 对该 mode 无条目 → 默认 normal state。

## 修法

**代码（`seshat-reader.el`）**：一个 append hook，排在 evil 的启用函数之后再关一次。evil 用非 append 注册（落列表前部），`append` 落末尾，故顺序确定。

```elisp
(add-hook 'after-change-major-mode-hook
          (lambda ()
            (when (derived-mode-p 'seshat-reader-mode
                                  'seshat-reader-outline-mode
                                  'seshat-reader-annotation-list-mode)
              (seshat-reader--disable-evil)))
          'append)
```

覆盖范围：reader（含派生的 reading）＋ outline ＋ annotation-list。译文/搜索/帮助面板是 minor mode 或 `special-mode`，hook 识别不到，保持各自「显示后再关一次」的路径不动。

**配置（`thomas-emacs/lisp/init-reader.el`）**：`:custom` 加一行 `(seshat-reader-select-copy-to-kill-ring t)`。

## 任务

- [x] T1 `seshat-reader.el`：插入上述 8 行 `add-hook`（唯一代码改动）。（依赖：无）
- [x] T2 `thomas-emacs/lisp/init-reader.el`：`:custom` 加 `(seshat-reader-select-copy-to-kill-ring t)`。（依赖：无）
- [x] T3 `emacs/tests/seshat-reader-evil-keymap-test.el`：3 个用例——① hook 已注册；② 在 reader 系 buffer 里 hook 对 `evil-local-mode` 传 -1（`cl-letf` 桩）；③ 在非 reader buffer 不调用。（依赖：T1）
- [x] T4 `thomas-emacs/test/init-smoke-test.el`：文本断言 `init-reader.el` 含 `seshat-reader-select-copy-to-kill-ring`。（依赖：T2）
- [x] T5 文档：`docs/emacs-reader.md` Troubleshooting 补一条；`emacs/seshat-reader/VENDORED.md` 补 `seshat-reader.el` 条目；两个仓库的 `CHANGELOG.md`；`openspec/tech-debt.md` 修正「evil 遮蔽鼠标绑定」的错误结论（原「已解决」不成立）。（依赖：T1–T4）
- [x] T6 验证与归档：L1/L2/L3 全过后勾选并移入 `openspec/completed/`；不 commit。（依赖：T1–T5）

## 验证标准

- **L1**：`cd emacs/seshat-reader && rm -f *.elc && make all` → EXIT 0，`grep -cE "Warning|Error"` ≤ 33（基线）；`make checkdoc` 0 报错。
- **L2**：ERT 逐文件跑 `seshat-reader-evil-keymap-test.el`，全绿、0 skipped。
- **L3（config 主实例，打开 `The-Art-of-Linear-Algebra-zh-CN.pdf` 后）**：
  1. `(bound-and-true-p evil-local-mode)` → nil；
  2. `(key-binding [down-mouse-1])` → `seshat-reader-select-drag`；
  3. `(key-binding "j")` → `seshat-reader-scroll-down-or-next-page`；`(key-binding (kbd "C-v"))` → `seshat-reader-scroll-down-screen`；
  4. `seshat-reader-select-copy-to-kill-ring` → t；
  5. 手动拖拽一次后 `(car kill-ring)` 非空。

## 注意事项

- **不要用 `evil-define-key` 重绑 `[down-mouse-1]`**：那是已删除的旧规避，本次要的是「evil 不生效」。
- **hook 必须 `append`**：否则再次被 evil 覆盖。
- **evil 是软依赖**：`--disable-evil` 内部已有 `fboundp` 守卫，hook 里不要再判。
- **config 任务禁止长耗时**：L3 只做变量/键位查询与一次人工拖拽，不在主实例跑 ERT。
