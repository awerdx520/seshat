# 阅读器关闭 evil + 键位重排 + 翻屏留 1 行 + defcustom 化

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成（2026-10-26）
- 已确认：方案 ✅ / 计划 ✅ / 执行 ✅ / 验证 ✅
- 结果：T1–T12 全部完成；26 个测试文件 0 unexpected；`make all` warning 33（基线不变）

## 目标

让 seshat 阅读器（阅读 buffer 与全部面板 buffer）**彻底不走 evil**，键位统一由 major/minor mode 的 keymap 承担，翻屏步长等于「窗口高度 − 1 行」，并把三项行为做成 **defcustom**，使用户可仅靠 `use-package ... :custom` 配置；全部完成后自动提交并推送两个仓库。

1. 阅读器相关 buffer 关闭 evil（`evil-local-mode -1`），消除 evil 对 `C-v` / `C-f` / `j` / `k` / `n` / `p` 的抢占；并处理「evil 在本包之后才加载」的时序。
2. 键位统一落到 mode-map（vim 主键 + Emacs 补齐），不再依赖用户配置 `init-evil.el` 的 49 条 evil 绑定。
3. 翻屏步长 = `window-body-height` − 1 行。
4. 新增 3 个 defcustom：`seshat-reader-disable-evil`、`seshat-reader-screen-context-lines`、`seshat-reader-keymap-preset`。
5. 用户配置侧改为 use-package `:custom` 声明；仓库内 3 处 evil 补绑实现与配置侧 seshat evil 段删除。
6. 同步测试、文档、决策与技术债；完成后两仓库各自提交并推送。

**非目标**：不改 C 渲染模块；不改翻页/滚动算法本身；不引入新依赖；不改 `seshat-reading-mode` 的库身份逻辑；不动既有 `C-c` 前缀功能键（保留为双绑）。

## 设计

### D1 关闭 evil：`evil-local-mode -1` +「evil 后加载」补扫

- helper（`seshat-reader.el`，唯一入口，软依赖，nil 判断内聚在 helper 内）：
  ```elisp
  (defun seshat-reader--disable-evil ()
    "Turn evil off in the current buffer when `seshat-reader-disable-evil' is non-nil."
    (when (and seshat-reader-disable-evil
               (fboundp 'evil-local-mode)
               (bound-and-true-p evil-local-mode))
      (evil-local-mode -1)))
  ```
- 调用点（全部只调 helper，不自带 `when`）：`seshat-reader-mode`、`seshat-reader-outline-mode`、`seshat-reader-annotation-list-mode`、`seshat-reader-translate-panel-mode`（minor mode）、`seshat-reader-search` 侧栏 buffer、`seshat-reader-help` 帮助页 buffer、`seshat-reader-sidebar` 面板显示漏斗。
- **时序兜底**：保留 `(with-eval-after-load 'evil (seshat-reader--disable-evil-in-existing-buffers))`，遍历 `(buffer-list)`，对 derived from `seshat-reader-mode` 或四类面板 mode 的 buffer 补调 helper（幂等）。覆盖「evil 在本包之后才加载」。
- 派生 mode（`seshat-reading-mode`）自动继承父 mode 行为，无需重复。

### D2 键位表（vim 主键 + Emacs 补齐）

**阅读 buffer（`seshat-reader-mode-map`）**

| 键 | 命令 | 状态 | 归属 preset |
|---|---|---|---|
| `n` / `p` | `seshat-reader-next-page` / `-previous-page` | 保留 | 两者 |
| `j` / `k` | `seshat-reader-scroll-down-or-next-page` / `-scroll-up-or-prev-page` | **新增** | `vim` |
| `SPC` / `DEL` / `S-SPC` | 滚一屏到底翻页 / 到顶翻页 | 保留 | 两者 |
| `C-v` / `M-v` | `seshat-reader-scroll-down-screen` / `-scroll-up-screen` | 保留（步长改） | 两者 |
| `C-f` / `C-b` | `vim`：`scroll-down-screen` / `scroll-up-screen`；`emacs`：`scroll-right` / `scroll-left` | **按 preset 分派** | 分派 |
| `h` / `l` | 横向左滚 / 右滚 | **新增** | `vim` |
| `^` / `$` | 横向最左 / 最右 | **新增** | `vim` |
| `C-a` / `C-e` | 横向最左 / 最右 | 保留 | 两者 |
| `gg` / `G` | 首页 / 末页 | **新增** | `vim` |
| `M-<` / `M->` | 首页 / 末页 | 保留 | 两者 |
| `M-g g` | 跳页 | 保留 | 两者 |
| `C-l` | 重渲染当前页 | **新增** | `vim` |
| `g` | 重渲染当前页（上游语义） | 保留 | `emacs` |
| `=` `+` `-` `0` `H` `W` `r` `R` `o` `Q` `?` | 缩放 / 适配 / 旋转 / 目录 / 关文档 / 帮助 | 保留 | 两者 |
| `t` / `e` | 翻译 / 解释（`C-c C-t` / `C-c C-e` 保留） | **新增** | 两者 |
| `a` / `m` | 建批注 / 批注列表（`C-c C-a` / `C-c C-l` 保留） | **新增** | 两者 |
| `w` | 面板宽度切换（`C-c w` 保留） | **新增** | 两者 |
| `/` | 跨页搜索（`C-s` 保留） | **新增** | `vim` |
| `M-o` | 面板全开合 | 保留 | 两者 |
| `C-c C-h` / `C-c C-r` / `C-c C-q` | 刷新高亮 / 引用 / 追问 | 保留 | 两者 |
| `q` | 继承 `special-mode` 的 `quit-window`（关窗口不关文档） | 保留 | 两者 |

**面板 buffer（无 vim/emacs 分派）**

| 面板 | 键位 |
|---|---|
| 目录（`seshat-reader-outline-mode-map`） | `j`/`k` 移动（**新增**）、`p`/`n` 移动（保留）、`RET` 跳转、`f` avy、`TAB` 折叠、`o`/`q` 关闭、`s` 切回阅读窗口 |
| 批注列表（`seshat-reader-annotation-list-mode-map`） | `j`/`k` 移动（**新增**）、`RET` 跳转、`d` 删除、`q` 关闭 |
| 译文/解释面板（`seshat-reader-translate-panel-map`） | `j`/`k` 滚动（**新增**）、`w` 宽度（**新增**）、`q` 关闭、`M-o` 全开合、`C-c C-s` 存批注、`C-c C-q` 追问 |
| 搜索侧栏（`seshat-reader-search--sidebar-map`） | `j`/`k` 移动（**新增**）、`n`/`p` 上/下一条命中（保留）、`RET` 跳转、`q` 关闭 |
| 帮助页（`special-mode`） | `q` 关闭 |

### D3 翻屏步长

`seshat-reader-screen-context-lines`（默认 `1`）在 `seshat-reader-mode` body 里 `(setq-local next-screen-context-lines (max 0 seshat-reader-screen-context-lines))`；派生 mode 继承。

`window-body-height` 不传 `pixelwise` 时返回**整数行数**（内部已 floor），不存在浮点失真；`SPC`/`DEL`（`scroll-down-screen-or-next-page` / `-prev-page`）与 `C-v`/`M-v` 读同一变量，四者步长同步变为「窗口高 − 1 行」。

### D4 键位归属

键位一律落 mode-map（仓库侧），配置侧只做声明。evil 关闭后 mode-map 是唯一事实源。

### D5 defcustom 设计（包侧，供 `use-package ... :custom`）

三个 defcustom 全部 `:group 'seshat-reader`、不新增依赖。

```elisp
(defcustom seshat-reader-disable-evil t
  "Non-nil means turn evil off in every Seshat reader buffer."
  :type 'boolean :group 'seshat-reader)

(defcustom seshat-reader-screen-context-lines 1
  "Lines of overlap kept when scrolling by a screen.
Bound locally to `next-screen-context-lines' in reader buffers."
  :type 'integer :group 'seshat-reader)

(defcustom seshat-reader-keymap-preset 'vim
  "Keymap preset for `seshat-reader-mode-map'.
`vim'   = Emacs native bindings plus vim aliases (j/k/h/l/^/$/gg/G, C-l);
          C-f/C-b scroll by a screen.
`emacs' = upstream Emacs bindings only; C-f/C-b scroll horizontally, g refreshes."
  :type '(choice (const :tag "vim" vim) (const :tag "emacs" emacs))
  :group 'seshat-reader
  :set #'seshat-reader--set-keymap-preset)
```

**定义顺序（N1 修正，必须遵守）**：`seshat-reader.el` 内固定为

1. `defvar-keymap seshat-reader-mode-map`（**仅**「永久键」：`<remap>` 系列、`<wheel-*>`、`S-<wheel-*>`、`C-<wheel-*>`、`n`/`p`、`SPC`/`DEL`/`S-SPC`、`C-v`/`M-v`、`C-a`/`C-e`、`M-<`/`M->`、`M-g g`、`=`/`+`/`-`/`0`、`H`/`W`、`r`/`R`、`o`/`Q`/`?`；**不含** `g`、`C-f`、`C-b`、`C-l`、`j`、`k`、`h`、`l`、`^`、`$`、`gg`、`G`、`/`）
2. 三组绑定表 `defconst`
3. `defun seshat-reader--install-keymap-preset` 与 `defun seshat-reader--set-keymap-preset`
4. 三个 `defcustom`（`-keymap-preset` 带 `:set #'seshat-reader--set-keymap-preset`）
5. `defun seshat-reader--disable-evil` / `--disable-evil-in-existing-buffers` + `(with-eval-after-load 'evil …)`
6. `define-derived-mode seshat-reader-mode`（文件末尾）

理由：`defcustom` 默认 `:initialize` 是 `custom-initialize-reset`，求值时就 `funcall` `:set` 钩子；函数前置即无 `void-function`。`use-package :custom` 在 `require` 之后经 `customize-set-variable` 直接调 `:set`（函数已定义），用户值覆盖默认值；`custom-initialize-reset` 的 `saved-value` 分支只在 custom-file 预先声明时生效——两条路径都能正确安装用户值。

**键归属对照表（X1）**

| 键 | 归属 | 是否进卸载清单 |
|---|---|---|
| `<remap> …` 全部、`<wheel-up/down>`、`S-<wheel-up/down>`、`C-<wheel-up/down>`、`n`/`p`、`SPC`/`DEL`/`S-SPC`、`C-v`/`M-v`、`C-a`/`C-e`、`M-<`/`M->`、`M-g g`、`=`/`+`/`-`/`0`、`H`/`W`、`r`/`R`、`o`/`Q`/`?` | `defvar-keymap`（永久） | 否（永不卸载） |
| `t` `e` `a` `m` `w` | `--shared`（两套都装） | 是（卸载后重装，幂等） |
| `g` | `--emacs-only`（值 = `seshat-reader-refresh-doc-buffer`） | 是 |
| `C-f` `C-b` | `--emacs-only`（横向）/ `--vim-only`（滚屏），同名键两套值不同 | 是 |
| `j` `k` `h` `l` `^` `$` `gg` `G` `C-l` `/` | `--vim-only` | 是 |

**幂等装载（N3 修正）**：`seshat-reader--install-keymap-preset` 固定为

1. 先对上述「卸载清单」中的**全部**键执行 `keymap-unset`（`g`、`C-f`、`C-b`、`C-l`、`j`、`k`、`h`、`l`、`^`、`$`、`gg`、`G`、`t`、`e`、`a`、`m`、`w`、`/`）；
2. 再按目标 preset 写入：`emacs` → `--shared` + `--emacs-only`；`vim` → `--shared` + `--vim-only`。

`keymap-unset "g"` 会移除整个 `g` 前缀（含 `g g` 子键），这正是 vim→emacs 切换所需，无需额外 unset `gg`。卸载清单不含任何 `<remap>` 或 `<wheel-*>` 键，故不会误删鼠标/remap 绑定；`M-g g` 与 `g` 前缀互相独立，也不会被误删。

**共享 map 立即生效**：`seshat-reader-mode-map` 是可变共享对象，`keymap-set` / `keymap-unset` 直接改它，对**已打开**的 buffer 立即生效，无需重建、无需 `evil-normalize-keymaps`。`:set` 钩子是唯一切换路径（`customize-set-variable` / `use-package :custom` / `M-x customize` 三者一致）。

### D6 提交与推送策略

- 两个仓库分别提交、分别推送，**同批完成**（与原子性一致）。
- 禁止 `git add -A` / `git add .` / **目录级 add**；一律**逐文件列路径**，避免误提交构建产物（`*.elc` / `seshat-render-core.so`）、`keystore.properties`、`data/secrets.env`、`release.keystore`，以及同目录并行计划的未跟踪文件。
- 提交信息遵循 Conventional Commits（中文）：seshat 侧 `feat(reader)!: …`，thomas-emacs 侧 `chore(reader): …`。
- 推送前必须确认有 upstream（`git rev-parse --abbrev-ref --symbolic-full-name @{u}`）；无 upstream 或推送失败（凭据/网络）→ 停止并回报用户，不重试、不改 remote、不强推。
- 若 `git status --porcelain`（限定到本次待提交路径）为空 → **跳过该仓库的 commit/push 并标注原因**，不视为失败。

## 任务

- [x] T1 `seshat-reader.el`（单文件、按 D5 顺序一次改完）：① `Package-Requires` 26.1 → 29.1；② `defvar-keymap` 瘦身为「永久键」；③ 三组绑定表 `defconst` + `--install-keymap-preset` + `--set-keymap-preset`；④ 三个 defcustom（preset 带 `:set`）；⑤ `--disable-evil` / `--disable-evil-in-existing-buffers` + `(with-eval-after-load 'evil …)`；⑥ `seshat-reader-mode` body 调 helper 并 `(setq-local next-screen-context-lines (max 0 seshat-reader-screen-context-lines))`；⑦ **删除** `seshat-reader--install-evil-bindings` 及其 `with-eval-after-load 'evil` 绑定段（**保留** ⑤ 的补扫段）。验收：`'emacs` preset 下 `(key-binding (kbd "C-f"))` = `seshat-reader-scroll-right`、`(key-binding (kbd "g"))` = `seshat-reader-refresh-doc-buffer`；`'vim` 下 `C-f` = `seshat-reader-scroll-down-screen`、`(key-binding (kbd "g g"))` = `seshat-reader-first-page`、`(key-binding (kbd "C-l"))` = refresh、`(key-binding (kbd "g"))` **不是** refresh；`<remap>`/鼠标绑定未丢；evil 未加载/已加载两条路径加载不报错；`Package-Requires` 为 29.1。（依赖：无）
- [x] T2 `seshat-reader-outline.el`：mode body 调 `seshat-reader--disable-evil`；map 增 `j`/`k`；删除 `seshat-reader-outline--install-evil-bindings` 与注册。（依赖：T1）
- [x] T3 `seshat-reader-sidebar.el`：删除 `--panel-normal-key-specs` / `--ensure-panel-evil-keys` 及其调用点（约 1486–1558 与 `--display` 内）；`--display` 的 buffer 显示路径调 `seshat-reader--disable-evil`（`declare-function` + `fboundp` 守卫，不 `require` 阅读器）；阅读 buffer 与各面板 map 增绑 `w`。（依赖：T1）
- [x] T4 `seshat-reader-annotation.el`：`seshat-reader-annotation-list-mode` body 调 helper 并增 `j`/`k`；`seshat-reader-mode-map` 增绑 `a` / `m`。（依赖：T1）
- [x] T5 `seshat-reader-translate.el`：`seshat-reader-translate-panel-mode` body 调 helper 并增 `j`/`k`/`w`；`seshat-reader-mode-map` 增绑 `t`/`e`。（依赖：T1、T3）
- [x] T6 `seshat-reader-search.el`：`seshat-reader-search--sidebar-map` 增 `j`/`k`；侧栏 buffer 显示时调 helper；`seshat-reader-mode-map` 增绑 `/`。（依赖：T1、T3）
- [x] T7 `seshat-reader-help.el`：帮助页 buffer 调 helper；`--navigation-keys` 补 `seshat-reader-scroll-left` / `-right` / `-first-page` / `-last-page` / `-refresh-doc-buffer`；`--feature-keys` **只补** `seshat-reader-annotation-create`（`annotation-toggle` / `search` / `sidebar-toggle-width` 已在表内，勿重复）。（依赖：T1、T4、T5、T6）
- [x] T8 `seshat-reader-etaf.el` + `docs/architecture.md`：更新「evil 先启用、面板后 mount」注释；补验证口径——ETAF 卡片 `:keys` 在 evil 关闭后仍生效（走 `emulation-mode-map-alists` 首位，与 evil 无关）。（依赖：T1）
- [x] T9 测试更新（**3 个**文件：`seshat-reader-outline-test.el` 449–476/936–990、`seshat-reader-sidebar-test.el` 2998–3060/3220–3491、`seshat-reader-search-test.el` 1006–1116）：evil 桩断言改为「关闭 evil + mode-map 直接绑定」；新增用例：`seshat-reader-disable-evil` 为 nil 时不调 `evil-local-mode`、`next-screen-context-lines` 为 1、两套 preset 的键位差异、`vim`→`emacs` 切换后 `g` 不再是前缀、旧 evil 辅助函数已不存在。（依赖：T1–T8）
- [x] T10 配置侧（`thomas-emacs`）：① `lisp/init-reader.el` 的 `use-package seshat-reader` 增 `:custom (seshat-reader-disable-evil t) (seshat-reader-screen-context-lines 1) (seshat-reader-keymap-preset 'vim)`；② 删除 `lisp/init-evil.el:169-271` 整个 seshat 段（含 `+seshat-reader-goto-first-page` 与 `+seshat-reader-goto-page` 两个私有 helper，删除前 grep 确认无段外引用）并修正 57–60 行注释；③ `test/init-smoke-test.el` 删除/重写 `test-evil-seshat-reader-keymap-rebuilt`（1105–1122），核对 `'reader-mode-map` 否定断言，新增断言「init-reader.el 含三个 `:custom` 变量」。（依赖：T1–T8；**必须与 T1–T8 同批落地**）
- [x] T11 文档沉淀：`docs/emacs-reader.md`（§3 键位表、§9 完整键位表 412–446、§4/§5/§6 面板键、面板承载节 338–341、§11 Troubleshooting 628–664 的 evil 条目）、`emacs/seshat-reader/README.org:161-171`、`emacs/seshat-reader/VENDORED.md`、`docs/architecture.md:152-153`、`CHANGELOG.md`、`openspec/decisions.md`（关闭 evil / vim 主键化 / 翻屏 1 行 / defcustom 化）、`openspec/tech-debt.md`（勾销 2 条），并把本计划移入 `openspec/completed/`。（依赖：T1–T10）
- [x] T12 提交与推送（按 D6，**逐文件**）：seshat 侧 `git add` 明确列出：`emacs/seshat-reader/seshat-reader.el`、`seshat-reader-outline.el`、`seshat-reader-sidebar.el`、`seshat-reader-annotation.el`、`seshat-reader-translate.el`、`seshat-reader-search.el`、`seshat-reader-help.el`、`seshat-reader-etaf.el`、`emacs/seshat-reader/VENDORED.md`、`emacs/seshat-reader/README.org`、`emacs/tests/` 下 3 个改动过的测试文件、`docs/emacs-reader.md`、`docs/architecture.md`、`CHANGELOG.md`、`openspec/decisions.md`、`openspec/tech-debt.md`、`openspec/active/2026-10-26-reader-disable-evil-and-keymap.md`（删除）、`openspec/completed/2026-10-26-reader-disable-evil-and-keymap.md`（新增）→ `git commit -m "feat(reader)!: 阅读器关闭 evil、键位 vim 主键化与 defcustom 化"` → `git push`；thomas-emacs 侧 `git add lisp/init-reader.el lisp/init-evil.el test/init-smoke-test.el`（若其有 CHANGELOG 一并）→ `git commit -m "chore(reader): 改用 use-package 声明 reader defcustom 并移除 evil 绑定"` → `git push`。任一侧失败即停止并回报。（依赖：T11）

## 文档清单

1. `docs/emacs-reader.md` — §3 键位表、§9 完整键位表（412–446）、§4 目录键、§5 批注列表键、§6 译文键、搜索侧栏键、面板承载节（338–341）、§11 Troubleshooting（628–664）。
2. `emacs/seshat-reader/README.org:161-171` — 上游键位表（`C-b`/`C-f` 语义已变）。
3. `emacs/seshat-reader/VENDORED.md` — 8 个 `.el` 的本地改动条目各补一条。
4. `docs/architecture.md:152-153` — ETAF evil/mount 注释。
5. `CHANGELOG.md` — `[Unreleased]`：`C-f`/`C-b` 与 `g`→`C-l` 属 breaking change；新增 3 个 defcustom。
6. `openspec/decisions.md` — 关闭 evil、键位 vim 主键化、翻屏 1 行、defcustom 化。
7. `openspec/tech-debt.md` — 勾销「evil 键位自维护」「evil 遮蔽鼠标绑定」。
8. `thomas-emacs` 仓库 — `init-reader.el` / `init-evil.el` / `init-smoke-test.el`（若其有 CHANGELOG 则补一条）。

## 验证标准

- **L1（结构）**：`make -C emacs/seshat-reader all` EXIT 0，warning 不超过当前基线 33（执行时先实测基线）；`make -C emacs/seshat-reader checkdoc` 0 报错；`emacs --batch -Q` 加载不报错。
- **L2（功能）**：ERT **逐文件**跑（一次性全量加载会失败，见 `docs/emacs-reader.md:756`），全绿、0 unexpected / 0 skipped；新增用例覆盖 D1–D5、`g` 前缀两向切换。
- **L3（实测，verify 隔离实例）**：
  1. 打开 `d2l-zh-pytorch.pdf`，`next-screen-context-lines` 断言为 1；
  2. `C-v`、`SPC`、`DEL` 三者 `(window-vscroll)` 增量均 ≈ `window-body-height - 1` 行；
  3. `(bound-and-true-p evil-local-mode)` 为 nil；`(key-binding (kbd "C-v"))` 为 `seshat-reader-scroll-down-screen`；
  4. `j`/`k`/`h`/`l`/`gg`/`G`/`C-l`/`t`/`e`/`a`/`m`/`/`/`w` 的 `key-binding` 与 D2 一致；
  5. `vim` → `emacs` → `vim` 往返后 `C-f`/`C-b`/`g`/`gg`/`C-l` 语义正确，`g` 在前缀与完整绑定间干净切换；
  6. 目录、批注列表、译文面板、搜索侧栏、ETAF 批注卡片：`q` 能关、`j`/`k` 能移动。
- **L3（跨仓库）**：`thomas-emacs` 的 `init-smoke-test.el` 通过；重启 Emacs 后打开 PDF 无 evil normal state 指示；`use-package :custom` 三值生效。
- **L3（提交）**：两仓库限定路径的 `git status --porcelain` 干净；`git log -1 --oneline` 可见提交；推送后 `git rev-parse HEAD` == `git rev-parse @{u}`。

## 注意事项

- **原子性**：T1–T8（仓库侧）与 T10（配置侧）**必须同批落地、同批验证**，禁止中间态进入可用构建。
- **定义顺序（N1 修正）**：`defcustom :set` 引用的函数必须先定义；顺序固定为 defvar-keymap → 绑定表 → install/set 函数 → defcustom → helper → mode。不要用 `:initialize` 覆盖绕过。
- **evil 是软依赖**：所有 `evil-local-mode` 调用必须有 `fboundp` 守卫，evil 不在时零副作用；不得写进 `Package-Requires`。
- **不改 C 模块**：纯 elisp，无需 `make clean all`；`straight-rebuild-package seshat-reader` 或重开文档即可生效。
- **`g` 与前缀等待**：`vim` preset 下 `g` 是前缀（单按会等 `echo-keystrokes`）；重渲染在 `C-l`。
- **`C-f`/`C-b` 是破坏性改绑**：CHANGELOG 必须标注；横向滚动替代是 `h`/`l` 与 `C-a`/`C-e`。
- **删除补绑代码时同步改测试**：`seshat-reader-sidebar-test.el:2998-3060` 与 `:3220-3491`、`seshat-reader-outline-test.el:449-476` 与 `:936-990`、`seshat-reader-search-test.el:1006-1116` 的 evil 桩断言必须改为新语义断言，不得直接删用例了事。
- **零依赖模块的调用边界**：`seshat-reader-sidebar.el` 不 `require` 阅读器；调用 helper 一律 `declare-function` + `fboundp` 守卫。
- **提交纪律（D6）**：禁止 `git add -A` / `git add .` / 目录级 add；逐文件列路径；`git status --porcelain` 限定路径为空则跳过并标注；无 upstream 或推送失败即停止回报，不重试、不改 remote、不强推。
- **用户配置仓库是独立 git 仓库**：`thomas-emacs` 的改动需单独确认工作区状态，禁止在其未提交状态下运行 `straight-pull-package`。
- **并行计划提示**：`openspec/active/2026-10-25-pdf-text-line-separators.md` 也改 `emacs/seshat-reader`（C 层与 select 模块），文件不重叠但同目录；执行前确认其状态，禁止把其未跟踪文件纳入本次 `git add`。
- **测试环境**：ERT 在 `verify` 隔离实例或批处理下逐文件跑；`config` 主实例禁止跑 ERT / 批量字节编译。
