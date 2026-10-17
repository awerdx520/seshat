# 架构设计

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

## 模块划分（服务端）

- cmd/server：入口
- internal/config：配置加载（config.yaml + 环境变量覆盖）
- internal/auth：单用户认证
- internal/storage：SQLite(SQLCipher) + 文件系统 + git 版本库
- internal/logging：结构化日志
- internal/webdav：WebDAV 服务（后续里程碑）
- internal/api：REST API（后续里程碑）
- internal/index：全文索引 FTS5（后续里程碑）
- internal/llm：LLM 接入层（后续里程碑）

## 同步协议

- 文件（org/附件/电子书）→ WebDAV，ETag 乐观锁
- 状态（阅读进度/批注）→ REST，后写覆盖 + 时间戳冲突检测
- 附件（二进制）→ 内容寻址存储（SHA256）+ 「附件清单」文件纳入 git

### 客户端侧批注同步约定（离线优先）

Emacs 阅读器（`seshat-reader`）的批注同步在客户端侧叠加一层**离线队列**，用于吸收服务端不可用时的创建/删除操作。约定如下：

- **离线入队**：create/delete 在服务端不可用时写入本地队列（`seshat-reader-annotation-queue-file`，原子写），不报错；列表离线时仍渲染本地项并标 `[待同步]`。
- **create 幂等去重**：同步前先拉取该文档现有批注，比对 `(location, text)`；若已存在完全相同的批注即视为已同步、**不重复 POST**。
- **delete 视为成功**：删除返回的 **404 视为成功**（幂等删除——服务端已无此批注即达成目标）；其它非 2xx 或异常才停止本轮。
- **失败即停**：任一条同步失败即停止本轮，该条及其后续项保留在队列中待下次同步（不丢弃、不报错）。
- **服务端零改动**：队列与同步均为**客户端侧**行为，不改变服务端 REST 契约（端点行为与 `document_id`/`location`/`text` 语义均不变）。

## `seshat:` 引用协议（M11.4）

笔记与阅读器之间的双向引用通道，格式为 **`seshat:<doc-id>[#<location>]`**：

| 场景 | 链接 |
|---|---|
| 整本书 | `seshat:ebook:d2l-zh-pytorch.pdf` |
| 某页 | `seshat:ebook:d2l-zh-pytorch.pdf#page:112` |
| 某区域（批注级） | `seshat:ebook:d2l-zh-pytorch.pdf#page:112;rect:50.00,100.00,545.00,140.00` |
| 不在任何书库根下的文档 | `seshat:local:/abs/path.pdf#page:3` |

**解析规则**：

- 剥掉 `seshat:` 前缀后，按**最后一个** `#` 分割为 doc-id 与 location（doc-id 自身含 `:`，如 `ebook:` 标签与 `local:` 绝对路径，故不能按 `:` 或首个 `#` 切分）；
- **不做任何百分号转义**：不使用 `url-hexify-string`（它会把 `:`、`/` 一并转义，破坏 doc-id 可读性并切断与批注 `document_id` 的复用），也不自造 `%23` 链路（org 自身会对 `%` 二次转义，双重转义无法自洽）；
- 因此 **doc-id 不得包含 `#` 与 `%`**：构造链接时检测到这两个字符即 `user-error` 并提示重命名文件；非法链接解析返回 nil。

**与批注 `location` 的同构关系**：批注的 `location` 形如 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（页码 1-based、页面坐标），链接片段**直接复用同一字符串**，不新增解析器。批注列表的行携带该字符串（文本属性），故「批注 → 引用」取值不触网；`page:` 段直接传给 `seshat-reader-goto-page`，`rect:` 段当前仅做格式校验（无高亮承载）。

**M7 uid 迁移点**：链接身份当前由 **doc-id 文本**承载。M7 引入 uid 后仅需替换两处——正向 `seshat-reader-annotation--doc-id`（文件 → doc-id）与反向 `seshat-reader-reference--file-from-doc-id`（doc-id → 绝对路径）；链接解析层可再加 uid 形式的回退分支。

## 阅读器面板分层（M11.7–M11.9）

面板分为「承载层 / 渲染层 / 兜底渲染」三层，渲染层可选，任一层不可用时下层接管。

**承载层 `seshat-reader-sidebar`（零依赖）**：

- **pop 式底部弹出**：`seshat-reader-sidebar-position` 取 `below-selected`（当前窗口下方分割，形如 `*Help*`）或 `at-bottom`（frame 底部整宽）。同一时刻只有一个面板窗口，批注与译文**后显示者接管**。
- **必须经 `display-buffer`**：首次显示、gt 的 `:window-config`、popper 重开三条路径都走 `display-buffer`，以保证**幂等**（同 buffer 同 kind 重复显示只复用窗口、不重建）；面板参数由 `seshat-reader-sidebar--display-params` **单一来源**生成。
- **`display-buffer-overriding-action`**：显示时用它包住 action list，使本包布局优先于 popper 在 `display-buffer-alist` 表头插入的规则；popper 重开（裸 `display-buffer`）时改由 `seshat-reader-sidebar-display-buffer` 分流回本包逻辑，故两条路径布局一致。
- **per-kind 高度记忆**：`seshat-reader-sidebar--state` 为内存 alist（零依赖）；切换内容前先捕获当前窗口高度（比例）存给其 kind，再用目标 kind 记住的高度新建窗口。仅会话内有效，不持久化。
- **禁用 `window-toggle-side-windows`**：它是 frame 级全量开关（会连带删除/恢复 eca-chat、which-key 的侧窗），toggle 只对本包面板窗口做 `delete-window`。

**渲染层 `seshat-reader-etaf`（可选，依赖 `etaf-ui`）**：

- 组件树：标题栏（文档名 + 条数）、批注卡片（页码徽章 / 摘要 / `[待同步]` 标记 / 选中标记）、底部键位提示；译文为标题 + 可折叠原文 + 正文排版。
- 交互：`:keys`（`RET` / `d` / `C-c C-r` / `q` / `n` / `p`）+ `:on-press`。Host keys 位于 `emulation-mode-map-alists` 最前，evil 不会吃掉——**但依赖加载顺序**：evil 先启用、面板再 mount 才成立；运行期 toggle evil 需重新 mount 面板。
- 双色板：按 `background-mode` 取内置明/暗配色，文字一律用普通 `text` + 父 Host 样式（`etaf-label` / `etaf-badge` 自带颜色会覆盖父 Host，故不用）；换主题后需重新渲染面板。
- 增量更新：状态（items / 选中项 / 文档标签）放在 `etaf-ref` 中，改 ref 由 ETAF 做 keyed patch + 行级 diff，不整树重渲染。
- 降级：未安装 / `require` 抛错 / 渲染抛错三态均回退兜底渲染（细节见 [`docs/configuration.md`](configuration.md)「ETAF 渲染层」）。

**兜底渲染**：

- 批注列表：`seshat-reader-annotation--render-list` 的纯文本 + 文本属性渲染，行携带 `id` / `page` / `queue-uuid` / `location` 属性。ETAF 已挂载时该函数**不再 `erase-buffer`**（交给渲染层增量刷新），否则随后的 `etaf-runtime-flush` 会因缓冲区被清空报 `Args out of range`。
- 译文：gt 自带的 `gt-buffer-render`（`sidebar` 渲染方式下中转 buffer 被隐藏，`pop` / `pin` 仍走 posframe）。

**数据流**：`seshat-reader-annotation--refresh-list`（拉服务端批注 + 读本地队列）→ items（服务端项在前、本地待同步项在后；本地项以 `:uuid` 标识、无 `:id`）→ 渲染层（ETAF）或兜底文本渲染 → `seshat-reader-sidebar-show` → `display-buffer`（参数单一来源、幂等、可选光标跟随）。

## 数据流

- 桌面端/Android 经 WebDAV 同步文件，经 REST 同步阅读进度/批注
- 服务端 WebDAV 写操作后自动 git commit（记录来源），ETag 用工作区内容即时 blob hash
- 敏感/需本地模型任务经任务队列路由到本地处理节点，结果明文回传服务端
