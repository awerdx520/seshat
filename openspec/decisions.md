# 架构决策日志

记录重大架构决策，格式：日期 + 决策 + 理由。

## 2026-10-11 — 个人笔记系统初始决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 静态加密语义（服务端可读明文 + 磁盘/DB 加密） | 用户显式选择；需服务端做全文索引，E2EE 下无法索引 |
| 2 | 服务端 Go + Android Kotlin + 桌面 elisp | 用户显式选择；Go 单二进制部署、WebDAV 生态成熟 |
| 3 | 云 VPS 部署 | 用户显式选择；需外网可访问 |
| 4 | WebDAV 双重定位（内部同步 + 对外出口） | 用户显式选择；对外给外部应用使用 |
| 5 | 单用户访问控制 | 用户显式选择；简单令牌认证 |
| 6 | git 版本化 + ETag 乐观锁处理文本冲突 | 详见 docs/adr/0001-git-versioning-conflict-resolution.md；WebDAV 整文件替换模型 + 外部应用不受控 |
| 7 | 对外 WebDAV 可读写 + 范围受限 + 每次写自动 commit | 用户显式选择；外部应用需要读写能力 |
| 8 | LLM 后端：混合（云端 API + 本地处理节点），本地节点为纯推理节点、结果明文回传 | 用户显式选择；VPS 无算力跑本地模型，详见 docs/adr/0002-llm-hybrid-backend.md |
| 9 | 对外 WebDAV 的 ETag/索引按「挂载目录相对 repo 根偏移」计算 | code-reviewer 复审发现路径错位，加 offset 参数修正（详见 internal/webdav/versioned.go） |

## 2026-10-12 — 品牌改名：notes → Seshat

将项目品牌由 `notes` 更名为 `Seshat`，覆盖三个命名域，边界如下：

- **A 品牌标识域**：Go module 与 import 路径、Elisp 包前缀与文件名、Android 源码包名、App 显示名、二进制/镜像名、systemd unit 名、文档标题。属纯标识替换，改完编译即可验证。
- **B 运行时契约域**：环境变量 `NOTES_*` → `SESHAT_*`、systemd unit 名、compose service/container 名、运行用户/组名。需与部署端配置同步。
- **C 数据契约域**：数据目录与文件名（`./data/notes*` → `./data/seshat*`）、WebDAV 远端目录、客户端本地目录、prefs 文件名。属**数据迁移**，改完必须移动既有文件并同步客户端配置，否则运行时静默失效；迁移用复制（`cp -a`）而非移动，旧目录在观察期内保留作回滚点。

用户裁决（D1–D5；D1/D2/D3/D5 均为「乙」＝彻底改）：

| 编号 | 决策 | 选项 | 裁决 |
|---|---|---|---|
| D1 | Android `applicationId` | 甲：保留 `com.notes.app`；乙：改 `com.seshat.app`（新 App，需重装并重配令牌） | **乙**（彻底改） |
| D2 | 系统用户/组名 `notes` | 甲：保留；乙：改 `seshat`（需 usermod + 全量 chown + 停机） | **乙**（彻底改） |
| D3 | Android prefs 文件名 | 甲：保留 `notes_sync`/`notes_sync_secure`；乙：改 `seshat_sync`/`seshat_sync_secure` | **乙**（彻底改） |
| D4 | VPS 数据实况 | 需用户在 VPS 上回报实际值（`webdav.root`、客户端 `remote-dir`/`local-dir`、目录层级） | 待回报（不阻塞实施） |
| D5 | `NOTES_DIR` → `SESHAT_DIR` | 甲：保留；乙：改 | **乙**（彻底改） |

明确保留清单（禁止机械替换，L3 审计据此判定）：

- FTS5 虚表名 `notes_fts`（真实 DB 表名，改名需 DB 迁移且收益为零）；
- Go 函数 `ReviewNotes` 及其测试（LLM 审查能力函数名，属业务语义而非品牌）；
- 中文用词「笔记」「笔记目录」「笔记同步」（领域语义）；
- org 文件头 `Keywords`（语义头，非品牌）；
- `:notes:` tag（数据语义，可能已被真实笔记引用）。

理由：一次性彻底改名以避免长期两名并存的心智负担；C 域改名按数据迁移单独处理，以复制 + 观察期降低风险。完整方案与实施清单见 [openspec/active/seshat-rename.md](active/seshat-rename.md)。

## 2026-10-12 · seshat-reader 包彻底自研化改名

**决策**：把 vendor 进本仓库的 emacs-reader 派生包整体改名为自研包：feature、elisp 符号、文件名、C 模块对 elisp 可见的名字（注册名/buffer-local 变量）、模块 feature 与构建产物统一为 `seshat-reader-*` / `seshat-render-core`。

**理由**：① 消除对 `load-path` 前插顺序的隐性依赖（原先与上游 emacs-reader 共用 feature 名 `reader`）；② 符号归属可辨识，自研扩展与上游代码不再混用命名空间；③ 为后续自研功能（批注采集、翻译/LLM、区域 OCR）提供干净的命名空间。

**代价（已接受）**：① 放弃与上游逐文件对照与同步能力，上游更新只能人工比对；② evil 键位从 evil-collection 转为本地自维护；③ C 源文件名与产物名不再一致。以上均已记入 openspec/tech-debt.md。

## 2026-10-16 · M11.3 批注的文档标识与位置约定

**决策**：Emacs 侧批注的 `document_id` 采用 `<根标签>:<相对路径>`（根由 `seshat-reader-annotation-roots` 配置，多根取最长匹配，未命中降级 `local:<绝对路径>` 并提示不跨端共享）；`location` 采用 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（1-based 页码 + 页面坐标，两位小数，不支持旋转页面）。

**理由**：① 电子书不在笔记同步域内，笔记的「相对路径」约定无法覆盖；② 两者由单一函数（`seshat-reader-annotation--doc-id` / `--location`）派生，M7 引入服务端 uid 时只需替换这两处；③ location 用页面坐标而非屏幕坐标，与缩放无关，便于跨端复现。

**代价**：① 路径依赖——电子书改名/移动会使既有批注失锚（由 M7 的 uid 化根治）；② 旋转页面坐标静默错误（Lisp 无法读取旋转状态）；③ 服务端 `location` 为不透明字符串，跨端语义需各端自行约定（EPUB 待 M10.3）。

## 2026-10-16 · 阅读器翻译/解释走 go-translate + posframe（而非自建 LLM 通道）

**决策**：阅读器内的选中文本翻译/解释复用用户已有的 Emacs 生态组件——翻译用 `go-translate`(gt) 的 youdao/google 引擎、解释用 `gt-chatgpt-engine`，UI 用 `posframe` 弹出；并新建 `reader` / `reader-explain` 两个 gt 预设（用户配置侧）供阅读器按名取用。

**理由**：① 服务端 LLM 增值层尚未暴露客户端 HTTP 接口，自建通道需先做服务端工作，阻塞且重复；② gt/posframe 用户已配置完成，零额外依赖即可用；③ 阅读器只需把「选区文本（字符串）」交给 gt（`gt-taker :text` 原生支持字符串），桥接成本极低；④ 引擎/端点可由用户随时替换（含改走本地模型），不锁死在服务端。

**代价**：① 与服务端 LLM 能力（本地节点路由、统一密钥管理、调用历史）暂时割裂，待服务端补齐端点后可能再次迁移；② 依赖第三方免费端点（youdao/google）的可用性；③ gt 的运行期行为有若干陷阱（`pick` 默认按段落切分、预设对象是全局单例、pop/pin 为不同缓冲区），已在实现中规避并写入 tech-debt。

## 2026-10-16 · 提交前密钥防护采用 pre-commit 框架 + 双本地钩子

**决策**：提交前密钥防护采用 pre-commit 框架 + 两个本地钩子——`gitleaks`（扫描暂存区内容）与 `no-secret-files`（keystore / env / 私钥文件名黑名单）。

**理由**：① 本机已具备 pre-commit 4.7.0 与 gitleaks，零新增运行时依赖；② 声明式配置随仓库分发，并提供统一的钩子运行入口 `pre-commit run --all-files`；gitleaks 另有独立命令（`gitleaks dir .` / `gitleaks git --log-opts="--all"`）可对工作区与全 git 历史做内容扫描，将来可直接复用为 CI 步骤。否决裸 git hook 方案（需每个克隆者手动配置 `core.hooksPath`、无统一运行入口、接 CI 需重写）。

**附带决策**：暂不引入 `gitleaks.toml` 自定义规则/白名单（实测：全 git 历史 21 个 commit 零命中；`gitleaks dir .` 在工作区命中 2 处，均位于未跟踪且被 `.gitignore` 忽略、从未提交的本地文件 `android/keystore.properties`，非 git 泄漏；`deploy/seshat.env.example` 这类模板由文件名钩子的 `exclude` 放行），出现误报时再引入。

**已知边界**：本地钩子可被 `--no-verify` 绕过，远端 CI 兜底未部署（待后续决策）。`pre-commit run --all-files` 不触发 gitleaks 的全仓库内容扫描（entry 固定 `--staged`），该命令对 `gitleaks` 无全量语义。

## 2026-10-16 · 批注离线优先（本地队列 + 自动同步）

**决策**：批注的创建/删除在服务不可用时**不报错**，改为写入本地队列（`~/.local/share/seshat/annotation-queue.eld`，原子写）；服务恢复后自动推进同步（启动后延迟首次 + 周期 + 手动 + 机会性）。列表在离线时仍渲染本地项并标 `[待同步]`。同步侧实现幂等：create 先比对服务端已有 `(location, text)`（相同即视为已同步、不发 POST）；delete 的 404 视为成功。

**理由**：阅读/记录场景常在网络不稳或服务未启动时发生，网络状态不应决定用户能否做批注；「先记录、后同步」是离线优先的基本要求。用户明确要求「服务不可用时用本地缓存，不要报服务不可用」。

**代价**：① 本地队列是 Emacs 侧的额外状态，需处理文件损坏（保留原文件不覆盖）与上限（默认 1000 条）；② 无服务端 `client_uuid`，去重依赖 `(location, text)` 内容比对，对「同位置同文本的有意重复」不敏感；③ 阅读进度仍未纳入离线（另议）；④ 队列与同步逻辑增加了客户端复杂度。

## 2026-10-17 · `seshat:` 链接协议（笔记 ↔ 书籍/批注）

**决策**：定义 org 链接协议 `seshat:<doc-id>#<location>`（`#<location>` 可省略）。`doc-id` 即批注的 `document_id`（`<书库标签>:<相对路径>`），`location` 与批注 `location` 同源同构（`page:<n>;rect:…`），不新增解析器；解析时取**最后一个** `#`（`string-match "#\\([^#]*\\)\\'"`）。注册 `:follow`（打开书籍并跳页，用 `find-buffer-visiting` 复用已有 reader buffer）与 `:store`（集成 `org-store-link`），**不做百分号转义**。

**理由**：① location 与批注同构，解析/生成两端共用一套约定，无需第二套解析器；② 转义不可行——`url-hexify-string` 会转义 `:`/`/`（破坏 doc-id 结构），org 又会对 `%` 二次转义，双重转义不自洽；③ 因此把不变量前移到生成端：`doc-id` 含 `#`/`%` 时 `user-error` 并提示重命名文件，解析端只需「最后一个 `#` 分割」这一简单规则。

**代价 / 迁移点**：① 含 `#`/`%` 的文档名无法生成引用（记 tech-debt）；② 链接以 **doc-id 文本**承载身份，电子书改名/移动会使既有链接失锚——M7 引入 uid 后只需替换两处：`seshat-reader-annotation--doc-id`（正向）与 `seshat-reader-reference--file-from-doc-id`（反向），解析层可加 uid 形式回退分支；③ 反向解析按 tag 精确匹配，同 tag 多根时只取第一个（tag 需唯一）。

## 2026-10-17 · 阅读器面板：承载层与 popper 分工

**决策**：阅读器信息面板采用 **pop 式底部弹出**（`display-buffer-below-selected` / `display-buffer-at-bottom`，由 `seshat-reader-sidebar-position` 切换），**单窗口 + per-kind 高度记忆**（批注与译文各自恢复高度，会话内 alist）；面板显示必须经 `display-buffer`（幂等），并用 `display-buffer-overriding-action` 保证本包布局优先于 `display-buffer-alist` 中的 popper 规则；popper 只负责**登记与开关**（`seshat-reader-sidebar-buffer-p` / `seshat-reader-sidebar-display-buffer` 分流），布局仍由本包掌控；用 `post-command-select-window` 实现光标跟随（`seshat-reader-sidebar-select-window` 可关）。

**理由**：① 侧窗（side window）与 posframe 分别带来布局抢占与焦点/自动消失问题，pop 式底部窗口行为最接近用户预期的 `*Help*`；② `window-toggle-side-windows` 是 **frame 级**全量开关，会连带删除/恢复 eca-chat 与 which-key 的侧窗，故**禁用**，本包只做本包面板窗口的 `delete-window`；③ 首次显示走 overriding-action、popper 重开走 display-function 分流，二者落到同一布局，保证「开关前后布局不变」这一不变量。

**代价**：① 底部单窗口下批注与译文互斥（后显示者接管）；② `window-height` 只对新建窗口生效，改高度对已显示面板不自动重排；③ popper 名单是硬编码正则，改 `seshat-reader-sidebar-translate-buffer-name` 后 popper 不再登记该面板；④ popper 的 `popper--delete-popup` 走 `quit-window`，不调本包 `--capture-state`，popper 关闭前的 resize 不会被记住（best-effort）。

## 2026-10-17 · ETAF 作为可选渲染层（软依赖）

**决策**：面板内容可选由 **ETAF** 渲染（`seshat-reader-etaf.el`），但 ETAF **四仓库不入 notes 仓库**——只 clone 到 `~/WorkSpace/emacs-taf/`，由用户配置侧 `load-path`（四仓库根 + 各自 `lisp/`）加载。模块内是**硬 `(require 'etaf-ui)`**，所有调用点用 `ignore-errors` 按需加载（`NOERROR` 只吞「找不到文件」）；降级四态（未安装 / 半损坏 / 渲染抛错 / 开关关闭）一律回退纯文本渲染，面板不空白、功能不中断。样式**不用** `etaf-ui` 的 label/badge/tag/divider，改用按 `background-mode` 取值的**内置双色板** + 普通 `text`（样式放父 Host），仅按钮用 `etaf-button`。

**理由**：① PoC 判定可行（零 warning 编译、加载 0.09s、首渲染 0.002s、无 native 依赖、+6.7MB），性能与兼容性风险可控；② 依赖不入库可让仓库零新增依赖文件、未安装者零影响；③ `etaf-label`/`etaf-badge` 的文字色/底色写死（`#252A2E`/`#FFFDF8`）且**覆盖父 Host 的 `:color`**，暗色主题（如 `doom-vibrant`）下不可读，故弃用其排版组件。

**代价**：① ETAF 0.x API 可能变动，需跟随上游；② pty/终端 frame 下 `etaf-mount` 会挂起（GUI frame 正常），终端用户可能不可用；③ 配色只用内置双色板、不跟随具体主题变量，换主题后需重新渲染面板；④ 依赖 ETAF 的加载顺序（evil 先启用再 mount 才能让 `:keys` 优先）。

## 2026-10-17 · `seshat-reader-translate-render` 默认改为 `sidebar`

**决策**：`seshat-reader-translate-render` 的默认值由 `pop` 改为 `sidebar`——译文/解释默认写入底部面板，而非 posframe。`pop`（posframe）/`pin` 保留，可随时切回；`seshat-reader-sidebar-enabled` 为 `nil` 时 `sidebar` 自动退回 posframe 行为。

**理由**：译文/解释与批注统一进同一面板，阅读区不被抢占；posframe 会抢焦点并在超时后自动消失（`gt-posframe-pop-render-timeout` 是全局 90s），阅读场景需要可停留、可回看的文本。

**代价**：**破坏性变更**——升级后译文弹窗行为改变；用户若偏好 posframe 需显式设回 `pop`。且底部单窗口下译文会接管、顶掉批注列表（已确认为设计行为；若要同屏需另立 section 统一渲染方案）。

## 2026-10-18 · 阅读器译文/解释改用面板内 Markdown 文本 buffer（ETAF 只保留批注卡片）

**决策**：译文/解释的呈现由「ETAF 组件树排版」改为**面板内只读 Markdown 文本 buffer**——gt 只把纯文本渲染到隐藏中转 buffer（` *Seshat gt*`，`:window-config` = `(display-buffer-no-window)` + `allow-no-window`），由 `:then` 回调取文本写入展示 buffer（`seshat-reader-sidebar-translate-buffer-name`），以 `gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链设视图（`truncate-lines`=nil + 显式 `word-wrap`=t、`header-line` 区分译文/解释）；面板键位 `q` / `C-c C-s` 改由 minor mode `seshat-reader-translate-panel-mode` 承载。**ETAF 渲染层收敛为只渲染批注卡片列表**（含分页），`seshat-reader-etaf-render-translate` 及其译文组件树删除。

**理由**：① ETAF 画布 viewport 固定，长译文被裁剪、无法原生滚动到全文；② 画布内容**不可选中复制**（阅读场景的核心诉求——摘录译文/搜索结果二次利用）；③ CJK 在 ETAF 中的 2 列宽度测量存在风险，长段落折行不可靠；④ Markdown 交给 `gfm-view-mode` 渲染可获得原生折行、滚动、复制、isearch，且无需在渲染层重复实现排版。**2026-10-18 用户确认。**

**代价**：① markdown-mode 成为软依赖（缺失时降级 `text-mode`，不折行美化、不隐藏标记）；② 面板内无法用 ETAF 的 `:keys` 统一承载译文键位，改由 minor mode 承载；③ ETAF 的译文排版代码（约 240 行）删除，`seshat-reader-etaf.el` 由 929 行降至 690 行。
