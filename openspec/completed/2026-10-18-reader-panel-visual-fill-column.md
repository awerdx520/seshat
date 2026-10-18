# 译文/解释面板启用 visual-fill-column-mode（M11.14）

## 当前状态

- 阶段：Phase 4（Review）· 已完成并归档
- 已确认：方案 ✅（用户 2026-10-18 确认，选项 A）、计划 ✅（用户 2026-10-18 确认）
- 实现：✅ T1–T5 完成（defcustom + `--prepare-view` 显式启停 + 软依赖 declare-function）
- 验证：L1 全绿（check-parens 2/2、byte-compile 零 warning、checkdoc 零告警）；L2 translate 46/46、sidebar 29/29、annotation 26/26、etaf 18/18
- 审查：code-reviewer 有条件通过；important 项（`-1` 误清 selected-window margin）已加窗口守卫修复，并补兜底测试与 `:safe`
- L3：待人工在运行中 Emacs 触发翻译确认缩窄留白（batch 无法验证）
- 归档：`openspec/completed/2026-10-18-reader-panel-visual-fill-column.md`

## 目标

译文/解释面板（`*Seshat Sidebar*` 的 Markdown 文本 buffer）在弹出显示时启用 `visual-fill-column-mode`，把正文按适宜宽度缩窄/居中，改善长行阅读舒适度。

用户已确认范围：**只对译文/解释面板启用**；批注列表（ETAF 卡片与纯文本回退）不动。

## 根本问题与假设

**根本问题**：译文/解释面板正文在宽窗口下拉满整个窗口宽度，长行阅读舒适度差；`visual-fill-column-mode` 通过窗口 margin 缩窄文本区，配合已有的 `word-wrap` 实现软折行。

**假设清单**：

| # | 假设 | 来源 |
|---|---|---|
| A1 | `visual-fill-column` 已安装且 `visual-fill-column-mode` 可 autoload 调用 | 事实✓（`build-31.1/visual-fill-column` 存在，运行中 Emacs `featurep` 为 t） |
| A2 | 该 mode 与 `gfm-view-mode`/`markdown-view-mode` 兼容；`--prepare-view` 已设的 `truncate-lines nil` + `word-wrap t` 正是其前置条件 | 事实✓（mode 文档：与软折行配合） |
| A3 | 批注列表不应开启：ETAF 按 `window-body-width` 计算布局，`window-margins` 缩窄后可能错位/被裁 | 假设?（用户已选 A 规避） |
| A4 | 宽度沿用用户全局 `visual-fill-column-width`（nil 时用 `fill-column`），本包不新增宽度变量 | 假设? |
| A5 | mode 启用时 buffer 可能尚未显示在窗口；包在 Emacs>27 注册 buffer-local 的 `window-state-change-functions` 与 `window-configuration-change-hook`，面板经 `display-buffer` 显示时触发 `--adjust-window` 设置 margin（无需 `visual-line-mode`） | 事实✓（审查核对包源码） |
| A6 | 面板 buffer 复用/重开时重复启用 mode 幂等 | 事实✓（minor mode 传正整数为启用） |

## 设计

### D1 新增 defcustom

```elisp
(defcustom seshat-reader-translate-visual-fill-column t
  "译文/解释面板是否启用 `visual-fill-column-mode'.
非 nil 时在 `seshat-reader-translate--prepare-view' 末尾启用该 minor mode，
按 `visual-fill-column-width'（nil 时回退 `fill-column'）缩窄文本区；设为
nil 可关闭。`visual-fill-column' 是软依赖：未安装时静默跳过。批注列表面板
不受本变量影响。"
  :type 'boolean
  :group 'seshat-reader-translate)
```

放在 `seshat-reader-translate-template` 相关 defcustom 之后、`capture-window` 之前（或与视图相关 defcustom 相邻）。

### D2 `--prepare-view` 末尾启用

在现有 `(setq-local buffer-read-only t)` 之后追加：

```elisp
(when (or (fboundp 'visual-fill-column-mode)
          (require 'visual-fill-column nil t))
  ;; 显式启停：关闭时传 -1 触发 `visual-fill-column--disable' 清窗口
  ;; margin，避免 major mode 重设（kill-all-local-variables）后残留缩窄。
  (visual-fill-column-mode
   (if seshat-reader-translate-visual-fill-column 1 -1)))
```

- 软依赖：`require` 失败时 `nil`，不启用、不报错
- 幂等：`--render-panel` 每次渲染都会调用 `--prepare-view`，重复启用无害
- 不改动 `truncate-lines` / `word-wrap` 的既有设置
- 不设置 buffer-local `visual-fill-column-width`（沿用全局）

### D3 批注列表保持不变

`seshat-reader-annotation--render-list`（ETAF 与纯文本两条路径）**不**启用 `visual-fill-column-mode`，也不新增任何相关变量。

## 任务

- [x] T1：实现（`emacs/seshat-reader/seshat-reader-translate.el`）
  - 新增 defcustom `seshat-reader-translate-visual-fill-column`（默认 t，docstring 见 D1）
  - `--prepare-view` 末尾按 D2 启用；docstring 同步说明
  - 验收：在 `visual-fill-column` 可加载时，调用 `--prepare-view` 后 `visual-fill-column-mode` 为 t；绑定变量为 nil 时为 nil（依赖：无）
- [x] T2：测试（`emacs/tests/seshat-reader-translate-test.el`）
  - 新增 `--prepare-view-enables-visual-fill-column`：调用 `--prepare-view` 后断言 `visual-fill-column-mode` 为 t（`skip-unless (require 'visual-fill-column nil t)`）
  - 新增 `--prepare-view-honors-disable-option`：绑定 `seshat-reader-translate-visual-fill-column` 为 nil，断言 mode 为 nil
  - 可选新增 `--prepare-view-tolerates-missing-visual-fill-column`：`cl-letf` 桩 `(symbol-function 'require)` 使其失败且 `fboundp` 为 nil，断言不报错（若桩写起来复杂可跳过，报告中说明）
  - 验收：translate 套件 `unexpected = 0`（期望 43 + 2 = 45 或 46，依赖：T1）
- [x] T3：文档同步（3 份）
  - `docs/configuration.md`：translate 配置表新增 `seshat-reader-translate-visual-fill-column` 行（默认 t；说明只影响译文/解释面板，宽度沿用 `visual-fill-column-width`/`fill-column`，软依赖）
  - `docs/architecture.md`：面板视图设置段落补一句「译文/解释面板启用 `visual-fill-column-mode`（软依赖，可关）；批注列表不启用（ETAF 布局按窗口宽度计算）」
  - `CHANGELOG.md`：`[Unreleased]` 的「新增」追加一条（不改历史）
  - 验收：新配置项在表格中可见；CHANGELOG 删除列为 0（依赖：T1）
- [x] T4：OpenSpec 收尾
  - `openspec/decisions.md`：**一律追加一条**简短决策（`## 2026-10-18 · 译文/解释面板启用 visual-fill-column` + 决策/理由/代价），不设「评估不记」分支
  - `openspec/active/roadmap.md` M11 表追加 `M11.14` 行
  - 验收：roadmap 3 列表格完整；decisions 格式与近期条目一致（依赖：T1–T3）
- [x] T5：验证与计划收尾（L1/L2 已完成；**L3 待人工**：运行中 Emacs 触发翻译确认缩窄留白）
  - L1：`check-parens`（translate.el + translate-test.el，emacs-lisp-mode）、`batch-byte-compile` 零新增 warning、checkdoc 零告警
  - L2：translate / sidebar / annotation / etaf 四套件 ERT 全绿
  - 勾选 T1–T5、更新「## 当前状态」
  - L3：在运行中 Emacs 触发一次翻译，确认面板正文两侧出现缩窄留白（或居中），关闭再打开仍生效
  - 验收：四套件 unexpected 全 0（依赖：T1–T4）

依赖关系：T1 → T2、T3；T1–T3 → T4；T1–T4 → T5。

## 文档清单

| 文档 | 是否需要更新 | 理由 |
|---|---|---|
| `docs/configuration.md` | 是 | 新 defcustom |
| `docs/architecture.md` | 是 | 面板视图设置补充 |
| `CHANGELOG.md` | 是 | `[Unreleased]` 新增条目 |
| `openspec/decisions.md` | 是（简短） | 启用范围与批注不启用的理由 |
| `openspec/active/roadmap.md` | 是 | M11.14 行 |
| `docs/llm.md` | 否 | 不涉及 LLM 接入 |
| `emacs/seshat-reader/VENDORED.md` | 否 | 职责描述未变化 |
| `openspec/tech-debt.md` | 否 | 无新增债务 |

## 验证标准

- **L1**：translate.el 与 translate-test.el `check-parens` 通过（emacs-lisp-mode）；byte-compile 零新增 warning；checkdoc 零告警
- **L2**：四套件 ERT 全绿（translate 期望 ≥45）。命令见各测试文件头部注释；translate 套件须额外加 `-L /home/thomas/thomas-emacs/.local/straight/build-31.1/visual-fill-column`
- **L3**：运行中 Emacs 触发一次翻译，面板正文缩窄留白可见；`seshat-reader-translate-visual-fill-column` 设 nil 后重开面板无留白

## 注意事项

- **启用顺序**：必须在 `--prepare-view` 的 major mode 调用与 `truncate-lines`/`word-wrap` 设置之后启用；不要提前到 `gfm-view-mode` 之前。
- **软依赖**：`visual-fill-column` 未安装时不得报错；`require` 用 `(require 'visual-fill-column nil t)`，并保留 `fboundp` 兜底。
- **不要设置 buffer-local 宽度**：沿用全局 `visual-fill-column-width`（nil → `fill-column`），避免给用户制造第二套宽度配置。
- **批注列表零改动**：不要给 `seshat-reader-annotation--render-list` 或 ETAF 渲染加任何 visual-fill-column 逻辑。
- **mode 变量名**：测试断言用 `visual-fill-column-mode`（minor mode 变量），不是函数调用返回值。
- **测试 load-path**：batch 测试需加 `-L /home/thomas/thomas-emacs/.local/straight/build-31.1/visual-fill-column`，否则 `require` 失败导致用例被 skip。
- **陈旧 .elc**：跑测试前删除 `seshat-reader-translate.elc`。
- **对 selected-window 的 margin 副作用**：`visual-fill-column--enable` 会立即对 `selected-window` 执行 `--adjust-window`（其中 `--reset-window` 会 `set-window-margins nil`）。面板未显示时 selected-window 是阅读器窗口，通常无 margin 故影响可忽略；但若用户也给阅读器 buffer 启用了 vfc，可能被重置。接受该副作用并在决策「代价」中记录。
- **batch 下实跑**：T2 会真实调用 `visual-fill-column-mode 1` → `--adjust-window` → `set-window-margins`，L2 需确认 batch 下不报错。
