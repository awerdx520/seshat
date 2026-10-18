# 译文/解释面板：模板拆分、去掉正文重复标题、原文默认显示（M11.12）

## 当前状态

- 阶段：Phase 4（Review）· 已完成并归档
- 已确认：方案 ✅（用户 2026-10-18 确认，样式 A）、计划 ✅（用户 2026-10-18 确认）
- 实现：✅ T1–T5 完成（两个模板变量、按 context 选模板、`show-source` 默认 t、测试 43/43）
- 验证：L1 全绿（check-parens 2/2、byte-compile 零 warning、checkdoc 零告警）；L2 translate 43/43
- 偏离：模板选择用 `context` 参数而非 `template` 参数（避免 nil 语义冲突，explain 模板 nil 不借用 translate 模板）
- 审查：code-reviewer 通过（无 blocking/major；3 处 minor 已修）
- 归档：`openspec/completed/2026-10-18-reader-panel-template-split.md`

## 目标

用户对 M11.11 的三点反馈：

1. 翻译和解释应使用**各自的模板变量**，可分别定制；
2. 正文里的 `# Seshat 译文` / `# Seshat 解释` 与 header-line 重复，**去掉正文标题**（保留 header-line）；
3. 译文/解释面板**默认显示原始句子**（原文引用块不再默认关闭）。

## 根本问题与假设

**根本问题**：M11.11 用单一模板变量服务两种用途，且默认模板把标题写进正文、原文块默认关闭，导致正文冗余、看不到原文、两类内容无法分别塑形。

**假设清单**：

| # | 假设 | 来源 |
|---|---|---|
| A1 | 「正文中去掉」= 去掉正文 `%k` 标题，header-line 保留（窗口装饰、滚动常驻） | 用户显式（样式 A） |
| A2 | 译文与解释拆成两个 defcustom；解释默认不含语言对行（解释场景语言对信息价值低） | 假设? |
| A3 | 原文默认显示对翻译与解释都成立 | 用户显式 |
| A4 | `%k` 占位符保留在 API 中（自定义模板仍可用），仅默认模板不含它 | 假设? |
| A5 | 模板为 `nil` 时退回纯正文的既有语义不变 | 事实✓ |

## 设计

### D1 拆分模板变量

| 变量 | 默认值 | 用途 |
|---|---|---|
| `seshat-reader-translate-template`（已有，改默认值） | `"%l\n\n%q\n\n---\n\n%t\n"` | 翻译 |
| `seshat-reader-translate-explain-template`（新增） | `"%q\n\n---\n\n%t\n"` | 解释 |

默认渲染效果（翻译，`show-source` 默认 t）：

```markdown
*en → zh*

> **原文**
>
> Hello world

---

译文正文
```

解释（默认无语言对行）：

```markdown
> **原文**
>
> Hello world

---

解释正文
```

- 两个变量都支持 `nil`（退回纯正文）与自定义占位符（`%k` / `%l` / `%q` / `%t` 全部保留）
- `%l` 为空时仍由 `--apply-template` 留空并清理空行；`%q` 为空时同理

### D2 去掉正文重复标题

默认模板不再含 `%k`；`header-line-format` 仍写 TITLE（`Seshat 译文` / `Seshat 解释`）。`%k` 占位符保留，用户自定义模板时仍可使用。

### D3 原文默认显示

`seshat-reader-translate-show-source` 默认值由 `nil` 改为 **`t`**：默认在正文前展示选中原文的引用块（`> **原文**` + 每行 `> ` 前缀）。用户仍可设 `nil` 关闭。

### D4 渲染链路透传模板

- `seshat-reader-translate--apply-template (text title &optional langs template)`：TEMPLATE 省略时回退 `seshat-reader-translate-template`
- `seshat-reader-translate--render-panel (text title &optional langs template)`：透传给 `--apply-template`
- `seshat-reader-translate--render-object (mode &optional title langs template)`：sidebar 分支的 `:then` 把 TEMPLATE 透传给 `--render-panel`
- `seshat-reader-translate--translator`：按 CONTEXT 选择模板后传给 `--render-object`：

```elisp
(let ((template (if (eq context 'explain)
                    seshat-reader-translate-explain-template
                  seshat-reader-translate-template)))
  (oset trans render (seshat-reader-translate--render-object
                      seshat-reader-translate-render
                      (if (eq context 'explain) "Seshat 解释" "Seshat 译文")
                      langs
                      template)))
```

所有新增参数均为 `&optional`，既有调用点向后兼容。

## 任务

- [x] T1：实现模板拆分与原文默认显示（`emacs/seshat-reader/seshat-reader-translate.el`）
  - 新增 defcustom `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`，见 D1；类型同 translate 模板）
  - 修改 `seshat-reader-translate-template` 默认值为 `"%l\n\n%q\n\n---\n\n%t\n"`，docstring 说明默认不含标题（header-line 承担标题）
  - `seshat-reader-translate-show-source` 默认值改为 `t`，docstring 同步（默认显示原文）
  - `--apply-template` 增加可选 TEMPLATE 参数；`--render-panel`、`--render-object` 增加可选 TEMPLATE 并透传；`--translator` 按 context 选模板
  - 验收：`--apply-template "正文" "Seshat 译文" '(en zh)` 返回以 `*en → zh*` 开头、含 `> **原文**`（`show-source` 为 t 且有选区时）、`---`、正文的字符串且**不含** `# Seshat 译文`；传入 explain 模板时不含语言对行（依赖：无）
- [x] T2：更新与新增测试（`emacs/tests/seshat-reader-translate-test.el`）
  - 更新既有模板断言（具体值）：
    - `--apply-template-default`：期望改为 `"*en → zh*\n\n---\n\n正文\n"`
    - `--apply-template-langs-nil`：期望改为 `"---\n\n正文\n"`
    - `--render-panel-show-source`：前缀断言改为 `"> **原文**"`
    - `--render-panel-show-source-off`：前缀改为 `"---\n\n译文正文\n"`
    - `--apply-template-percent-in-text` 用 `standard-value` 动态取模板、不依赖具体结构，**无需修改**
  - 更新 `--render-object-then-passes-langs`：断言 `--render-panel` 收到第 4 个实参（模板）。该测试直接调用 `--render-object`、不经过 `--translator`，因此**必须显式传入** `seshat-reader-translate-template` 作为第 4 实参（否则第 4 实参为 nil，`--render-panel` 回退默认模板）
  - 更新 `--integration-selection-to-panel` 与 `--integration-panel-to-annotation` 的面板内容断言（前缀从 `# Seshat 译文` 改为 `*en → zh*` 或 `> **原文**`）
  - 新增：① 译文/解释使用不同模板（同一选区分别以 `translate`/`explain` context 构造渲染对象，`:then` 传入的模板不同）；② `seshat-reader-translate-show-source` 默认值为 t；③ `--apply-template` 传 explain 模板时不出现 `%l` 语言对行；④ 两个模板都为 nil 时均退回纯正文
  - 验收：translate 测试套件 `unexpected = 0`（依赖：T1）
- [x] T3：文档同步（4 份）
  - `docs/configuration.md`：`seshat-reader-translate-template` 默认值改为 `"%l\n\n%q\n\n---\n\n%t\n"` 并说明不含标题；新增 `seshat-reader-translate-explain-template` 行；`seshat-reader-translate-show-source` 默认值改为 `t`
  - `docs/architecture.md`：模板链路补「按 context 选模板」；默认模板说明更新
  - `docs/llm.md`：模板说明更新（译文/解释各自模板、原文默认显示）
  - `CHANGELOG.md`：`[Unreleased]` 增加 M11.12 条目（模板拆分、去正文标题、原文默认显示），不改历史条目
  - 验收：文档中 `show-source` 默认值、模板默认值与代码一致；无「`# Seshat 译文` 写在正文」的旧描述（依赖：T1）
- [x] T4：OpenSpec 收尾
  - `openspec/active/roadmap.md` M11 表追加 `M11.12` 行（状态 ✅ 完成 2026-10-18，链接本计划）
  - `openspec/decisions.md` 追加决策条目（沿用近期段落格式：`## 2026-10-18 · …` + `**决策**` / `**理由**` / `**代价**`）
  - 验收：roadmap 表格 3 列完整；decisions 三段齐全、零删除（依赖：T1–T3）
- [x] T5：全量验证与计划收尾
  - L1：`check-parens`（translate.el + translate-test.el，emacs-lisp-mode 下）、`batch-byte-compile` 零新增 warning、checkdoc 零新增告警
  - L2：translate / sidebar / etaf / annotation 四套件 ERT 全绿（translate 期望 ≥43）
  - 勾选 T1–T5 checkbox，更新「## 当前状态」为 Phase 3 完成待审查
  - 验收：四套件 unexpected 全为 0（依赖：T1–T4）

依赖关系：T1 → T2、T3；T1–T3 → T4；T1–T4 → T5。

## 文档清单

| 文档 | 是否需要更新 | 理由 |
|---|---|---|
| `docs/configuration.md` | 是 | 两个模板变量、默认值、`show-source` 默认 t |
| `docs/architecture.md` | 是 | context → 模板选择链路 |
| `docs/llm.md` | 是 | 模板与原文呈现说明 |
| `CHANGELOG.md` | 是 | `[Unreleased]` 新增/变更条目 |
| `openspec/active/roadmap.md` | 是 | M11.12 行 |
| `openspec/decisions.md` | 是 | 模板拆分与默认值决策 |
| `emacs/seshat-reader/VENDORED.md` | 否 | 职责描述未变化 |
| `openspec/tech-debt.md` | 否 | 无新增债务（沿用既有启发式测量评估） |

## 验证标准

- **L1**：2 个 `.el` 文件 `check-parens` 通过（emacs-lisp-mode）；`batch-byte-compile` 零新增 warning；checkdoc 零新增告警
- **L2**：四套件 ERT 全绿（load-path 含 `build-31.1/{gt,pdd,posframe,compat}`，etaf 另加 ETAF 四仓库）
- **L3**：在运行中 Emacs 触发一次翻译与一次解释，确认正文无 `# Seshat 译文/解释`、header-line 仍显示标题、原文可见

## 注意事项

- **默认值变更**：`seshat-reader-translate-show-source` 从 nil 改 t 属行为变更，需在 CHANGELOG「变更」与 decisions「代价」中写明（面板默认更高、默认显示原文）。
- **参数顺序**：新增 TEMPLATE 作为 `&optional` 第 3/4 参，必须保持既有 `(text title)` / `(mode title)` 调用兼容；所有直接调用点（含 sidebar-test）逐一核对。
- **测试耦合**：既有断言把默认模板串写死；改默认值时必须同步更新，避免「跳过测试」式修法。
- **陈旧 .elc**：跑测试前删除 `seshat-reader-translate.elc`，避免加载旧字节码。
- **模板 nil 语义**：两个模板分别为 nil 时，各自退回纯正文；不要互相回退（explain 模板为 nil 时不能借用 translate 模板）。
- **header-line 决策**：保留 header-line 是用户显式选择（样式 A），不要在实现中顺手去掉。
- **不要误改 `--apply-template-percent-in-text`**：该用例用 `standard-value` 动态取默认模板，只验证正文 `%` 不被二次解析，不依赖 `%k` 或具体模板结构；改默认值后应原样通过。
