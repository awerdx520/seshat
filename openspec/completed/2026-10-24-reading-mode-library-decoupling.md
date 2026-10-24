# Emacs 阅读模式：阅读能力与库身份解耦（`seshat-reading-mode` + 显式入库）

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成并归档（2026-10-24）**
- 已确认：方案 ✅（用户 2026-10-24）；两个决策 ✅（入库=复制上传保留原件、新 mode=派生 major mode）
- 执行结果：T1–T5 全部完成；新增 `emacs/seshat-reading.el` + `emacs/tests/seshat-reading-test.el`，改动 reader 三文件（3 处 `eq` 改 `derived-mode-p`、`--doc-id` 增 QUIET 参数与 6 处调用点）；全仓 ERT 637 → **669**（19 个文件，0 unexpected / 0 skipped）
- 审查记录：两轮 plan-reviewer——首轮判「有条件通过」，3 个 major 已修（`auto-mode-alist` 加载顺序、入库 base-blob 取复制后目标文件、**H4 被推翻**：库外文档本就不支持批注，计划目标相应降级）；二轮补 4 处收口（四态、`broken` 优先级、pattern 文本一致性、假设复核回填）
- 下一步：L3 真机 5 项待人工验收；「库外批注 + 入库迁移」与「原件/副本双份」已记 tech-debt

## 目标

1. 新增 **`seshat-reading-mode`**（`define-derived-mode` 自 `seshat-reader-mode`），作为 Seshat 阅读场景的入口；渲染/翻页/目录/缩放**全部复用** `seshat-reader-mode`，不复制任何渲染逻辑。
2. 同一套能力可作 **Emacs 通用阅读器**：`find-file` 打开 PDF/EPUB 进入 `seshat-reading-mode`（本 mode 接管 `auto-mode-alist`，见 D1），渲染 100% 来自 reader；文件不在任何库根下时显示 `[库外]`，完全无库、无网络、无警告。
3. **入库是显式动作**：`seshat-library-add` 把库外文件复制到 `mirror` 根并上传登记；通用打开的库外书籍**不会**自动入库。
4. 未入库文档**不再每次 `message` 刷警告**，改为 mode-line 标识。**库外文件的批注能力不在本计划范围**：`seshat-reader-annotation--uid`（`seshat-reader-annotation.el:178-181`）对不在根下的文件抛 `user-error`，实现「库外本地批注 + 入库后迁移」需要新的本地存储与迁移语义，记入 `tech-debt.md` 作为后续增强。本计划不改变批注能否创建的行为，只去掉「派生 doc-id 时反复警告」的噪声。

## 根本问题

「阅读」与「库身份」当前由文件位置**隐式**耦合，造成三处失真：

| # | 现状 | 失真 |
|---|---|---|
| 1 | 能否同步取决于文件是否在 `seshat-reader-annotation-roots` 命中的目录下（`seshat-reader-annotation.el:150` 的 `--doc-id`） | 用户无法「把库外的书加进来」，只能手工 `mv` 进根目录再等引擎处理 |
| 2 | 库外文件每次派生 doc-id 都 `message` 「降级为 local:」警告（`:155`） | 把 reader 当通用阅读器用时会刷警告，通用体验被污染 |
| 3 | 没有「当前文档是否在库」的可视表达 | 用户看不出这本批注会不会同步、进度会不会上传 |

## 事实清单

| # | 事实 | 证据 |
|---|---|---|
| F1 | `seshat-reader-mode` 是 `define-derived-mode ... special-mode`，渲染/翻页/目录/缩放全由本地 C 模块提供，**不依赖服务端** | `seshat-reader.el:1734` |
| F2 | 父 mode 体内有 `(setq major-mode 'seshat-reader-mode)` 与 `(setq mode-name "Seshat Reader")`（`:1779-1780`），位于 `define-derived-mode` 的 `delay-mode-hooks` 期间；子 mode 随后会覆盖为自己的名字，**对派生无害** | `seshat-reader.el:1778-1781` |
| F3 | 全仓对 reader 的模式判断**绝大多数已是 `derived-mode-p`**（22 处），只有 3 处是精确 `(eq major-mode 'seshat-reader-mode)` | `seshat-reader.el:1813`、`:1820`、`seshat-reader-annotation.el:850` |
| F4 | 批注能力按需挂键：`C-c C-a` / `C-c C-l` / `C-c C-h` 绑在 `seshat-reader-mode-map` | `seshat-reader-annotation.el:1295-1299` |
| F5 | `--doc-id` 命中根 → `tag:path`；未命中 → `local:<绝对路径>` 并 `message` 警告 | `seshat-reader-annotation.el:150-170` |
| F6 | 计划 A/B 已有：`seshat-state-roots`（`(TAG DIR MODE)`）、`seshat-state-uid-for-path`、`seshat-state-set` / `-set-base-blob`；`seshat-rest-upload-file`（条件写）、`seshat-rest-resolve-uid` | `openspec/completed/2026-10-24-m8a-*.md`、`2026-10-24-m8b-*.md` |
| F7 | 入库必须上传内容：服务端是权威，文件路径必须落在某个根下（`PUT /api/files/{path}?root=`）；`ondemand` 根写请求返回 `403` | `docs/api.md` §8.2、§7 |
| F8 | `seshat-sync-roots` 是 M8-B 的根映射配置，未配置时同步明确提示并跳过 | `emacs/seshat-sync.el` 的 `--ensure-roots` |
| F9 | `auto-mode-alist` 由 `seshat-reader.el:1827-1828`（及 `seshat-reader-autoloads.el:35`）把 `seshat-reader-supported-formats` 的每个扩展名都指向 `seshat-reader-mode`；`add-to-list` 对 `auto-mode-alist` 加在**前面**，后加载者可覆盖 | `seshat-reader.el:1827-1828`、`seshat-reader-autoloads.el:35` |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| H1 | 派生 major mode 不会破坏 reader 的渲染与交互（父 mode 已 `derived-mode-p` 友好，仅 3 处需改） | 事实✓（F2、F3） |
| H2 | 通用阅读由 `seshat-reading-mode` 承担（渲染 100% 来自 `seshat-reader-mode`，无任何差异）；`seshat-reader-mode` 仍可被显式使用 | 用户显式（2026-10-24：PDF 阅读仍用 reader）＋事实✓（F9：`auto-mode-alist` 可被后加载者覆盖） |
| H3 | 入库采用「复制到根 + 上传」，本地原件保留 | 用户显式（2026-10-24） |
| H4 | 库外文件当前**不支持批注**（`--uid` 抛 `user-error`）；本计划只静音警告与展示状态，**不实现**本地批注 | 事实✓（`seshat-reader-annotation.el:178-181` 抛错、`:297` 无条件调用） |
| H5 | 库身份解析**完全零网络**（纯本地 `state` 查表）；只有用户显式 `seshat-reading-refresh` 才向服务端 `resolve-uid` 确认一次 | 用户显式（2026-10-24 修订）＋事实✓（`seshat-rest-resolve-uid` 是同步 HTTP，会阻塞「打开即阅读」） |

## 设计

### D1 新文件 `emacs/seshat-reading.el`（项目层，**不放** `emacs/seshat-reader/`）

`emacs/seshat-reader/` 是上游 reader 的 fork（VENDORED.md 有改动清单），项目级新功能一律放顶层。

```elisp
(define-derived-mode seshat-reading-mode seshat-reader-mode "Seshat Reading"
  "Seshat 阅读模式：在 seshat-reader-mode 之上叠加库身份与同步能力。")
```

- mode 体内（父 mode 完成后）：
  1. 解析库身份（D2）并存入 buffer-local `seshat-reading--state`；
  2. 设置 mode-line 标识（D3）；
  3. 未入库时把批注的降级警告静音（D4）。
- **不复制任何渲染代码**，全部继承。
- `seshat-reading-mode-hook` 供用户扩展。
- 提供 `seshat-reading-open`（interactive，读文件名后 `find-file` 并切到本 mode）作为 Seshat 侧入口；通用场景用户仍直接 `find-file`。

**`auto-mode-alist` 指向本 mode**：`seshat-reading.el` 在文件末尾用

```elisp
(dolist (pattern seshat-reader-supported-formats)
  (add-to-list 'auto-mode-alist (cons (concat "\\." pattern "\\'") #'seshat-reading-mode)))
```

把支持的全部格式指向 `seshat-reading-mode`（`add-to-list` 加在 alist 前面，`auto-mode-alist` 按顺序匹配，因此覆盖 `seshat-reader.el:1827-1828` 的默认）。这样：

- **通用场景**（文件不在任何根下）→ 进 `seshat-reading-mode`，显示 `[库外]`，零网络、无警告，行为与纯阅读器无异；
- **库内场景** → 同一 mode 显示 `[库]`，批注/进度可用；
- 入库后再打开**自动**显示 `[库]`，无需用户额外操作。

`auto-mode-alist` 的覆盖必须用 `add-to-list`（而非 `setq`），以保留用户自己对其它模式的映射；若用户显式把某扩展名改回 `seshat-reader-mode`，后加载顺序决定胜负——在 docstring 里说明。

**加载顺序必须锁定**：`auto-mode-alist` 按顺序取第一个命中，而 `seshat-reader.el:1827-1828` 与 `seshat-reader-autoloads.el:35` 各有一次 `add-to-list`（前者带 `;;;###autoload`）。因此 `seshat-reading.el` 必须：

1. 顶层 `(require 'seshat-reader)`——保证 reader 的注册已经完成（`require` 幂等，autoloads 通常更早加载，之后不会再重复 `add-to-list`）；
2. 注册时**先清除**同扩展名的既有 `seshat-reader-mode` 项，再前插 `seshat-reading-mode`（例如对每个 pattern 用 `assoc-delete-all` 或过滤 `auto-mode-alist`）；
3. 若不在第 1 步 `require`，reader 的 lazy-load 可能在之后前插 `seshat-reader-mode` 反超，导致「第一个 PDF 进 reading、之后进 reader」的不确定行为。

T2 必须有一例用例覆盖「reader 之后再注册仍被覆盖」。

**pattern 文本必须与 reader 逐字一致**：`assoc-delete-all` 按 key 的 `equal` 匹配，若本 mode 用 `"\\.pdf\\'"` 而 reader 实际写的是别的等价正则，删除会漏掉、前插后仍会重复。实现时**不要重新拼 pattern**，而是从 `auto-mode-alist` 里筛出 `(cdr . seshat-reader-mode)` 的项、取其 `car` 原样复用后再替换 cdr（这样即使 reader 改了拼法也自动跟随）。T2 的「无重复项」断言用于兜住这类偏差。

### D2 库身份解析（四态，**零网络**）

```elisp
(defun seshat-reading--resolve (file) ...)
;; 返回 plist (:state library|unregistered|external :uid UID :root TAG :rel PATH)
```

规则（顺序固定，**全部只读本地状态，不发任何 HTTP 请求**）：

1. `file` 不在任何 `(seshat-state-roots)` 的 `DIR` 下 → `:state external`；
2. 在某个根下且 `(seshat-state-uid-for-path TAG REL)` 命中 → `:state library`；
3. 在根下但 state 无记录 → `:state unregistered`。
4. 状态库不可用（`seshat-state-roots` 为空**且**状态文件曾走「损坏 → 备份为空」路径）→ `:state broken`，mode-line 显示 `[状态异常]`。区分方法：`seshat-state-load` 的损坏路径会 `warn` 并返回空状态——`--resolve` 需要在加载后读一个标志（若 `seshat-state.el` 未暴露这样的标志，本计划允许在 `seshat-reading.el` 侧通过「roots 为空 + 之前是否调用过 load」启发式判断，并在 docstring 注明这是启发式）。

**为什么零网络**：这个函数在 mode 体里执行（每次打开文件都会跑）。`seshat-rest-resolve-uid` 是**同步** HTTP，服务端不可达时会阻塞若干秒，直接毁掉「打开即阅读」的体验；而「未入库」与「服务端其实有但本地 state 没记」在用户视角下都需要**显式**动作才能改变。

需要向服务端确认时，由显式命令 `seshat-reading-refresh`（interactive）触发一次 `seshat-rest-resolve-uid`：成功 → 登记 uid 进 state + 状态转 `library`；失败 → 保持 `unregistered` 并 `message` 说明（这条路是用户主动触发的，允许提示与等待）。

**`broken` 的判定优先级最高**：它在 `--resolve` 的 `condition-case` 兜底**之前**先判——否则「状态文件损坏 → roots 为空 → 规则 1 命中 → `external`」会把状态异常静默显示成 `[库外]`，用户永远看不到「该修状态文件」的信号。顺序：先判状态可用性（`broken`）→ 再判是否命中根（`external`）→ 再判 uid（`library` / `unregistered`）。

### D3 mode-line 标识

在 `mode-line-process` 或 `mode-line-misc-info` 追加：

| 状态 | 展示 |
|---|---|
| `library` | ` [库]` |
| `unregistered` | ` [未入库]` |
| `external` | ` [库外]` |
| `broken` | ` [状态异常]` |

**不得**用 `message` 播报（通用阅读时不能刷屏）。

`unregistered` 状态下，`seshat-reading-mode` 的 `mode-line` 或一次性的 `message`（仅首次打开该文件时，用 buffer-local 标记避免重复）提示「可 `M-x seshat-reading-refresh` 向服务端确认，或 `M-x seshat-library-add` 入库」——**不得**在 `external` 状态提示任何与库有关的内容。

### D4 未入库时不再刷警告（**不改变批注能力**）

- 现状两条事实：① `--doc-id`（`seshat-reader-annotation.el:150`）在降级为 `local:` 时 `message` 警告（`:155`）；② 真正创建批注时 `--uid`（`:178-181`）对库外文件抛 `user-error`——**库外文件本来就不能批注**。
- 本计划只处理 ①：
  - 给 `--doc-id` 增加可选参数 `QUIET`（默认 nil，保持既有行为）；已有 `--quiet-doc-id`（`:607`，用 `inhibit-message`）可直接复用为 QUIET=t 的实现路径；
  - `seshat-reading-mode` 的**展示路径**（mode-line 身份解析）走 QUIET 版本；
  - **不修改** `--uid` 的 `user-error`：库外文件创建批注仍会明确报错，这是正确的用户提示。
- **必须穷举 `--doc-id` 的调用点并说明各自的 buffer 语境**（`annotation.el:293`、`:1289`、`reference.el:201`、`:218`、`:407`、`:511`、`translate.el:785`）——只有 `translate.el:785`（`translate-save-as-annotation`，可在翻译面板 buffer 触发）位于 reader buffer 之外，因此**不得**用 buffer-local 开关，必须用参数传递。
- 库外本地批注能力（含入库后的批注迁移）记入 tech-debt，不在本计划。

### D5 入库命令 `seshat-library-add`（interactive）

```text
1. 取当前 buffer 的文件；不在 `seshat-reading-mode` 或已是 library 状态 → user-error
2. 目标根 = `(seshat-state-roots)` 里 MODE 为 "mirror" 的根；多个则 completing-read
3. 目标相对路径 = `(read-string "库内路径" (file-name-nondirectory file))`，默认同名
4. （可选）让用户确认「复制到 <根>/<rel> 并上传」——用 `y-or-n-p`，这是**交互命令**，允许询问
5. 复制文件到 `(expand-file-name rel ROOT-DIR)`（父目录 `make-directory` 递归；已存在则询问是否覆盖）
6. `(seshat-rest-upload-file rel 内容 :root TAG :if-none-match "*")`
   - 2xx → `(seshat-state-set uid (list :root TAG :path rel))` + `(seshat-state-set-base-blob uid (plist-get resp :etag) size mtime)`——**`size` 与 `mtime` 必须取自复制后的目标文件**：`size` = `(nth 7 (file-attributes TARGET))`、`mtime` = `(truncate (float-time (nth 5 (file-attributes TARGET))))`。**不得**用原文件属性：`copy-file` 默认不保留 mtime，基线取错会让下一轮 `seshat-sync-detect-renames` 立即把该文件判为「本地已修改」并重复推送。 + `(seshat-state-save)` → 重新解析 → mode-line 变 `[库]` → `message` 成功（含 uid 与目标路径）
   - `412`（同名已存在）→ 询问是否改用 `:if-match` 覆盖（带远端 etag）；用户拒绝则中止
   - `403`（只读根）→ `user-error`（不该出现在 mirror 根）
   - 其它 → `user-error` 附状态码
7. 失败时**不得**留下半成品：复制目标若已写入且上传失败，询问是否删除副本（默认保留并提示路径）
```

### D6 3 处精确 `eq major-mode` 改 `derived-mode-p`

| 位置 | 改动 |
|---|---|
| `seshat-reader.el:1813`（`seshat-reader-dark-mode`） | `(eq major-mode 'seshat-reader-mode)` → `(derived-mode-p 'seshat-reader-mode)` |
| `seshat-reader.el:1820`（`seshat-reader-presentation-mode`） | 同上 |
| `seshat-reader-annotation.el:850`（高亮源校验） | 同上 |

**向后兼容**：`derived-mode-p` 对 `seshat-reader-mode` 自身仍返回 t，既有行为零变化。

### D7 边界（硬约束）

- **渲染 100% 来自 `seshat-reader-mode`**：`seshat-reading-mode` 不复制任何渲染/翻页/目录代码，也不直接调用 C 模块函数；
- 通用场景**零网络**：`external` 与 `unregistered` 状态都不发请求（只有显式 `seshat-reading-refresh` 会问服务端）；
- 加载即接管 `auto-mode-alist`，因此 mode 体必须极轻：**首次调用会触发一次 `seshat-state-load`（磁盘读，通常几十 ms 内）**，此后全部是 O(1) 内存查表；**不得**在该路径做任何网络请求
- 鉴于此，`seshat-reading--resolve` 若抛错必须**降级为 `external`** 而不是让打开文件失败（`condition-case` 兜底 + `display-warning` 一次）；
- 不新增键位到 `seshat-reader-mode-map`；`seshat-reading-mode-map` 只放本 mode 特有命令（`seshat-library-add` / `seshat-reading-refresh`）。

## 已知取舍

1. **入库复制而非移动**（用户 2026-10-24 决定）：本地会同时存在原件与库内副本，用户需自行管理原件；代价换来「不动用户文件布局」。
2. **不做「未入库文档的批注迁移」**：若用户在未入库状态下写了本地批注（`local:`），入库后这些批注仍挂在 `local:` doc-id 上，不会自动迁到 uid。属后续增强（需重写批注的 document-id 并重新上传）。
3. **`auto-mode-alist` 被本 mode 接管**：`seshat-reading.el` 一旦加载，所有受支持格式默认进 `seshat-reading-mode` 而非 `seshat-reader-mode`。这是「入库后自动显示库状态」的代价——若用户或第三方包依赖 `(eq major-mode 'seshat-reader-mode)` 做精确判断（全仓仅 3 处，本计划 T1 已改 `derived-mode-p`；仓库外未知），会受影响。回退方式：用户可自行 `(add-to-list 'auto-mode-alist '("\\.pdf\\'" . seshat-reader-mode))` 覆盖回来。
4. **`unregistered` 状态不触网**：在根下但 state 无记录时不再询问服务端（`seshat-reading--resolve` 纯本地查表）；需要确认时由显式 `M-x seshat-reading-refresh` 触发一次 `seshat-rest-resolve-uid`，失败则保持 `[未入库]` 并说明。
5. **不做书籍列表**：本计划只提供「打开即阅读 + 显式入库」；从服务端列书（书架 UI）是独立需求，属计划 C（M8.4 多根之后）。
6. **`seshat-reader-mode-hook` 会运行两次**（父 mode body 内 `run-hooks` + 派生机制的 `run-mode-hooks`）：这是既有行为、非本计划引入；两个 hook（`seshat-reader-mode-line`、`imenu-add-menubar-index`）均幂等且不读 `major-mode`，无副作用。本计划不修。

## 任务

### [x] T1 3 处 `eq major-mode` 改 `derived-mode-p`

- 动作：按 D6 改 3 处。
- 依赖：无
- 验收：既有 ERT 零回归（`seshat-reader-resize-test` 80 例、`sidebar` 57、`annotation` 48 等）；新增 3 例断言「在派生 mode 下 dark-mode / presentation-mode / 高亮源校验仍然生效」（用临时 `define-derived-mode` 或在测试里 `(setq major-mode 'seshat-reading-mode)` 后断言）。
- 完成记录：**已完成**。3 处精确 `eq major-mode` 已改 `derived-mode-p`（`seshat-reader.el` 2 处、`seshat-reader-annotation.el` 1 处）；新增 4 例（`emacs/tests/seshat-reading-test.el`），派生 mode 下暗色 / 演示模式 / 高亮源校验均生效。

### [x] T2 `seshat-reading-mode` + 库身份解析 + mode-line

- 动作：新建 `emacs/seshat-reading.el`，实现 D1/D2/D3。
- 依赖：T1
- 验收：新增 ERT ≥10 例——`external` 状态不产生任何请求（桩断言 0 次）；在根下且 state 有 uid → `library`；在根下但 state 无记录 → `unregistered` 且**不触网**（桩断言 0 次）、**无 warning**；`seshat-reading-refresh` 成功 → `library` 且 uid 被登记进 state；`seshat-reading-refresh` 失败（404 / 网络错误）→ 保持 `unregistered` 且有 `message`、不抛错；mode-line 四态字符串正确；派生 mode 下 `derived-mode-p 'seshat-reader-mode` 为 t；并覆盖「加载顺序」：先加载 `seshat-reader`（其 `auto-mode-alist` 注册已生效）再加载 `seshat-reading`，断言 `(assoc-default "x.pdf" auto-mode-alist #'string-match-p)` 仍解析为 `seshat-reading-mode`（不被反超）；同时断言 `auto-mode-alist` 里同一扩展名**没有重复项**
- 完成记录：**已完成**。新增 `emacs/seshat-reading.el`（`define-derived-mode` + 四态身份解析（零网络）+ mode-line + `auto-mode-alist` 接管：先 `require` reader、再从既有项原样取 pattern 就地替换 cdr）；新增 13 例。

### [x] T3 `seshat-library-add` 入库命令

- 动作：按 D5 实现。
- 依赖：T2
- 验收：新增 ERT ≥8 例——`external` 文件入库：复制到根 + 上传 `:if-none-match "*"` + 登记 uid + base-blob + 保存 + mode-line 变 `[库]`；已是 `library` → `user-error`；不在 `seshat-reading-mode` → `user-error`；412 时用户拒绝覆盖 → 中止且不留 state 变更；412 时用户同意 → 用 `:if-match` 重发；上传失败 → 报错且可回滚副本（按实现说明）；多个 mirror 根时走 `completing-read`（桩断言）；`ondemand` 根不出现在候选里；并断言「入库后立即跑 `seshat-sync-detect-renames` **不产生 dirty**」（验证 base-blob 的 size/mtime 取自复制后目标文件而非原文件）
- 完成记录：**已完成**。`seshat-library-add` 复制上传、保留原件；base blob 的 size/mtime 取自**复制后的目标文件**（入库后立即跑 `seshat-sync-detect-renames` 不产生 dirty）；新增 11 例。
- **内部可拆 2 步**：复制 + 上传主路径 → 412/失败分支。

### [x] T4 未入库时批注静默

- 动作：按 D4 加 `--quiet-fallback` 开关，并在 `seshat-reading-mode` 里启用。
- 依赖：T2
- 验收：新增 ERT ≥3 例——`seshat-reader-mode` 下未命中根仍有 `message`（既有行为不变）；`--doc-id` 传 `QUIET` 时**无** `message` 且 doc-id 仍为 `local:<abs>`；`translate.el:785` 那条跨 buffer 路径（在非 reader buffer 触发）同样能静音（证明用参数而非 buffer-local 开关）；库外文件创建批注仍抛 `user-error`（既有行为不变，本计划不改）。
- 完成记录：**已完成**。`--doc-id` 增可选 `QUIET` 参数（默认 nil 保持既有行为），6 处调用点逐一核对 buffer 语境后按参数传递；新增 4 例。

### [x] T5 文档与归档

- 动作：见「## 文档清单」。
- 依赖：T0–T4（即 T1–T4）
- 验收：文档按要求更新；计划归档。
- 完成记录：**已完成**。文档 8 项全部落地（`docs/emacs-reader.md` / `docs/configuration.md` / `CHANGELOG.md` / `decisions.md` / `tech-debt.md` / `roadmap.md` / `emacs/seshat-reader/VENDORED.md` 第 ⑪ 项 / 本计划归档）；全仓 ERT 637 → **669**（19 个文件，0 unexpected / 0 skipped）。

## 依赖关系

```text
T1 ──▶ T2 ──┬──▶ T3
            └──▶ T4
                   └──▶ T5
```

T3（入库命令）与 T4（批注静默）都只依赖 T2，文件不同（T3 改 `seshat-reading.el`；T4 改 `seshat-reader-annotation.el` + `seshat-reading.el`），**T4 里对 `seshat-reading.el` 的改动只有一行 mode 体开关**，若并行需协调；因此建议 T3 → T4 串行执行。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `docs/emacs-reader.md` | 新增「阅读模式：通用阅读 vs Seshat 阅读」小节：`seshat-reader-mode`（通用）与 `seshat-reading-mode`（Seshat）的分工、mode-line 四态含义、`seshat-library-add` 的入库语义（复制上传、保留原件）、未入库时的批注行为（本地 `local:`） | T5 |
| `docs/configuration.md` | 若 T4 引入用户可见开关（如 `seshat-reading-quiet-fallback`）则补；否则说明「零新增 defcustom」 | T5 |
| `CHANGELOG.md` | `### 新增`：`seshat-reading-mode`（库身份 + mode-line 标识 + 显式入库）；**行为变更提示**：未入库文档的 `local:` 降级不再刷 message（仅限新 mode） | T5 |
| `openspec/decisions.md` | 一条 2026-10-24：阅读与库身份解耦——派生 major mode 而非叠加 minor；入库＝复制上传保留原件；通用阅读零触网 | T5 |
| `openspec/tech-debt.md` | 新增：未入库批注不随入库迁移（`local:` → uid）；无书籍列表 UI（计划 C）；新增一条：库外文件不支持批注（`--uid` 抛 `user-error`），「本地批注 + 入库后迁移」待设计 | T5 |
| `openspec/active/roadmap.md` | 记录本计划与 M8 剩余项的关系（本计划不替代 M8.4 多根与书籍列表） | T5 |
| `emacs/seshat-reader/VENDORED.md` | 追加一条：D6 的 3 处 `eq major-mode` → `derived-mode-p`（上游 fork 的本地改动必须记录） | T5 |
| `docs/api.md` / `docs/errors.md` | **不改**（无服务端变更） | — |

## 验证标准

### L1

- `emacs --batch -Q -L emacs -L emacs/seshat-reader -f batch-byte-compile emacs/seshat-reading.el emacs/seshat-reader/seshat-reader.el emacs/seshat-reader/seshat-reader-annotation.el` → 新增文件 **0 warning 0 error**；两个改动的 reader 文件与基线逐条对比零新增。
- `check-parens` 所有改动文件通过。
- `make -C emacs/seshat-reader all` EXIT=0、警告集 33 → 33（reader 仅 3 行改动，不应引入新告警）。

### L2

- 全仓 ERT **逐文件**跑，带齐 `-L`（`emacs`、`emacs/seshat-reader`、`emacs/tests` + straight `build-31.1` 的包目录，**`etaf` 在 `build-31.1/etaf/lisp/`**）。基线 **637**（18 文件），本计划后 **19 个文件**、应达 **637 + N**（N ≥ 21），`unexpected = 0`、`skipped = 0`。

### L3（真机，需人工）

1. `find-file` 打开任意 PDF（库外）→ 进入 `seshat-reading-mode`，mode-line 显示 `[库外]`，**无**任何网络请求、**无** `local:` 警告，翻页/目录/缩放与改造前一致；
2. 该文件执行 `M-x seshat-reading-refresh` → 若服务端确认存在则转 `[库]`，否则保持 `[未入库]` 并有说明；
3. 把该文件 `M-x seshat-library-add` 到 `mirror` 根 → mode-line 变 `[库]`，服务端 `GET /api/resources/{uid}` 能查到；
4. 库内 PDF 用 `seshat-reading-mode` 打开 → 直接显示 `[库]`，批注创建后服务端可见；
5. 用 `seshat-reader-mode`（通用）打开同一库内文件 → 仍可批注（走既有 `tag:path` 解析），行为与改造前一致。

若服务端不可用，第 3–4 项记「未验证」，不阻塞归档。

### 回滚

全部为新增文件 + 3 行改动。`git checkout -- emacs/seshat-reader/seshat-reader.el emacs/seshat-reader/seshat-reader-annotation.el` + 删除 `emacs/seshat-reading.el` 与其测试文件。无持久化数据变更（入库会写 state 与服务端，回滚不回退已上传的文件）。

## 注意事项

1. **`auto-mode-alist` 指向 `seshat-reading-mode`**——通用阅读路径的**行为**必须零变化（渲染仍 100% 来自 `seshat-reader-mode`）。
2. **不得复制渲染代码**：`seshat-reading-mode` 只叠加身份/展示/入库，不碰 C 模块调用。
3. 通用阅读**绝不触网**：`external` 与 `unregistered` 状态都不调 `resolve-uid`。
4. 入库是**交互命令**，可以 `y-or-n-p`；但 `seshat-reading--resolve` 与 mode 体**不得**有任何交互（可能被程序化调用）。
5. 修改 `seshat-reader/` 下的文件只允许 D6 的 3 行（那是上游 fork，改动需记入 `VENDORED.md`；本计划若要记，归 T5）。
6. 新文件放 `emacs/` 顶层，不进 `emacs/seshat-reader/`。
7. 测试零网络；临时目录；不污染 `~/.local/share/seshat/`。
8. 不接触运行中的 Emacs；不 commit。

## 假设复核

T1–T4 执行后逐条回填（2026-10-24 完成）。

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| H1 | 派生 mode 不破坏 reader | 成立 ✓ | `derived.el` 宏展开确认父 mode body 先跑、子 mode 随后设 `major-mode`；全仓 3 处精确 `eq` 已改 `derived-mode-p`，既有 ERT 零回归 |
| H2 | 通用阅读由 `seshat-reading-mode` 承担、渲染与 reader 零差异 | 成立 ✓ | 通用阅读由 `seshat-reading-mode` 承担，渲染零差异（本 mode 不含任何渲染代码，全部继承） |
| H3 | 入库复制上传保留原件 | 成立 ✓ | `seshat-library-add` 按用户决定复制上传、保留原件（副本与原件并存已记 tech-debt） |
| H4 | 未入库仍可本地批注 | **被推翻 ✗** | `seshat-reader-annotation--uid`（`seshat-reader-annotation.el:178-181`）对库外文件抛 `user-error`，`annotation-create`（`:297`）无条件调用——库外批注本就不存在。本计划只静音警告；「本地批注 + 入库后迁移」已记 tech-debt |
| H5 | 解析全本地（零网络），仅显式 refresh 触网 | 成立 ✓ | `seshat-reading--resolve` 只读本地状态；ERT 以桩断言「打开路径零请求」，仅 `seshat-reading-refresh` 触网 |
