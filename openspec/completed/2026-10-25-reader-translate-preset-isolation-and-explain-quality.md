# 阅读器翻译/解释：gt 预设隔离与解释质量提升

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅（用户 2026-10-25 确认：Q1 独立计划 / Q2 seshat 默认 prompt 且可覆盖 / Q3 子类 override）
- 已确认：计划 ✅（用户 2026-10-25 确认）
- 独立审查：plan-reviewer 需修订（4 major / 7 minor）→ 全部修订 → 复审余 2 处 → 已修
- 代码审查：code-reviewer ✅ 通过（0 blocking / 0 major / 5 minor）→ 4 项已修（T6d），1 项记 tech-debt
- T0 ✅ / T1 ✅ / T1.5 ✅ / T2 ✅ / T3 ✅ / T4 ✅ / T5 ✅ / T6a ✅ / T6b ✅ / T6b-3 ✅ / T6d ✅ / T6c ✅（归档）
- 验证：L1 ✅（make all exit 0、translate.el 0 警告、checkdoc 0）· L2 ✅（25 文件 / 896 例 / 0 unexpected / 0 skipped）· L3a ✅（真实 PDF 页顶/中部选区、gt 隔离阻断项）
- L3b（用户真机目视）：真实 LLM 回复质量与面板观感待用户验收
- 归档：本文件已移入 `openspec/completed/`

## 目标

1. **隔离**：seshat 的两个 gt 预设（`reader` / `reader-explain`）不再进入 gt 全局预设表 `gt-preset-translators`；seshat 与 thomas-emacs 配置不再改写 gt 全局 key 变量 `gt-chatgpt-key`。gt 的 `gt-translate` 预设选择列表、以及用户其它 gt chatgpt 用法恢复原状。
2. **提质**：解释（`C-c C-e`）从「孤立片段 + 一句话 prompt」升级为「带上下文 + 结构化 prompt + 长度护栏 + 输出净化」，并把解释 prompt 变成 seshat 的一等 defcustom。

## 非目标

- 不做流式渲染、追问的**改造** —— 它们已由并发会话在 commit `8d43480` 落地（属 active 计划 `2026-10-24` 的 T4/T5）；本计划只在其之上追加「预设隔离 + 解释上下文/prompt」，**不得改动其流式与追问代码**（`--enable-stream` / `--follow-up-*` / `--stream-sync`）。
- 不改 C 模块（`emacs/seshat-reader/render/`）、不改 `seshat-reader-select.el` / `seshat-reader-sidebar.el` / `seshat-reader-etaf.el`。
- **不克隆、不新建、不 `oset` 任何 gt 引擎实例的槽**（原因见 D2）。
- 不改 go-translate（gt）源码。

## 背景与事实（实测 2026-10-25）

| # | 事实 | 依据 |
|---|---|---|
| F1 | `gt-preset-translators` 是 gt 的全局预设表，gt 自身的 `gt-translate`（前缀选预设）/`gt-setup` 读取它；`push` 进该表会让 `reader` / `reader-explain` 出现在 gt 的预设列表里 | `~/.local/straight/repos/gt.el`（thomas-emacs）中 `gt-preset-translators` 的消费点 |
| F2 | `gt-resolve-key` 的解析链是 authinfo → `gt-chatgpt-key` → `OPENAI_API_KEY`；配置里 `(setq gt-chatgpt-key (getenv "DEEPSEEK_API_KEY"))` 会让**所有** chatgpt 引擎（含用户其它 gt 用法）用 DeepSeek key 打各自端点 | `gt-engine-chatgpt.el` 的 `gt-resolve-key`；`thomas-emacs/lisp/init-tools.el` 的 setq |
| F3 | gt 的 engine / parser / render 都继承 `gt-single`，其 `make-instance` 以「槽参数的 sha1」为键做 **class 级实例缓存**；`eieio` 的 `clone` 是否绕过该缓存**未实测**（`describe-function clone` 只说明是 generic 并带 PARAMS，不保证不经 `make-instance`）。**但 `gt-translator` 不继承 `gt-single`**（`(defclass gt-translator ())`），故 translator 可安全 `clone`、engine/parser/render 不可——这是 D2 理由 3 的根因 | `gt-core.el` 的 `(cl-defmethod make-instance ((class (subclass gt-single)) …))`、`(defclass gt-translator ())` |
| F4 | seshat 目前只会从 `gt-preset-translators` 查预设名，查不到就回退内置 youdao/google | `seshat-reader-translate.el` 的 `seshat-reader-translate--translator` |
| F5 | `gt-chatgpt-engine` 的 `prompt` 槽支持字符串模板（`{{text}}` / `{{lang}}`）与函数；`stream` 槽在父类 `gt-engine` 上 | `gt-engine-chatgpt.el` 的 `gt-execute`、`gt-core.el` 的 `gt-engine` |
| F6 | 取上下文的能力已具备：`seshat-reader-dyn--page-text`（0/1 参：可按页）、`seshat-reader-dyn--text-in-rect`（5 参）、`seshat-reader-dyn--lines-in-rect`（5 参，返回选区触达的**整行**矩形） | `render/render-core.c` 的 `register_module_func` 段 |
| F7 | 选区的 `seshat-reader-select-last` 含 `:text` / `:page`（1-based）/ `:rect`（bbox）/ `:file` | `seshat-reader-select.el` 的 `seshat-reader-select-extract` |
| F8 | thomas-emacs 的 `gt-source-text-transformer`（`+thomas/gt-normalize-source-text`）对每个送引擎的 text 做软换行归一化；**保护行正则**（`#`/`>`/`-`/`1.`/```/≥2 空格缩进）的行保留换行，段落间空行保留 | `thomas-emacs/site-lisp/thomas-text-normalize.el` |
| F9 | childframe 计划的 T1–T3.6 已落地；**T4（流式）/T5（追问）已由并发会话在 commit `8d43480` 实现**（`seshat-reader-translate-stream` / `--follow-up-*` / `--enable-stream`） | `git log` + 代码 grep |
| F10 | commit `8d43480` 的实现在 stream / follow-up 上采用「`(clone engine)` 后 `oset copy stream t` / `oset engine-copy prompt`」；该路径依赖「eieio `clone` 对 `gt-single` 子类能产出副本」，而这一点**至今无测试支撑**（本计划 D2 因此选择不动引擎） | `seshat-reader-translate.el` 的 `--enable-stream` / `--follow-up-translator` |
| F11 | `seshat-reader-translate--translator` 现为 **4 参** `(preset text langs &optional context)`，本计划追加可选第 5 参不冲突 | 代码 |

## 设计

### D1 预设归属：seshat 自有表 + 兼容回落

`emacs/seshat-reader/seshat-reader-translate.el` 新增：

```elisp
(defcustom seshat-reader-translate-presets nil
  "Seshat 专用的 gt 预设表：(NAME . TRANSLATOR) 或 (NAME . THUNK)。
THUNK 是无参函数，调用后返回 gt-translator（用于避开「配置加载时 gt 尚未加载」的顺序问题）。
查表顺序：本表 → `gt-preset-translators`。本表命中时优先，故 seshat 的预设不必再进 gt 的全局表。"
  :type '(alist :key-type symbol :value-type (choice (function :tag "thunk") sexp))
  :group 'seshat-reader-translate)
```

新增内部查表函数（替换 `--translator` 里现有的 `alist-get … gt-preset-translators`）：

```elisp
(defun seshat-reader-translate--preset-translator (preset)
  "按 PRESET 名取 gt-translator：先查 `seshat-reader-translate-presets'，再查 `gt-preset-translators'。
值为函数（thunk）时调用一次取结果。都未命中返回 nil。"
  ...)
```

约束：
- 查询前仍先 `(seshat-reader-translate--ensure-gt)`（保持 gt 软依赖语义与既有报错文案）。
- `gt-ensure-plain` 的既有用法保留（`gt-preset-translators` 可能是 plain 形式）。
- **既有测试大量引用 `gt-preset-translators`**（`seshat-reader-translate-test.el` 中多处，具体数量以 T0 基线实测为准）：由于回落顺序保留，这些测试**零改动**；同时新增「seshat 表命中优先」「thunk 被调用」「两表都缺仍回退内置引擎」的用例。

### D2 引擎零改动原则（为什么不用引擎 prompt）

解释的 prompt 需求（结构、上下文、长度约束）**不通过引擎的 `prompt` 槽实现**，理由：

1. F3 的单例缓存意味着「克隆预设里的引擎再改槽」可能根本没克隆（`clone` 是否绕开 `make-instance` 缓存未验证），一旦命中缓存就会**污染全局引擎实例**，把 seshat 的 prompt 泄漏给用户其它 gt 用法。
2. 新建引擎实例需要 seshat 硬编码引擎类与厂商参数（host/model/key），违反「seshat 只做桥接」的职责边界。
3. 现有 `--translator` 只 `oset` translator 的 `taker` / `render` 两个槽（translator 自身已 `clone`，且 `gt-translator` 不继承 `gt-single`），这条路径已验证无污染，应予保留。

因此：**解释的 prompt 与上下文，全部装配进 `taker` 的 `:text`**（见 D4）。引擎侧只需把 `prompt` 槽设为纯透传 `"{{text}}"`（由 thomas-emacs 配置侧一行完成，见 D7）。`gt-chatgpt-engine` 的 `prompt` 本就支持字符串模板 + `{{text}}` 占位（F5），这是公开用法而非 hack。

> 遗留项记 `openspec/tech-debt.md`：若将来要做「流式 + 引擎级 prompt（messages 多轮）」，必须先做 `eieio clone` vs `gt-single` 缓存的行为 spike，再决定克隆策略——这正是 childframe 计划 T4/T5 的前置。

### D3 解释上下文：行矩形扩行 → 降级链

新增纯函数（可在批处理里 ERT，不依赖 C 模块）：

```elisp
(defun seshat-reader-translate--expand-rect (rects lines)
  "RECTS 为选区触达的整行矩形列表 ((x0 y0 x1 y1) …)，LINES 为上下各扩的行数。
返回扩后的单个矩形 (x0 y0 x1 y1)：横向取全部 RECTS 的并集，纵向按行高均值外扩 LINES 行。
RECTS 为空、非列表或行高无法计算（≤0）时返回 nil。")

(defun seshat-reader-translate--context-window (page-text selection max-chars)
  "在 PAGE-TEXT 中定位 SELECTION，取其前后各 half 的窗口，总长不超过 MAX-CHARS。
定位失败时取 PAGE-TEXT 前 MAX-CHARS 个字符；PAGE-TEXT 为 nil 时返回 nil。
返回值已做空白压缩（连续空白折叠为单空格、保留段落空行）。")
```

新增 IO 包装（唯一调用 C 模块的地方，全程 `condition-case`，失败静默返回 nil）：

```elisp
(defun seshat-reader-translate--context-text ()
  "返回选区所在页的上下文文本（供解释 prompt 使用），失败返回 nil。
步骤：① `seshat-reader-select-last' 的 `:page`（**1-based**）与 `:rect` → **必须先 `(1- page)` 转 0-based**（`--lines-in-rect` / `--text-in-rect` 的 page 参数是 0-based，见 `render-core.c` 的 `prepare_rect_query`）→ `--lines-in-rect` 取触达行；
② `--expand-rect' 按 `seshat-reader-translate-context-lines' 外扩；
③ `--text-in-rect' 取该矩形文本，剔除选区原文后交 `--context-window' 截断；
④ 任一步失败（无模块 / 无选区 / 空结果）→ 降级 `--page-text`（**同样必须传 0-based page**；省略参数时的「当前页」语义依赖 selected window，批处理下不可靠，故显式传 `(1- page)`）+ `--context-window`；
⑤ 仍失败返回 nil（不报错、不阻塞）。")
```

新增 defcustom：

| 变量 | 默认 | 说明 |
|---|---|---|
| `seshat-reader-translate-context-enabled` | `t` | 解释时是否注入上下文；`nil` 时 `--context-text` 直接返回 nil |
| `seshat-reader-translate-context-lines` | `2` | 选区上下各扩的行数 |
| `seshat-reader-translate-context-max-chars` | `1200` | 上下文文本上限字符数 |

### D4 解释 prompt：模板 + 装配进 taker text

新增 defcustom（默认值即产品级 prompt；`nil` 表示不装配、沿用预设引擎自带 prompt —— 旧行为可回退）：

```elisp
(defcustom seshat-reader-translate-explain-prompt
  "## 任务

解释下文「需要解释的原文」，读者是一位正在读专业书的中文读者。不要翻译，不要复述原文。

## 要求

1. 首行用一句话概括这段在说什么（≤30 字，加粗）。
2. 随后用 2-4 个要点展开：关键概念/术语的准确含义、它在本文语境中的作用、读者容易误解的地方。
3. 术语首次出现时给出「英文原词（中文释义）」。
4. 若原文含代词指代、代码、公式，明确指出它指代/对应什么。
5. 全文不超过 200 字；信息不足时直说「仅凭本段无法确定」，不要编造。
6. 输出 Markdown，不要用代码围栏包裹整段。

## 上下文（仅供理解，不要解释）

{{context}}

## 需要解释的原文

{{text}}
"
  "解释 prompt 模板；nil 表示不装配（沿用预设引擎自带的 prompt）。
占位符：{{text}} 选区原文、{{context}} 上下文（可能为空行）、{{doc}} 文档名（无则替换为「未知文档」）、{{lang}} 目标语言。

**每个标题行后必须有一个空行**：thomas-emacs 的 `gt-source-text-transformer`（`+thomas/normalize-soft-wraps`）只在空行处分段；`## ` / `1. ` / `- ` 开头的行虽被当作「保护行」，但保护行只保留**自身之前**的换行，紧随其后的普通正文行会被并入它（实测规则，见 H2）。标题后留空行即可让标题与正文分属不同段落。"
  :type '(choice (const :tag "不装配（沿用预设 prompt）" nil) string)
  :group 'seshat-reader-translate)
```

装配纯函数：

```elisp
(defun seshat-reader-translate--explain-request-text (text context title)
  "把 TEXT / CONTEXT / TITLE 装配成送引擎的完整 prompt 文本。
`seshat-reader-translate-explain-prompt' 为 nil 时原样返回 TEXT（不装配）。
用 `format-spec' 填充 {{text}} {{context}} {{doc}} {{lang}} 之外的 `%' 不解析；模板非法时 message 警告并原样返回 TEXT。")
```

接线（`seshat-reader-translate-explain-selection` 内）：

1. `(seshat-reader-translate--selection-text)` 取纯选区（用于面板 `%q` 引用块与 `last-result` 语义，不变）。
2. `(seshat-reader-translate--context-text)` 取上下文（受 `context-enabled` 控制）。
3. `(seshat-reader-translate--explain-request-text selection context title)` 得 request-text。
4. `--translator` 新增**可选第 5 参 request-text**：`(preset text langs &optional context request-text)`。契约**唯一**：`request-text` 是**已装配好的字符串**（由调用方算好），`--translator` 只做 `(oset trans taker (gt-taker :text (or request-text text) :pick nil :langs langs))`，自身不读选区、不调 C 模块、不装配模板。翻译路径不传第 5 参（`request-text` 为 nil → 用 `text`）。既有测试里 `--translator` 全是 **3 参**调用、命令代码是 4 参，均不受影响。

约束：
- 面板 `%q` 原文引用块仍取**纯选区**（`--selection-source-text`），不显示上下文与 prompt。
- `seshat-reader-translate-last-result` 仍记录模型输出（`--record-result`），语义不变。
- 解释面板模板 `seshat-reader-translate-explain-template` 不变。

### D5 长度护栏与输出净化

| 变量/函数 | 默认 | 说明 |
|---|---|---|
| `seshat-reader-translate-explain-max-chars` | `2000` | 解释输入里**选区原文**的字符上限；超限时截断并在文本尾部加「（以下为节选）」 |
| `seshat-reader-translate-strip-chatter` | `t` | 是否净化模型输出的寒暄前缀 |
| `seshat-reader-translate--strip-chatter (text)` | — | 纯函数：仅当首行匹配 `\\(好的\\|以下是\\|下面\\|这段\\|该段\\)` 且以 `\\c`（冒号）结尾时，删掉该行与前导空行；其余原样返回。有开关，避免误删正文 |

净化在 `--record-result` 之前统一执行，因此**对翻译与解释、面板与 posframe 四条组合都生效**（不只解释）；开关 `seshat-reader-translate-strip-chatter` 默认 `t`，设为 nil 即恢复「原样输出」。

### D6 可观测

解释失败（`condition-case` 的 `error` 分支）的 `message` 追加引擎信息：从 translator 的首个引擎读 `host` / `model` 槽（`slot-exists-p` 守卫，读不到就省略），**绝不输出 key**。形如：

`Seshat Reader translate: 解释失败（deepseek-chat @ api.deepseek.com）：<原因>`

### D7 thomas-emacs 配置侧（key 与预设隔离）

`/home/thomas/thomas-emacs/lisp/init-tools.el` 的 `use-package gt :config` 内：

1. `reader` / `reader-explain` 两个 `push` 的目标从 `gt-preset-translators` 改为 `seshat-reader-translate-presets`（用 `with-eval-after-load 'seshat-reader-translate` 包裹，或先 `(require 'seshat-reader-translate nil t)` 再 `push`；二者取能保证变量已定义的写法）。
2. `reader-explain` 的 engine `:prompt` 改为 `"{{text}}"`（纯透传，D2/D4 的约定）；删除原来的中文长 prompt 字符串，`:root` 保留（system prompt）。
3. 删除 `(setq gt-chatgpt-key (or gt-chatgpt-key (getenv "DEEPSEEK_API_KEY")))`。
4. 新增 DeepSeek key 的引擎子类（Q3 选项 ①）：

```elisp
;; HACK: gt 的 `gt-resolve-key' 解析链固定为 authinfo → `gt-chatgpt-key' → OPENAI_API_KEY。
;; 为让 seshat 的 DeepSeek 引擎独立取 key、且不改全局 `gt-chatgpt-key'，用子类 + cl-defmethod 分流。
(defclass thomas-seshat-chatgpt-engine (gt-chatgpt-engine) ())
(cl-defmethod gt-resolve-key ((engine thomas-seshat-chatgpt-engine))
  (or (getenv "DEEPSEEK_API_KEY")
      (cl-call-next-method)))
```

并把 `reader-explain` 的 engine 换成 `(thomas-seshat-chatgpt-engine :host … :path … :model … :root …)`。若 `seshat-reader-translate-presets` 用 thunk 形式，把 `defclass` 放进 thunk 内也无妨（保持懒加载）。

5. `test/init-smoke-test.el` 新增两条**文件级机械断言**（放在现有 seshat 相关断言附近；沿用该文件既有「读文件文本 + 搜索」风格）：
   - 正向：`init-tools.el` 文本含 `seshat-reader-translate-presets`（预设已迁到 seshat 自有表）。
   - 反向：`init-tools.el` 文本不含 `(setq gt-chatgpt-key`。
   - 「reader 预设不再进 `gt-preset-translators`」**不用脆弱的跨行正则做文件断言**，改由下一条的 verify 实例运行时断言承担。

## 假设与验证点

| # | 假设 | 来源 | 验证方式 | 不成立时的降级 |
|---|---|---|---|---|
| H1 | 不改引擎槽即可满足解释 prompt 需求（prompt 装配进 taker text） | 事实✓（F5 + D2 三理由） | T3 单测断言 `taker` 的 `:text` 等于装配串；L3 目视解释质量 | 若模型仍表现「像翻译」，优先调 prompt 模板（数据层面，不动代码） |
| H2 | 装配串在 `+thomas/normalize-soft-wraps` 后结构保持：**分段靠空行**（保护行只保留自身之前的换行，紧随其后的普通正文行会被并入该保护行） | 事实✓（`split-string "\n[ \t]*\n+"` 分段 + 保护行正则 `^\\(#\\|[-*+•◦▪] \\|1\\. \\)`） | T3 单测断言「默认模板每个 `## ` 标题行后紧跟空行」+ L3 在 verify 实例用真实 `+thomas/normalize-soft-wraps` 归一化装配串后目视 | 仍被合并时：每行加两个行尾空格（Markdown 硬换行），或全 `- ` 保护行写法 |
| H3 | `--lines-in-rect` 返回的整行矩形可按行高均值外扩，得到有意义的上下文 | 假设? | T2 用桩数据单测 `--expand-rect`；L3 在 `d2l-zh-pytorch.pdf` 上目视上下文文本质量 | 关闭 `seshat-reader-translate-context-enabled`，或只走 `--page-text` 降级路径 |
| H4 | `cl-defmethod gt-resolve-key` 对子类实例分派，`(getenv "DEEPSEEK_API_KEY")` 生效 | 事实✓（CLOS 分派语义） | T5 在 `verify` 实例里 `(gt-resolve-key (make-instance 'thomas-seshat-chatgpt-engine …))` 断言非 nil（**不回显 key 值**，只断言 `stringp` 且长度>0） | 改走 authinfo（`apikey@api.deepseek.com`），计划追加一条任务 |
| H5 | 面板 `%q` 用纯选区、`last-result` 用模型输出的既有语义不被 D4 破坏 | 事实✓（代码路径未变） | T3 单测断言面板内容含纯选区、不含 prompt 指令行 | — |
| H6 | 既有 `gt-preset-translators` 相关测试在查表顺序变更后仍全绿 | 假设? | T1 跑 `seshat-reader-translate-test.el` 全文件（数量以 T0 基线为准） | 若失败，调整回落顺序为「全局优先」（但须在 decisions.md 记原因） |

## 任务

### T0 安全点与基线（依赖：无）

- 两仓 `git status` 各自确认干净（seshat 在 `master`，thomas-emacs 在 `develop`）。有未提交改动 → 报告 harspower，**不自行提交**。
- seshat 建 tag：`git tag pre-translate-preset-isolation`。
- 基线：按 `docs/emacs-reader.md` §「构建与测试」逐文件跑 ERT，记录 `seshat-reader-translate-test.el` 的用例数与全仓总数到 `/tmp/baseline-ert-translate.txt`（前置：`make -C emacs/seshat-reader all` 已成功，`.so` 存在）。
- 验收：tag 存在；基线数字被记录；两仓 git 状态如实报告。
- **实测结果（2026-10-25）**：`make -C emacs/seshat-reader all` exit 0、警告 33 条（`seshat-reader-translate.el` 0 条）；`seshat-reader-translate-test.el` **74 passed**；全仓 **25 文件 / 849 passed / 0 unexpected / 0 skipped**（重打 tag 前为 24 文件 / 839 passed）；逐文件日志 `/tmp/baseline-ert-final.txt`（1134 行）+ `/tmp/ert-final/*.log`。tag 已重打到 `8fdf434`（当前 HEAD；原 `8d43480`）。

### T1 seshat：预设表 + 查表顺序 + thunk（依赖：T0）

- 文件：`emacs/seshat-reader/seshat-reader-translate.el`
- 新增 `seshat-reader-translate-presets`（D1）与 `seshat-reader-translate--preset-translator`；`--translator` 改用该函数。
- 验收：ERT ≥5 例——① seshat 表命中优先于全局表（两表同名不同引擎，断言取到 seshat 的）；② seshat 表未命中回落全局表；③ 值是 thunk 时被调用且返回的 translator 被使用；④ 两表都未命中 → 回退内置 youdao/google（已有用例保持通过）；⑤ 值是 thunk 但返回 nil 时不崩溃、走回退。

### T2 seshat：上下文纯函数 + IO 包装（依赖：T1）

- 文件：同上
- 新增 `seshat-reader-translate--expand-rect`、`--context-window`、`--context-text` 与三个 defcustom（D3）。
- 验收：ERT ≥8 例——`--expand-rect`：空 rects→nil、单行矩形扩 2 行、多行矩形取横向并集 + 纵向按行高均值外扩、行高为 0→nil；`--context-window`：能定位选区时前后各半且总长 ≤max、定位不到取前缀、page-text 为 nil→nil、空白压缩正确；`--context-text`：`context-enabled` 为 nil→nil（用 `cl-letf` 桩替 `seshat-reader-dyn--lines-in-rect` / `seshat-reader-dyn--text-in-rect` / `seshat-reader-dyn--page-text` 三个模块函数并断言零调用）、三个模块函数都不可用（桩成抛错函数）时静默返回 nil（验证 `condition-case` 兜住）、**page 基数正确**（选区 `:page` 为 1 时，三个模块函数收到的 page 参数必须是 0）。

### T3 seshat：prompt 装配 + explain 接线（依赖：T2）

- 文件：同上
- 新增 `seshat-reader-translate-explain-prompt`（默认值见 D4）、`--explain-request-text`；`--translator` 增可选第 5 参 **`request-text`**（已装配好的字符串，契约唯一，见 D4，无 plist 形式）；`seshat-reader-translate-explain-selection` 按 D4 步骤接线。
- 验收：ERT ≥6 例——① 模板为 nil 时 request-text 就是纯选区；② 模板非 nil 时装配串含选区、上下文、文档名，且 `{{text}}` 只出现一次；默认模板满足「每个 `## ` 标题行后紧跟空行」（`(string-match-p "## 任务\n\n" assembled)` 非 nil，其余标题同理）；③ 模板非法（未知占位符）时 message 警告并回退纯选区；④ 传第 5 参 request-text 时 taker `:text` 恰为该字符串；不传时 taker `:text` 为纯选区（回归）；⑤ 翻译路径不传第 5 参时行为与现状逐字一致（回归）；⑥ 面板 `%q` 仍取纯选区（断言 `--quote-block` 输出不含 prompt 指令行）。

### T4 seshat：长度护栏 + 输出净化 + 可观测（依赖：T3）

- 文件：同上
- 新增 `seshat-reader-translate-explain-max-chars`、`seshat-reader-translate-strip-chatter`、`--strip-chatter`；在 `--record-result` 之前接入净化；`explain` 的 error 分支 message 追加 host/model。
- 验收：ERT ≥6 例——① 超长选区被截断且带「（以下为节选）」；② 未超长不截断；③ `--strip-chatter` 删「好的，以下是…：」首行；④ 非寒暄首行原样返回；⑤ 开关为 nil 时不净化；⑥ error message 不含 key（用桩 engine 的 key 槽放哨兵字符串，断言 message 不含该哨兵）。

### T5 thomas-emacs：配置迁移 + 冒烟不变量（依赖：T3）

- 文件：`/home/thomas/thomas-emacs/lisp/init-tools.el`、`/home/thomas/thomas-emacs/test/init-smoke-test.el`
- 按 D7 全部 5 项改动。另在 `/home/thomas/thomas-emacs/openspec/active/2026-10-25-seshat-gt-preset-isolation.md` 建**指针文件**（≤25 行：指向 seshat 主计划路径、本仓改动清单、验收方式）。
- 验证：`verify` 实例（`elisp_mcp_set_task verify`）里按 H4 断言子类取到 key（只断言类型与长度，**不回显值**）；`emacs --batch` 跑 `test/init-smoke-test.el` 全绿；收尾 `set_task auto` → `instance(stop, verify)` → `instance_status` 确认。
- 验收（**以 `verify` 实例运行时断言为主**，比文件文本断言可靠）：在该实例里 `(require 'seshat-reader-translate)` + `(require 'gt)` 后断言 ① `(assq 'reader gt-preset-translators)` 与 `(assq 'reader-explain gt-preset-translators)` 均为 nil；② `(assq 'reader seshat-reader-translate-presets)` 与 `(assq 'reader-explain seshat-reader-translate-presets)` 均非 nil；③ `(gt-resolve-key <reader-explain 预设的引擎>)` 是长度 > 0 的字符串（**只断言类型与长度，禁止回显值**）；④ 冒烟测试新增的两条文件级断言通过；⑤ thomas-emacs 指针文件存在。

### T6 验证、文档与归档（依赖：T0–T5）

- L1：`make -C emacs/seshat-reader all`（**实测只含** `.so` + autoloads + `.elc` + checkdoc，**不含 check-parens**），另需单独对改动文件跑 `check-parens`；警告集与基线（**33 条**）逐条 diff，不得新增；thomas-emacs 侧按该仓既有入口（Makefile / 字节编译）验证。
- L2：seshat 全仓 **25 个**测试文件逐文件 ERT，0 unexpected / 0 skipped，总数 ≥ **874**（本次实测基线 **849**；`docs/emacs-reader.md` 的「23 文件 / 773 例」已过时）；thomas-emacs 冒烟全绿。
- L3（`verify` 实例 + **GUI frame**：daemon 的 selected-frame 是 terminal frame，须显式 `(make-frame '((window-system . pgtk)))`）：
  1. 打开 `d2l-zh-pytorch.pdf`，拖选一段 → `C-c C-e`：面板出现解释，首行是加粗一句话，含 2–4 要点，长度 ≤200 字量级。
  2. 解释的输入含上下文（用 `gt-debug-p` 或桩引擎捕获 request-text 目视核对），且上下文来自同页邻近文本而非整页复制。
  3. `C-c C-t` 翻译行为与改动前一致（面板显示纯译文，无 prompt 指令泄漏）。
  4. 打开 `《新赤脚医生手册》 .pdf`（含中文）解释中文选区，输出仍是中文解释。
  5. gt 侧未受影响：`M-x gt-translate` 的预设列表**不含** `reader` / `reader-explain`；`(bound-and-true-p gt-chatgpt-key)` 不是 DeepSeek key（只断言非等于哨兵，不回显）。
  6. 扫描件/无文本层页面选区为空时解释走既有 `user-error` 提示（不崩、不挂）。
- 文档：见「文档清单」，逐项落地并输出同步报告。
- 归档：勾选任务 → 计划移入 `openspec/completed/`；thomas-emacs 指针文件同步归档/删除。

## 文档清单

| 文档 | 更新内容 |
|---|---|
| `emacs/seshat-reader/seshat-reader-translate.el` Commentary | 预设查表顺序（自有表优先）、解释 prompt 装配与上下文来源、引擎零改动原则（含 F3 原因） |
| `docs/configuration.md` | 新增 defcustom 全量：`seshat-reader-translate-presets` / `-explain-prompt` / `-explain-max-chars` / `-context-enabled` / `-context-lines` / `-context-max-chars` / `-strip-chatter`；并在「阅读器翻译 / 解释（go-translate 预设）」节改写「预设需在配置侧定义」的说明（改为「推荐放 `seshat-reader-translate-presets`，不污染 gt 全局表」） |
| `docs/llm.md` | 「引擎」段改写：解释 prompt 由 seshat 装配（含上下文），预设的 engine `:prompt` 应为 `"{{text}}"` 透传；key 由引擎子类取自 `DEEPSEEK_API_KEY`（不再设 `gt-chatgpt-key`）；补上下文与长度护栏说明。**同时改写「隐私提示」段**：解释时发送到引擎的数据从「仅选区」扩大为「选区 + 同页邻近上下文」，需明确写出 |
| `docs/emacs-reader.md` | 键位表附近补一句：解释带上下文、prompt 可自定义 |
| `CHANGELOG.md`（seshat） | 新增：解释带上下文 + 结构化 prompt + 长度护栏 + 输出净化 + 预设隔离；破坏性：`seshat-reader-translate-presets` 新变量（旧配置仍可用，回落 gt 全局表） |
| `CHANGELOG.md`（thomas-emacs） | 改：reader/reader-explain 预设迁出 gt 全局表；不再设 `gt-chatgpt-key`；新增 DeepSeek 引擎子类 |
| `openspec/decisions.md`（seshat） | 四条决策：① 预设归属改为 seshat 自有表；② **不克隆引擎**（gt-single 单例风险，选 taker-text 装配 prompt）；③ 解释上下文取行矩形扩行的理由与降级链；④ **与 childframe 计划的接口承接**：childframe T4/T5 在本计划版本上继续改 `--translator`，其首轮 user message 复用本计划的 `--explain-request-text` 产物，且必须先把「`eieio clone` vs `gt-single` 缓存」spike 作为其前置 |
| `openspec/tech-debt.md`（seshat） | 残余项：`eieio clone` vs `gt-single` 缓存未验证（**childframe 计划 T4/T5 的前置 spike**）；`--page-text` 与 `--text-in-rect` 的软换行粘连（依赖 active 计划 `2026-10-25-pdf-text-line-separators`）；解释不显示上下文（可选开关未做）；引擎级 prompt（messages 多轮）未做（本计划用 taker-text 装配规避） |
| `emacs/seshat-reader/VENDORED.md` | 记录 `seshat-reader-translate.el` 的改动边界（仅 translate 模块，不涉 C/select/sidebar） |
| thomas-emacs `AGENTS.md` | 若形成新不变量（「seshat 专用 gt 预设不得进 `gt-preset-translators`」「不得改 `gt-chatgpt-key`」）则登记并附机械检查说明（对应 T5 的两条冒烟断言） |

## 验证标准

- **L1**：`make -C emacs/seshat-reader all` 通过（`.so` + autoloads + `.elc` + checkdoc）；**另单独**对改动文件跑 `check-parens`（`make all` 不含该步）判 0 错；byte-compile 警告集与基线（33 条）逐条 diff 无新增；thomas-emacs 侧字节编译无新警告。
- **L2**：seshat 全仓 25 个测试文件逐文件 ERT，0 unexpected / 0 skipped，总数 ≥ **874**（实测基线 849，其中 `seshat-reader-translate-test.el` 74 例）；thomas-emacs 冒烟全绿。
- **L3**：上节 6 项全部通过；其中第 5 项（gt 侧预设列表干净、key 未被接管）为**阻断性不变量**，不通过即视为任务失败并回滚。
- **回归**：`seshat-reader-translate-render` 取 `pop` / `pin` 两条 posframe 路径的既有 ERT 全绿；`seshat-reader-translate-preset` 回退路径（预设缺失 → youdao/google）行为不变。

## 注意事项

- **不要改 `--render-object` 与渲染分支**：childframe 计划的 T4/T5 会在那里加流式与骨架；本计划只碰 `--translator`、新增纯函数与 explain 命令层。
- **`--translator` 签名只允许加可选第 5 参**，不得重排或重命名既有参数（既有测试为 3 参调用、命令层为 4 参调用、docstring 中含示例）。
- **上下文获取必须在 `condition-case` 内且不得 `message` 报错**：无 C 模块（批处理 / 未构建 `.so`）是常态，静默降级。
- **不得回显 key**：任何 message / 测试断言都只判类型与长度，禁止把 `DEEPSEEK_API_KEY` 的值打进日志或报告（见 `rules/secrets-protection.md`）。
- **测试逐文件运行**：一次 `emacs --batch` 加载全部测试文件会因 `etaf-ui` 可用性差异导致既有 3 例失败（既有基线特性）。
- **ERT 前必须清字节码**：`rm -f emacs/seshat-reader/*.elc`（实测陷阱：`.el` 比 `.elc` 新时 Emacs 默认 `load-prefer-newer=nil` 会加载旧 `.elc`，测到的是旧代码）。
- **thomas-emacs 的 `defclass` 必须懒加载**：放在 thunk 或 `with-eval-after-load 'gt` 内，避免配置启动时报 `gt-chatgpt-engine is void`。
- **HACK 注释规范**：`cl-defmethod gt-resolve-key` 的覆写必须带 `;; HACK: <改了什么 + 为什么>`。

## 风险与降级

| 风险 | 触发判据 | 降级动作 |
|---|---|---|
| 上下文提取质量差（H3 失败） | L3 第 2 项目视发现上下文是整页噪声或空 | `seshat-reader-translate-context-enabled` 设 nil（只解释选区），记 tech-debt 待 C 层行边界计划落地后重试 |
| prompt 装配被 normalizer 合并（H2 失败） | L3 第 2 项目视发现指令行粘连 | 把模板改成「每行以 `- ` 开头」的全保护行写法（纯数据改动） |
| 解释仍像翻译（H1 部分失败） | L3 第 1 项目视 | 调 prompt 模板措辞（defcustom 层）；`seshat-reader-translate-explain-max-chars` 收紧到 800 抑制长篇复述 |
| 子类 key 不生效（H4 失败） | T5 断言失败 | 回退 authinfo 方案（`machine api.deepseek.com login apikey password …`），追加一条任务并改 decisions.md |
| 既有测试回归（H6 失败） | T1 全文件 ERT 失败 | 回落顺序改为「全局优先」（`gt-preset-translators` 先查），并记 decisions.md 说明与后续清理计划 |
| 并发写者已在 `translate.el` 实现流式/追问（`8d43480`） | 本计划 T1/T3 改动 `--translator` 与其代码重叠 | 只做**追加式**改动（加可选第 5 参、改查表那一行），不重排/删除其逻辑；若冲突则保留其流式与追问分支后再合并 |
