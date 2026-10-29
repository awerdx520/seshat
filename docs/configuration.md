# 配置说明

> **服务端配置已迁出**：`config.yaml` 与 `KEYSTONE_*` 环境变量见 keystone 仓 `docs/configuration.md`。本文件只描述客户端（Emacs + Android）配置。

## Emacs 客户端配置（批注侧车）

> 本节为**客户端侧**配置（`notes/emacs/`），与服务端部署配置无关，不影响服务端行为。

Emacs 端通过 `seshat-reader-annotation` 采集 PDF 页面选区并同步为服务端批注（侧车，不写回 PDF）。相关变量：

| 变量 | 说明 |
|---|---|
| `seshat-reader-annotation-roots` | 书库根映射：`("<标签>" . "<根目录>")` 的 alist。批注的 `document_id` 由 **`<标签>:<相对路径>`** 组成（相对路径 = 文件相对所命中根目录的路径）。多根命中时取**最长**匹配根；文件不在任何根下时降级为 `local:<绝对路径>`，并在提示中说明该批注**不跨端共享**。 |
| `seshat-rest-base-url` | 服务端 REST 基地址（不含末尾斜杠），如 `"https://example.com"`。 |
| `seshat-rest-token` | REST Bearer 令牌（即服务端 `SESHAT_AUTH_TOKEN`）。令牌从环境变量 `SESHAT_AUTH_TOKEN` 读取（`(getenv "SESHAT_AUTH_TOKEN")`），**不得写入配置文件**。 |

配置示例：

```elisp
(setq seshat-rest-base-url "https://example.com"
      seshat-rest-token (or (getenv "SESHAT_AUTH_TOKEN") "")
      seshat-reader-annotation-roots '(("ebook" . "~/WorkSpace/e-book/")))
```

### 同步地基（M8-A）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-transport-backend` | `rest` | 传输后端：`rest`（`url.el` + Bearer，走 `/api/...`）或 `webdav`（`curl` + Basic，走 `/dav/...`）。灰度期保留 WebDAV 以便回滚；**WebDAV 通道会静默忽略 `If-Match`/`If-None-Match`，冲突检测能力弱于 REST**。 |
| `seshat-state-file` | `~/.local/share/seshat/sync-state.eld` | 同步状态库（全局游标、uid↔路径索引、per-uid base blob、dirty 与墓碑）。原子写，单 Emacs 进程假设（多 daemon 同时同步会互相覆盖）。 |

**迁移说明**：旧的单文件 head（`~/.emacs.d/seshat-head`）**不再使用、不会自动迁移**。新状态库在首次同步时以服务端为准重建 base blob；若本地有离线改动，可能触发一次三方合并（有 `diff3` 兜底）。

### 同步根映射（M8-B）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-sync-roots` | `nil` | **同步必配**（否则同步无事可做）：每项为 `(TAG DIR MODE)`。`TAG` 必须与服务端 `GET /api/roots` 的 `tag` 一致；`DIR` 是本地目录；`MODE` 为 `mirror`（笔记根，可写）或 `ondemand`（书库根，只读），填 `nil` 表示由服务端自动补齐。 |
| `seshat-merge-diff3-program` | `"diff3"` | 三方合并所用的 `diff3` 可执行文件。找不到时合并降级为「保留待推送 + 提示手动处理」，不会报错。 |

配置示例：

```elisp
(setq seshat-sync-roots
      '(("notes" "~/seshat/notes" mirror)      ; 笔记根：全量镜像、可写
        ("books" "~/seshat/books" ondemand)))  ; 书库根：按需下载、只读
```

**改配置后必须运行 `M-x seshat-sync-reset-roots`**：根映射在首次同步时会写入状态库，之后不再读取配置；不重置则新配置不生效。

**`ondemand` 根必须配 `DIR`**：书架（`M-x seshat-library`）只能对配了本地目录的 `ondemand` 根取书——`DIR` 为空（`nil` / 空串）时该根在书架里只给一次 `message` 提示（「根 X 未配置本地目录，无法取书」）、**不列出任何条目**，因为无法由「根 tag + 服务端相对路径」定位落点。`MODE` 填 `nil`、由服务端 `GET /api/roots` 自动补齐时同样适用：**补齐的只是 `MODE`，`DIR` 永远不会被自动补齐**（服务端根到本地目录的对应关系只有用户配置说得清）。

**首次同步**：会为 `mirror` 根建一次全库索引（耗时与库规模成正比），之后每次同步的代价与变更数成正比。

**迁移**：旧的单文件 head `~/.emacs.d/seshat-head` 不再使用，无需迁移。

### 书架与按需取书（M8-C）

> **M8-C 新增 2 个 defcustom（见下）**：书架（`emacs/seshat-library.el`，命令 `M-x seshat-library`）不做根过滤持久化、也没有可调键位表；Phase 4 安全审查后补了**下载边界**两项（超时与字节上限）。除此之外，它的行为由两个既有变量驱动：

| 既有变量 | 对书架的作用 |
|---|---|
| `seshat-sync-roots` | 决定有哪些根；其中 `MODE` 为 `ondemand` 的根进书架（`mirror` 根不进）。每个 `ondemand` 根**必须配 `DIR`**，否则该根在书架里只给一次提示、不列条目（无法定位落点） |
| `seshat-state-roots` | 书架实际读的是**状态库里的根映射**（`seshat-sync-roots` 在首次同步时写入的那份），不是配置变量本身：根配好后需跑过一次 `M-x seshat-sync-now`，改配置后需 `M-x seshat-sync-reset-roots` |

**新增变量（M8-C 安全加固）**：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-library-download-timeout` | `30` | 单次取书下载的超时秒数；`nil` 表不限。作用于 `seshat-rest-download-file` 的 `:timeout`（rest 后端的 `url-retrieve-synchronously` 与 curl 后端的 `--max-time` 都已实现） |
| `seshat-library-max-download-bytes` | `(* 512 1024 1024)`（512 MiB） | 单次取书允许的最大字节数；`nil` 表不限。按响应 `Content-Length` 在**写盘前**预判，超限不写盘、报 `:too-large` |

备注：两个变量的 `:type` 均为 `(choice (const nil) integer)`，**可在 Customize 里选「不限」**（即设为 `nil`）；在 Lisp 里 `setq` 同样有效，例如 `(setq seshat-library-max-download-bytes nil)`。上限判定用 `numberp`，因此配浮点（如 `1.5e8`）也生效。

**根归属是硬门（安全底线）**：只有 `ondemand` 根的书才能在书架里**取书**（`RET` / `u`）与**删本地副本**（`d`）。`mirror` 根上的 uid 即使混进书架清单，`seshat-library-fetch` 与 `seshat-library-delete-local-at-point` 都会 `user-error` 拒绝——`mirror` 根是用户自己正在编辑的笔记，书架不该有覆盖或删除它们的能力。客户端的清单收集环节还会**校验响应 `:root` 与请求 tag 一致**（不一致的行直接丢弃并警告），因此「服务端在清单里塞 `mirror` 根 uid」这条路径不会到达用户按键。

**`u` 刷新已有副本会先确认**：`u` 是强制重下（`force` 非 nil），若本地已有副本会先 `yes-or-no-p` 询问「覆盖本地副本 …？」——拒绝则保留原副本、不做任何改动（`user-error "已取消（保留原副本）"`）。`RET` 与 `seshat:` 链接的 `:follow` 不带 `force`，本地已有副本时直接打开、不触发确认。

同理，`seshat:` 链接的 uid 形态也不需要新配置：能否产出 uid 形态由「两套根配置能否映射到同一路径」决定（见下节），不引入开关。

### 书架离线层（2026-10-29）

> 本轮把书架改为**离线优先**（清单主源 = 本地状态库），新增 5 个模块与 **16 个 defcustom**。上一节的两个下载边界变量（`seshat-library-download-timeout` / `seshat-library-max-download-bytes`）仍然有效、含义不变。

**日志（`emacs/seshat-log.el`）**：

| 变量 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `seshat-log-level` | `info` | `(choice (const debug) (const info) (const warn) (const error))` | 写入 `*Seshat Log*` 的最低级别（权重 `debug` 0 / `info` 1 / `warn` 2 / `error` 3）；未知级别按 `info` 处理 |
| `seshat-log-quiet` | `t` | `boolean` | 非 nil 时日志只进 `*Seshat Log*`、不写 echo area（`error` 级例外仍 `message`）；设 `nil` 恢复全部 echo 输出（前缀 `Seshat: `），用于排障 |
| `seshat-log-max-lines` | `2000` | `integer` | `*Seshat Log*` 保留的最大行数；超出后从 buffer **头部**裁剪，最新行一定保留 |

**阅读进度侧车（`emacs/seshat-reads.el`）**：

| 变量 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `seshat-reads-file` | `~/.local/share/seshat/reads.eld` | `file` | 进度侧车路径；与同目录 `sync-state.eld` / `annotation-queue.eld` 同一惯例，由 `seshat-reads-save` 以「同目录临时文件 + `rename-file`」原子替换写入 |
| `seshat-reads-debounce` | `2` | `number` | `seshat-reads-record` 的落盘去抖秒数（翻页会连续触发记录）；`0` 表示不延迟（仍经定时器，语义一致） |

**封面（`emacs/seshat-covers.el`）**：

| 变量 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `seshat-covers-dir` | `~/.cache/seshat/covers/` | `directory` | 封面缓存目录；**惰性创建**（只有真正写图片或负缓存时才 `make-directory`，只读路径不建目录） |
| `seshat-covers-timeout` | `3` | `integer` | 单次外部命令（`unzip` / `mutool`）的超时秒数；超时即 `delete-process` 并按失败降级——一个挂住的 `unzip` 不能无限期占住主线程。**默认 3 秒（不是 10）**：封面是装饰，不值得为它冻结主线程——队列在 idle 定时器里**同步**跑，一页 30 本 × 10 秒 = 最坏 5 分钟无响应；3 秒足够任何正常的 `unzip -p` / `mutool draw -r 24` 跑完（低分辨率栅格化一本普通 PDF 在百毫秒量级），超时的那本按失败降级即可 |
| `seshat-covers-max-bytes` | `(* 4 1024 1024)`（4 MiB） | `(choice (const nil) integer)` | 源图字节数上限；超限**不落盘**、按失败降级（写负缓存）；`nil` 表不限，`0` 等价「所有封面都走占位」 |
| `seshat-covers-queue-delay` | `0.2` | `number` | 串行队列两本封面之间的空闲间隔秒数（idle 定时器，每次只处理 1 本，不抢用户输入） |

**书架（`emacs/seshat-library.el`，本轮新增 5 个）**：

| 变量 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `seshat-library-max-entries` | `200000` | `(choice (const nil) integer)` | 远端清单刷新的总条数硬上限；超出即截断并记一条 warn（**不抛错**，书架照常可用、只是这次少列一些书）。这是 **DoS 护栏**而非性能调优：分页上限 500 × 每页 2000 最多 100 万条，防恶意 / 异常服务端返回海量条目把 `g`（刷新）拖到长时间无响应；`nil` 表不限（不推荐） |
| `seshat-library-cache-file` | `~/.local/share/seshat/library-cache.eld` | `file` | 远端清单缓存；**只缓存**远端清单（uid / 根 / 路径 / 大小 / mtime），**不缓存**本地三态（三态每次按磁盘事实重算）。原子写入，写失败不抛错；删掉即回到「只用状态库」的降级形态 |
| `seshat-library-page-size` | `30` | `integer` | 每页书目条数；非正整数按 `1` 处理（不让「除以 0」把整张表打不开）。**同时是 I-OOM 的驻留上限**：驻留 image 数 ≤ 本值 |
| `seshat-library-cover-height` | `48` | `integer` | 行内封面的显示高度（像素），只影响 `create-image` 的 `:height` 缩放；改大改小**不改变**「同时驻留几个 image」 |
| `seshat-library-cover-width` | `36` | `integer` | 封面区占用的**像素**宽度，用于把占位文本折算成列数（夹在 `[2, 8]` 列之间）；只影响列对齐，不影响 I-OOM |

**启动汇总（`emacs/seshat-status.el`）**：

| 变量 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `seshat-status-startup-notify` | `t` | `boolean` | 非 nil 时 Emacs 启动后**一次**在 echo area 汇总 Seshat 状态（书库本数与已下载数、待同步笔记 / 批注、上次同步时间与结果、状态库是否损坏）；`nil` 完全不提醒（仍可随时 `M-x seshat-status`） |
| `seshat-status-startup-delay` | `2` | `number` | 启动汇总的延迟秒数；不在 `emacs-startup-hook` 里同步计算，避免拖慢启动、也避免与启动期其他 `message` 抢 echo area |

**回退路径**（把某个新行为关掉而不改代码）：

| 想关掉 | 做法 |
|---|---|
| 远端缓存（回到「只用状态库」） | 删 `~/.local/share/seshat/library-cache.eld` |
| 静默化（回到 echo 全量输出） | `(setq seshat-log-quiet nil)` |
| 封面（全部走书名首字占位） | `(setq seshat-covers-max-bytes 0)` |
| 启动汇总 | `(setq seshat-status-startup-notify nil)` |
| 分页（近似一屏到底） | 调大 `seshat-library-page-size`（**代价**：I-OOM 的驻留上限随之放宽） |

**封面队列熔断（内部常量，不可配）**：连续失败 **5** 次（`seshat-covers--failure-threshold`）即暂停封面队列 **60** 秒（`seshat-covers--cooldown-seconds`），成功一次即清零——两者都是 `defconst` 而非 defcustom，**没有配置入口**（改它们等于改代码）。它兜的是「环境整体不可用」：缺 `unzip` / `mutool`、或源文件全部损坏时，不会让队列逐本空跑一遍超时。熔断与冷却只在 `*Seshat Log*` 记一条 warn（不写 echo area）。

### 阅读器翻译 / 解释（go-translate 预设）

> 与批注侧车同属**客户端侧**配置（由 `seshat-reader-translate` 模块读取），与服务端无关。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-translate-preset` | `reader` | 「翻译」使用的 gt 预设名（阅读器按名从 `seshat-reader-translate-presets` → `gt-preset-translators` 依次取用） |
| `seshat-reader-translate-explain-preset` | `reader-explain` | 「解释」使用的 gt 预设名（通常指向 `gt-chatgpt-engine`） |
| `seshat-reader-translate-fallback-langs` | `(en zh)` | 语言回退：源语言取本列表首项，目标语言由此推导（可由命令前缀参数覆盖） |
| `seshat-reader-translate-render` | `sidebar` | 译文/解释呈现方式：`sidebar`（默认，写入**底部面板内的 Markdown 文本 buffer**——`gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链，原生折行/滚动/复制/isearch 可用，**不经 ETAF 排版**）、`pop`（posframe 弹出，超时自动消失）或 `pin`（posframe 固定停留）。取 `sidebar` 但 `seshat-reader-sidebar-enabled` 为 nil 时退回 `pop` 式 posframe |
| `seshat-reader-translate-show-source` | `t` | 是否在面板正文前插入**选中原文的引用块**（`> **原文**` + 每行 `> ` 前缀、不截断）。**默认开启**（便于对照原文与译文）；设 `nil` 关闭，面板更紧凑 |
| `seshat-reader-translate-template` | `"%l\n\n%q\n\n---\n\n%t\n"` | **翻译**面板的 Markdown 模板；`nil` 表示不套模板、直接插入正文。默认**不含标题**（`header-line` 显示「Seshat 译文」/「Seshat 解释」）；`%k` 标题占位符保留供自定义模板使用。占位符：`%k` 标题、`%l` 语言对（斜体，如 `*en → zh*`；无 langs 时留空）、`%q` 原文引用块、`%t` 正文。模板非法（未知占位符等）时回退纯正文并 `message` 警告 |
| `seshat-reader-translate-explain-template` | `"%q\n\n---\n\n%t\n"` | **解释**面板的独立 Markdown 模板；默认不含标题与语言对（解释场景前者由 `header-line` 承担、后者信息价值低），占位符与上一行相同。`nil` 退回纯正文，**不会借用** `seshat-reader-translate-template` |
| `seshat-reader-translate-visual-fill-column` | `t` | 译文/解释面板启用 `visual-fill-column-mode`（**软依赖**，未安装时静默跳过）。**只负责开关**：正文宽度自 2026-10-26 起不再取 `visual-fill-column-width`（`nil` → `fill-column`），而由下面的 ratio 决定并跟随面板窗口宽度；设 `nil` 关闭并清理窗口 margin；批注列表不受影响（ETAF 按窗口宽度布局） |
| `seshat-reader-translate-visual-fill-column-ratio` | `0.94` | 折行模式下正文宽度 = **面板窗口可用文本宽 × 本值**，随窗口尺寸变化实时重算（`C-c w` 扩宽面板后正文同步变宽）。可用宽与 vfcm 自身 `--window-max-text-width` **同源**：`window-width` 取 `remap` 单位 → 扣左右 margin 后按 remap 比例折算 → 按 `text-scale` 折减，并沿用 `visual-fill-column-adjust-for-text-scale` 的前置判断；**不用 `window-body-width`**（remap 下少算 2–4 列）。留白口径：本包**不设** `visual-fill-column-center-text`（尊重用户全局值）——默认 `nil` 时正文左对齐、约 **6% 留白集中在右侧**，该项为 `t` 时左右各约 3%。设 `nil` = **恢复旧行为**（正文固定为全局 `fill-column`、不跟随窗口）——这是刻意保留的回退路径，不是废弃分支。仅**窗口承载 + 左右分栏**的面板有意义（childframe / 底部模式不按窗口宽排版） |
| `seshat-reader-translate-valign` | `t` | 用 `valign-mode` 对齐译文/解释里的 Markdown **表格列**（**软依赖**，未安装静默跳过；`(display-graphic-p)` 为 nil 时**静默不启用、不提示**）。仅 `seshat-reader-panel-truncate-lines` 为 `nil`（折行）时生效，不折行时与 vfcm 一并跳过。与 ratio **互不耦合**：只改表格单元格像素宽度，不参与正文宽度计算。译文与解释**共用同一个面板 buffer**，无法只对解释生效。注意 `:align-to` 绝对像素对齐，**宽表格会被面板右缘裁切**（见 `docs/emacs-reader.md` §12 第 28 条与 tech-debt） |
| `seshat-reader-translate-stream` | `t` | 译文/解释**流式增量输出**：为克隆后的引擎设 `stream` 槽，把 `gt-buffer-render-output-hook` 的增量同步到面板——模板骨架只写一次（正文 `%t` 为空）并记正文起点 marker，后续只替换 marker 之后的正文区，完成时只更新 `header-line` 不再 `erase-buffer`（避免完成瞬间整块跳变）。引擎不支持流式或取 `nil` 时退回「完成即整体渲染」的旧路径 |
| `seshat-reader-translate-engines-pick` | `all` | 多引擎结果的展示方式：`all`（**默认**，展示全部**成功**结果，每条前标注 `【引擎名】`、段间用 Markdown 分隔线 `---`）/ `first`（只展示第一个成功结果）/ `last`（只展示最后一个成功结果）——`first` / `last` **不带**来源标签。带 `gt-buffer-render-error-face` 的片段视为失败跳过；来源取不到时退化为纯译文（不加标签不加分隔线）。改成「拼接后不可区分」的旧观感请显式设 `first` |
| `seshat-reader-translate-follow-up-max-rounds` | `6` | 追问（`C-c C-q`）历史保留的**轮数上限**（一轮 = 问 + 答两条 messages）；超出时**丢弃最早的轮次**，但首轮的原文与首轮解释（messages 前两条）**始终保留**。取 `0` 表示不带任何历史轮次（每次追问只看原文与首轮解释）。轮数越多每次请求的上下文越长、费用越高 |
| `seshat-reader-translate-presets` | `nil` | **seshat 专用的 gt 预设表**，元素为 `(NAME . TRANSLATOR)` 或 `(NAME . THUNK)`（THUNK 是无参函数，调用后返回 `gt-translator`，用于避开「配置加载时 gt 尚未加载」的顺序问题）。查表顺序：**本表 → `gt-preset-translators`**，本表命中优先，故 seshat 的预设不必再进 gt 全局表 |
| `seshat-reader-translate-explain-prompt` | 结构化中文模板（含 `## 任务` / `## 要求` / `## 上下文` / `## 需要解释的原文` 四节，每个标题后有空行） | 「解释」的 prompt 模板；`nil` 表示**不装配**：只发送纯选区文本，由引擎的 `:root`（system prompt）决定行为。注意 `reader-explain` 预设的 `:prompt` 已改为纯透传 `"{{text}}"`（解释指令改由 seshat 装配），因此 `nil` **不等于**恢复此前的旧中文长 prompt——需要那种效果请在配置侧把 `:prompt` 改回长指令。占位符：`{{text}}` 选区原文、`{{context}}` 上下文（可能为空行）、`{{doc}}` 文档名（无则替换为「未知文档」）、`{{lang}}` 目标语言；输入值里的 `{{` 会被转义（原样保留，不参与替换）。**每个标题行后必须留一个空行**：`gt-source-text-transformer` 只在空行处分段，否则标题会与紧随的正文行合并 |
| `seshat-reader-translate-explain-max-chars` | `2000` | 送模型的**选区原文字符上限**（超出截断并在尾部加「（选区过长，以上为节选）」）；只作用于送模型的文本，**不影响**面板原文引用块与追问的来源文本 |
| `seshat-reader-translate-strip-chatter` | `t` | 去掉模型输出的**寒暄首行**（首行以「好的 / 以下是 / 下面 / 这段 / 该段」开头且以冒号结尾时，删掉该行与其前导空行）；在 `--record-result` 处统一执行，故**翻译与解释、面板与 posframe 四条组合都生效**；流式增量过程不经过该净化 |
| `seshat-reader-translate-context-enabled` | `t` | 解释时是否注入**同页邻近上下文**（= 选区**上方块 + 下方块**）；设 `nil` 时不触碰 C 模块（只送纯选区） |
| `seshat-reader-translate-context-lines` | `2` | 上下文向选区上下各扩的**行数**：上方块取「外扩顶 → 选区顶」，下方块取「选区底 → 外扩底」，两块**分别**取文本后拼接（选区原文不在任一块内，不做字符串剥离） |
| `seshat-reader-translate-context-max-chars` | `1200` | 上下文文本的**字符上限**（超出时截断：矩形路径只保留前 N 个字符，整页降级路径以选区为中心取窗口）。这也是解释时随原文一起离开本机的额外数据量上限 |

说明：

- `reader` / `reader-explain` 两个 gt 预设**推荐定义在 `seshat-reader-translate-presets`**（示例见 `thomas-emacs/lisp/init-tools.el`）——该表是 seshat 自有的，**不进** gt 全局 `gt-preset-translators`，因此不会出现在 `M-x gt-translate` 的预设选择列表里，也不影响用户其它 gt 用法；查表仍回落 `gt-preset-translators`，**把预设留在全局表的旧配置继续可用**，无需迁移。预设缺失时回退内置默认（翻译回退 youdao/google，解释需显式配置端点）。
- `reader-explain` 的引擎 `:prompt` 应为**纯透传** `"{{text}}"`：解释的结构化指令由 seshat 装配（见 `seshat-reader-translate-explain-prompt`），配置侧再写长 prompt 会变成**双层指令**。
- **解释的输入已从「纯选区」变为「结构化指令 + 同页上下文 + 选区原文」**：上下文取选区所在页、按选区触发行上下各扩 `seshat-reader-translate-context-lines` 行，然后**分上块与下块两次**取矩形文本（上块 = 外扩顶 → 选区顶，下块 = 选区底 → 外扩底），用空行拼接——选区原文天然不在任一块内，因此**不做任何「删除选区原文」的字符串操作**；取不到时降级「整页文本 + 窗口截取」，再失败则退化为「纯选区 + 指令」。**一键回退**：`explain-prompt` 设 `nil` → 只发送纯选区、由引擎 `:root` 决定（**不等于**旧中文长 prompt，需要旧效果请把预设 `:prompt` 改回长指令）；`context-enabled` 设 `nil` → 无上下文；`strip-chatter` 设 `nil` → 原样输出。
- 解释 / 翻译失败时 `message` 会在原因前追加引擎标识 `（model @ host）`，便于判断是哪条链路出错；**不含任何 key**。
- gt 的 key（如 `gt-chatgpt-key`）**一律走 authinfo / 环境变量**（本项目经 `DEEPSEEK_API_KEY` 环境变量注入），**禁止写入配置文件**。seshat 的 DeepSeek 引擎由 `thomas-emacs` 侧的 `thomas-seshat-chatgpt-engine` 子类覆写 `gt-resolve-key` 从 `DEEPSEEK_API_KEY` 取 key，**不再** `setq gt-chatgpt-key`（改全局变量会让用户其它 gt chatgpt 用法也用 DeepSeek key 打各自端点）。
- **多引擎与追问的配置前提（M12 T8a，2026-10-25）**：① `seshat-reader-translate-engines-pick` 默认 `all`，多引擎预设（如 `reader` = youdao-dict + google）的输出改为逐条 `【引擎名】` 标注 + `---` 分隔；想要单条输出（旧观感）设 `first` / `last`。② `C-c C-q` 追问（`seshat-reader-translate-follow-up`）要求预设里**含 `gt-chatgpt-engine`**（如 `reader-explain`）——引擎克隆后把 `prompt` 槽换成「返回 messages 列表的函数」，由 `gt-chatgpt-send` 按 `messages` 数组发送；预设只有 youdao / google 这类纯翻译引擎时**报 `user-error` 并提示改配置**，不做文本拼接降级（翻译引擎没有对话语义）。追问历史轮数由 `seshat-reader-translate-follow-up-max-rounds`（默认 `6`）限制。

### 批注离线队列（服务不可用时的本地暂存）

> 与批注侧车同属**客户端侧**配置（由 `seshat-reader-annotation-queue` 模块读取），与服务端无关。

服务端不可用时，批注的创建/删除不再报错，而是写入本地队列暂存；服务端恢复后自动推进同步。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-annotation-queue-file` | `~/.local/share/seshat/annotation-queue.eld` | 离线队列文件路径 |
| `seshat-reader-annotation-queue-auto-sync` | `t` | 是否启用自动同步（服务恢复后自动推进） |
| `seshat-reader-annotation-queue-sync-interval` | `300` | 周期同步间隔（秒） |
| `seshat-reader-annotation-queue-initial-delay` | `10` | Emacs 启动后首次自动同步的延迟（秒） |
| `seshat-reader-annotation-queue-max-entries` | `1000` | 队列条目上限（达上限时拒绝入队） |

说明：

- 服务端不可用时，批注/删除操作写入本地队列（**不报「服务不可用」**）；用户得到的是「已存入本地，待联网同步」。批注**列表**在离线时仍显示本地待同步项并标 `[待同步]`。
- 服务恢复后，同步由以下时机推进：**启动后 `initial-delay`（默认 10 秒）首次 + 每 `sync-interval`（默认 300 秒）周期 + 手动 `M-x seshat-reader-annotation-queue-sync` + `list`/`create` 成功后的机会性同步**。
- 队列文件为 elisp 数据（`prin1` 写出的 plist 列表），采用**原子写**：先把内容写入同目录唯一临时文件，再 `rename-file` 原子覆盖目标文件，避免写入中途崩溃留下损坏内容；读取到损坏文件时保留原文件不覆盖并报错。

### 阅读器面板（M11.7–M11.14）

> 与批注侧车同属**客户端侧**配置（由 `seshat-reader-sidebar` 承载层读取，该模块零依赖、不渲染内容），与服务端无关。批注列表与译文/解释统一显示在承载层面板中（M12 起默认**右侧** side window，可配 `left` / `below-selected` / `at-bottom`）。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-sidebar-enabled` | `t` | 是否用面板展示批注列表与译文/解释；`nil` 时批注列表退回 `pop-to-buffer`，译文按 `seshat-reader-translate-render` 处理（取 `sidebar` 时退回 `pop` 式 posframe） |
| `seshat-reader-sidebar-position` | `right` | **信息栏**（`annotations` / `translate`）的弹出位置：`right`（frame 右侧 side window，**宽度语义**）/ `left`（frame 左侧 side window，宽度语义）/ `below-selected`（当前窗口下方分割，形如 `*Help*`，**高度语义**）/ `at-bottom`（frame 底部整宽，高度语义）。**M12 起默认值由 `below-selected` 改为 `right`**（破坏性变更，回退写法见本节末） |
| `seshat-reader-sidebar-width` | `0.25` | 信息栏在 `left` / `right` **side window** 下的宽度（占 frame 宽度比例）：**小数**按 frame 根窗口总宽的比例换算为列数，**整数**直接作列数。仅 side 模式生效（底部模式改用 `seshat-reader-sidebar-height`；childframe 承载改用 `seshat-reader-panel-width`），且改动仅对**新建**面板窗口生效。**2026-10-25 默认值由 `0.24` 改为 `0.25`**（与 childframe 的 `seshat-reader-panel-width` 对齐） |
| `seshat-reader-outline-sidebar-position` | `left` | **目录栏**（`outline`）的弹出位置，取值同 `seshat-reader-sidebar-position` 的四项，但只作用于目录面板；默认与信息栏分居两侧，构成「左目录 / 右信息 / 中间阅读区」 |
| `seshat-reader-outline-sidebar-width` | `0.20` | 目录栏在 `left` / `right` 下的宽度（语义同 `seshat-reader-sidebar-width`，默认更窄——目录标题通常短于批注/译文卡片）。仅 side 模式生效 |
| `seshat-reader-sidebar-expanded-width` | `0.75` | **「扩大」后的面板宽度**（占 frame 宽度比例，语义同 `seshat-reader-sidebar-width`：小数按 frame 根窗口总宽换算列数、整数直接作列数）。由命令 `seshat-reader-sidebar-toggle-width`（`C-c w`，阅读 buffer / 译文面板 / 批注列表 / 目录面板四处同一键位）使用：按一次把当前面板从常态宽度（`seshat-reader-sidebar-width` / `seshat-reader-outline-sidebar-width`）扩到本值，再按一次**恢复扩大前的宽度**。仅「窗口承载 + 左右分栏」生效：childframe 承载（宽度由 `seshat-reader-panel-width` 决定）与底部模式（高度语义）只提示、不改布局。扩大值**不持久化**：关闭面板时承载层会把实测宽度记进会话内尺寸记忆，重开仍是扩大的；重启 Emacs 回到常态宽度 |
| `seshat-reader-sidebar-height` | `0.35` | 面板**首次显示**时的初始高度，作为 `display-buffer` 的 `window-height`（按比例）；译文/解释面板随后按内容自适应（见 `seshat-reader-sidebar-min-height` / `seshat-reader-sidebar-max-height`），批注列表固定用本值。改动仅对**新建**面板窗口生效，对已显示窗口不自动重排 |
| `seshat-reader-sidebar-max-height` | `0.8` | 译文/解释面板按内容自适应时的**高度上限**（占 frame 比例）；自适应范围夹紧在 `seshat-reader-sidebar-min-height`（默认 0.25）与本值之间。仅对 `translate` 且未挂载 ETAF runtime 的面板生效，批注列表固定高度不受影响 |
| `seshat-reader-sidebar-min-height` | `0.25` | 译文/解释面板按内容自适应的**下限**（占 frame 比例，至少 1 行）；与 `max-height` 共同夹紧。仅对 `translate` 且未挂载 ETAF runtime 的面板生效，批注列表不受影响；`min` 配得比 `max` 大时以 `max` 为准 |
| `seshat-reader-sidebar-select-window` | `t` | 面板显示后是否在**命令结束时**把光标移入面板（`display-buffer` 的 `post-command-select-window`）；`nil` 时光标留在原窗口 |
| `seshat-reader-sidebar-translate-buffer-name` | `"*Seshat Sidebar*"` | 译文/解释的**展示 buffer** 名（只读 Markdown 文本 buffer，也是 popper 判定的名字之一）；gt 中转改用隐藏 buffer ` *Seshat gt*`，本变量不再作 gt `:name`、也不再作结果捕获的守卫依据 |
| `seshat-reader-panel-carrier` | `window` | 面板**承载方式**：`window`（默认，side window / 底部窗口承载，行为与 `seshat-reader-sidebar-position` 一族一致）/ `childframe`（child frame 覆盖在父 frame 右上角，不参与窗口树，显示/刷新/滚动面板**不改变阅读窗口像素尺寸**，故不触发阅读器 refit）。**2026-10-25 起默认由 `childframe` 改回 `window`**：childframe 不在窗口树内，满高显示时**遮挡 frame 底部的 minibuffer 与 `M-x` 补全列表**（`*Completions*`），而 side window 天然参与布局、满高也只挤压阅读区。想要「浮层覆盖、不挤占阅读区」时显式设 `(setq seshat-reader-panel-carrier 'childframe)`，并注意它无法避让底部 minibuffer（可配 `seshat-reader-panel-full-height` 为 `nil` 或减小 `seshat-reader-panel-height`）。**非图形环境**（`display-graphic-p` 为 nil）强制回退 `window`；`childframe` 建不出 frame 时自动回落窗口后端 |
| `seshat-reader-panel-carrier-alist` | `((annotations . window))` | 逐 kind 覆盖 `seshat-reader-panel-carrier`：键取 `outline` / `annotations` / `translate`，值取 `childframe` / `window`。默认只有批注列表一条，把「批注要长列表浏览与逐条跳转、覆盖浮层既遮挡正文又放不下」这一意图显式写下——全局默认已是 `window`，两者等价；用户把全局改成 `childframe` 后，批注列表仍留在窗口承载。解析顺序 alist 命中项 → 全局值 → 非法值静默回落 `window` |
| `seshat-reader-panel-width` | `0.25` | child frame 承载时的宽度**比例**（占父 frame 像素宽）。默认与侧边栏宽度一致（约 1/4 屏宽）；调大时注意面板会遮挡更多正文。与 `-height` 一起在**打开那一刻**固定几何，改动只对随后新建的面板生效 |
| `seshat-reader-panel-height` | `0.45` | child frame 承载时的高度**比例**（占父 frame 像素高）。**仅在 `seshat-reader-panel-full-height` 为 `nil` 时生效**；为 `t`（默认）时高度取「父 frame 像素高 − 2×margin」。面板**打开即固定、全程不 resize**，内容超出后在面板窗口内滚动（按内容行数自适应高度是窗口后端的行为，childframe 承载下不参与） |
| `seshat-reader-panel-margin` | `16` | child frame 距父 frame 边缘的像素间距（贴边侧的左右间距 + 上下各一份；满高时上下各留一个） |
| `seshat-reader-panel-position-alist` | `((outline . left) (translate . right))` | 各 kind 面板贴父 frame 的哪一侧：`left` / `right`。未命中的 kind 回落到 `seshat-reader-sidebar-position`（取其 `left` / `right`；该变量取 `below-selected` / `at-bottom` 等**非左右**值时按 `right` 处理——child frame 是覆盖浮层，没有「底部」概念）。默认「目录贴左、译文/解释贴右」 |
| `seshat-reader-panel-full-height` | `t` | 面板是否**占满父 frame 高度**（上下各留 `seshat-reader-panel-margin`）：非 nil 时高度 = 父 frame 像素高 − 2×margin；同侧已有其它面板时按剩余空间分配（至少保留父 frame 高的 **30%**，不足则允许超出）。`nil` 时回落 `seshat-reader-panel-height` 的比例 |
| `seshat-reader-panel-truncate-lines` | `nil` | 面板正文是否**不折行**（**默认 `nil` = 折行**）。`nil` 时折行——`truncate-lines` 为 nil、`word-wrap` 为 t，并按 `seshat-reader-translate-visual-fill-column` 启停 `visual-fill-column-mode`（正文宽度跟随 ratio）与 `seshat-reader-translate-valign`（表格列对齐）；非 nil 时不折行、超出面板宽度可**横向滚动**（`truncate-lines` 为 `t`、`word-wrap` 为 `nil`、`auto-hscroll-mode` 为 `t`），并**禁用** `visual-fill-column-mode` **与 `valign-mode`**——前二者互斥（按列宽折行与横向滚动不能并存），valign 的像素对齐也只在折行模式下调好。**2026-10-25 默认值由 `t` 改为 `nil`**：面板窄、横滚看长行需要来回拖，折行更省事；想要横向滚动显式设 `(setq seshat-reader-panel-truncate-lines t)` |
| `seshat-reader-panel-follow-bottom` | `t` | 流式输出期间面板是否自动跟随底部（显示最新内容）；用户**向上滚动后停止跟随**，自己滚回底部时恢复 |
| `seshat-reader-panel-hide-on-buffer-change` | `t` | 当前 buffer 不再是阅读器 buffer（不派生自 `seshat-reader-mode`）时关闭本包 child frame 面板；面板内容仍留在 buffer 里，可用 `C-c C-o` 重开。设 `nil` 让面板常驻 |

说明：

- **三栏版式（M12）**：`left` / `right` 下侧栏是 **side window**（`display-buffer-in-side-window` + 独立 slot），显示/收起不挤压阅读区；且侧栏是 **per-kind 独立窗口**——目录（默认 `left`）与批注/译文（默认 `right`）可同时存在，不再「后显示者接管」，`o` 收起/展开左侧目录（只开合目录的命令 `seshat-reader-sidebar-toggle-outline` 不再绑键，仍可 `M-x` 调用）。底部模式（`below-selected` / `at-bottom`）仍是单窗口、后显示者接管（M11 语义，非缺陷）。
- **破坏性变更与回退（M12）**：`seshat-reader-sidebar-position` 默认值由 `below-selected` 改为 `right`，升级后批注/译文面板出现在**右侧**而非底部。恢复旧观感：`(setq seshat-reader-sidebar-position 'below-selected)`；`left` / `right` 为 M12 新增取值，`below-selected` / `at-bottom` 仍然可用。
- **译文/解释为 Markdown 文本 buffer**：面板正文是普通只读 buffer，用 `gfm-view-mode`（缺失时降级 `markdown-view-mode` / `text-mode`）渲染，并按 `seshat-reader-panel-truncate-lines` 设置折行与横向滚动——**默认（`nil`）折行**：`truncate-lines` 为 nil + 显式开 `word-wrap`，可叠加 `visual-fill-column-mode`（`seshat-reader-translate-visual-fill-column`，默认 `t`；2026-10-26 起正文宽度由 `seshat-reader-translate-visual-fill-column-ratio` 跟随窗口，不再是固定全局 `fill-column`）与 `valign-mode`（`seshat-reader-translate-valign`，默认 `t`，表格列对齐）；设 `t` 时不折行、超出面板宽度可用 `scroll-left` / `C-x <` **横向滚动**（同时跳过 `visual-fill-column-mode` 与 `valign-mode`，折行与滚动互斥）。`header-line` 显示「Seshat 译文」/「Seshat 解释」；`q`（关面板）、`C-c w`（宽度切换）与 `C-c C-s`（存为批注）由 minor mode `seshat-reader-translate-panel-mode` 承载。**markdown-mode 为软依赖**：未安装时降级 `text-mode`（不折行美化、不隐藏标记），功能仍可用。正文按模板渲染——翻译面板用 `seshat-reader-translate-template`（默认「语言对 + 原文块 + 分隔线 + 正文」）、解释面板用 `seshat-reader-translate-explain-template`（默认「原文块 + 分隔线 + 正文」）；两者默认都**不含正文标题**，因为 `header-line` 已显示「Seshat 译文」/「Seshat 解释」，需要正文标题时自定义模板加 `%k`（或设模板为 `nil` 退回纯正文）。
- **高度自适应**：译文/解释面板显示后按内容实际行数（`window-text-pixel-size` 换算）调整高度，夹紧 `seshat-reader-sidebar-min-height`（默认 0.25）到 `seshat-reader-sidebar-max-height`（默认 0.8），并把实测比例写入该 kind 的高度记忆；同帧内面板增高会压缩上方阅读窗口（预期行为）。单行像素高取首行 `line-pixel-height` 与 `frame-char-height` 的**较小值**（Markdown 标题行通常比正文行高，直接用首行会把内容行数低估），测量上限 120 行（超长内容按上限计，避免测量耗时）。
- **连续流展示**：批注列表**不分页**，全量条目一次性单列渲染（无页脚、无 `]`/`[` 翻页键）；徽章始终显示「N 条」，`n`/`p` 只移动选中、不再切页。列表超出面板高度时由**面板窗口**滚动查看；ETAF 渲染层按条目数显式计算 viewport 高度（`--content-viewport-height`，已挂载时经 `etaf-runtime-refit` 放大），保证新增条目不被裁剪。
- **per-kind 尺寸记忆（仅会话内，带方向标签）**：M11 的单窗口语义下同一时刻只有一个面板窗口，但 `annotations` 与 `translate` **各自记住自己的尺寸**——切换内容前先把当前窗口的实际尺寸（比例）记给它的类型，再用目标类型记住的尺寸新建窗口；同一类型重复显示走 `display-buffer` 复用，不重建、也不重置用户手动调整过的尺寸。M12 起记忆项带**方向标签**（宽度语义 vs 高度语义），因此把方位在 `left`/`right` 与 `below-selected`/`at-bottom` 之间切换时，旧值不会被按错误单位复用。某类型首次显示时，side 模式用 `seshat-reader-sidebar-width` / `seshat-reader-outline-sidebar-width`，底部模式用 `seshat-reader-sidebar-height`。状态保存在内存 alist 中，**重启 Emacs 后回到默认值**。
- **关闭**：面板是非固定窗口；面板内 `q` 由 minor mode 承载（批注列表与译文面板各有其 minor mode 键位），`seshat-reader-sidebar-toggle` 可开合（关闭本包面板窗口，打开时按最近一次的内容类型重开，含 `translate`）。toggle **不使用** `window-toggle-side-windows`——它是 frame 级全量开关，会连带删除/恢复 eca-chat、which-key 的侧窗。
- **popper 集成**：`*Seshat Annotations*` 与 `*Seshat Sidebar*` 两个 buffer 名已在 `thomas-emacs/lisp/init-window.el` 登记为 popper popup，可用 `C-'` 或 `` M-` `` 开关；popper 重开时经 `seshat-reader-sidebar-display-buffer` 分流回本包的显示逻辑，因此**布局（`position` / `width` / `height` / per-kind 尺寸）仍由本包掌控**，不会被 popper 的默认 bottom side window 规则改写。该分流由用户配置侧（`init-window.el`）接入，本包只提供函数。
- **承载变更与回退（M12 T8a，2026-10-25）**：面板默认承载由 **窗口** 改为 **child frame 覆盖**（`seshat-reader-panel-carrier` 默认 `childframe`；**该默认已于同日改回 `window`，见下一条**）——child frame 不参与窗口树，显示/刷新/滚动面板不再改变阅读窗口像素尺寸，也就消除了「开面板 → 窗口尺寸变化 → 阅读器 refit → 页面跳动」这条链。随之而来的四点行为差异：① **固定尺寸**（`seshat-reader-panel-width` / `-height` / `-margin`），打开即固定、内容超出内部滚动，`seshat-reader-panel-follow-bottom` 控制流式期间是否跟随底部；② **去 mode-line**（面板窗口设 window parameter `mode-line-format` 为 `none`，`header-line` 保留）；③ **面板内 `q` 统一走 `seshat-reader-sidebar-quit`**（按 buffer 名推断 kind，child frame 走 `delete-frame`；批注列表仍是 `quit-window`），阅读器侧 `C-c C-o` 重新绑到无参的 `seshat-reader-sidebar-toggle`（开着即全部关闭、关了重开最近一个）；④ **切走即隐藏**（`seshat-reader-panel-hide-on-buffer-change`，默认 `t`）。**回退写法**：`(setq seshat-reader-panel-carrier 'window)`；只把译文/目录退回窗口承载可设 `(setq seshat-reader-panel-carrier-alist '((annotations . window) (translate . window) (outline . window)))`；**非图形环境自动回退 `window`**，无需配置。child frame 面板**不经过** `display-buffer`，故 popper 的 `C-'` 只作用于窗口承载的面板；多个 child frame 面板同时存在时由承载层**纵向堆叠**、互不重叠。
- **满高贴边与可滚动正文（2026-10-25）**：child frame 面板改为「**按侧贴边 + 满高**」——`seshat-reader-panel-position-alist`（默认 `((outline . left) (translate . right))`）决定各 kind 贴哪一侧（目录左、译文/解释右），`seshat-reader-panel-full-height`（默认 `t`）让高度铺满父 frame（上下各留 `seshat-reader-panel-margin`），宽度仍为 `seshat-reader-panel-width`（**默认由 `0.34` 改为 `0.25`**，约 1/4 屏宽，少遮挡正文）。同侧多面板按剩余高度分配（下限父 frame 高的 30%，不足时允许超出）；跨侧面板互不影响（两侧各占满高度）。正文**默认折行**（`seshat-reader-panel-truncate-lines` 现默认 `nil`：`truncate-lines` 为 nil、`word-wrap` 为 t，可叠加 `visual-fill-column-mode`；**2026-10-25 当天由 `t` 改为 `nil`**，见上表），要横向滚动则设 `(setq seshat-reader-panel-truncate-lines t)`；纵向滚动始终天然可用。**几何精度**：`set-frame-size` 的 PIXELWISE 尺寸是文本区尺寸（不含 internal border / fringe），实测 pgtk 下 read-back 恒比请求值宽 32、高 16；`seshat-reader-sidebar--cf-place` 因此按实测差值再收口一次，使整框像素尺寸精确等于目标。**回退旧观感**：`(setq seshat-reader-panel-full-height nil)`（恢复按 `seshat-reader-panel-height` 比例）+ `(setq seshat-reader-panel-position-alist nil)`（全部回落到 `seshat-reader-sidebar-position` / `seshat-reader-outline-sidebar-position`）+ `(setq seshat-reader-panel-truncate-lines t)`（改为不折行 + 横向滚动）。
- **面板默认承载改回 side window（2026-10-25）**：`seshat-reader-panel-carrier` 默认值由 `childframe` 改为 **`window`**，`seshat-reader-sidebar-width` 由 `0.24` 改为 `0.25`。**原因**：childframe 不在窗口树内，满高显示时无法避让 frame 底部的 minibuffer 与 `M-x` 补全列表（`*Completions*`），会盖住候选与回显——改用 side window 承载后它天然参与布局，满高也只挤压阅读区。**改后版式**：目录在左（`seshat-reader-outline-sidebar-position` 默认 `left`）、译文/解释在右（`seshat-reader-sidebar-position` 默认 `right`），两者都是满高 side window（贴边、纵向滚动，横向滚动由 `seshat-reader-panel-truncate-lines` 控制），minibuffer 与补全窗口始终可见。**代价**（已接受）：阅读区被挤占约 1/4 宽度，开关面板会触发页面重新适配（窗口尺寸变化 → 阅读器 refit）。**回退到浮层**：`(setq seshat-reader-panel-carrier 'childframe)`（并注意它无法避让底部 minibuffer）。
- **已删除的变量（M12 T8a，2026-10-25）**：`seshat-reader-select-message-limit`（原「框选回显摘要上限 200 字符」的截断阈值）**已删除**——框选回显改为只报 `已复制 N 行 · M 字` / `已选中 N 行 · M 字`（取决于 `seshat-reader-select-copy-to-kill-ring`），不再回显正文。配置里残留的 `setq` 不报错但**不再有效**，删掉即可。

### 阅读器版式、连续布局与批注高亮（P1 起）

> 客户端侧配置（分别由 `seshat-reader` / `seshat-reader-annotation` 读取），与服务端无关。版式类变量（`seshat-reader-sidebar-position` / `-width` / `seshat-reader-outline-sidebar-position` / `-width`）见上一节表格。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-page-gap-lines` | `0` | **页间空行数**（P1 连续布局）：`0` = 相邻页紧贴（与 Android 连续滚动一致），正整数则在上一页底部与下一页顶部之间留这么多空行。这是**分隔区之外**再追加的整行空白（见下面四行）。改动在下次重建版式（重开文档 / `g` / 改缩放 / 触发一次 `seshat-reader--multipage-relayout`）后生效 |
| `seshat-reader-page-separator` | `t` | 是否显示页间**分隔区**（一条横贯窗口的线 + 上下各约 0.25 行留白）。设 `nil` **且** `page-gap-lines` 为 `0` 时完全不产生附加像素，回到改造前的「两页紧贴」。与 `page-gap-lines` 一样在页行插入时读取，改后需重开文档或触发一次重排才生效（无 `:set` 自动重排） |
| `seshat-reader-page-separator-height` | `0.5` | 分隔区**总高**，单位为「默认文本行」，允许小数：`0.5` ≈ 12px（`frame-char-height` 24px 时），线垂直居中、上下各约 0.25 行；`0` = 不占空间。`0.5` 指**整段总高**，不是「线下方空 0.5 行」 |
| `seshat-reader-page-separator-thickness` | `2` | 线的**像素粗细**（整数，夹紧到总高以内）。1px 拿不到——face `:height` 与 1px 图像在真实字体 frame 上的渲染下限都约 2px，故默认 `2`；想更醒目可调 `3`–`4` |
| `seshat-reader-page-separator-face` | `((t (:background "gray70")))` | 线的颜色（**face**，不是 defcustom）：只取 `:background` 填充那条横贯窗口的 stretch space，高度由分隔区几何决定。暗色主题建议改 `gray40` 一类深色 |
| `seshat-reader-scroll-step-ratio` | `0.15` | **一次滚动步长** = 窗口文本区像素高 × 比例。`j` / `k`（以及 remap 的 `next-line` / `previous-line`、`C-n` / `C-p`）与滚轮每档都按它移动，默认约 1/7 屏；比例非正数、或取整后不足 1 像素时回退「一行」= `frame-char-height`（绝不出现「按了没反应」） |
| `seshat-reader-scroll-step-pixels` | `nil` | 非 nil 时**覆盖**上面的比例，把步长钉死为绝对像素（不随窗口大小变化，适合想要固定手感的人）；非正数视同 `nil`，仍走比例 |
| `seshat-reader-multipage-memory-warning-mb` | `75` | 驻留 spec 的**内存估算告警线**（MB）：按每份缓存 spec 的 `data-width × data-height × 4` 估算（canvas 缓冲的 ARGB32 像素；**不翻倍**，Lisp 侧不再有 `:data` 副本。缺 `data-*` 时退回 `:width × :height × 4`，即按逻辑像素计，缩放 frame 下为低估），超过时 `message` 一次（每个 buffer 只报一次，重载 / 清缓存后重新武装）；`nil` 关闭告警 |
| `seshat-reader-annotation-highlight-enabled` | `t` | 是否把批注 `location` 的 `rect:` 段绘制为页面上的半透明高亮。`nil` 时只清空已有高亮并重绘（不添加矩形）；高亮由 C 渲染层绘制，与页面共用同一 `ctm`，故缩放/旋转自动对齐。改动后按 `C-c C-h` 立即刷新 |
| `seshat-reader-annotation-ink-enabled` | `t` | 是否把批注 `location` 的 `ink:` 段绘制为页面手写笔迹（2026-10-25 起）。与 `annotation-highlight-enabled` **互相独立**：关掉它只影响 ink，rect 类装饰照常；ink 的坐标与 `rect:` 同 page space（页面 pt），不翻转 y。改动后按 `C-c C-h` 立即刷新 |
| `seshat-reader-select-flash-duration` | `2.0` | 框选松手后闪现选区高亮的时长（秒），`<= 0` 关闭；不受 `annotation-highlight-enabled` 约束 |
| `seshat-reader-search-limit` | `1024` | 跨页搜索的单页命中请求上限（C 侧夹到 1..10000，且实际收集硬上限也是 1024）；达上限时状态行提示「仅显示前 1024 条」 |
| `seshat-reader-search-max-matches` | `20000` | 整次搜索保留的命中总数上限，达到即停止扫描并提示「命中过多」；`nil` 表示不限制（不推荐，可能占几十 MB） |
| `seshat-reader-search-color` | `(1.0 0.45 0.0)` | 搜索命中的填充色 RGB（默认橙，与批注黄 / 下划线蓝可区分） |
| `seshat-reader-search-alpha` | `0.55` | 搜索命中的填充透明度（比批注 highlight 的 `0.35` 更实，便于叠在已有高亮之上辨认） |

> **已移除（2026-10-27）**：连续布局取代跨页 strip，`seshat-reader-page-join-lines` 不再存在。旧配置里的这一项会成为 free variable（`custom-set-variables` 里留着它不会报错，但**静默无效**），需从 `custom-set-variables` 中删除；同时把 `seshat-reader--page-join-pixels` 一类旧辅助函数的引用一并清掉（它们也已删除）。

说明：

- **avy 是软依赖**：目录面板的 `f` 跳转由本包**零依赖自实现**（`seshat-reader-outline-avy-jump`），未安装 avy 时功能等价；标签字符表优先读 `avy-keys`（avy 已加载且其值为字符列表时），否则退回内置表。按本项目惯例（与 `markdown-mode` / `visual-fill-column` / `etaf-ui` 同类处理），**软依赖不写入 `Package-Requires`**，也不在加载期 `require`。
- **`C-c C-h`**：批注高亮的手动刷新入口（清掉目标页 spec 缓存并重渲染驻留页；C 侧 `--refresh-highlights` 入口已在 2026-10-28 canvas 迁移中删除）；自动刷新发生在打开文档与批注列表增删之后。
- **`o`**：收起/展开左侧目录面板（目录不再 `pop-to-buffer` 抢窗口，改由承载层按 `seshat-reader-outline-sidebar-position` 显示）。只开合目录的命令 `seshat-reader-sidebar-toggle-outline` 不再绑键（与 `o` 功能重复），仍可 `M-x` 调用。

### 阅读器两阶段渲染（P2-B，2026-10-29）

> 客户端侧配置（由 `seshat-reader` 读取），与服务端无关。默认行为**已变更**：滚动进入新页时先只查页尺寸、把页行按最终高度立起来（占位态），像素由 idle / 周期 timer 补上；页高与滚动范围不变、不会跳变。设 `seshat-reader-render-async` 为 `nil` 即完全回到改造前的「逐页同步渲染」。用户视角说明见 [`docs/emacs-reader.md`](emacs-reader.md) §7「两阶段异步渲染」。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-render-async` | `t` | **两阶段渲染开关**。非 nil（默认）时，滚动一步只**同步渲染** point 所在页 + 沿 `seshat-reader--multipage-scroll-direction` 相邻的一页，其余可见页登记进 pending 队列、由 idle / 周期 timer 补像素；`nil` 时完全走旧路径——可见范围逐页同步渲染、队列与两个 timer 一并丢弃，结果布局**逐字节等价**（同页同 spec 写到同一行），只差「什么时候渲染」。该开关在**每一步滚动**都重新读取，改完下一条命令即生效（无需重启/重载）。**它只覆盖 elisp 路径**：C 侧改动（如 `--page-size` 入口、`:scale 1` 修复）必须 `make clean all` 重编 `.so` 并**重启 Emacs** 才生效——动态模块不可卸载 |
| `seshat-reader-render-async-timeout` | `1.0` | pending 队列存活超过该秒数即触发**超时兜底**：下一次 `post-command-hook` 里的 `--multipage-sync` 把**本窗口**可见范围强制同步渲染，并只把这次覆盖到的页出队；幸存队项（其它窗口登记的页 + 同步预取刚登记的一页）**保留**，同时重启计时起点并重排两个 timer，使它们各自拿到完整的超时窗；只有出队后队列为空才整清（队列 + 两个 timer + 时间戳）。队列是 buffer 级并集、强制同步是窗口级操作，故强制同步**永不整队清空**（D8）。计时起点 = 队列首次变为非空的时刻，或**上一次留下队项的强制同步**时刻。**边界**：`0` 或负数 ⇒ 判据 `(> 已存活秒数 超时值)` 恒成立（存活秒数非负且时钟持续推进）⇒ 队列一非空，**下一条命令**就强制同步，等价于「几乎总是同步渲染」；非数字 ⇒ `numberp` 守卫使 `--multipage-async-overdue-p` 恒返回 nil（永不超时，只剩 idle/周期 timer 两条保险）。该值在**检查截止期时**读取，`setq` 立即生效 |
| `seshat-reader-render-idle-delay` | `0.05` | **周期推进间隔**（秒）——**不是**「idle 延迟」。同一个数承担两件事：① 首次推进的 **idle timer 延迟**（该 timer 用 `nil REPEAT` 武装）；② 之后推进队列的 **`run-at-time` 周期 timer 周期**。为什么必须两条：daemon Emacs 里 `run-with-idle-timer` 的一个 idle 窗口**只 fire 一次**（批次 0 的 G3b 实测 ticks=1，无新输入不 re-arm），不能当自续驱动，故 idle 只负责「首轮启动」、周期 timer 负责「持续推进」。`0.05` = 每秒 20 轮，远高于每轮渲染 `render-idle-batch` 页所需（每页几毫秒）。**不建议设为 0**：周期 timer 会几乎无间隔地连续触发，等于占满主线程推进队列 |
| `seshat-reader-render-idle-batch` | `2` | **每轮最多渲染的页数**（单轮成本上限，不是总量上限）。一轮渲染完即返回，剩下的交给周期 timer 的下一拍。存在这个上限的原因是渲染跑在 **Emacs 主线程**：一次渲染整队会让事件循环挨一整块长阻塞，读者感受到的正是异步想消除的那种卡顿。扫描书单页 p95 ≈ 49 ms ⇒ `2` 页时单轮可达 ~100 ms（约一条命令的延迟）；大页 / 扫描书场景建议降到 `1`。`nil` 或非正数按 `1` 处理（`(max 1 (or … 1))`） |

说明：

- **三层兜底**（从快到慢）：① 视口内同步——point 页与滚动方向相邻页永远同步渲染，任何情况下「正在看的页」不会是空白；② 超时强制同步——队列超过 `render-async-timeout` 未排空则下一条命令走同步（唯一不依赖 timer 的保险）；③ 周期推进——idle 首轮 + `run-at-time` 自续（timer 可能因 Emacs 忙而漏拍）。
- **失败 3 次落占位并放弃**：同一页连续渲染失败 3 次后永久移出 pending（不再尝试），页停在占位态；该页**重新进入可见范围**时计数清零重试，代际变化（缩放 / 切暗色 / 重载 / 关文档）时整表清空。
- **观测方式**：这四个选项都是普通 defcustom，`M-x customize-option` 逐个可见（`:group 'seshat-reader`）；不设 `:set` 回调，`setq` / customize 本身不触发重排或重绘（与本包既有版式类选项一致）。

### 阅读器暗色模式配色（2026-10-27）

> 客户端侧配置（由 `seshat-reader` 读取，经原生模块的进程级状态生效），与服务端无关。暗色开关仍是 `M-x seshat-reader-dark-mode`，本节的选项只决定**暗色下页面被映射成哪两色**。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-dark-tint` | `charcoal` | 暗色模式的像素映射配色。取值是 `seshat-reader-dark-tint-presets` 里的预设符号（见下表），或直接给出 `(BG . FG)` 两个 `#xRRGGBB` 整数组成的 cons 自定义配色；`nil` 与 `graphite` 同义（不下发 tint，走旧满量程反色） |

内置预设（`seshat-reader-dark-tint-presets`）：

| 预设 | BG | FG | 观感 |
|---|---|---|---|
| `graphite` | `-1`（哨兵） | `-1`（哨兵） | **不下发 tint**：走 `fz_invert_pixmap_luminance` + `fz_gamma_pixmap(1/1.4)`，像素与改造前逐位一致（白→黑、对比度 21:1） |
| `midnight` | `#x1c1c22` | `#xc8c4ba` | 极暗底 + 冷灰字，对比最低、最省眼 |
| `charcoal`（默认） | `#x26262b` | `#xa8a49a` | 深灰底 + 暖灰字，正文可读性与柔和度折中 |
| `night-sepia` | `#x201d18` | `#xc0b49c` | 暗底 + 旧纸色字，偏暖 |
| `sepia` | `#xe8dfc8` | `#3a342a` | **亮底暗字**的米黄纸观感（不是严格意义的「暗色」，但同属该开关） |

说明：

- **双端压缩，不是反色**：原生模块把每像素亮度线性映射到 BG–FG 之间（最黑的像素画成 BG、最白的画成 FG）。因此暗底不再等于「白变纯黑」，代价是彩色内容被压成**单色调**——彩色插图、彩色封面会失去原有颜色（见 `openspec/tech-debt.md`「暗色 tint 把彩色内容压成单色调」）。
- **`graphite` 是一键回退口**：它的 `(-1 . -1)` 是哨兵而非颜色，表示「不下发 tint」，像素变换退回改造前的满量程反色 + gamma。想要旧观感设 `(setq seshat-reader-dark-tint 'graphite)` 即可，无需降级 `.so`。
- **进程级共享，不是逐 buffer**：配色与开关都由原生模块的进程级 static 承载（`seshat-reader-dyn--doc-invert` / `--doc-tint` 写入），因此**同一 Emacs 内所有 reader buffer 共用同一套配色**，也不能按文档分别设置；反过来**重载文档或新开另一本都保持当前选择**——暗色是用户偏好，不是文档属性。关闭 `seshat-reader-dark-mode` 时**不下发** tint（偏好保留），下次打开仍是同一档。
- **非法值的处置**：未知预设符号、cons 里的元素不是整数或超出 `0..#xFFFFFF` 时，一律按「不下发 tint」处理（即回退旧满对比路径），只在 `*Messages*` 留一条 `message` 说明原因——**不报错、不静默换成另一档配色**。C 侧对 `>0xFFFFFF` 的参数返回 nil 并 `message`，非整数参数则不改状态。
- **改后需重新 toggle**：修改 `seshat-reader-dark-tint` **不会自动重绘**已打开的 buffer——重新 toggle `seshat-reader-dark-mode`（`M-x` 两次）下发新配色，或按 `C-l` 让当前页重新渲染。
- **想逐档试配色用循环命令（即时重绘）**：`M-x seshat-reader-dark-tint-cycle` 按预设表顺序逐档切换 `graphite → midnight → charcoal → night-sepia → sepia`（末档回绕到 `graphite`），`C-u -`（负前缀）反向；当前值若为表外自定义 `(BG . FG)` 或 `nil`，起点视为「表首之前」——反向一步落在表尾前一档（`night-sepia`），这是刻意的循环语义。每次切档都**即时下发并重绘**所有阅读 buffer，**不需要** toggle 也不需要 `C-l`。暗色关着时调用会自动开启（且只重绘一次）；当前值是表外自定义 `(BG . FG)` 或 `nil` 时从表首 `graphite` 起步；非阅读 buffer 里调用只改全局偏好、不重绘。该命令包内**无默认键位**，绑法示例见 `thomas-emacs` 的 `lisp/init-reader.el`（绑在阅读 buffer 的 `T`）。注意它改的仍是全局偏好——**`setq` / `customize` 本身依旧不触发重绘**，这条不受影响。
- **新增预设不改 C 侧**：预设表就在 `seshat-reader.el` 的 `seshat-reader-dark-tint-presets` 里，加档只改 elisp，不需要重编 `seshat-render-core.so`。

配置示例：

```elisp
;; 默认：charcoal（深灰底暖灰字）
(setq seshat-reader-dark-tint 'charcoal)

;; 旧观感（满量程反色 + gamma，改造前的像素）
(setq seshat-reader-dark-tint 'graphite)

;; 亮底暗字的米黄纸
(setq seshat-reader-dark-tint 'sepia)

;; 自定义：BG 与 FG 直接给 #xRRGGBB 整数
(setq seshat-reader-dark-tint (cons #x101014 #xd0ccc0))
```

### 双向引用（M11.4）

> 客户端侧配置（由 `seshat-reader-reference` 读取），与服务端无关。链接有**两种形态**（M8-C 起）：`seshat:uid:<uid>[#<location>]`（身份由服务端 uid 承载，**改名后仍可跟随**）与 `seshat:<tag>:<相对路径>[#<location>]`（人类可读，改名后失效）；新产生的链接能零网络解析出 uid 时用前者，否则回落后者。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-reference-target-file` | `nil` | 摘录/引用写入的目标 org 笔记文件。`nil` 时首次交互询问落点文件，并把所选文件**仅在会话内记忆**（不写回用户配置）；也可直接设为固定路径（可含 `~`）。插入位置由 `seshat-reader-reference-insert-position` 决定（M12 起可配） |
| `seshat-reader-reference-insert-position` | `end-of-file` | 摘录写入目标文件的插入位置：`end-of-file`（文件末尾，与 M12 之前行为一致）/ `headline`（**当前 headline 子树的末尾**，即整个子树之后、下一个同级或更高级 headline 之前；需 `featurep 'org` 且 `derived-mode-p 'org-mode'` 双守卫）/ `point`（目标文件 visiting buffer 中 `point` 处）。后两种在目标文件**没有 visiting buffer** 时一并回退 `end-of-file`——不为支持新语义强行打开用户未打开的笔记 |
| `seshat-reader-reference-format` | `"#+begin_quote\n%s\n#+end_quote\n来源：[[%s][%s]]\n"` | 摘录块模板，三个 `%s` 依次为**正文文本**、**链接**、**链接描述**；正文为空时以空串填充 |

说明：

- 链接格式为 **`seshat:<target>#<location>`**（`#<location>` 可省略）。两种 `<target>` 形态：**uid 形态** `uid:<26 位 Crockford Base32>`（如 `seshat:uid:01J8ZKQ2ABCDEFGHJKMNPQRST#page:112`，改名稳定）与 **doc-id 形态** `<书库标签>:<相对路径>`（如 `seshat:ebook:d2l-zh-pytorch.pdf#page:112`，人类可读）。`location` 与批注的 `location` **同源同构**，不新增解析器；doc-id 形态的 `<书库标签>:<相对路径>` 即批注的 `document_id`（由 `seshat-reader-annotation-roots` 决定）。
- **uid 形态的判别**：`uid:` 之后到第一个 `#` 之前必须是 26 位 Crockford Base32（`[0-9A-HJKMNP-TV-Z]`，排除 I / L / O / U，大小写敏感），否则按 doc-id 解析——因此把根标签取名为 `uid` 仍然合法。
- **`doc-id` 不得包含 `#` 或 `%`**：含这两个字符时生成链接会 `user-error` 并提示重命名文件（本实现不做百分号转义，理由见 [`docs/architecture.md`](architecture.md) 的「`seshat:` 引用协议」小节）。
- 键位：阅读器内 `C-c C-r` 插入**选区摘录**；批注列表 buffer 内 `C-c C-r` 插入**该条批注的引用**（服务端项与本地待同步项都支持，取值不触网）。两条路径与 `M-x org-store-link`、`M-x seshat-reader-reference-copy-link` 一样，**能零网络解析出 uid 时产 uid 形态，否则回落 doc-id 形态**（不报错、不阻塞插入）。
- 阅读器内执行 `M-x org-store-link` 可直接把当前文档（或当前页）存为 `seshat:` 链接；在笔记里 `C-c C-o` 即可跳回对应文档与页码（uid 形态且本地无副本时**按需下载**，软依赖 `seshat-library`）。
- **补全与导出（M12）**：该协议另注册 `:complete`（候选来自 `seshat-reader-annotation-roots` 下的书库文件，当前文档优先，**候选恒为人类可读的 doc-id**）与 `:export`（导出为「文件名 第 N 页」的可读文本，不输出裸 `seshat:` 协议串——下游读者点开假链接比纯文本更有害；uid 形态还原不到文件名时回落 `uid:<前 8 位>…`，**绝不输出空串**）。

**两套根配置是两回事**（M8-C 起这一点会直接影响链接形态）：

| 配置 | 用途 | 形状 |
|---|---|---|
| `seshat-state-roots`（由 `seshat-sync-roots` 在首次同步写入） | **同步**：同步引擎的根映射，含 `MODE` | `(TAG DIR MODE)` |
| `seshat-reader-annotation-roots` | **批注 / 引用**：`document_id` 与 `seshat:` 链接的 doc-id 来源 | `(TAG . DIR)` |

uid 形态的产出要求**两者 tag 一致**（且都能映射到同一本地路径）：`:store` / 摘录 / 批注引用 / `copy-link` 先按 `seshat-reader-annotation-roots` 得 `(tag . 相对路径)`，再用它查同步状态库的 uid 索引；tag 不一致或状态库未登记该路径时**查不到 uid**，新链接回落 doc-id 形态（不报错、不阻塞插入）。

反过来，**已有的 uid 形态链接**在本地查不到路径时（尚未下载 / 换了机器 / 两套根配置事后不一致），链接描述与 `:export` 会回落为 `uid:<前 8 位>…`（如 `uid:01J8ZKQ2…`；uid 长度不大于 8 时原样输出 `uid:<uid>`）——它是「这一步查不到本地路径」的可辨识标识，**不是 bug**，也绝不是空串。`:follow` 对 uid 形态会先按需下载（软依赖 `seshat-library`），因此描述里的回落标识不妨碍打开。（两套根配置统一已记入 [`../openspec/tech-debt.md`](../openspec/tech-debt.md)。）

### ETAF 渲染层（M11.9 引入，M11.10 收敛，可选）

> 面板内容的可选渲染层（`seshat-reader-etaf`），依赖 `etaf-ui`。**ETAF 四仓库不入 notes 仓库**，仅通过 `load-path` 加载；未安装时功能完全不受影响。
>
> **职责边界（M11.10 起）**：ETAF **只渲染批注卡片列表**（页码徽章 / 摘要 / `[待同步]` 标记 / 选中高亮 / 键位提示）。**译文与解释不再经过 ETAF**——它们由 `seshat-reader-translate--render-panel` 写成面板内的只读 Markdown 文本 buffer（`gfm-view-mode` 降级链），原生折行、滚动、复制与 isearch 全部可用，不受 ETAF 固定画布 viewport 裁剪。因此 ETAF 不可用只影响批注列表的观感，**译文/解释功能完全不受影响**。

安装：

```bash
# 首次安装：四个仓库 clone 到 ~/WorkSpace/emacs-taf/
for repo in ecss ebox etaf etaf-ui; do
  git clone --depth 1 "https://github.com/emacs-taf/$repo.git" ~/WorkSpace/emacs-taf/$repo
done

# 编译（四仓库均为纯 Elisp，无 native 依赖）
for repo in ecss ebox etaf etaf-ui; do
  make -C ~/WorkSpace/emacs-taf/$repo compile
done
```

`thomas-emacs/lisp/init-reader.el` 已自动把四个仓库根目录**及各自的 `lisp/`** 加入 `load-path`（**目录存在才加**），并 `(require 'seshat-reader-etaf nil t)`；未安装时该段自动跳过。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-etaf-enabled` | `t` | 是否在 ETAF 可用时用它渲染**批注列表**；`nil` 时批注列表直接走纯文本渲染（`--render-list`），行为与未安装一致。译文/解释不受本开关影响（Markdown 文本 buffer 与 ETAF 无关） |

降级三态（均**不影响**翻译与批注功能，面板不空白）：

| 条件 | 行为 |
|---|---|
| **未安装**（四仓库不在 `load-path`） | `(require 'etaf-ui nil t)` 失败 → 回退纯文本渲染，仅 `message` 提示一次 |
| **半损坏**（`require` 抛错） | `condition-case` 兜底 → 回退纯文本渲染，不中断命令 |
| **渲染抛错**（组件树或 `etaf-mount` 异常） | `condition-case` 捕获 → `message` 警告 + 回退纯文本渲染 |
| `seshat-reader-etaf-enabled` = `nil` | 不进入渲染层，行为同「未安装」 |

上表只影响**批注列表**的呈现；译文/解释走面板内的 Markdown 文本 buffer，**在任何降级状态下都不受影响**（与 ETAF 是否可用无关）。

已知限制：

- **配色不跟随具体主题**：只使用按 `background-mode` 取值的**内置双色板**（明/暗两套），不读取用户主题变量；切换明暗主题后需重新打开（重新渲染）面板才会用上新色。
- **终端 frame 可能不可用**：pty / `emacs -nw` 下 `etaf-mount` 可能挂起（真机 GUI frame 正常），建议在 GUI frame 使用。
- **gt 中转 buffer 已隐藏**：`" *Seshat gt*"` 由本包直接以 `:window-config` = `(display-buffer-no-window)` + `(allow-no-window . t)` 隐藏（缺 `allow-no-window` 时 `display-buffer` 会回退默认动作而弹窗），用户无需自行配置 `display-buffer-alist`。

## Emacs 客户端配置（阅读器适配模式）

> 客户端侧配置（由 `seshat-reader` 读取），与服务端无关。该选项只决定**新窗口 / 新文档的起点**，不影响服务端行为，也不改变已打开窗口。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-default-fit` | `contain` | 新窗口 / 新文档打开时的初始适配模式：`contain` 整页可见（取按宽与按高的较小缩放）、`width` 填满窗口宽度（纵向滚动）、`height` 填满窗口高度（横向滚动） |

旧值兼容（取值经 `seshat-reader--normalize-default-fit` 归一化，无需手工改写配置）：

| 配置值 | 归一化结果 | 说明 |
|---|---|---|
| `contain` | `contain` | 整页可见（默认） |
| `width` | `width` | 填满窗口宽度，纵向溢出靠滚动 |
| `height` | `height` | 填满窗口高度，横向溢出靠滚动 |
| `seshat-reader-fit-to-width` | `width` | 旧函数符号，保留其显式意图（按宽） |
| `seshat-reader-fit-to-height` | `contain` | 旧默认值，保持改造前现状 |
| 其它任意值 | `contain` | 兜底为整页可见，不报错 |

说明：

- 该选项**只决定起点**：`W` / `H` 覆盖当前窗口的适配模式（写入窗口参数 `fit-mode`），且**不跨会话**——窗口关闭或重开 Emacs 后，新窗口回到该初值。
- 手动缩放（`+` / `-` / `=` / `0`）会把窗口标为 manual，**优先于**适配模式；此后尺寸变化只归位滚动、不再自动适配。再按一次 `W` / `H` 即回到适配模式。
- `width` / `height` 模式下页面必然在另一维溢出（需滚动查看），这是「填满一维」的固有代价，不是缺陷。

配置示例：

```elisp
;; 默认：整页可见（取按宽与按高的较小缩放，与改造前行为一致）
(setq seshat-reader-default-fit 'contain)

;; 新窗口默认填满宽度，纵向滚动
(setq seshat-reader-default-fit 'width)

;; 新窗口默认填满高度，横向滚动
(setq seshat-reader-default-fit 'height)

;; 旧写法，仍可用：等价于 'width
(setq seshat-reader-default-fit 'seshat-reader-fit-to-width)
```

> 阅读模式（`seshat-reading-mode`）不引入新的用户配置项：库根由 `seshat-sync-roots` 决定，状态由 `seshat-state-file` 承载。详见 `docs/emacs-reader.md` 的「阅读模式」节。
