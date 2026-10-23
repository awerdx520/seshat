# 配置说明

seshat 服务的配置由三部分组成，优先级从低到高：

1. 内置默认值
2. `config.yaml`（可选，文件不存在时全部使用默认值）
3. 环境变量（仅敏感项）

服务通过 `config.Load(path)` 加载配置。敏感值（数据库密钥、API 令牌、LLM API key）禁止写入配置文件或任何落盘文件，只能通过环境变量注入。

## 配置项一览

| 配置项 | YAML 键 | 环境变量 | 默认值 | 敏感 |
|---|---|---|---|---|
| 监听地址 | `server.addr` | — | `":8080"` | 否 |
| 读超时 | `server.read_timeout` | — | `30s` | 否 |
| 写超时 | `server.write_timeout` | — | `30s` | 否 |
| SQLite 路径 | `db.path` | — | `"./data/seshat.db"` | 否 |
| 笔记根目录 | `webdav.root` | — | `"./data/seshat"` | 否 |
| 公开出口目录 | `webdav.public` | — | `"./data/seshat/public"` | 否 |
| 对外出口只读 | `webdav.public_read_only` | — | `false` | 否 |
| 对外出口写扩展名白名单 | `webdav.public_allow_exts` | — | 空（不限制） | 否 |
| 多根映射 | `webdav.roots` | — | 空（归一为单根 `notes`） | 否 |
| 数据库密钥 | 不可配置（不落盘） | `SESHAT_DB_KEY` | 空 | **是** |
| API 访问令牌 | 不可配置（不落盘） | `SESHAT_AUTH_TOKEN` | 空 | **是** |
| LLM API key | 不可配置（不落盘） | `SESHAT_LLM_API_KEY` | 空 | **是** |
| LLM 节点令牌 | 不可配置（不落盘） | `SESHAT_NODE_TOKEN` | 空 | **是** |
| 本地 LLM 节点 URL | `llm.local_node_url` | — | 空 | 否 |

说明：

- `read_timeout` / `write_timeout` 使用 Go `time.ParseDuration` 支持的字符串格式（如 `30s`、`1m30s`）。
- `server.addr` 等非敏感项当前仅由配置文件控制；敏感项的 YAML 键被忽略，只能通过环境变量提供。
- `webdav.public_read_only` 只作用于对外公开出口（内部同步通道不受影响）。置为 `true` 后对外出口的全部写操作（PUT/MKCOL/DELETE/MOVE/COPY 等）被拒绝，读操作（GET/PROPFIND/HEAD 等）不受影响。
- `webdav.public_allow_exts` 是允许对外出口写入的文件扩展名白名单（如 `[".org", ".md", ".pdf", ".epub"]`），仅在写文件时校验，读操作不受限制；置空表示不限制扩展名。扩展名比较忽略大小写，前导点可省略。
- 两项同时配置时只读优先：只要 `public_read_only` 为 `true`，任何写操作都被拒绝。
- `SESHAT_NODE_TOKEN` 是本地 LLM 处理节点专用令牌（对应 `Config.LLM.NodeToken`），仅保护节点端点（注册 / 轮询 / 回传，最小权限）。未配置时节点端点回退接受主令牌 `SESHAT_AUTH_TOKEN`（向后兼容既有单令牌部署）；配置后主令牌不能访问节点端点、节点令牌也不能访问普通端点，二者经 `auth.NodeMiddleware` 相互隔离。

## 多根映射（`webdav.roots`）

服务端可同时管理多个文档根：**首个为笔记根**（`mirror`：WebDAV 全量镜像 + FTS 索引 + git 版本化），**其余为书库根**（`ondemand`：不挂 WebDAV、不进 FTS，只经 REST 按需读取）。

未配置 `webdav.roots` 时行为与历史版本完全一致——只有一个 `notes` 根，路径取 `webdav.root`。

```yaml
webdav:
  root: "./data/seshat"        # 向后兼容：等价 roots[0].path
  roots:
    - { tag: notes,  path: "./data/seshat" }
    - { tag: ebooks, path: "./data/ebooks", mode: ondemand }
```

### 字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `tag` | 是 | 根标签，作为资源登记与服务端引用（`tag:relpath`）中的根标识。必须**非空**、**唯一**、**不含 `:`**（`:` 是 `tag:path` 语法的分隔符） |
| `path` | 条件必填 | 物理根目录（相对服务进程工作目录）。仅**首根**可留空——留空时回落 `webdav.root`；其余根必须显式配置 |
| `mode` | 否 | 根模式，取 `mirror` 或 `ondemand`；留空按位置推导（见下） |

### `mode` 语义

| 模式 | 位置约束 | WebDAV | FTS 索引 | git 版本化 | 写入口 |
|---|---|---|---|---|---|
| `mirror`（笔记根） | 至多一个，且**必须是首根** | `/dav/` 全量镜像 | 索引 `.org` | 版本化 | WebDAV + REST |
| `ondemand`（书库根） | 只能在第二根起 | 不挂载 | 不索引 | 不管 | 仅 REST 按需读取（写操作被拒绝） |

「mirror 至多一个且必须首根」的理由：FTS 索引与 WebDAV 出口**只挂载首根**，多个 mirror 会让「哪个根对外可写」变得不可判定，故在配置层直接拒绝。

### 归一化与校验

`Load()` 末尾调用 `Config.Validate()`，把配置归一化后**写回** `Config.WebDAV.Roots`（后续代码只读归一形态）：

1. `roots` 为空 → 归一为 `[{ tag: notes, path: webdav.root, mode: mirror }]`（单根向后兼容）；
2. `mode` 留空 → 首根推导为 `mirror`，其余为 `ondemand`；
3. **首根** `path` 留空 → 回落 `webdav.root`（其余根的 `path` 不回落）；
4. 校验：`tag` 非空、唯一、不含 `:`；`path` 非空；`mode` ∈ {`mirror`, `ondemand`}；`mirror` 根至多一个且必须是首根；
5. 归一化幂等——对已归一的结果再次 `Validate()` 不改变内容。

任一校验失败即 `Load()` 返回错误，**服务带着非法根配置无法启动**（错误信息含 `webdav.roots[N]` 下标与 tag，便于定位）。

显式写出的 `mode` 原样保留、不被位置规则改写：单根配 `mode: ondemand` 是合法的（零个 mirror 根被允许，此时没有镜像根可挂 FTS/WebDAV，挂载策略由调用方决定）。

### 与 `webdav.root` 的兼容关系

- `webdav.root` 仍有效，语义等价于 `roots[0].path`；配置了 `roots` 时它们**互不覆盖**（`roots` 显式值优先）。
- 只配 `webdav.root`（不配 `roots`）→ 单根 `notes`，路径为该值，行为与升级前一致。
- 只配 `roots`（保留默认 `webdav.root`）→ 完全以 `roots` 为准；`webdav.root` 仅在 `roots[0].path` 留空时作为回落值。

### 目录与仓库约束（启动期）

上面 4 条归一化规则之外，以下 4 条事实决定「配置能起来」与「写操作会不会失败」：

1. **只有笔记根与公开出口会被自动创建**：启动时 `os.MkdirAll` 只作用于 `roots[0].path`（笔记根）与 `webdav.public`；`roots[1..]`（`ondemand` 书库根）**不会自动创建**。书库根目录不存在时，启动期的 bootstrap 扫描该根失败 → 服务**以非零码退出**（日志 `seshat 服务退出` 携带 `读取根目录失败` 与该根的物理路径），不会把缺失目录静默当成空根继续服务。部署时需自行创建好 `ondemand` 根目录。
2. **mirror 根的 `path` 必须与 git 仓库根一致**：服务端以首根路径初始化版本库，而 git 写方法接受「仓库内相对路径」。配置漂移（两处指向不同目录）时 `/api/files` 的写端点直接返回 `500 internal`（错误信息只带根 tag，不回物理路径），宁可报错也不静默写到错误位置。
3. **`webdav.public` 应是笔记根的子目录**：公开出口相对笔记根的偏移 `offset` 由 `filepath.Rel(笔记根, public)` **自动计算**（如 `public`），用于把对外请求路径换算成仓库内路径（ETag blob hash 与 FTS key 都按仓库内路径计算）。若配置在笔记根**之外**，启动时只告警（`公开出口不在笔记根目录内…`）不阻止启动：此时对外写入不在 git 工作区内，**写后不产生 commit**，ETag 也退化为 mtime 启发式。
4. **`mode` 的归一化口径**：`mode` 留空时按位置推导——**首根默认 `mirror`，其余默认 `ondemand`**；显式写出的 `mode` 原样保留（单根配 `ondemand` 合法）。`mirror` 根**至多一个且必须位于首根**，违反即启动失败（FTS 索引与 WebDAV 出口只挂载首根，多个 mirror 会让「哪个根对外可写」不可判定）。

## 敏感值处理

敏感项对应的结构体字段标记为 `yaml:"-"`，因此：

- 无法通过 `config.yaml` 或任何配置文件提供；
- 即使配置文件中出现同名键（如 `db.key`），也会被忽略；
- 序列化（`yaml.Marshal`）时不会输出敏感值。

敏感值只能由部署环境通过环境变量注入：

```bash
export SESHAT_DB_KEY=...        # → Config.DB.Key
export SESHAT_AUTH_TOKEN=...    # → Config.Auth.Token
export SESHAT_LLM_API_KEY=...   # → Config.LLM.CloudAPIKey
export SESHAT_NODE_TOKEN=...    # → Config.LLM.NodeToken
```

## Emacs 客户端配置（批注侧车）

> 本节为**客户端侧**配置（`notes/emacs/`），与服务端 `config.yaml` / 环境变量无关，不影响服务端行为。

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

### 阅读器翻译 / 解释（go-translate 预设）

> 与批注侧车同属**客户端侧**配置（由 `seshat-reader-translate` 模块读取），与服务端无关。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-translate-preset` | `reader` | 「翻译」使用的 gt 预设名（阅读器按名从 `gt-preset-translators` 取用） |
| `seshat-reader-translate-explain-preset` | `reader-explain` | 「解释」使用的 gt 预设名（通常指向 `gt-chatgpt-engine`） |
| `seshat-reader-translate-fallback-langs` | `(en zh)` | 语言回退：源语言取本列表首项，目标语言由此推导（可由命令前缀参数覆盖） |
| `seshat-reader-translate-render` | `sidebar` | 译文/解释呈现方式：`sidebar`（默认，写入**底部面板内的 Markdown 文本 buffer**——`gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链，原生折行/滚动/复制/isearch 可用，**不经 ETAF 排版**）、`pop`（posframe 弹出，超时自动消失）或 `pin`（posframe 固定停留）。取 `sidebar` 但 `seshat-reader-sidebar-enabled` 为 nil 时退回 `pop` 式 posframe |
| `seshat-reader-translate-show-source` | `t` | 是否在面板正文前插入**选中原文的引用块**（`> **原文**` + 每行 `> ` 前缀、不截断）。**默认开启**（便于对照原文与译文）；设 `nil` 关闭，面板更紧凑 |
| `seshat-reader-translate-template` | `"%l\n\n%q\n\n---\n\n%t\n"` | **翻译**面板的 Markdown 模板；`nil` 表示不套模板、直接插入正文。默认**不含标题**（`header-line` 显示「Seshat 译文」/「Seshat 解释」）；`%k` 标题占位符保留供自定义模板使用。占位符：`%k` 标题、`%l` 语言对（斜体，如 `*en → zh*`；无 langs 时留空）、`%q` 原文引用块、`%t` 正文。模板非法（未知占位符等）时回退纯正文并 `message` 警告 |
| `seshat-reader-translate-explain-template` | `"%q\n\n---\n\n%t\n"` | **解释**面板的独立 Markdown 模板；默认不含标题与语言对（解释场景前者由 `header-line` 承担、后者信息价值低），占位符与上一行相同。`nil` 退回纯正文，**不会借用** `seshat-reader-translate-template` |
| `seshat-reader-translate-visual-fill-column` | `t` | 译文/解释面板启用 `visual-fill-column-mode`（**软依赖**，未安装时静默跳过），按 `visual-fill-column-width`（`nil` → `fill-column`）缩窄正文；设 `nil` 关闭并清理窗口 margin；批注列表不受影响（ETAF 按窗口宽度布局） |

说明：

- `reader` / `reader-explain` 两个 gt 预设**需在用户配置侧定义**（示例见 `thomas-emacs/lisp/init-tools.el`）；阅读器侧只按预设名取用，缺失时回退内置默认（翻译回退 youdao/google，解释需显式配置端点）。
- gt 的 key（如 `gt-chatgpt-key`）**一律走 authinfo / 环境变量**（本项目经 `DEEPSEEK_API_KEY` 环境变量注入），**禁止写入配置文件**。

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
| `seshat-reader-sidebar-width` | `0.24` | 信息栏在 `left` / `right` 下的宽度：**小数**按 frame 根窗口总宽的比例换算为列数，**整数**直接作列数。仅 side 模式生效（底部模式改用 `seshat-reader-sidebar-height`），且改动仅对**新建**面板窗口生效 |
| `seshat-reader-outline-sidebar-position` | `left` | **目录栏**（`outline`）的弹出位置，取值同 `seshat-reader-sidebar-position` 的四项，但只作用于目录面板；默认与信息栏分居两侧，构成「左目录 / 右信息 / 中间阅读区」 |
| `seshat-reader-outline-sidebar-width` | `0.20` | 目录栏在 `left` / `right` 下的宽度（语义同 `seshat-reader-sidebar-width`，默认更窄——目录标题通常短于批注/译文卡片）。仅 side 模式生效 |
| `seshat-reader-sidebar-height` | `0.35` | 面板**首次显示**时的初始高度，作为 `display-buffer` 的 `window-height`（按比例）；译文/解释面板随后按内容自适应（见 `seshat-reader-sidebar-min-height` / `seshat-reader-sidebar-max-height`），批注列表固定用本值。改动仅对**新建**面板窗口生效，对已显示窗口不自动重排 |
| `seshat-reader-sidebar-max-height` | `0.8` | 译文/解释面板按内容自适应时的**高度上限**（占 frame 比例）；自适应范围夹紧在 `seshat-reader-sidebar-min-height`（默认 0.25）与本值之间。仅对 `translate` 且未挂载 ETAF runtime 的面板生效，批注列表固定高度不受影响 |
| `seshat-reader-sidebar-min-height` | `0.25` | 译文/解释面板按内容自适应的**下限**（占 frame 比例，至少 1 行）；与 `max-height` 共同夹紧。仅对 `translate` 且未挂载 ETAF runtime 的面板生效，批注列表不受影响；`min` 配得比 `max` 大时以 `max` 为准 |
| `seshat-reader-sidebar-select-window` | `t` | 面板显示后是否在**命令结束时**把光标移入面板（`display-buffer` 的 `post-command-select-window`）；`nil` 时光标留在原窗口 |
| `seshat-reader-sidebar-translate-buffer-name` | `"*Seshat Sidebar*"` | 译文/解释的**展示 buffer** 名（只读 Markdown 文本 buffer，也是 popper 判定的名字之一）；gt 中转改用隐藏 buffer ` *Seshat gt*`，本变量不再作 gt `:name`、也不再作结果捕获的守卫依据 |

说明：

- **三栏版式（M12）**：`left` / `right` 下侧栏是 **side window**（`display-buffer-in-side-window` + 独立 slot），显示/收起不挤压阅读区；且侧栏是 **per-kind 独立窗口**——目录（默认 `left`）与批注/译文（默认 `right`）可同时存在，不再「后显示者接管」，`o` 收起/展开左侧目录（只开合目录的命令 `seshat-reader-sidebar-toggle-outline` 不再绑键，仍可 `M-x` 调用）。底部模式（`below-selected` / `at-bottom`）仍是单窗口、后显示者接管（M11 语义，非缺陷）。
- **破坏性变更与回退（M12）**：`seshat-reader-sidebar-position` 默认值由 `below-selected` 改为 `right`，升级后批注/译文面板出现在**右侧**而非底部。恢复旧观感：`(setq seshat-reader-sidebar-position 'below-selected)`；`left` / `right` 为 M12 新增取值，`below-selected` / `at-bottom` 仍然可用。
- **译文/解释为 Markdown 文本 buffer**：面板正文是普通只读 buffer，用 `gfm-view-mode`（缺失时降级 `markdown-view-mode` / `text-mode`）渲染，`truncate-lines` 为 nil 且显式开 `word-wrap`；`header-line` 显示「Seshat 译文」/「Seshat 解释」；`q`（关面板）与 `C-c C-s`（存为批注）由 minor mode `seshat-reader-translate-panel-mode` 承载。**markdown-mode 为软依赖**：未安装时降级 `text-mode`（不折行美化、不隐藏标记），功能仍可用。正文按模板渲染——翻译面板用 `seshat-reader-translate-template`（默认「语言对 + 原文块 + 分隔线 + 正文」）、解释面板用 `seshat-reader-translate-explain-template`（默认「原文块 + 分隔线 + 正文」）；两者默认都**不含正文标题**，因为 `header-line` 已显示「Seshat 译文」/「Seshat 解释」，需要正文标题时自定义模板加 `%k`（或设模板为 `nil` 退回纯正文）。
- **高度自适应**：译文/解释面板显示后按内容实际行数（`window-text-pixel-size` 换算）调整高度，夹紧 `seshat-reader-sidebar-min-height`（默认 0.25）到 `seshat-reader-sidebar-max-height`（默认 0.8），并把实测比例写入该 kind 的高度记忆；同帧内面板增高会压缩上方阅读窗口（预期行为）。单行像素高取首行 `line-pixel-height` 与 `frame-char-height` 的**较小值**（Markdown 标题行通常比正文行高，直接用首行会把内容行数低估），测量上限 120 行（超长内容按上限计，避免测量耗时）。
- **连续流展示**：批注列表**不分页**，全量条目一次性单列渲染（无页脚、无 `]`/`[` 翻页键）；徽章始终显示「N 条」，`n`/`p` 只移动选中、不再切页。列表超出面板高度时由**面板窗口**滚动查看；ETAF 渲染层按条目数显式计算 viewport 高度（`--content-viewport-height`，已挂载时经 `etaf-runtime-refit` 放大），保证新增条目不被裁剪。
- **per-kind 尺寸记忆（仅会话内，带方向标签）**：M11 的单窗口语义下同一时刻只有一个面板窗口，但 `annotations` 与 `translate` **各自记住自己的尺寸**——切换内容前先把当前窗口的实际尺寸（比例）记给它的类型，再用目标类型记住的尺寸新建窗口；同一类型重复显示走 `display-buffer` 复用，不重建、也不重置用户手动调整过的尺寸。M12 起记忆项带**方向标签**（宽度语义 vs 高度语义），因此把方位在 `left`/`right` 与 `below-selected`/`at-bottom` 之间切换时，旧值不会被按错误单位复用。某类型首次显示时，side 模式用 `seshat-reader-sidebar-width` / `seshat-reader-outline-sidebar-width`，底部模式用 `seshat-reader-sidebar-height`。状态保存在内存 alist 中，**重启 Emacs 后回到默认值**。
- **关闭**：面板是非固定窗口；面板内 `q` 由 minor mode 承载（批注列表与译文面板各有其 minor mode 键位），`seshat-reader-sidebar-toggle` 可开合（关闭本包面板窗口，打开时按最近一次的内容类型重开，含 `translate`）。toggle **不使用** `window-toggle-side-windows`——它是 frame 级全量开关，会连带删除/恢复 eca-chat、which-key 的侧窗。
- **popper 集成**：`*Seshat Annotations*` 与 `*Seshat Sidebar*` 两个 buffer 名已在 `thomas-emacs/lisp/init-window.el` 登记为 popper popup，可用 `C-'` 或 `` M-` `` 开关；popper 重开时经 `seshat-reader-sidebar-display-buffer` 分流回本包的显示逻辑，因此**布局（`position` / `width` / `height` / per-kind 尺寸）仍由本包掌控**，不会被 popper 的默认 bottom side window 规则改写。该分流由用户配置侧（`init-window.el`）接入，本包只提供函数。

### 阅读器版式、跨页衔接与批注高亮（M12）

> 客户端侧配置（分别由 `seshat-reader` / `seshat-reader-annotation` 读取），与服务端无关。版式类变量（`seshat-reader-sidebar-position` / `-width` / `seshat-reader-outline-sidebar-position` / `-width`）见上一节表格。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-page-join-lines` | `0` | 跨页衔接 strip 的高度，**单位是页面文本行高**（允许小数）。翻页时在当前页 image 上方插入一行显示上一页底部，形成阅读上下文；设 `0` 完全关闭，翻页行为与 M12 之前一致。改动在下次翻页生效。**默认关闭**：strip 行与页面 overlay 的几何存在已知冲突，开启后 `fit-to-height` 等整页操作可能裁切页面（见 `openspec/tech-debt.md`「跨页衔接（M12 strip）在 fit-to-height 下裁切页面」） |
| `seshat-reader-annotation-highlight-enabled` | `t` | 是否把批注 `location` 的 `rect:` 段绘制为页面上的半透明高亮。`nil` 时只清空已有高亮并重绘（不添加矩形）；高亮由 C 渲染层绘制，与页面共用同一 `ctm`，故缩放/旋转自动对齐。改动后按 `C-c C-h` 立即刷新 |
| `seshat-reader-select-flash-duration` | `2.0` | 框选松手后闪现选区高亮的时长（秒），`<= 0` 关闭；不受 `annotation-highlight-enabled` 约束 |

说明：

- **avy 是软依赖**：目录面板的 `f` 跳转由本包**零依赖自实现**（`seshat-reader-outline-avy-jump`），未安装 avy 时功能等价；标签字符表优先读 `avy-keys`（avy 已加载且其值为字符列表时），否则退回内置表。按本项目惯例（与 `markdown-mode` / `visual-fill-column` / `etaf-ui` 同类处理），**软依赖不写入 `Package-Requires`**，也不在加载期 `require`。
- **`C-c C-h`**：批注高亮的手动刷新入口（重投当前文档的矩形并触发 C 侧 `--refresh-highlights`）；自动刷新发生在打开文档与批注列表增删之后。
- **`o`**：收起/展开左侧目录面板（目录不再 `pop-to-buffer` 抢窗口，改由承载层按 `seshat-reader-outline-sidebar-position` 显示）。只开合目录的命令 `seshat-reader-sidebar-toggle-outline` 不再绑键（与 `o` 功能重复），仍可 `M-x` 调用。

### 双向引用（M11.4）

> 客户端侧配置（由 `seshat-reader-reference` 读取），与服务端无关。链接仅以 **doc-id 文本**承载身份，不依赖尚未实现的服务端 uid。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-reference-target-file` | `nil` | 摘录/引用写入的目标 org 笔记文件。`nil` 时首次交互询问落点文件，并把所选文件**仅在会话内记忆**（不写回用户配置）；也可直接设为固定路径（可含 `~`）。插入位置由 `seshat-reader-reference-insert-position` 决定（M12 起可配） |
| `seshat-reader-reference-insert-position` | `end-of-file` | 摘录写入目标文件的插入位置：`end-of-file`（文件末尾，与 M12 之前行为一致）/ `headline`（**当前 headline 子树的末尾**，即整个子树之后、下一个同级或更高级 headline 之前；需 `featurep 'org` 且 `derived-mode-p 'org-mode'` 双守卫）/ `point`（目标文件 visiting buffer 中 `point` 处）。后两种在目标文件**没有 visiting buffer** 时一并回退 `end-of-file`——不为支持新语义强行打开用户未打开的笔记 |
| `seshat-reader-reference-format` | `"#+begin_quote\n%s\n#+end_quote\n来源：[[%s][%s]]\n"` | 摘录块模板，三个 `%s` 依次为**正文文本**、**链接**、**链接描述**；正文为空时以空串填充 |

说明：

- 链接格式为 **`seshat:<doc-id>#<location>`**（`#<location>` 可省略），例如 `seshat:ebook:d2l-zh-pytorch.pdf#page:112`。`doc-id` 即批注的 `document_id`（`<书库标签>:<相对路径>`，由 `seshat-reader-annotation-roots` 决定），`location` 与批注的 `location` **同源同构**，不新增解析器。
- **`doc-id` 不得包含 `#` 或 `%`**：含这两个字符时生成链接会 `user-error` 并提示重命名文件（本实现不做百分号转义，理由见 [`docs/architecture.md`](architecture.md) 的「`seshat:` 引用协议」小节）。
- 键位：阅读器内 `C-c C-r` 插入**选区摘录**；批注列表 buffer 内 `C-c C-r` 插入**该条批注的引用**（服务端项与本地待同步项都支持，取值不触网）。
- 阅读器内执行 `M-x org-store-link` 可直接把当前文档（或当前页）存为 `seshat:` 链接；在笔记里 `C-c C-o` 即可跳回对应文档与页码。
- **补全与导出（M12）**：该协议另注册 `:complete`（候选来自 `seshat-reader-annotation-roots` 下的书库文件，当前文档优先）与 `:export`（导出为「文件名 第 N 页」的可读文本，不输出裸 `seshat:` 协议串——下游读者点开假链接比纯文本更有害）。

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

## 相关文件

- 示例配置：[`config.example.yaml`](../config.example.yaml)
