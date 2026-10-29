# 架构设计

> **服务端架构已迁出**：服务端（REST/WebDAV/存储/身份登记/路径安全/模块装配）的架构说明见 keystone 仓 `docs/architecture.md`。本文件只描述客户端（Emacs + Android）架构。

## 概述

个人笔记同步系统是单用户、云 VPS 自托管的个人知识中枢，三端协作 + LLM 增值：

- 桌面端 Emacs（org-mode）负责笔记编辑，文件同步复用 org-mode 设施
- Android 端负责电子书阅读/批注（epub/pdf，mobi 转 epub）与 org GTD 查看
- 服务端统一汇总文件、附件与三端阅读状态，提供 WebDAV、REST、git 版本化、静态加密、全文索引与 LLM 能力

## 核心决策（P0，用户确认）

1. 加密语义：静态加密（SQLCipher + 磁盘 LUKS，服务端可读明文做索引）
2. 技术栈：服务端 Go、Android Kotlin 原生、桌面端 elisp
3. 部署：云 VPS
4. WebDAV：双重定位（内部同步通道 + 对外标准出口）
5. 访问控制：单用户（Bearer 令牌 + WebDAV Basic Auth 同令牌）
6. 冲突处理：服务端 git 版本化 + ETag 乐观锁 + 自有客户端三方合并（ADR-001）
7. 对外 WebDAV：可读写 + 范围受限（笔记目录 + 文件类型白名单）+ 每次写自动 commit
8. LLM 后端：混合（云端 API + 本地处理节点），本地节点为纯推理节点、结果明文回传，无 E2EE（ADR-002）

## 客户端侧批注同步约定（离线优先）

Emacs 阅读器（`seshat-reader`）的批注同步在客户端侧叠加一层**离线队列**，用于吸收服务端不可用时的创建/删除操作。约定如下：

- **离线入队**：create/delete 在服务端不可用时写入本地队列（`seshat-reader-annotation-queue-file`，原子写），不报错；列表离线时仍渲染本地项并标 `[待同步]`。
- **create 幂等去重**：同步前先拉取该文档现有批注，比对 `(location, text)`；若已存在完全相同的批注即视为已同步、**不重复 POST**。
- **delete 视为成功**：删除返回的 **404 视为成功**（幂等删除——服务端已无此批注即达成目标）；其它非 2xx 或异常才停止本轮。
- **失败即停**：任一条同步失败即停止本轮，该条及其后续项保留在队列中待下次同步（不丢弃、不报错）。
- **服务端零改动**：队列与同步均为**客户端侧**行为，不改变服务端 REST 契约（端点行为与 `location`/`text` 语义不变；文档键 M7 起为 uid，队列条目相应携带 `:uid`，缺 `:uid` 的旧条目跳过并提示）。

## Emacs 客户端同步分层（M8-A）

M8 把 Emacs 端同步器从 WebDAV 传输迁到 REST，分三层落地，本节点只记录地基（计划 A）已完成的部分：

| 层 | 文件 | 职责 |
|---|---|---|
| 传输层 | `emacs/seshat-transport.el` | 统一 HTTP 契约 `(:status :headers :body)`；**永不抛错**（失败只回报 `:status nil` + `:error`）；后端可换：`rest`（`url.el` + Bearer，默认）与 `webdav`（`curl` + Basic，灰度期保留） |
| API 层 | `emacs/seshat-rest.el` | 服务端端点封装（roots / resources / changes / files / move / versions）与统一状态码解释；`seshat-rest--request` 保留为**薄包装**（旧 `(status . body)` 契约 + 抛错语义不变，保护既有 4 处调用方） |
| 状态层 | `emacs/seshat-state.el` | 单一 `.eld` 原子写：全局 `cursor`、per-uid `base-blob`（取代旧的单文件 head）、`uid ↔ (root . path)` 双索引、`dirty` 集合、墓碑 |

**分层约束**：传输层抛错责任在 API 层，不得上提；二进制下载必须传 `:binary t`（否则 `url.el` 后端会按 UTF-8 解码破坏字节）。**接入进度**：M8-B 已接入增量循环、条件写、move 检测与冲突合并（见下一节）；计划 C（M8-C）已补上书架 / 按需取书与 `seshat:` uid 形态的 follow（见「书架与按需取书（M8-C）」节）。

## Emacs 增量同步引擎（M8-B）

M8-B 把同步从「全量遍历 + 路径身份 + WebDAV 弱乐观锁」切到「增量游标 + uid 身份 + REST 条件写」。执行顺序固定：

```
seshat-sync-now
  ├─ seshat-sync-pull          首同步：预建索引 → changes 追平取游标
  │                            增量：从状态库游标继续
  ├─ seshat-sync-detect-renames 本地 size/mtime 快照比对 → mark-dirty；rename 配对 → POST move
  ├─ seshat-sync-push          遍历 dirty → If-Match / If-None-Match 条件写 → 412 走三方合并
  └─ seshat-sync-status        逐 uid 拉阅读进度（失败不阻塞前三步）
```

**三条不变量**：

1. **游标最后写**：每批「apply → 批量块退出重建索引 → 推进游标 → 落盘」，中断后从落盘游标重放是幂等的；
2. **首同步职责分离**：`changes?since=0` 是权威全集，`/api/resources` 分页只是尽力而为的预建（同秒超一页会丢记录，由 changes 补齐）；
3. **零交互**：push 的 412 分支与 rename 检测都可能由定时器触发，任何分支都不得询问用户或用 smerge 进入文件；冲突标记写回本地后提示用户手动处理。

**根映射**：`seshat-sync-roots`（`(TAG DIR MODE)`）是唯一配置入口，`seshat-sync--ensure-roots` 在首次 pull 时把它写入状态库（`MODE` 为 nil 时向 `GET /api/roots` 取权威值）；改配置后需 `M-x seshat-sync-reset-roots`。

## 书架与按需取书（M8-C）

M8-C 在 M8-A/M8-B 之上新增**一层**：`emacs/seshat-library.el`（项目层，与 `seshat-sync.el` / `seshat-state.el` 同级，**不属于** vendored 的 `seshat-reader` 包）。它补的是同步引擎留下的两个缺口——`ondemand` 根「只登记不下载」与「本地副本无刷新入口」。

| 层 | 文件 | 职责 |
|---|---|---|
| 数据层 | `emacs/seshat-library.el`（`seshat-library--entries-local` / `--entries-cached` / `--entries-merge` / `--state-for` / `seshat-library-fetch`） | **本地状态库为主源 + 远端缓存增强**：`seshat-state-entries` 枚举书目（零网络）、`library-cache.eld` 补远端清单、D1 策略合并（以状态库为准，缓存独有项以 `unregistered` 出现）、按需取书（六步事务，见 [`docs/emacs-reader.md`](emacs-reader.md)「书架（离线优先）」） |
| UI 层 | 同一文件的 `seshat-library-mode`（**自建 `special-mode` buffer + 显式分页**）+ `seshat-library` / `-open-at-point` / `-refresh-at-point` / `-refresh-remote` / `-delete-local-at-point` / `-delete-marked` / `-toggle-mark` / `-dired-at-point` / `-next-page` / `-previous-page` / `-first-page` / `-last-page` / `-filter-keyword` / `-filter-state` / `-sort-cycle` | 书架 buffer `*Seshat Library*`：一条目一行 = 行首标记 + 行内封面 image（固定像素高）+ 书名 · 根 · 大小 · 进度 · 待同步 · 状态；只渲染当前页（`seshat-library-page-size`，默认 30）；**15 键位**（`RET` / `u` / `d` / `x` / `m` / `D` / `n` / `p` / `M-<` / `M->` / `g` / `/` / `F` / `s` / `q`） |

**依赖方向（单向，无环）**：

| 依赖 | 内容 |
|---|---|
| `seshat-library` → `seshat-rest` / `seshat-state` / `seshat-sync` | 项目层依赖基础设施层与引擎层（路径校验、游标推进、位置登记） |
| `seshat-library` → `seshat-reading` → `seshat-reader/**` | 书架 `RET` 经 `seshat-reading-open` 打开文档（单向：library → reading → reader） |
| `seshat-reader/**` 不得依赖 `seshat-library` | **禁止反向 require**：reader 是 vendored 包，需取书的两处一律软依赖（`fboundp` 探测 + `declare-function`） |

- `seshat-library` 复用 `seshat-sync` 的**路径安全校验**（`seshat-sync--local-path`）、**游标推进**（`seshat-sync--next-since-mtime`）与**位置登记**（`seshat-sync--event-set-location`），不另写一份——另写必然与引擎漂移。
- `emacs/seshat-reader/**` **不得 require** `seshat-library`：reader 是 vendored 包，反向依赖会让它在没有项目层时无法加载。需要取书的两处一律**软依赖**：`fboundp` 探测 + `declare-function`（`seshat-reader-reference--fetch-library` 调 `seshat-library-fetch`；`:follow` 的 uid 分支由它托管）。缺函数时 `user-error` 说明缺什么，**不自行 require**（否则成环）。
- `seshat-reading-open` 也是软依赖：`seshat-library` 用 `(require 'seshat-reading nil t)` 探测，缺失时书架 `RET` 退化为 `find-file`——可选依赖缺失不该让「打开一本书」失败。

**三条不变量**：

1. **`d`（删本地副本）零网络**：只用 buffer-local 缓存的清单重算状态列并重绘该行（`seshat-library--refresh-item-state` / `seshat-library--redraw-line`），不走「重拉远端清单」那条路。远端文件一律保留。
2. **所有落盘路径都过 `seshat-sync--local-path`**：服务端下发的相对路径不可信（拒绝 `..`、绝对路径、盘符、`~`、符号链接逃逸），取书与删本地副本共用这一处校验，不自行拼路径字符串。
3. **`ondemand` 根绝不写远端**：`seshat-library` 只发 `GET`；服务端对书库根的写入本就 `403 root_read_only`，客户端不制造撞墙的机会。

**为什么书架读的是状态库而不是配置变量**：`seshat-library--roots` 从 `seshat-state-roots`（状态库里的根映射）筛 `MODE` 为 `ondemand` 的根——与同步引擎同源，避免「书架认一套根、同步认另一套」。代价是**首次使用前必须先跑过一次同步**（`M-x seshat-sync-now` 把 `seshat-sync-roots` 写入状态库），改配置后需 `M-x seshat-sync-reset-roots`。

## 书架离线层（2026-10-29）

2026-10-29 一轮把书架从「打开即拉远端清单」改为**离线优先**：主源换成本地状态库，远端降级为可选增强 + 落盘缓存，UI 从列式表格（内置表格库）改为自建 `special-mode` buffer + 显式分页。动机与备选方案见 [`docs/adr/0006-offline-first-library.md`](adr/0006-offline-first-library.md)。

**分层与职责**：

| 模块 | 职责 | 依赖 |
|---|---|---|
| `emacs/seshat-log.el` | 分级日志（`seshat-log`）+ `*Seshat Log*` ring（`seshat-log-max-lines` 默认 2000 行，超出从头部裁剪）+ 静默层（`seshat-log-quiet`：自动路径不写 echo，`error` 级例外） | 零依赖 |
| `emacs/seshat-state.el` | 状态库：uid → `(root . path)` 登记、根映射、墓碑 / 孤儿、`seshat-state-entries`（只含活条目） | 基础设施层 |
| `emacs/seshat-reads.el` | 阅读进度侧车 `reads.eld`（`seshat-reads-get` / `-record` / `-percent`），落盘去抖 `seshat-reads-debounce` | 纯本地文件系统 |
| `emacs/seshat-covers.el` | 封面三级回退（EPUB `unzip` → PDF `mutool` → 占位）+ 缓存目录 + 负缓存 + idle 串行队列 | 纯本地文件系统（**禁止 require `seshat-rest`**） |
| `emacs/seshat-library.el` | 书架数据层 + UI：三层取数、D1 合并、过滤 / 排序 / 分页（纯函数）、封面驻留管理、15 键位 | `state` / `reads` / `covers` / `log` / `rest` / `sync`；软依赖 `seshat-reading`、`seshat-reader-annotation-queue` |
| `emacs/seshat-status.el` | 启动后一次汇总（`seshat-status-startup-notify` / `-startup-delay`）+ 详情 buffer `*Seshat Status*` | `state` / `reads` / queue / `log`；**禁止 require `seshat-rest`**（可达性只读状态库 `:runtime`，启动不探测网络） |

**依赖方向（与实现一致，单向无环）**：

| 依赖 | 内容 |
|---|---|
| 所有模块 → `seshat-log` | 日志是叶子，谁都可以 require 它 |
| `seshat-library` → `seshat-state` / `seshat-reads` / `seshat-covers` / `seshat-log` / `seshat-rest` / `seshat-sync` | 数据层拿本地事实 + 取书；封面与进度是纯本地只读依赖 |
| `seshat-status` → `seshat-state` / `seshat-reads` / `seshat-reader-annotation-queue` / `seshat-log` | 汇总只读本地事实，**不** require `seshat-rest` |
| `seshat-library` ⇢ `seshat-reading` / `seshat-reader-annotation-queue` | **软依赖**（`require … nil t` + `fboundp`）：缺失时 `RET` 退化为 `find-file`、「待同步」段省略 |
| `seshat-reader/**` ⇢ `seshat-library` | 仍**禁止反向 require**（vendored 包），取书一律 `fboundp` + `declare-function` |

**三条机械不变量**（都可在 ERT 里判定，不靠人工约定）：

| 不变量 | 断言内容 | 守护点 |
|---|---|---|
| **I-OOM** | 任一时刻驻留（已构造、未 flush）的 image 个数 ≤ `seshat-library-page-size`；对**非当前页**条目的封面文件 / 文档解析次数为 0 | 唯一构造点 `seshat-library--make-cover-image` + 驻留表 `seshat-library--resident`（buffer-local）+ `--render` 只插当前页、插入前释放离开页 |
| **I-NONET** | 打开 / 翻页 / 过滤 / 排序 / 删本地 / 批量删 / 标记 / `D` / 启动汇总 / 进度侧车只读路径 / 封面只读路径 / 日志：**零网络** | 三层网络入口全部桩成 `error`（见下） |
| **I-READONLY** | `ondemand` 根**不发写请求**；所有落盘路径过 `seshat-sync--local-path` | 根归属门 `seshat-library--ondemand-root-p` + 取书事务的越界校验；服务端侧本就 `403 root_read_only` |

**网络三层（为什么必须三层全钉）**：清单请求走的是 `seshat-rest-list-resources`，它**直连** `seshat-transport-request`（要拿响应头做 `:since-mtime` 翻页），**不经**薄包装 `seshat-rest--request`。因此只桩薄包装会漏掉真正的清单路径。`seshat-offline-invariant-test.el` 把 `seshat-rest--request` / `seshat-transport-request` / `url-retrieve-synchronously` **三层都绑成抛错函数**，再跑书架全链路；另有一个自检用例证明「`g` 在同样的桩下必须失败」——否则那些 I-NONET 用例可能只是「根本没走到网络」的假绿。

**反假绿设计（重点，为什么这么切）**：

- `seshat-library--make-cover-image` 是**唯一** image 构造点，且函数体**不含** `display-graphic-p`——`create-image` 在 `emacs --batch` 下是安全的，构造与「能否显示」是两件事。有专门用例按函数体文本断言这一点（`seshat-library-make-cover-image-has-no-display-graphic-p`）。
- `seshat-library--insert-cover` 是**唯一**显示检查点，且 `display-graphic-p` 判断**在构造之前**。顺序不能反：若先构造再判断「不显示」，看不见的 image 会白占驻留预算（I-OOM 的「驻留 ≤ 一页」随之失去意义）；若把判断挪进 `--make-cover-image`，测试桩 `display-graphic-p` 为 `t` 之后**正断言 P 依然成立**——自检失效。
- 正断言 **P**：桩 `display-graphic-p` 为 `t` 后断言「`--make-cover-image` 实际构造次数 > 0 **且** == 当前页『有封面可用』的条目数」，再叠加三条守恒式（构造 + 复用 == 需要封面的条目数、释放数 == 离开页驻留数、驻留数 ≤ 页大小）与三个场景（首屏 / 翻页 / 重渲染）。**去桩后 P 必须失败**（`i-oom-selfcheck-no-graphic-stub` 用例专门断言批处理下构造次数为 0）。
- 桩的边界：桩 `seshat-library--make-cover-image` 与 `image-flush`，**不桩** `create-image`（它是被测对象的下游）；去重逻辑在 `seshat-library--register-cover` 里，故另有用例让真 `--make-cover-image` 跑起来测去重。

## `seshat:` 引用协议（M11.4）

笔记与阅读器之间的双向引用通道，格式为 **`seshat:<target>[#<location>]`**，`<target>` 有两种形态（见下「双形态」）：

| 场景 | 链接 |
|---|---|
| 整本书 | `seshat:ebook:d2l-zh-pytorch.pdf` |
| 某页 | `seshat:ebook:d2l-zh-pytorch.pdf#page:112` |
| 某区域（批注级） | `seshat:ebook:d2l-zh-pytorch.pdf#page:112;rect:50.00,100.00,545.00,140.00` |
| 不在任何书库根下的文档 | `seshat:local:/abs/path.pdf#page:3` |

**解析规则**：

- 剥掉 `seshat:` 前缀后，按**最后一个** `#` 分割为 doc-id 与 location（doc-id 自身含 `:`，如 `ebook:` 标签与 `local:` 绝对路径，故不能按 `:` 或首个 `#` 切分）；
- **不做任何百分号转义**：不使用 `url-hexify-string`（它会把 `:`、`/` 一并转义，破坏 doc-id 可读性并切断与批注文档键（M7 起为 uid，展示与链接仍用 doc-id 文本）的复用），也不自造 `%23` 链路（org 自身会对 `%` 二次转义，双重转义无法自洽）；
- 因此 **doc-id 不得包含 `#` 与 `%`**：构造链接时检测到这两个字符即 `user-error` 并提示重命名文件；非法链接解析返回 nil。

**与批注 `location` 的同构关系**：批注的 `location` 是**页锚 + 可选几何尾段**——形如 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（页锚 `page:<n>` 1-based、唯一导航真值；`rect:` 段是可选几何、页面坐标、只供渲染），链接片段**直接复用同一字符串**（引用锚复用，不新增解析器）。批注侧唯一的构造点是 `seshat-reader-annotation--anchor`（2026-10-25 由 `--location` 改名，语义收窄为「页锚 + 可选几何尾段」；守 `location` 长度上限的 defconst `seshat-reader-annotation--location-max-length` 保留原名，它守的是 API 字段）。批注列表的行携带该字符串（文本属性），故「批注 → 引用」取值不触网；`page:` 段直接传给 `seshat-reader-goto-page`，`rect:` 段在 M11 只做数据保留，自 M12 起在 Emacs 客户端渲染为页面半透明高亮，`ink:` 段自 2026-10-25 起同样渲染为页面手写笔迹（见「Emacs 阅读器：展示层与渲染层（M12）」节与「搜索与 ink 渲染流程」节）。

**双形态（M7 起）**：`<target>` 可以是 **uid**（服务端权威身份，如 `seshat:01J8ZK4Q7M2X9VYB3TR6NDW5PC#page:3`）或 **doc-id 文本**（`tag:path` 或纯 path，人可读、可手写）。**客户端视角**：uid 形态跨改名稳定，doc-id 形态在文档改名后失效、需重新构造，故客户端产出链接时优先 uid。服务端侧的解析优先级（uid → `tag:path` → 纯 path）与解析实现见 keystone 仓 `docs/architecture.md`。含 `#`/`%` 的非法 target 仍按上述规则拒绝。

**客户端新增的 `uid:` 前缀（M8-C）**：Emacs 端产出的 uid 形态写作 `seshat:uid:<uid>[#<location>]`——多一个 `uid:` 前缀，既让「根 tag 恰好叫 `uid`」的 doc-id 不被误判（判别靠 `uid:` 之后是否匹配 26 位 Crockford Base32），也让链接形态在文本上一眼可辨。服务端对 `uid:<uid>` 显式前缀的识别与「`uid:` 之后不合法时回落 `tag:path`」的规则见 keystone 仓 `docs/architecture.md`；客户端只需保证前缀形态合法，`GET /api/refs` 的返回与客户端产出的链接形态一致。

**refs 表的维护在服务端**：`.org` 写入成功后，服务端解析全文 `seshat:` 链接并整份替换该源的引用（`RefreshRefs` / `ClearRefs`），细节见 keystone 仓 `docs/architecture.md`。客户端只需正确产出链接形态；查询走 `GET /api/refs?uid=&direction=in|out`（响应结构见 keystone 仓 `docs/api.md`，错误码见 [`docs/SERVER-CONTRACT.md`](SERVER-CONTRACT.md)）。

**Emacs 侧的双值分工**：`seshat-reader-annotation--uid`（路径 → `GET /api/resolve` → uid，`file-truename` 内存缓存）只用于状态 API；`seshat-reader-annotation--doc-id`（文件 → `tag:path`）曾只用于显示与链接文本。二者分别落在列表 buffer 的 `seshat-reader-annotation-list-uid` 与 `seshat-reader-annotation-list-document-id`。**M8-C 起链接身份也走 uid**：`seshat-reader-reference.el` 不再是「零改动」的旁观者，新增单一身份入口 `seshat-reader-reference--identity`（按 `seshat-reader-annotation-roots` 得 `(tag . 相对路径)` → 零网络 `seshat-state-uid-for-path` 查 uid），产出链接与链接描述时优先 uid 形态、查不到回落 doc-id 形态（见「书架与按需取书（M8-C）」节与 [`docs/emacs-reader.md`](emacs-reader.md) §8）。

## 阅读器面板分层（M11.7–M11.10）

面板分为「承载层 / 批注渲染层（ETAF，可选）/ 兜底渲染」三层，另有一条独立的**译文/解释 Markdown 文本 buffer 路径**（不经 ETAF）。

**承载层 `seshat-reader-sidebar`（零依赖）**：

- **弹出位置（M11 语义，M12 已扩展）**：`seshat-reader-sidebar-position` 取 `below-selected`（当前窗口下方分割，形如 `*Help*`）或 `at-bottom`（frame 底部整宽）；M12 新增 `left` / `right` 两个 side window 取值并把默认改为 `right`，批注与译文改为 per-kind 独立窗口并存，详见下节「Emacs 阅读器：展示层与渲染层（M12）」。M11 语义下同一时刻只有一个面板窗口，批注与译文**后显示者接管**。
- **必须经 `display-buffer`**：首次显示、gt 的 `:window-config`、popper 重开三条路径都走 `display-buffer`，以保证**幂等**（同 buffer 同 kind 重复显示只复用窗口、不重建）；面板参数由 `seshat-reader-sidebar--display-params` **单一来源**生成。
- **`display-buffer-overriding-action`**：显示时用它包住 action list，使本包布局优先于 popper 在 `display-buffer-alist` 表头插入的规则；popper 重开（裸 `display-buffer`）时改由 `seshat-reader-sidebar-display-buffer` 分流回本包逻辑，故两条路径布局一致。
- **per-kind 尺寸记忆**：`seshat-reader-sidebar--state` 为内存 alist（零依赖）；切换内容前先捕获当前窗口尺寸（比例）存给其 kind，再用目标 kind 记住的尺寸新建窗口；M12 起记忆项带**方向标签**（宽度语义 / 高度语义），方位在宽/高之间切换时不复用旧值。仅会话内有效，不持久化。
- **禁用 `window-toggle-side-windows`**：它是 frame 级全量开关（会连带删除/恢复 eca-chat、which-key 的侧窗），toggle 只对本包面板窗口做 `delete-window`。

**渲染层 `seshat-reader-etaf`（可选，依赖 `etaf-ui`；只负责批注卡片）**：

- 职责（M11.10 起）：**仅渲染批注卡片列表**——标题栏（文档名 + 条数徽章）、批注卡片（页码徽章 / 摘要 / `[待同步]` 标记 / 选中标记）、底部键位提示。**译文/解释不经过本层**（原「译文排版」组件树已删除）。
- 交互：`:keys`（`RET` / `d` / `C-c C-r` / `q` / `n` / `p`）+ `:on-press`。Host keys 位于 `emulation-mode-map-alists` 最前，**与 evil 是否启用无关**——阅读器默认在**所有面板与阅读 buffer** 里关闭 evil（`seshat-reader--disable-evil`，受 `seshat-reader-disable-evil` 控制），故不存在 evil 抢占 `:keys` 的前提；**仅当**用户把 `seshat-reader-disable-evil` 设为 nil 时才回到旧前提（evil 先启用、面板再 mount，运行期 toggle evil 需重新 mount 面板）。
- 双色板：按 `background-mode` 取内置明/暗配色，文字一律用普通 `text` + 父 Host 样式（`etaf-label` / `etaf-badge` 自带颜色会覆盖父 Host，故不用）；换主题后需重新渲染面板。
- 增量更新：状态（items / 选中项 / 文档标签）放在 `etaf-ref` 中，改 ref 由 ETAF 做 keyed patch + 行级 diff，不整树重渲染。
- 视口高度（M11.13 起）：卡片列表**不设固定高度、不做内部滚动**，改按条目数**显式计算 viewport 高度**（`seshat-reader-etaf--content-viewport-height`：chrome 6 行 + 每卡 2 行，最小 20 行）；已挂载时经 `etaf-runtime-refit` 放大视口，条目增多不被裁剪，超出面板高度的部分由**面板窗口**滚动查看。
- 降级：未安装 / `require` 抛错 / 渲染抛错三态均回退兜底渲染（细节见 [`docs/configuration.md`](configuration.md)「ETAF 渲染层」）；**降级只影响批注列表观感，译文/解释不受影响**。

**译文/解释渲染（Markdown 文本 buffer，不经 ETAF）**：

- `seshat-reader-translate--render-panel` 把 gt 在隐藏中转 buffer（` *Seshat gt*`，`:window-config` = `(display-buffer-no-window)` + `allow-no-window`）中渲染出的纯文本写入**展示 buffer**（`seshat-reader-sidebar-translate-buffer-name`），以 `gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链设视图，`truncate-lines`=nil + 显式 `word-wrap`=t，并写 `header-line`（「Seshat 译文」/「Seshat 解释」）。
- **模板链路**：`--render-panel (TEXT TITLE &optional LANGS CONTEXT)` → `seshat-reader-translate--apply-template (TEXT TITLE &optional LANGS CONTEXT)`（`format-spec` 填 `%k` 标题 / `%l` 语言对 / `%q` 原文引用块 / `%t` 正文）→ 写入只读 Markdown buffer。**模板按 `CONTEXT` 选择**：`explain` → `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`），其余（含 nil）→ `seshat-reader-translate-template`（默认 `"%l\n\n%q\n\n---\n\n%t\n"`）；两个模板**相互独立**，explain 模板为 `nil` 时不借用翻译模板。默认模板都**不含正文标题**（`%k`），标题由 `header-line` 承担。`%l` 由 `--translator` 透传的 langs 经 `--format-langs` 转成 `*en → zh*`；`%q` 由 `--quote-block` 生成、**默认开启**（`seshat-reader-translate-show-source` 默认 `t`）。`--render-object (MODE &optional TITLE LANGS CONTEXT)` 同样带可选 `LANGS` / `CONTEXT`（向后兼容）。模板非法时 `--apply-template` 回退纯正文并 `message` 警告。
- **正文宽度跟随面板窗口 + valign（2026-10-26；取代 M11.14 的「按全局 `fill-column` 缩窄」）**：`--prepare-view` 末尾按 `seshat-reader-translate-visual-fill-column`（默认 `t`）启停 `visual-fill-column-mode`——软依赖、未安装时静默跳过，关闭分支显式传宽度 `-1` 以清理窗口 margin（buffer 复用、major mode 重设后不残留缩窄），并 `kill-local-variable 'visual-fill-column-width` 作**防御性冗余**（正常情况下 vfcm 自己会清）。宽度不再沿用全局 `visual-fill-column-width`，改由 `seshat-reader-translate-visual-fill-column-ratio`（默认 `0.94`）决定：`--vfcm-follow-window` 把 buffer-local `visual-fill-column-width` 设为「可用宽 × ratio」，再调 vfcm 的**公开命令** `visual-fill-column-adjust` 让库按新宽度重算 margin——即「写数据」走公开变量、「触发重排」走公开命令，不直接改 vfcm 的窗口参数与内部状态。可用宽由 `--vfcm-available-width` 计算，必须与 vfcm 自身 `--window-max-text-width` **同源**：以 `window-width` 的 `remap` 单位起算，扣掉左右 `window-margins` 后按 remap 比例折算，再按 `text-scale` 折减，且复用 `visual-fill-column-adjust-for-text-scale` 的前置判断；**不能用 `window-body-width`**——它不处理 remap 与 margin，实测比同源口径**少 2–4 列**（有 margin 或缩放后偏差更明显），用它会与 vfcm 内部判据打架、正文宽度抖动。触发靠 **buffer-local** `window-state-change-functions`：`--prepare-view` 以 **prepend** 注册 `--vfcm-refresh`（`ignore-errors` 包裹，hook 里不抛错）、vfcm 自身以 **append** 注册它的重排函数，因此顺序恒为「本包先写宽度 → vfcm 再据此算 margin」；这是**顺序契约**，若改成 append 或让 vfcm 先跑，会退化为「第一次 resize 不变、第二次才变」（vfcm 按旧宽度算完 margin，本包才改宽度，只能等下一次事件补上）。此外 `seshat-reader-sidebar--resize-width` 的两个成功出口会**显式**调一次 `--vfcm-refresh`（软依赖、`fboundp` 守卫），因此 `w` / `C-c w` 的扩大与恢复**不依赖** `window-state-change-functions` 是否已注册——hook 缺失时（旧渲染残留 buffer、换 major mode 等）正文仍跟随；该兜底是刻意冗余，勿删。`--render-panel` 在面板**显示之后**再补一次 `--vfcm-refresh`，收口首帧的已知副作用（首次渲染时窗口尚未成型，按 `selected-window` 算出的 margin 是错的）。ratio 设 `nil` 即**回退旧行为**（正文固定为全局 `fill-column`，不跟随窗口），这是刻意保留的逃生口。**`valign-mode`**：同一分支下再判 `(and seshat-reader-translate-valign (display-graphic-p) (or (fboundp 'valign-mode) (require 'valign nil t)))`，满足才启用——非图形环境**静默跳过**（不提示，终端等宽字体本就对齐），并用 `display-graphic-p` 提前短路以免在 tty 上做无意义的像素对齐；仅折行模式（`seshat-reader-panel-truncate-lines` 为 `nil`）生效，不折行时 vfcm 与 valign 一并跳过。**批注列表不启用**：ETAF 布局按 `window-body-width` 计算，`window-margins` 缩窄会导致错位（同 M11.14 的结论，机制未变）。已知限制：valign 用 `:align-to` 绝对像素对齐，面板里的**宽表格会被右缘裁切**（记入 tech-debt「面板宽表格溢出被裁切」）。
- 键位 `q`（关面板）/ `C-c C-s`（存为批注）由 minor mode `seshat-reader-translate-panel-mode` 承载，不污染 Markdown 视图共享键位表。理由见 [`openspec/decisions.md`](../openspec/decisions.md)（ETAF 画布固定 viewport 裁剪、内容不可选中复制、CJK 2 列测量风险）。

**高度自适应（sidebar 层）**：

- 仅对 kind=`translate` 且**未挂载 ETAF runtime** 的面板生效：`seshat-reader-sidebar--fit-height-for-content` 用 `window-text-pixel-size` 换算内容行数，夹紧 `seshat-reader-sidebar-min-height`（默认 0.25）到 `seshat-reader-sidebar-max-height`（默认 0.8），成功后把实测比例写入 per-kind 高度记忆；批注列表固定用 `seshat-reader-sidebar-height`。同帧内面板增高会压缩上方阅读窗口（预期）。
- **测量口径**：`seshat-reader-sidebar--content-height` 的单行像素高取首行 `line-pixel-height` 与 `frame-char-height` 的**较小值**（Markdown 标题行通常比正文行高，直接用首行会把内容行数低估），`window-text-pixel-size` 测量上限 120 行（超长内容按上限计，避免测量耗时），再向上取整换算为行数。目标高度 = `max(1, max(min(min-h, max-h), min(max-h, content+2)))`，其中 `min-h` / `max-h` 分别是 `seshat-reader-sidebar-min-height` / `seshat-reader-sidebar-max-height` × `frame-height` 向下取整，`content` 为内容行数、`+2` 留给 header-line 与余量。

**兜底渲染**：

- 批注列表：`seshat-reader-annotation--render-list` 的纯文本 + 文本属性渲染，行携带 `id` / `page` / `queue-uuid` / `location` 属性。ETAF 已挂载时该函数**不再 `erase-buffer`**（交给渲染层增量刷新），否则随后的 `etaf-runtime-flush` 会因缓冲区被清空报 `Args out of range`。
- 译文/解释：`seshat-reader-translate--render-panel` 的 Markdown 文本 buffer 路径（见上一小节）；只有 `seshat-reader-translate-render` 取 `pop` / `pin`（或禁用面板）时回退 posframe，由 gt 的 `gt-posframe-pop-render` / `gt-posframe-pin-render` 承载。

**数据流**：`seshat-reader-annotation--refresh-list`（拉服务端批注 + 读本地队列）→ items（服务端项在前、本地待同步项在后；本地项以 `:uuid` 标识、无 `:id`）→ **全量条目**（不分页、不切片）→ 渲染层（ETAF 卡片或文本兜底；ETAF 按条目数显式计算 viewport 高度、条目增多时 `etaf-runtime-refit`）→ `seshat-reader-sidebar-show` → `display-buffer`（参数单一来源、幂等、可选光标跟随）；译文/解释的数据流为 gt → 隐藏中转 buffer → `:then` 回调 → `seshat-reader-translate--render-panel` → 同一 `sidebar-show`。

## Emacs 阅读器：展示层与渲染层（M12）

M12 把 M11 的「单个底部面板」升级为「左目录 / 右信息 / 中阅读」三栏，并把批注高亮下沉到 C 渲染层。展示层归 elisp（`seshat-reader-sidebar` / `seshat-reader-outline`），渲染层归 `render-core.c`。

**三分栏版式**：

- **用 `display-buffer-in-side-window` 而非自建 `split-window`**：显示参数为 `(side . left|right)` + `(slot . N)`。自建 `split-window` 每显示一次就重新切分主窗口，多开几次会把阅读区**逐次挤压**，关闭时又不自动回收；side window 由 Emacs 维护独立的窗口树，同侧不同 slot 互不顶替，故目录与批注可同时存在，阅读区尺寸只受两侧宽度影响。
- **per-kind 方位映射**：kind `outline` → `left`（`seshat-reader-outline-sidebar-position`，默认 `left`），kind `annotations` / `translate` → `right`（`seshat-reader-sidebar-position`，默认 `right`）；方位由单一判据 `seshat-reader-sidebar--position-for-kind` 解析，side / slot / 尺寸默认值全部由它派生。slot 由 `seshat-reader-sidebar--slot-for-kind` 按稳定 kind 顺序分配（同一 kind 恒定同 slot，显示/关闭一个 kind 不会顶掉其它 kind 的窗口）；slot 数量上限受 `window-sides-slots` 约束，超出会被 `display-buffer-in-side-window` 拒绝而回落为普通窗口。
- **尺寸语义方向化**：side 模式是**宽度**语义（`seshat-reader-sidebar-width` / `seshat-reader-outline-sidebar-width`，小数按 frame 根窗口总宽比例换算列数、整数直接作列数）；底部模式（`below-selected` / `at-bottom`）是**高度**语义（`seshat-reader-sidebar-height` 与 min/max）。per-kind 尺寸记忆因此带**方向标签**——方位在宽/高之间切换后，旧值不会按错误单位复用。

**目录面板**：

- **纯函数行模型**：`seshat-reader-outline--rows`（按 **DFS 前序**摊平成行列表，入参为树、折叠态集合、当前页）与 `--current-path`（按当前页求根→叶路径）。折叠态用**行路径**（自根到该节点的标题列表）而非标题字符串，以免同名节点互相折叠；折叠节点自身仍出行、其子树不出行。
- **渲染规则**：行首保留 outline 星号（去掉会令 `outline-regexp` 失配、TAB 折叠失效），但把星号区间设为**零宽显示**（`display ""` 只改显示、不改 buffer 文本，故 `outline-regexp` 照常匹配、`outline-hide-subtree` 仍可用）→ 每级 1 列缩进（`seshat-reader-outline--indent-width`）+ 折叠符号的 2 列，标题落在第 3/4/5 列 → `▾`/`▸` 折叠符号（无子节点用 2 空格占位对齐）→ 标题按钮 → 弹性空白 `display` 属性把页码推向右缘 → 按深度取三级 face；当前章另用 `line-prefix` 画竖线（`line-prefix` 只是显示属性、不进 buffer 文本，故不破坏 outline 结构）。
- **avy 风格跳转**：`f` 触发 `seshat-reader-outline-avy-jump`，候选为可见区带页号属性的按钮，标签由 overlay `before-string` 承载（不写 buffer 文本），`read-key` 逐键匹配，`unwind-protect` 清理标签。**零新增依赖**：不 `require` avy，只在 `avy-keys` 已绑定时复用自己的字符表，未加载时用内置表。

**装饰表（Decoration，渲染层）**：

- **数据结构**：一张 `Decoration` 表取代原来的单色 `Highlight` 表，每条带 `kind`（`DECORATION_KIND_RECT` 填充矩形 / `DECORATION_KIND_STROKE` 折线）、几何（rect 四角，或 `fz_point *pts` + `pt_count`）、`color`（RGB ∈ [0,1]）与 `alpha`。rect 与 stroke **共用一张表**，因此渲染线程只遍历一次；`width` 只对 stroke 有意义，rect 恒为 0。上限：`DECORATION_MAX_COUNT`（100000 条）、`DECORATION_MAX_ABS_COORD`（±1e6 点）、`DECORATION_MAX_POINTS`（每笔 1024 点，超出**截断而非拒绝**）、`DECORATION_MAX_STYLE_GROUPS`（64 个样式分组）。
- **为何必须改 C**：elisp 层无法在已有页面 image 上叠加半透明矩形——同一区域的 `display` 属性**互斥**（一处只有一份 `display` 规格生效），image 规格里也没有「第二个矩形」这一层。既有两个证据：M11.2b 计划记录（`openspec/completed/2026-10-12-m11.2b-reader-selection.md:25`）与 `seshat-reader.el` 的选区实现注释（只做文本属性、不做矩形绘制）。因此装饰在 C 侧渲染函数（现为 `render_page_to_buffer`）内绘制：栅格化与像素变换之后、导出 BGRA 进 canvas 缓冲之前；原 worker 版 `draw_page_thread` 已随线程池删除。
- **绘制顺序（不变）**：在暗色像素变换（暗色模式下 `fz_tint_pixmap`，未设 tint 时为 `fz_invert_pixmap_luminance` + `fz_gamma_pixmap`）**之后**、把 BGRA 字节写进 canvas 缓冲 **之前**。这一层是整页像素变换，若在装饰之后做会连装饰一起变色；写进 canvas 之后再画则进不了页面位图，翻页回来装饰消失。
- **颜色分组与「重叠不叠深」**：rect 先扫一遍收集至多 64 组不同的 `(R,G,B,A)`，再**每组一条 `fz_path` + 一次 `fz_fill_path`**（`fz_identity` 下传，device 已持 ctm）；同组内重叠区域只被填充一次，因此多段高亮叠在一起仍是同一个透明度。越过组上限的 rect 各自单独填充（只是多几次 fill，语义不变）。
- **`ctm` 复用**：直接复用该页 rasterize 用的同一个 `fz_transform_page(dp->bbox, resolution, rotate)`，因此缩放与旋转自动对齐，不必另算变换；`rect_to_page_space` 是「Emacs rect → MuPDF 页面空间」的**唯一**换算点（被 `--text-in-rect` / `--rects-in-rect` 与绘制共用）。
- **快照深拷贝与所有权**：装饰表在每次渲染调用开始时**快照**一份（`deco` + `deco_count`），渲染函数只读快照、不碰 `DocState`；快照由本次调用持有，收尾统一经 `free_decoration_table` 释放（worker 线程池与 `DrawThreadArgs` / `free_draw_thread_args` 已于 2026-10-28 删除）。stroke 的点列是**堆分配**，struct 浅拷贝会与 `DocState` 共享 `pts`——因此快照对每条 stroke **逐条深拷贝 `pts`**；所有权规则写进 `Decoration` 结构体注释（「谁持有结构体谁释放 `pts`，且只有一份所有权」），`free_decoration_table` 是**唯一**释放路径（`--clear-highlights`、`free_doc_state`、渲染路径共用），从机制上排除双 free。
- **elisp 侧只改表**：三个入口改表并置 `decorations_dirty`，渲染线程不参与。**刷新链在 2026-10-28 已改写**：原「`--refresh-highlights` 内部 `wait_for_win_jobs` → `nullify_window_cache` → `build_cache_window` → `wait_for_cached_page` → `display_cached_page`」随 legacy 渲染路径**整条删除**（`--refresh-highlights` 入口、worker 池、`CachedPage`、overlay 显示路径均已不存在，见本节「渲染后端：canvas」）；现在的等价动作在 elisp 侧——清目标页 spec 缓存并重渲染驻留页（`seshat-reader--multipage-refresh-decorations`）。
- **三个入口**（C 函数 / 注册 arity）：
  1. `--add-highlight`（`5,5`，`page x0 y0 x1 y1`）——历史入口，名字与 arity **均不变**，内部映射为「rect + 默认黄 1.0/0.85/0.0 + α 0.35」，是默认配色下的**像素级等价路径**。
  2. `--add-decoration`（`9,9`，`page x0 y0 x1 y1 r g b alpha`）——带颜色的 rect 入口；非有限颜色分量回退默认色、其余夹到 `[0,1]`。Lisp 侧在 `kind` 为 underline/strikeout 或用户改了高亮配色时走这条。
  3. `--add-stroke`（`7,7`，`page r g b alpha width points`）——折线入口，`points` 是**扁平**列表 `(x0 y0 x1 y1 …)`（逐对 `car`/`cdr` 读取并 `numberp` 守卫，超过 1024 点截断，少于 2 个点返回 nil），点数组由 C 侧 `malloc`+`memcpy` 自持。自 2026-10-25 起由 ink 轨迹渲染调用（`seshat-reader-annotation--ink-strokes-from-location` 的解析结果）。
  4. `--search-page`（`3,3`，`page needle limit`）——只读，返回该页命中矩形的列表（`fz_search_page` → `fz_rect_from_quad`，与 `--text-in-rect` 同一条 `rect_to_page_space` 换算，故命中矩形喂给装饰入口落在文字原处）。**页号 1-based**（与三个装饰入口同口径）。
  另加只读入口 `--rects-in-rect`（`5,5`，`page x0 y0 x1 y1`）——返回矩形内每个命中字符的 quad 矩形列表，与 `--text-in-rect` 共享同一份 stext 遍历（`stext_query_in_rect`），空结果返回 nil 且**不发消息**（矩形内无文本是正常答案）。这两个只读入口的页号是**历史 0-based**（服务于选区代码），与装饰/搜索入口的 1-based 并存——基数见各函数注释首段。
  另加只读入口 `--lines-in-rect`（`5,5`，`page x0 y0 x1 y1`）——**整行吸附**用：框碰到某行即返回该行**全部**字符 quad 的并集（双遍遍历，先判该行是否被碰到，命中才求并集；输出的是整行范围而非框内片段），每行一条矩形、按阅读顺序；无命中返回 nil 且**不发消息**；页号同为 **0-based**，与 `--rects-in-rect` 共享 `prepare_rect_query` 的参数校验/换算与全部消息文案。`prepare_rect_query` 只按 **buffer-local** 的 `seshat-reader-current-doc-state-ptr`（`get_doc_state_ptr`）解析文档，**不依赖 selected window 的 overlay / `EmacsWinState`**——多页布局下拖选刻意不 `select-window`（P2-A 真机修复，2026-10-27）；代价是这三个入口必须在**阅读 buffer** 里调用，在别的 buffer（如搜索侧栏）里调用会静默返回 nil。

**框选闪现（M12 补）**：

- **数据流**：`seshat-reader-select--flash-selection` 把选区矩形按 `(PAGE X0 Y0 X1 Y1)` 存进 buffer-local 的 `seshat-reader-select--flash-rects`，再调 `seshat-reader-select--redraw-highlights`——后者委托 `seshat-reader-annotation--redraw-highlights`，把**批注矩形在前、闪现矩形在后**合并成一次投喂（一次 clear + 逐条 add + 一次 refresh），因此闪现不会抹掉批注、批注重绘也不会抹掉闪现；批注模块未加载时退化为「只投闪现」。
- **timer 到点**：武装一个 `run-at-time` 定时器，到点由 `seshat-reader-select--clear-flash` 清空该 buffer 的 `--flash-rects` 并**重投一次**（批注仍在、闪现消失）；timer 指向的 buffer 已死（用户已关文档）时静默跳过。
- **buffer-local**：`--flash-timer` 与 `--flash-rects` **都是** buffer-local。两份文档几乎同时框选时，第二次 `cancel-timer` 只取消自己那份 timer，前一文档的闪现不会被「取消 + 遗留」——全局变量正是本补丁修掉的缺陷。
- **与批注高亮的关系**：闪现**不受** `seshat-reader-annotation-highlight-enabled` 约束（它是框选的即时反馈，不是批注），时长由 `seshat-reader-select-flash-duration` 决定，`<= 0` 关闭。

**防御上限**（针对不可信输入，全部在实现侧硬夹紧）：

| 对象 | 上限 | 越界行为 |
|---|---|---|
| 装饰条数 | 100000（`DECORATION_MAX_COUNT`） | 静默返回 nil，不覆盖已有条目 |
| 装饰坐标 | ±1e6 点（`DECORATION_MAX_ABS_COORD`） | 判非法、不进表（`--text-in-rect` / `--rects-in-rect` 同受此限） |
| 每笔 stroke 点数 | 1024（`DECORATION_MAX_POINTS`） | **截断**（保存前 1024 点），不拒绝整笔 |
| 装饰样式分组 | 64（`DECORATION_MAX_STYLE_GROUPS`） | 越过组上限的 rect 各自单独填充（多几次 fill，语义不变） |
| outline 标题 | 8192 字节（`OUTLINE_TITLE_MAX`） | 截断，不中断开书 |
| 批注 `location` | 64 KB、至多 2000 段 `rect:`（写入端 500 段） | 超限不解析，不影响列表渲染 |
| 搜索单页命中 | 1024（`SEARCH_PAGE_MAX_QUADS`；`limit` 另被夹到 1..10000） | 截断为前 1024 条，状态行提示「仅显示前 1024 条」 |
| 搜索整次命中 | 20000（`seshat-reader-search-max-matches`） | 达到即停止扫描并提示「命中过多」 |

### 渲染后端：canvas（2026-10-28，取代 PBM/PNM）

每页位图的传输层由「PNM 编码成 Lisp 字符串 + `create-image :type pbm`」换成「MuPDF 直接写 Emacs canvas 的像素缓冲 + `canvas-refresh`」。canvas 是 **Emacs 32 的编译期特性**，因此本仓库**只支持 Emacs 32.0+**（29/30/31 不再支持，也不保留 pbm 双路径）。

**像素链路（不用预乘、不做反预乘）**：

1. `fz_new_pixmap_from_display_list(ctx, dl, ctm, fz_device_bgr(ctx), **0**)` — 第五参 `alpha = 0` 表示**不分配 A 通道**，得到 3 分量 BGR pixmap；MuPDF 把页面直接合成到不透明背景（初始像素 0 = **黑**），与旧 PNM/RGB 路径语义一致。通道序与 canvas 的 `0xAARRGGBB`（小端字节序 B, G, R, A）天然吻合，**零重排**。
2. 因为起点不透明（没有 A 通道、也没有半透明合成），「预乘 alpha」问题根本不存在——**不需要预乘，也不需要反预乘**（改成 alpha=1 反而会拿到预乘像素、且 MuPDF 没有反预乘 API）。
3. 渲染 → 暗色像素变换 → 装饰 wash（次序同前）。
4. **导出为紧凑 BGRA**：逐行按 `fz_pixmap_stride` 取源行，每像素一次 32 位写 `0xFF000000 | R<<16 | G<<8 | B`（**A 恒填 255**）到一块 `data_w × data_h × 4` 的中间缓冲。
5. **写进 canvas**：主线程取 `canvas_data`（**每次重取，禁止跨调用缓存**）→ 按行 `memcpy`（canvas 行宽 = `data_w × 4`，与中间缓冲同构，无需重排）→ `canvas-refresh`（第二参 nil）。

**尺寸双轨制（硬约束）**：

| 属性 | 语义 | 写权限 |
|---|---|---|
| `:data-width` / `:data-height` | **设备像素** = MuPDF pixmap 尺寸 | **只在渲染时设一次，之后任何路径禁止改写**——改它会重建缓冲并清零（残影 / 花屏） |
| `:width` / `:height` | **逻辑像素** = 设备像素 ÷ `frame_scale` | 可随时 `setf`，即显示层缩放（拖分割线 / `W` / `H` / `+` / `-` / `0` 走这条） |

**内存模型（Lisp 侧零常驻）**：

- canvas spec 的 `:data` 为 **nil**——位图只存在 Emacs 的 canvas 缓冲里（`w*h*4` 字节），Lisp 堆**不持副本**；canvas 没有 `image-flush` 语义，代码里也**不再有**该调用。
- 渲染期另有两块**临时**内存：MuPDF pixmap（3 分量 + alpha）与 BGRA 中间缓冲，渲染函数返回前释放。
- 每页 612×792 从旧 ≈3.4 MB（Lisp 字符串副本 + C 侧副本）降到 ≈1.9 MB（**−43%**）。

**刷新粒度 = 整张 canvas**：`canvas-refresh` 只有 `(image &optional reload-data)`，**没有局部区域刷新**。因此「只刷新一部分像素」只能靠「按页切分 canvas」——每页一个 canvas 对象是当前唯一的增量手段（多页布局正是每页一个 spec）。改一条批注仍要重渲染受影响页，代价见 `docs/emacs-reader.md`。

**性能与取舍（实测）**：单页 `--page-image-spec` 中位 **0.589 → 1.22 ms**（scale 1.0）、**1.732 → 2.77 ms**（1.5）、**0.742 → 1.16 ms**（rotate 90），即 **+0.6~1.0 ms/页**，来源是 BGR→BGRA 的逐行扩展。三种优化写法（`memset` + 3 字节写、64 位块写、`-O3`）实测**均无收益**——瓶颈是「3 分量 pixmap → 中间缓冲 → memcpy 进 canvas 缓冲」的结构性往返，不是逐像素写循环。**明示取舍：不做结构重构**（真要回补只能改成渲染端直出 4 分量，见 `openspec/tech-debt.md`）。

**legacy 路径已退役（净删 1714 行）**：`--redisplay-doc` / `--next-page` / `--prev-page` / `--first-page` / `--last-page` / `--goto-page` / `--scale-page` / `--rotate-page` / `--window-create` / `--window-close` / `--refresh-highlights` 共 **11 个 C 入口**、worker 线程池（`render/render-threads.c/.h` 整文件删除）、`CachedPage`、`EmacsWinState`、overlay 机制与 `image-flush` 调用**全部删除**，保留 14 个入口；`render/` 净删 **1714** 行（全仓 21 文件 **+786/−2423** 中的 `render/` 部分，21 文件合计 **+786/−2423**）。`--load-doc` 现在只建 `DocState`（不再建 overlay / win-state），渲染完成标志 `set_current_render_status` 移到 `--page-image-spec` 的成功路径。

> **历史说明（避免去 grep 不存在的代码）**：下文与旧计划里出现的 `--refresh-highlights`、overlay 显示路径、`CachedPage`、`wait_for_win_jobs` / `build_cache_window` / `display_cached_page`、`render/render-threads.c` 一律**已删除**，描述仅保留作历史背景；当前有效路径只有 `--page-image-spec` → canvas。

### 暗色像素变换与状态存储（2026-10-27）

暗色模式是**用户偏好**而非文档属性，因此在 C 侧同时改了两件事：像素变换的方式，以及这份状态的存储粒度。

- **像素变换只有一条分支**：`render_page_to_buffer` 里 `dark_on && tint_set` → `fz_tint_pixmap(ctx, pixmap, bg, fg)`（把每像素亮度线性映射到 BG–FG 两端）；`dark_on` 但未设 tint → 旧的 `fz_invert_pixmap_luminance` + `fz_gamma_pixmap(1/1.4)`（满量程反色）。次序不变：**栅格化 → 像素变换 → 装饰 wash → 导出 BGRA 进 canvas 缓冲**（理由见上节「绘制顺序」）。tint 是双端压缩，暗底不再等于「白变纯黑」，代价是彩色内容被压成单色调（见 `openspec/tech-debt.md`）。
- **状态是进程级原子字段**：`render-theme.c` 的 `g_dark_enabled` / `g_tint_set` / `g_tint_pair`（BG 与 FG 打包在一个 64 位字里）承载开关与配色，**不随 `reset_doc_state` 清零**——重载文档或新开另一本都保持用户当前选择。`DocState` 因此**没有** `invert` 字段（原字段已删除），`mupdf-helpers.c` 的 `reset_doc_state` 也不再初始化它。
- **elisp 侧如何写**：`seshat-reader-dyn--doc-invert` 只翻进程级开关、**不再要求文档存在**（进程级标志没有「文档缺失」这种失败态，恒返回 `t`）；`seshat-reader-dyn--doc-tint`（arity `2`，`BG FG` 均为 `#xRRGGBB` 整数）写配色，`-1 -1` 是**清空 tint** 的哨兵（回退旧 invert+gamma，即 `graphite` 预设的「一键回旧观感」），`> 0xFFFFFF` 返回 nil 且只 `message`、不改状态，非整数同样不改状态。两者都**不重绘**，重绘由调用方显式触发。
- **原子性**：三者均为 atomic（`atomic_bool` × 2 + `atomic_uint_fast64_t`，字段清单见上条）；主线程写（release）、渲染线程读（acquire），一帧只读一次整对端点色，避免混用两档配色。

### 按页渲染查询接口（P0，2026-10-26）

面向「PDF 多页连续布局」（路线 3，见 `openspec/decisions.md` 2026-10-26 条）的**前置地基**：本仓库第一次提供「渲染任意页并把 image spec 交回 Lisp」的通道。

- **为什么需要**：改造前渲染结果**只**由 C 直接写进 per-window overlay（`display_img_to_overlay` → `overlay-put overlay 'display spec`），调用方拿不到 spec；所有翻页入口都走同一条 `wait_for_win_jobs` → `build_cache_window` → `wait_for_cached_page` → `display_cached_page` 模板并写 `selected-window` 的 `page` 参数。要做多页纵向布局，必须有「给定页号 → 得到该页位图」的纯查询能力，否则只能借「隐藏窗口预渲染」（每窗口独占 11 张位图，且会被 `--manage-window-overlays` 反复重建），代价过高。
- **接口形态**：C 入口 `seshat-reader-dyn--page-image-spec`（arity `2..3`，`PAGE SCALE [ROTATE]`），页号 **1-based**、`SCALE` 为 72 dpi 的倍数并按既有 `MINRES/MAXRES` clamp、`ROTATE` 只接受 0/90/180/270；非法参数、页越界、`is_reloading` 一律**静默 nil**。elisp 包装 `seshat-reader--page-spec`。**同步**执行、**显式**给 scale / rotate、**不读写**任何窗口参数 / overlay / per-window 缓存槽——即调用前后显示状态逐项不变（ERT 有专门用例守门）。渲染段由 `render_page_to_buffer` 承担；装饰走文档装饰表的深拷贝快照，渲染后 `free_decoration_table`。**2026-10-28 起返回 canvas spec**（`:data` 为 nil、像素直写 canvas 缓冲），与旧 pbm 基线**逐字节等价**（三组 `(scale, rotate)` 差异均为 0）。
- **缓存上限 8 的理由**：spec 的 `:data` 为 nil（Lisp 侧零常驻），位图常驻在 Emacs 的 canvas 缓冲（每页 `w*h*4` 字节，612×792 ≈ 1.9 MB）。上限固定为 8（`defvar`，不是 defcustom，不暴露给用户），使常驻增量落在 15 MB 量级而非无界。内存估算 `seshat-reader--multipage-resident-spec-megabytes` 改按 `data-width × data-height × 4`（不再读 `:data` 长度）。
- **边界（P0 明确不做）**：**不接入任何显示 / 滚动 / redisplay 路径**，只供显式调用与测量。同步阻塞主线程，实测 0.7–11 ms/页（72 dpi，与既有 `wait_for_cached_page` 同量级，见 `openspec/completed/2026-10-26-reader-multipage-p0-page-spec-api.md` 的「实测数据」）。另外**顺序扫超过 8 页时缓存命中率为 0**（上限 8 + 先进先出淘汰，第二轮开始前槽位已被后 8 页占满）——P1 的虚拟化必须让视口驻留页数 ≤ 上限，否则要先换淘汰策略。
- **未改变的既有结构**：hscroll 的窗口级语义、多窗口各自的页号、`--multipage-*` 的虚拟化与淘汰策略原样保留。**per-window 11 槽缓存与 `--refresh-highlights` 已不存在**（2026-10-28 随 legacy 路径删除），其历史缺口记录在 `openspec/tech-debt.md`。

## 多页连续布局（P1，2026-10-27）

单页 overlay 模型已退役并**彻底删除**（2026-10-28）：elisp 侧**没有任何** `(window-parameter … 'overlay)` 读取点；C 侧原有 `--window-close`（释放 `EmacsWinState`）与 `--refresh-highlights`（兼容入口）两个残留入口也随 legacy 渲染路径一并移除，装饰刷新只走 elisp 的 spec 缓存失效 + 重渲染。

- **buffer 结构**：**每页一行**。行 = 引导空格（`display` 取 `(space :align-to (+ center (-0.5 . SPEC)))`，让页面在窗口里居中且随 redisplay 求值）+ 图像空格（`display` 取页面 image spec）+ 换行。每个页行之后依次是 `seshat-reader-page-gap-lines`（默认 `0`）个整行空行 + **分隔区 3 行**（上空行 / 横贯窗口的线 / 下空行）——线是 `(space :align-to (- right 0))` 的 stretch space 配 `seshat-reader-page-separator-face` 的 `:background`，三段高度由 face `:height` 相对 `frame-char-height` 缩放，总和 = `seshat-reader-page-separator-height`（默认 `0.5`）行像素（**名义值**；其中横贯窗口的那条**规则行**是 stretch space，行高恒为一个 `frame-char-height`、不吃 face 的相对高度，故实际高度比名义多 `frame-char-height − thickness`——char-h 20 → +18 px/页，见 `docs/emacs-reader.md` §7 与 §12）。分隔区像素由 `seshat-reader--multipage-separator-segments`（返回 `(TOP LINE BOTTOM)`）**单一产出**，滚动几何（`--multipage-page-span` / `--multipage-page-max-offset`）与行构造共用它，避免口径分叉；**`--multipage-page-gap-pixels` 返回的是实测值**（gap 行 + 名义分隔区 + `--multipage-separator-extra-pixels` 补偿），span 与跨页累减距离因此与真实布局一致（P2-B T9 修复，修复前每页少算一个字符行高、5 页累计 90 px）。页表 `seshat-reader--pages` 是升序 alist，元素 `(PAGE MARKER . SPEC)`，marker 指向**行首**（插入/删除页行时自动跟随，故页号永远由 marker 反查而不是由行号推算）。
- **可见集与虚拟化**：驻留集 = 视口顶页 − `seshat-reader--multipage-preload` .. 视口底页 + 同值（默认 `2`）；越界页 recycle（删行 + 释放 spec），相邻一页保留 spec 缓存。spec 缓存 `seshat-reader--page-spec-cache` 上限 = `min 16 (2K+2)`（K = preload，下限 4），**视口外优先淘汰**；`--multipage-prefetch` 按滚动方向预热**一页**（只暖缓存、不插行）。内存：`--multipage-check-memory` 按 `data-width × data-height × 4` 估算（canvas 缓冲的 ARGB32 像素，缺 `data-*` 时退回 `:width × :height × 4`，缩放 frame 下为低估），超 `seshat-reader-multipage-memory-warning-mb`（默认 75）时每 buffer `message` 一次。
- **页号派生**：`seshat-reader-current-doc-pagenumber` = **视口顶页**（`window-start` 经 `--multipage-page-at-pos` 反查页行），不再读窗口参数 `page`；`goto-page`（及 `n` / `p` / `M-<` / `M->` / 搜索跳转 / 引用跳转）= 把目标页行设为 `window-start` 并把 `window-vscroll` 归零，故整页跳转恒停在页首。
- **滚动原语**：一页一行、行高 = 整页位图高，因此**内置行滚动等于翻页**。滚动由 `seshat-reader--multipage-scroll` 实现：「页内用 `window-vscroll` 的像素偏移，跨页时改 `set-window-start` 到相邻页行，余量成为新页的偏移」；步长 = `seshat-reader-scroll-step-pixels`（绝对像素，优先）或 `scroll-step-ratio`（默认 `0.15`）× `(window-body-height WIN t)`，再退回一行（`frame-char-height`）。首尾由「页内偏移夹到 `[0, 高−1]`」自然截止，每轮必前进一页，占位页（spec 为 nil）不会死循环。
- **几何**：`base-scale` 由**打开文档那一页**的 native 尺寸锚定（`seshat-reader--multipage-reference-native`，reload / rotate 时清空），保证 `W` / `H` / `0` 的基准稳定。每页 target 由分模式表给出：`contain` = `min(base, 该页 width-fit)`、`width` = 该页 width-fit、`height` = 该页 height-fit（**不裁剪**，可横向滚动）、`manual` = base；`contain` / `width` 下任一可见页宽度 ≤ 窗口宽。refit 闸门 `seshat-reader--refit-scale-tolerance`（`0.005`）：已渲染 scale 与目标 scale 差小于该值即视为「已清晰」，避免反复重渲染。
- **装饰刷新**：装饰（批注 rect、选区闪现、搜索命中、ink 笔迹）在**渲染时烘进位图**，所以「刷新高亮」= 清掉目标页的 spec 缓存并把**全部驻留页**重渲染一次（`seshat-reader--multipage-refresh-decorations`），不再走 C 侧 overlay 重绘入口。代价是每次刷新 O(驻留页) 次重渲染（实测 0.7–11 ms/页）。

## 阅读器两阶段异步渲染（P2-B，2026-10-29）

**动机**：P1 的 `--multipage-sync` 在 range 变化时**逐页同步渲染**，像素渲染因此留在滚动同步路径上——批次 0 的 S1 实测单页 `--page-spec` p95 最高 **49 ms**（扫描书 p50 19 ms，矢量 letter 页 8–10 ms 尖峰），滚动一屏 2 页即几十毫秒的主线程阻塞。**但布局真正需要的只有页高**，它来自页面 bounds（MediaBox/CropBox × scale × rotate），与栅格化无关 ⇒「异步」不必等于「后台线程」，可拆成「尺寸先行（同步、微秒级）+ 像素后补（idle/周期 timer）」。

**为什么不做 worker 线程池**（决策 D1 的取舍）：`render-threads.c/.h`、`CachedPage`、`EmacsWinState` 已在 canvas 后端迁移中**整族删除**；`DocState` 有单线程纪律（`render/render-core.h`），装饰表由主线程拥有，`canvas_data` 指针不可跨调用缓存。重建线程池 = 重建调度器 + 快照 + 生命周期，规模远超本项，且收益被「页高与像素可解耦」这条结构性事实直接绕开。

**两阶段的拆分依据**：

| 阶段 | 入口 | 代价 | 产物 |
|---|---|---|---|
| 尺寸先行（同步） | `seshat-reader--page-size` → C 入口 `seshat-reader-dyn--page-size`（`fz_load_page → fz_bound_page → fz_drop_page`） | 中位 4.5–10.3 µs/次 | `(W H)` 显示像素 → 占位行 `(space :width (W) :height (H))`（**括号形式**：裸数字会被当作字体尺寸倍数） |
| 像素后补（异步） | `seshat-reader--async-render-tick`（每轮 ≤ `seshat-reader-render-idle-batch` 页） | 0.7–11 ms/页 | 真 spec，写回同一页行（只改 `display` 文本属性、**不动 marker**） |

因此「已定尺寸未渲染」成为第三种状态（`spec = nil` 仍是「未渲染」的唯一表达，尺寸另存 buffer-local 平行 alist `seshat-reader--multipage-page-sizes`，不改 `seshat-reader--pages` 的 `(MARKER . SPEC)` 结构）。**占位态与已渲染态页高逐像素相等**（独立 GUI 实测 4/4 组差 0 px），这是 P1 不变量①在异步路径下的延续：页高不变 ⇒ 滚动范围不变 ⇒ `window-vscroll` 不被 redisplay 回滚、不会跳变。

**代际作废（决策 D4）**：`seshat-reader--multipage-render-generation` 是 buffer-local 整数，**只在全量失效入口 `--page-spec-clear-cache` 自增**——它同时清空尺寸缓存与渲染失败计数表，是 rotate / 关闭 / reload / redisplay-all 四类作废时机的汇合点。缓存写入、尺寸缓存写入与 tick 回调都比对代际，不匹配即丢弃（不写缓存、不补位）。**单页入口 `--multipage-forget-specs` 明确不自增**：它被 `--multipage-recycle-page`（滚动回收远页）调用，若在此自增，则「每回收一页就作废全部在途 pending」，持续快速滚动时 idle 补位被系统性作废、退化为超时强制同步，直接吃掉本计划的全部收益。这条写进了代码注释防回归，并有 ERT 回归守卫（「单页 forget 不改变代际、不丢弃在途 pending」）。

**队列是 buffer 级并集，强制同步是窗口级操作（决策 D8）**：`seshat-reader--multipage-pending-renders` 的语义是「所有显示该 buffer 的窗口请求的并集」。因此两个出口必须都按并集口径：

| 出口 | 修前 | 修后 |
|---|---|---|
| 态 B 的裁剪（`--multipage-prune-pending` 实参） | 调用窗口的可见页（交集）⇒ 两窗口互相删掉对方的队项 | `--multipage-all-visible-pages`（`frame-list` → `window-list FRAME` → 过滤显示本 buffer 的窗口 → 各窗口 range 展开后取并集） |
| 态 C 的超时清空（`--multipage-force-sync`） | `--multipage-clear-async-state` **整队清空** ⇒ 其它窗口的占位页失去唯一驱动源、永远补不上像素 | `--multipage-clear-synced-pending`：只把本窗口这一轮同步渲染的页（取 `--multipage-sync-blocking` 的返回值，即同步前的 range）出队；幸存队项保留 + 重启计时起点 + 重排两个 timer；队空才整清（`--multipage-reset-async-state`，态 A 仍用它） |

**三层兜底（决策 D5）**：① 视口内同步（point 页 + 沿 `--multipage-scroll-direction` 相邻的一页）；② 超时强制同步（`seshat-reader-render-async-timeout`，唯一不依赖 timer 的保险）；③ `run-at-time` 周期推进——**idle timer 只作首轮启动**，因为 daemon Emacs 的一个 idle 窗口只 fire 一次（批次 0 的 G3b 实测 ticks=1，`nil REPEAT` 也不行），不能当自续驱动。

**与 canvas 后端的关系**：`--page-size` 走独立的轻量路径（`fz_load_page → fz_bound_page → fz_drop_page`），**不建 display list、不分配像素、不写 `DocPage` 缓存、不动 `DocState`**（含 `current_page_number`），实测 100 次调用后进程 RSS 增量 0 kB；它返回的 `(W H)` 与 `--page-image-spec` 的 `:width`/`:height` **同口径**（`:scale 1` 后的显示尺寸，36 组样本逐值相等），因此占位行与真实 image 的显示尺寸天然一致。像素后补仍走 `--page-image-spec` → canvas 缓冲（每页 ≈1.9 MB），本项**不改内存模型**：异步只改变「何时渲染」，驻留集与缓存上限一概不动（扩大驻留集会直接撞 75 MB 告警线）。

**与 `--scale 1` 修复的关系**：canvas spec 缺 `:scale` 会让 Emacs 按 `image-scaling-factor` 放大 1.2×，而 `--multipage-page-pixel-height` 读声明值 ⇒ 页高系统性少算约 20%（单页最多 365 px）。该缺陷由本计划的批次 0 S2 真机测量暴露并同批修掉；不修则「占位页高 == 真实 image 行高」这条不变量在 canvas 后端下根本不成立，两阶段渲染会引入跳变。

## 多窗口布局状态的两级归属（2026-10-29）

同一文档可以同时显示在多个窗口（同 frame 上下分窗，或跨 frame 各一个）。**纵向**上每个窗口各自滚动、互不干扰（2026-10-29 起，P1 follow-up 交付）；本节说明哪些状态放在 buffer 级、哪些必须放在窗口级，以及为什么这么分。背景与验收记录见 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`。

- **buffer 级**（一个文档一份，所有窗口共享）：驻留行表 `seshat-reader--pages`（升序 `(PAGE MARKER . SPEC)`——页行**本身就是 buffer 文本**，不可能按窗口各存一套，那等于复活多套布局）、spec 缓存与页尺寸缓存、渲染代际与失败计数、`seshat-reader--multipage-scroll-direction`（预取方向）。
- **窗口级**（每个窗口一份）：**可见范围**（由 `window-start` / `window-end` 经 `--multipage-visible-range` 派生，不单独存储）、**上次同步区间**（window-parameter `seshat-reader--range-parameter`，值 `(BUFFER . RANGE)`，读时校验 buffer——窗口切 buffer 再切回时参数不会自动清除）、`window-vscroll` / `window-hscroll`、`fit-mode` 与缩放。
- **驻留集语义：从「某窗口视口 ± preload」扩大为「所有显示该 buffer 的窗口可见范围的并集」**（`--multipage-all-visible-pages`，遍历 `frame-list` → `window-list FRAME`，只留显示本 buffer 的窗口）。**回收只按并集**（`--multipage-sync-blocking` / `--multipage-sync-async` 的回收判据是 `(not (memq page keep))`），而**渲染循环、渲染失败清零、预取边界、早退判据仍按本窗口 range**。两者不能混：并集只回答「哪些行不能删」，不回答「哪些页该由本窗口渲染」；用并集喂渲染会让队列膨胀到并集大小，并让一个窗口的占位行覆盖另一个窗口刚补好的像素。
- **早退判据按窗口**：`--multipage-last-range-for` / `--multipage-set-last-range` 读写窗口参数；修前是 buffer 级单值，于是「区间未变即早退」在多窗口下永远按「最后一个跑过的窗口」记账，早退与否取决于命令顺序（用户感知为**「随机」**）。`--multipage-force-sync` 走 `force` 形参：既绕过早退、也**不**写回记账（保持「强制同步 ≠ 已同步」的契约）。`--multipage-clear` 与态 A 复位必须**遍历所有窗口**清参数，否则会留下「行表已空 + 区间恰好相等 → 早退 → 行永不重建」的永久空白。
- **重锚的锚点是「最近的页行」**（`--multipage-row-nearest`：起点 ≤ POS 的最后一个页行，优先前驱、否则后继），不是「最小驻留页」；`--ensure-window-layout` 仍对 hook 报告的**每一个**窗口执行——它是 `split-window` / 换 buffer / `--render-buffer` 重载 / 回收删行四条路径上**唯一**的纠正点，移除会引入新的错位。锚点换掉后，回收删行把某窗口的 `window-start` 推到页间空行时也能回到**它自己**那一页，而不是被钉到当前驻留集的下沿。顺序固定为 sync → 重锚 → `--ensure-centered`（sync 会移动 marker）。
- **与 P2-B 决策 D8 的一致性**：pending 渲染队列是 buffer 级并集（与驻留集同一来源 `--multipage-all-visible-pages`），强制同步是窗口级操作（只把本窗口这一轮同步渲染的页出队）。两者是同一条口径的两个消费方——队列管「谁的像素还没补上」，驻留集管「哪些行不能删」。内存上限也按这条口径算：并集 = 两窗口之和，`--multipage-resident-spec-megabytes` 的估算与 75 MB 告警线不变。

## 搜索与 ink 渲染流程（2026-10-25）

两条能力的共同点：**装饰只有一个出口**——文档级装饰表 + `seshat-reader-annotation--redraw-highlights` 的全量重投。因此新增能力不新建渲染管线，只往同一次投喂里加一路几何。

### 跨页文本搜索

- **为什么整本扫描**：状态行要显示「第 i/N 个命中」，N 必须先知道；MuPDF 只给按页的 `fz_search_page`，没有文档级搜索 API。不重建文本索引是选它的理由——797 页文档整本扫描约 **1.1 秒**（`seshat-reader-search--scan` 逐页走，边界由 `seshat-reader-current-doc-pagecount` 约束）。
- **按页缓存**：`seshat-reader-search--page-results`（buffer-local 哈希，page → rect 列表）+ `seshat-reader-search--matches`（摊平后的 `(page . rect)` 序列，页号升序、页内保持 MuPDF 命中顺序，故序列确定）。跳转只移动 `--index`，不重新搜索；缓冲随 buffer 消失，无全局状态。
- **双上限**：单页由 C 侧 `SEARCH_PAGE_MAX_QUADS`（1024）硬夹紧，Lisp 侧 `--truncated-p` 判定后在状态行显式提示「仅显示前 1024 条」；总量由 `seshat-reader-search-max-matches`（默认 20000）控制，达到即停止扫描并置 `--capped`，否则一条 `.` 能扫出几十万条命中、几十 MB 常驻内存。
- **装饰共存钩子**：搜索命中不做自己的 `--clear-highlights`，而是注册 buffer-local 的 `seshat-reader-annotation-extra-decorations-function`——由 `seshat-reader-annotation--redraw-highlights` 在投喂「批注 rect → 框选闪现」之后再取当前页命中。搜索、跳转、退出都走同一次全量重投，因此三路装饰（批注 / 闪现 / 命中）永远同步，不会互相擦除。批注模块未加载时搜索降级为自投（clear → add → refresh）。
- **临时键表而非改 mode-map**：`set-transient-map` + keep 谓词（会话 active 且同一 buffer）让 `n` / `p` 只在会话存续期间表示下一个/上一个命中，退出即恢复翻页语义；把 `n` / `p` 写进 `seshat-reader-mode-map` 会永久抢掉翻页。
- **页号基数**：`--search-page` 与三个装饰入口同为 **1-based**（`resolve_page_arg` 统一校验并做唯一一次 `-1`），Lisp 侧不做换算；`--text-in-rect` / `--rects-in-rect` 保留历史 **0-based**（服务于已在页索引空间工作的选区代码）。见 `openspec/decisions.md` 的「C 侧页号基数约定」。

### ink 渲染流程（解析 → 缓存 → 投喂 stroke）

1. **解析**（纯 Lisp，零 C 依赖，可单测）：`seshat-reader-annotation--ink-strokes-from-location` 把 `location` 的每个 `ink:` 段解为 `(PAGE R G B ALPHA WIDTH POINTS TRUNCATED)`。颜色只认恰好 8 位 `#AARRGGBB`；缺颜色/宽度、非有限数、坐标个数为奇数、点数为 0 均**整笔跳过**（画歪一笔比不画更误导）；超过 1024 点截断为前 1024 点并标记 `TRUNCATED`（整笔丢弃等于用户笔迹凭空消失）。解析有界：`location` 先按 64 KB 截断。
2. **过滤与缓存**：重绘只投**当前文档**的批注（`--cached-entries` 做跨文档过滤），每页笔迹集合按 buffer 缓存（`--annotation-strokes`），避免每次重绘都重新解析整本文档。
3. **投喂**：`--add-stroke`（`page r g b alpha width points`，页号 **1-based**，`points` 为扁平 `(x0 y0 x1 y1 …)`）→ C 侧 `Decoration` 表追加 `DECORATION_KIND_STROKE` 条目（`pts` 堆分配、渲染时逐条深拷贝进快照）→ 渲染函数在暗色像素变换（`fz_tint_pixmap`，或未设 tint 时的 `fz_invert_pixmap_luminance` + `fz_gamma_pixmap`）**之后**、导出 BGRA 进 canvas 缓冲**之前**绘制（圆头圆角），因此缩放后与页面同变换对齐。
4. **投喂顺序（唯一约定）**：`clear` → 批注 rect → 框选闪现 → 搜索命中 → **ink 笔迹** → `refresh`。ink 放在最后是因为它是唯一带 alpha 且可能很长的折线，先画不会被后画的半透明矩形叠加影响判断；顺序写进 `seshat-reader-annotation--redraw-highlights`，新增装饰路必须插进这条链而不是另起一条。
5. **失败隔离**：缺 stroke 入口（旧 `.so`）或 ink 解析失败时只跳过 ink，rect 装饰照常投喂；返回值仍只统计批注 rect 条数（ink 不进这个计数）。
6. **坐标**：ink 点与 `rect:` 同 page space（页面 pt、原点左上、y 向下），**不翻转**（数值证据见 `docs/emacs-reader.md` §5「手写轨迹显示」）。

## 数据流

- 桌面端/Android 经 WebDAV 同步文件，经 REST 同步阅读进度/批注
- **服务端侧**的数据流（WebDAV 写后自动 git commit、ETag 用工作区内容即时 blob hash、敏感/本地模型任务经任务队列路由到本地处理节点）见 keystone 仓 `docs/architecture.md`
