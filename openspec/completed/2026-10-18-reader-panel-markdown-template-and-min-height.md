# 阅读器译文/解释面板：Markdown 模板与初始高度（M11.11）

## 当前状态

- 阶段：Phase 4（Review）· 已完成并归档
- 已确认：方案 ✅（用户 2026-10-18 确认，样式 C）、计划 ✅（用户 2026-10-18 确认）
- 实现：✅ T1–T7 完成（translate 模板 + langs 透传；sidebar min-height + 测量口径；文档 4 份；roadmap/decisions 已补）
- 验证：L1 全绿（check-parens 4/4、byte-compile 零新增 warning、checkdoc 零告警）；L2 四套件全绿（translate 39/39、sidebar 29/29、etaf 20/20、annotation 31/31，unexpected 均为 0）
- 审查：code-reviewer 通过（无 blocking/major）；must-fix（`--format-langs` nil 元素）已修复并补测试
- 归档：`openspec/completed/2026-10-18-reader-panel-markdown-template-and-min-height.md`

## 目标

1. 译文/解释面板正文套一层**可配置的 Markdown 模板**：标题、语言对元信息、可选原文引用块、分隔线、正文，提升可读性与视觉层级。
2. 提高译文/解释面板的**初始高度**：把自适应下限从硬编码 5 行改为可配置比例（默认 0.25 ≈ 12 行），并修正行数测量口径。
3. 保持 `seshat-reader-translate-template` 为 `nil` 时退回当前纯正文行为（向后兼容）；批注列表面板不受影响。

## 根本问题与假设

**根本问题**：面板已能正确渲染 Markdown，但内容缺少视觉层级（只有纯正文），且首屏高度下限只有 5 行；用户每次翻译都要手动拉伸窗口才能舒适阅读。

**假设清单**：

| # | 假设 | 来源 |
|---|---|---|
| A1 | 「初始高度太低」主因是 5 行硬编码下限 + 标题行高造成的行数低估，而非 `display-buffer` 布局 | 假设?（依据：fit 在显示后立即覆盖 0.35 默认值；用户未改任何高度配置） |
| A2 | `gfm-view-mode` / `markdown-view-mode` 能渲染 `#` 标题、`---` 分隔线、`> **粗体**` 引用块与 `*斜体*` 元信息 | 事实✓（现有降级链 + M11.10 实测记忆） |
| A3 | 模板用 defcustom 字符串 + 占位符，与仓库既有 `seshat-reader-reference-format` 模板先例一致 | 类比⚡（`~/thomas-emacs/lisp/init-reader.el` 的 `%s` 模板） |
| A4 | 原文引用块默认仍关闭（`show-source=nil`），模板只是在开启时给它更好样式 | 事实✓（M11.10 刚定的默认值） |
| A5 | 不需要独立渲染抽象层：模板属 translate 的内容呈现，高度属 sidebar 的窗口参数 | 假设?（tech-debt 已记「暂不抽象渲染层」） |

## 设计

### D1 Markdown 模板（可配置）

新增 defcustom `seshat-reader-translate-template`：

```elisp
(defcustom seshat-reader-translate-template
  "# %k\n\n%l\n\n%q\n\n---\n\n%t\n"
  "译文/解释面板的 Markdown 模板；nil 表示不套模板、直接插入正文..."
  :type '(choice (const :tag "不使用模板" nil) string)
  :group 'seshat-reader-translate)
```

占位符：

| 占位符 | 含义 | 取值来源 |
|---|---|---|
| `%k` | 标题 | `--render-panel` 的 TITLE 参数（`Seshat 译文` / `Seshat 解释`） |
| `%l` | 语言对元信息（斜体，如 `en → zh`） | `--render-panel` 新增可选 LANGS 参数，`--translator` 透传 |
| `%q` | 原文引用块（`> **原文**` + 每行 `> ` 前缀），未启用时为空 | `seshat-reader-translate-show-source` 与最近选区 |
| `%t` | 译文/解释正文 | gt `:then` 回调取出的纯文本 |

默认渲染效果（开启原文时）：

```markdown
# Seshat 译文

*en → zh*

> **原文**
>
> 选中的第一行
> 选中的第二行

---

译文正文
```

`show-source` 为 nil 时，`%q` 为空，渲染后清理多余空行：

```markdown
# Seshat 译文

*en → zh*

---

译文正文
```

实现要点：
- 新增 `seshat-reader-translate--format-langs (langs)`：把 `(en zh)` 转为 `"en → zh"`；多目标语言按 `(en zh ja)` → `"en → zh → ja"` 逐项拼接；少于 2 个元素时按实际元素拼接；nil / 非 list / 元素非 symbol 时返回 nil。
- 新增 `seshat-reader-translate--quote-block ()`：把现有 `--render-panel` 中的原文引用块逻辑抽出；无原文时返回 nil；有原文时输出 `> **原文**\n>\n> <行1>\n> <行2>`。
- 新增 `seshat-reader-translate--apply-template (text title &optional langs)`：
  1. 模板为 nil → 返回 TEXT；
  2. `format-spec` 替换 `?k ?l ?q ?t`（值里出现的 `%` 不会被二次解析）；
  3. `(replace-regexp-in-string "\n\\{3,\\}" "\n\n" ...)` 清理空占位符造成的连续空行；
  4. `string-trim` 去首尾空白并补一个尾换行；
  5. 仅把 `format-spec` 调用包在 `condition-case` 内（只有它会因未知占位符报错）：模板非法时 `message` 警告并返回 TEXT（绝不中断翻译流程）；`--format-langs` 与 `--quote-block` 保持裸露，真实 bug 不被吞掉。
- 更新 `seshat-reader-translate--render-panel` 的 docstring，列出占位符表。

#### header-line 与正文标题的关系

`--render-panel` 仍把 TITLE 写入 `header-line-format`（窗口顶行、不占正文行、滚动时仍在），模板 `%k` 也在正文首行输出同一 TITLE（用户确认的样式 C）。**决策：接受两处重复**——header-line 是窗口装饰，正文 H1 是文档层级，职责不同；用户若不喜欢，可把 `seshat-reader-translate-template` 改成不含 `%k` 的模板。

### D2 初始高度

新增 defcustom `seshat-reader-sidebar-min-height`（比例，默认 `0.25`）：

```elisp
(defcustom seshat-reader-sidebar-min-height 0.25
  "译文/解释面板按内容自适应时的**下限**，按 `frame-height' 比例计..."
  :type 'number
  :group 'seshat-reader-sidebar)
```

`seshat-reader-sidebar--fit-height-for-content` 公式改为：

```
min-h  = floor(min-height × frame-height)
max-h  = max(1, floor(max-height × frame-height))
target = max(1, max((min min-h max-h), (min max-h (+ content 2))))
```

- 默认 0.25 × 50 行 = 12 行（原下限 5 行）；
- min 配得比 max 大时取 max 兜底，避免负数窗口；`max-h` 与最终 `target` 均加 `max 1` 保底，frame 极小（如 1 行）或 min-height 配 0 时都不会算出 0 行；
- `seshat-reader-sidebar-height` 默认值 0.35 **不变**（批注列表仍用它）。

`seshat-reader-sidebar--content-height` 两处调整：
- 单行像素高改为 `(min 首行像素高 frame-char-height)`（首行有效时）；标题行更高会把行数算少，取较小值使行数估算偏大、面板更高；batch 下 `frame-char-height` 可能为 1，测试必须补桩（见 T5）；
- `window-text-pixel-size` 的测量上限从 40 行提高到 120 行（大 frame 下 40 行会截断），最终高度仍由 `max-height` 夹紧。

### D3 渲染链路透传 langs（保持向后兼容）

- `seshat-reader-translate--render-panel (text title &optional langs)`：第三参数可选，既有单/双参调用不受影响；用 `--apply-template` 生成内容后写入 buffer。
- `seshat-reader-translate--render-object (mode &optional title langs)`：sidebar 分支的 `:then` 闭包捕获 LANGS，调用 `--render-panel result title langs`。
- `seshat-reader-translate--translator`：调用 `--render-object` 时传入已有的 `langs` 变量。

## 任务

- [x] T1：模板基础设施（`seshat-reader-translate.el`）
  - 新增 `seshat-reader-translate-template` defcustom（默认值见 D1，类型 `(choice (const nil) string)`）
  - 新增 `--format-langs`、`--quote-block`、`--apply-template` 三个内部函数
  - 更新相关 docstring 与 Commentary
  - 验收：`--format-langs '(en zh)` 返回 `"en → zh"`、`'(en zh ja)` 返回 `"en → zh → ja"`；`--apply-template "正文" "Seshat 译文" '(en zh)` 返回含 `# Seshat 译文`、`*en → zh*`、`---`、`正文` 的字符串；模板为 nil 时原样返回正文（依赖：无）
- [x] T2：渲染链路透传 langs（`seshat-reader-translate.el`）
  - `--render-panel` 增加可选 LANGS 参数并改用 `--apply-template`；`--render-object` 增加可选 LANGS 并透传到 `:then`；`--translator` 传 `langs`
  - 验收：`--render-panel "正文" "Seshat 译文" '(en ja)` 的 buffer 内容含 `*en → ja*`；不传 LANGS 时 `%l` 为空且无连续空行（依赖：T1）
- [x] T3：高度下限与测量口径（`seshat-reader-sidebar.el`）
  - 新增 `seshat-reader-sidebar-min-height` defcustom；按 D2 公式改 `--fit-height-for-content`（`min-h` 加 `max 1` 保底）；`--content-height` 单行高改为 `min(首行像素高, frame-char-height)` 并把测量上限 40 → 120 行
  - 同步更新 `--content-height`、`--fit-height-for-content` 的 docstring（「下限 5 行」→「下限 `seshat-reader-sidebar-min-height`」，并更新测量上限描述）
  - 验收：frame 50 行、内容 1 行时目标高度 12 行；`min-height` 设 0.4 时目标 20 行；min > max 时取 max；frame-height=1 时目标高度 ≥1（依赖：无）
- [x] T4：更新与新增 translate 测试（`emacs/tests/seshat-reader-translate-test.el`）
  - 更新 `--render-panel-writes-text-and-view`、`--render-panel-show-source`、`--render-panel-show-source-off` 的 buffer 内容断言（改为模板渲染结果）
  - 更新 `--integration-selection-to-panel`：**保留**断言 ①（渲染对象）、③（视图参数与 header-line 不变，复核即可）、④（last-result = 纯译文）、⑤（显示类型与光标跟随）、⑥（无失败消息）；**仅改**断言 ②（面板 buffer 由 `equal` 纯译文改为 `equal` 模板渲染结果）
  - 更新 `--integration-panel-to-annotation`（**blocking 回归点**）：面板 buffer 为模板渲染结果，`last-result` 与存批注实参 `(nth 2 call)` 仍为**纯译文**；断言改为「存批注正文 = last-result = 纯译文」+「面板 buffer 内容包含纯译文子串（`(string-match-p (regexp-quote translated-text) (buffer-string))`，纯译文含 `*`/`-` 等正则特殊字符，必须 `regexp-quote`）」，不再断言两者相等
  - 新增测试：① 默认模板含标题/语言对/分隔线/正文；② `langs` 为 nil 时元信息行被清理（内容中无 `\n\n\n`、无空斜体行）；③ 模板为 nil → 纯正文；④ 自定义模板 `"## %k\n\n%t"` 生效；⑤ 非法占位符 `"%z"` 回退纯正文且不报错；⑥ `--render-object` 的 `:then` 把 langs 传给 `--render-panel`（可用 `cl-letf` 桩 `--render-panel` 断言实参）
  - **已核对无需改动**：`emacs/tests/seshat-reader-etaf-test.el` 的 `--sidebar-render-object-uses-hidden-gt-buffer` 只断言 name/window-config/then，`&optional langs` 向后兼容，不要动它
  - 验收：该测试文件在 batch ERT 下全绿（依赖：T1、T2）
- [x] T5：更新与新增 sidebar 测试（`emacs/tests/seshat-reader-sidebar-test.el`）
  - **在 `seshat-reader-sidebar-test--fit-run` 桩中补 `frame-char-height` 桩**（默认 10，与 `line-pixel-height` 桩一致，保证既有用例期望不变）
  - 更新 `--fit-height-for-content-clamps-min` 期望：5 行 → 12 行（frame 50 × 0.25）
  - 新增：`min-height` 覆盖生效（0.4 → 20 行）；min > max 时取 max 兜底；`frame-height`=1 时目标 ≥1
  - 新增 `--content-height` 单行高取 `min` 的用例：桩 `line-pixel-height`=20、`frame-char-height`=10、内容 6 行 → 单行高取 10 → 行数 12（覆盖「标题行更高时行数估算偏大」的 D2 行为）
  - 复核 `--fit-height-for-content-translate-adjusts`（内容 12 行 → 14 行，高于新下限，断言不变）与 `--fit-height-for-content-clamps-max`（上限不变）
  - 验收：该测试文件在 batch ERT 下全绿（依赖：T3）
- [x] T6：文档同步（三份 + llm.md）
  - `docs/configuration.md`：translate 配置表新增 `seshat-reader-translate-template`（含占位符表）；sidebar 配置表新增 `seshat-reader-sidebar-min-height`；把「夹紧 5 行到 max-height」改为「夹紧 min-height（默认 0.25）到 max-height」
  - `docs/architecture.md`：面板渲染小节补充模板链路；高度小节改下限描述
  - `docs/llm.md`：客户端接入节的结果呈现补一句 `seshat-reader-translate-template` 模板说明
  - `CHANGELOG.md`：`[Unreleased]` 的「新增」加两条（Markdown 模板；可配置高度下限）；**不改** M11.10 历史条目
  - 验收：`docs/configuration.md` 与 `docs/architecture.md` 不再出现「夹紧 5 行」；`CHANGELOG.md` 的 M11.10 历史条目保持原样；新配置项在表格中可见（依赖：T1、T3 完成后）
- [x] T7：OpenSpec 与验证收尾
  - `openspec/active/roadmap.md` 的 M11 表追加 `M11.11` 行：主题「译文/解释面板 Markdown 模板与初始高度」，状态「✅ 完成（2026-10-18）」，链接本计划相对路径
  - `openspec/decisions.md` 追加一条决策，**沿用近期段落格式**：`## 2026-10-18 · 译文/解释面板 Markdown 模板与高度下限可配置` + `**决策**` / `**理由**` / `**代价**`
  - 执行 L1（2 个源 `.el` 的 check-parens + `batch-byte-compile` + checkdoc；2 个测试 `.el` 的 check-parens）与 L2（translate / sidebar / etaf / annotation 四套 ERT）
  - 验收：L1、L2 全绿；计划中 check box 全部勾选（依赖：T1–T6）

依赖关系：T1 → T2 → T4；T3 → T5；T1/T3 → T6；T1–T6 → T7。

## 文档清单

| 文档 | 是否需要更新 | 理由 |
|---|---|---|
| `docs/configuration.md` | 是 | 新增 2 个 defcustom；高度范围描述变更 |
| `docs/architecture.md` | 是 | 面板渲染链路与高度下限描述 |
| `docs/llm.md` | 是 | 已描述面板渲染链路（客户端接入节），需补一句模板说明 |
| `CHANGELOG.md` | 是 | `[Unreleased]` 新增两条 |
| `emacs/seshat-reader/VENDORED.md` | 否 | 自研扩展职责描述未变化 |
| `openspec/tech-debt.md` | 否 | 评估：模板非法已有运行时兜底、测量口径有测试覆盖，暂无新增债务；若实施中发现 frame-char-height 不可靠则补记一条 |
| `openspec/active/roadmap.md` | 是 | 追加 M11.11 行 |
| `openspec/decisions.md` | 是 | 追加一条决策 |
| `~/thomas-emacs/lisp/init-reader.el` | 否（默认） | 跨仓库；配置示例注释默认不改，用户另行决定 |

## 验证标准

- **L1（语法）**：2 个源 `.el`（`seshat-reader-translate.el`、`seshat-reader-sidebar.el`）`check-parens` 通过 + `batch-byte-compile` 无新增 warning（gt/ETAF 软依赖相关的既有告警不计）+ `checkdoc` 与基线一致；2 个测试 `.el` `check-parens` 通过。
- **L2（测试）**：batch ERT 四套件全绿，load-path 需包含 straight 构建目录 `~/thomas-emacs/.local/straight/build-31.1/` 下的 `gt`、`pdd`、`posframe`（ETAF 套件另需 `compat`），路径以测试文件头部注释为准，换机器/Emacs 版本时按其中命令探测 `GTROOT`：
  - `emacs/tests/seshat-reader-translate-test.el`
  - `emacs/tests/seshat-reader-sidebar-test.el`
  - `emacs/tests/seshat-reader-etaf-test.el`
  - `emacs/tests/seshat-reader-annotation-test.el`
- **L3（目视）**：在运行中 Emacs 用真实选区触发一次 `C-c C-t`（或直接 `--render-panel`），确认面板显示标题、语言对、分隔线与正文，且初始高度明显高于 5 行。

## 注意事项

- **陈旧 .elc**：改动 `.el` 后若 load-path 上存在同名旧 `.elc`，batch 测试可能加载旧代码（M11.10 已踩坑）。测试前删除或重编 `seshat-reader-translate.elc` / `seshat-reader-sidebar.elc`。
- **format-spec 转义**：模板字符串里的 `%` 需成对；正文/标题值中的 `%` 不会被 `format-spec` 二次解析，无需转义。非法模板必须在 `condition-case` 内回退，不能让模板错误中断翻译。
- **空行清理范围**：`\n{3,}` 压缩会同时作用于正文内部的 3+ 连续空行；Markdown 语义上无损失，但测试断言需按此规则写。
- **测试桩**：`seshat-reader-sidebar-test--fit-run` 已桩 `frame-height`=50、`line-pixel-height`=10、`window-text-pixel-size`；本次必须补 `frame-char-height` 桩（batch 下真实值可能为 1，会让行数估算漂移 10 倍）。T5 已把补桩写进任务。
- **checkdoc**：新增 defcustom/函数需符合 checkdoc（首行完整句子、参数大写、`\\='` 转义），包内 Makefile 的 `checkdoc` 目标会检查。
- **不改 `seshat-reader-sidebar-height` 默认值**：批注列表高度不应被本次改动影响。
- **向后兼容**：`--render-panel` / `--render-object` 的新增参数必须为 `&optional`，既有测试与调用点不得被迫改写。
