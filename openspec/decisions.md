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

理由：一次性彻底改名以避免长期两名并存的心智负担；C 域改名按数据迁移单独处理，以复制 + 观察期降低风险。完整方案与实施清单见 [openspec/completed/seshat-rename.md](completed/seshat-rename.md)。

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

## 2026-10-18 · 译文/解释面板 Markdown 模板与高度下限可配置

**决策**：译文/解释面板的正文呈现改为可配置 Markdown 模板
`seshat-reader-translate-template`（默认「`# 标题` + `*语言对*` + 可选
`> **原文**` 引用块 + `---` + 正文」，`nil` 退回纯正文）；面板自适应高度的
下限改为可配置 `seshat-reader-sidebar-min-height`（默认 0.25，至少 1 行），
区间为 min–max。

**理由**：
1. 纯正文面板缺少视觉层级，长译文与标题、原文混在一起不易扫读；
2. 硬编码 5 行下限在短译文场景下明显偏矮，用户每次都要手动拉伸窗口；
3. 模板与高度都用 defcustom 暴露，避免把样式偏好写死在代码里；
4. 模板错误有运行时回退（非法占位符 → 纯正文 + 警告），不阻断翻译流程。

**代价**：
1. header-line 与正文 `# 标题` 有意重复（窗口装饰 vs 文档层级），用户需通过自定义模板去掉 `%k` 才能消除；
2. `--content-height` 改用 `min(首行像素高, frame-char-height)` 属启发式估算，face-remapping 让正文行高于 char height 时会高估行数（保守方向，面板偏高而非裁内容）；
3. `--render-panel` / `--render-object` 新增可选 `langs` 参数，内部 API 面扩大（保持 `&optional` 向后兼容）。

## 2026-10-18 · Android 采用单 Activity Shell + 保留独立阅读器 Activity（M9.1）

**决策**：Android 端采用「单 Activity Shell + Fragment 内容区」——`MainActivity` 承载 `MaterialToolbar` + `FragmentContainerView` + `BottomNavigationView`（笔记 / 阅读双 tab），tab 切换用 `show/hide` 保留状态；epub/pdf 阅读器与 GTD 保持独立全屏 Activity，由 Fragment 内入口启动。UI 栈继续用 **View/XML + Material Components**，不引入 Compose / Navigation Component / 协程 / Room；零新增第三方依赖（仅显式固定 `androidx.fragment:fragment:1.5.4`，原由 appcompat 传递引入）。

**理由**：① 现有 3274 行 UI 全部是 View/XML，M9.1 的定位是「可承载 Notes/Reader 的壳」而非重写；② `androidx.navigation`、`androidx.preference`、`fragment-ktx` 均不在本机 Gradle 缓存中，零新增依赖可离线构建；③ 阅读需要沉浸与全屏，嵌入 tab 会压缩阅读区并牵动既有阅读器实现（违背「零回归」目标）；④ 设置页必须复用 `SecurePrefs` 的加密创建与回退逻辑，而 `PreferenceFragmentCompat` 直接操作 `SharedPreferences` 会绕过加密。

**代价**：① 无 Navigation Component，深层页面（M9.3 列表→详情、M10 书架→阅读）需手写事务或后续引入；② 无 Compose，声明式 UI 的长期收益延后；③ Fragment 生命周期与 tab 恢复由手写 `commitNow()` 管理，正确性依赖自身实现；④ 设置页只承载两项配置，`remoteDir` 仍为默认 `/`。

## 2026-10-18 · Android 设置页安全加固（M9.1 安全审查后）

**决策**：① 机密（访问令牌）**绝不降级写入明文**——加密存储不可用时 `putSecret()` 返回 false、设置页禁用保存并告警，功能不可用优于凭据泄露；② 备份策略采用「保留 `allowBackup=true` + 排除同步配置两份 prefs」，而不是关闭整个应用备份（阅读进度、批注、org 文件仍可备份）；③ 服务端地址**仅接受 https**，拒绝 userinfo / 查询参数 / 锚点；④ 解密异常视为「配置不可用」而非崩溃，并提供「重置本地配置」自救入口；⑤ 增加「清除访问令牌」撤销路径。

**理由**：security-reviewer 安全审查发现 3 项 blocking（加密回退静默写明文、`allowBackup` 无排除规则、解密异常无兜底）与 3 项 major（URL 校验不拒 userinfo、放行 http、无凭据撤销路径）。这些均为「不需要攻击者具备特殊能力即可发生」的风险，超出既有威胁模型。

**代价**：① `sync/SecurePrefs.kt` 被修改（突破 M9.1 原定「既有模块零改动」边界，属安全例外，用户已批准）；② `GtdActivity` 只经 `SecurePrefs.getString` **读取**配置、不写令牌；但它调用 `SecurePrefs.open(this)` 未传 `onUnreadable`，加密不可用时属**静默使用** legacy 明文值（无新增泄露面，但无提示），已在 tech-debt 记录；③ 禁用 http 后，纯内网 http 部署需用户改用 https 反代；④ 加密不可用设备上设置页功能受限（设计取向：安全优先）。

## 2026-10-18 · 译文/解释模板拆分、去正文标题、原文默认显示

**决策**：翻译与解释使用各自独立的模板变量——`seshat-reader-translate-template`（默认 `"%l\n\n%q\n\n---\n\n%t\n"`）与新增的 `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`）；默认模板不再含 `%k`（正文标题），标题由 header-line 承担；`seshat-reader-translate-show-source` 默认值改为 `t`。渲染链路以可选 `context` 参数选择模板（`explain` → explain 模板，其余 → translate 模板）。

**理由**：
1. 两种用途的版式需求不同（解释不需要语言对行，译文需要），单一变量无法分别塑形；
2. 正文 `# Seshat 译文/解释` 与 header-line 完全重复，删除正文标题可减少冗余且不影响滚动时的定位；
3. 原文是理解译文的参照，默认关闭导致「看不见原始句子」，改为默认显示更符合阅读场景。

**代价**：
1. `show-source` 默认翻转属用户可见行为变更（面板默认更高）；
2. 模板由 1 个变 2 个，配置面扩大；
3. `%k` 保留但默认不用，自定义模板仍需理解 4 个占位符。

## 2026-10-18 · 批注列表去分页，改单列连续流

**决策**：删除批注列表的全部分页机制（`seshat-reader-annotation-page-size`、当前页、页数/切片/夹紧函数、4 个翻页命令、`]`/`[` 键位、纯文本页脚，以及 ETAF 的 page refs 与跨页选中逻辑）；批注列表改为**全量单列连续渲染**，徽章恒为「N 条」，`n`/`p` 只移动选中；ETAF 卡片列表去掉固定 12 行高度与内部滚动，渲染入口按条目数**显式计算 viewport 高度**（已挂载时 `etaf-runtime-refit`），面板靠窗口滚动查看超出部分。

**理由**：
1. 分页 + 固定 12 行内部滚动把列表切碎，无法连续浏览，`isearch` 只能搜当前页；
2. 「只删分页不删固定高度」会退化为 12 行内部滚动，问题依旧；
3. ETAF 根 viewport 高度固定、决定写入 buffer 的行数，必须按内容显式计算才能显示全部条目。

**代价**：
1. **破坏性**：删除 `seshat-reader-annotation-page-size` 与 `]`/`[` 键位，用户配置与肌肉记忆失效；
2. 全量渲染无虚拟化，条目极多时首次渲染成本线性增长（已记 tech-debt）；
3. viewport 高度按「每卡 2 行」保守估算，估算偏大（实测每卡 1 行）；实测
   `computed-viewport-height=66`、`buffer-lines=35`——ebox 只写实际内容行、
   不补空行，故无视觉副作用。

## 2026-10-18 · 译文/解释面板启用 visual-fill-column

**决策**：译文/解释面板在 `--prepare-view` 末尾启用 `visual-fill-column-mode`（软依赖，`seshat-reader-translate-visual-fill-column` 默认 t，可关），宽度沿用全局 `visual-fill-column-width`（nil → `fill-column`）；批注列表不启用。

**理由**：
1. 面板正文在宽窗口下拉满整行，长行阅读舒适度差；
2. 复用用户已有的 visual-fill-column 配置，不引入第二套宽度设置；
3. 批注列表的 ETAF 布局按 `window-body-width` 计算，`window-margins` 缩窄会错位，故不启用。

**代价**：
1. `visual-fill-column--enable` 会对 `selected-window` 重置 margin；`--disable` 还会重置 fringe。实现已加「仅面板已显示时才传 -1」的窗口守卫，避免选项为 nil 时每次渲染误清阅读器窗口；但启用路径（面板未显示时）的 selected-window margin 重置仍无法规避（影响窄）；
2. 新增一个软依赖（未安装时功能静默缺失，无提示）。

## 2026-10-18 · Android 设置存储分层与阅读器连续滚动容器（M9.2）

**决策**：① 配置分两层存储——机密（令牌）与服务端地址走 `SecurePrefs`（EncryptedSharedPreferences）；远程目录/主题/字号/翻页模式走新增的 `settings/AppPreferences`（普通 `seshat_app_prefs.xml`，不加密、参与系统备份）。② 阅读器连续滚动统一用 `RecyclerView`：PDF 单一容器 + 横向 `PagerSnapHelper`；EPUB 双容器（横向 `ViewPager2` / 竖向 `RecyclerView` of 高度自适应 `WebView`）。③ 阅读偏好（字号/翻页模式）**下次打开阅读器生效**，不做运行中热切换；主题**立即生效**（`AppCompatDelegate` + 新增 `SeshatApp`）。

**理由**：① 加密层初始化可能失败（Keystore 损坏/定制 ROM），若把主题与阅读偏好也放加密 prefs，会在加密不可用时一并失效；分层后非机密偏好始终可用，且无需为它们承担加密开销。② `ViewPager2` 竖向只支持整页吸附、无法零间隙连续滚动，而 `RecyclerView` 同时满足「横向吸附（`PagerSnapHelper`）」与「竖向连续」两种模式，避免同一页面维护两套容器。③ 热切换翻页模式需要迁移滚动位置、重建 WebView/位图，风险与收益不匹配；主题切换只影响资源重解析，可即时生效。④ `ScrollProgressMath` 抽成纯函数，让「可见位置 ↔ 进度锚点」的换算可 JVM 单测（`onScroll` 回调本身无法单测）。

**代价**：① 两套 prefs 文件增加理解成本（已在 `docs/android.md` 与 `docs/security.md` §7 说明）；② EPUB 竖向禁复用导致滚动时反复创建 `WebView`，章节多时有性能开销；③ WebView 高度测量依赖 `onPageFinished` 与随后的一次 JS 往返，测量完成前 item 高度为占位值，需要重锚兜底；④ PDF 竖向模式仍按「整页 item」连续堆叠（页内不连续），不是单页视口内的流式排版。

## 2026-10-18 · M7 文件身份采用服务端 uid（直接切换，无兼容层）

**决策**：文件身份采用服务端生成的 26 字符 Crockford Base32 uid（`crypto/rand` 16 字节，零新增依赖），`resources` 表为权威登记，路径降级为可变属性。状态表（`reading_progress` / `annotations`）在 v6 迁移中直接 `DROP` 重建为以 uid 为键；状态 API 不再接受 `document_id`，`/api/resolve?root=&path=` 是客户端获取 uid 的唯一入口。Emacs 端两处派生/调用点同步改造。

**理由**：① 服务端尚未部署、无存量生产数据，兼容期的维护成本（双列读写 + legacy 映射 + 兼容层分支）没有任何实际收益；② 改名/移动不再失锚，三端身份（Emacs `tag:path`、Android SHA-256）收敛到同一 uid；③ 一次切换比长期两套路径更不容易出错。

**代价**：① 破坏性变更——状态 API 与客户端不兼容，Emacs 必须同步升级（已纳入 M7 任务 B5），Android 留给后续里程碑；② 若将来有第三方客户端接入，需按 uid 契约实现。详见 `docs/adr/0003-uid-identity-model.md`。

## 2026-10-18 · M7 增量同步采用全局 changes.seq 游标

**决策**：增量同步采用「全局 `changes.seq` 单调游标 + 客户端 cursor」；删除写墓碑并保留 `delete` 事件；registry 是**派生状态**，可由文件系统 `rescan` 重建。

**理由**：单写者 SQLite 下最简单可靠，跨根统一；墓碑使客户端能感知删除；派生状态使钩子失败可修复。

**代价**：`changes` 无 TTL 会增长（单用户量级可忽略）；钩子失败窗口内事件缺失，需 rescan 兜底。详见 docs/adr/0004-incremental-change-log.md。

## 2026-10-18 · M7 多根映射：仅笔记根挂 WebDAV 与 FTS

**决策**：多根映射中仅 `roots[0]`（笔记根）挂 WebDAV 全量镜像与 FTS 索引，其余根（书库）只经 REST 按需读取；REST 写复用 `gitver.WriteAndCommit` + `If-Match`，不引入第二套冲突语义。

**理由**：契合路线图决策 5（笔记全量、电子书按需）；多根挂 WebDAV 会破坏路径命名空间；冲突检测应单点实现。

**代价**：书库上传/管理暂无 WebDAV 入口（可后续按需补挂载点）；REST 写需复刻 ETag 语义。

## 2026-10-18 · M7 迁移拆分为 v6（身份三表）与 v7（状态表重建）

**决策**：M7 的 schema 变更拆成两条迁移——v6 只创建身份三表（`resources` / `changes` / `refs`，含索引），**不动任何既有表**；v7 才 `DROP` 重建 `reading_progress` / `annotations` 为以 uid 为键。v7 配 `preMigrationChecks[7]` 防御：脚本执行前对两表做 `COUNT(*)`，任一非空即中止，整条迁移回滚、`user_version` 保持 6。

**理由**：① 批次自洽——批次 A（身份三表 + registry）可独立交付与验证，不必把「不可逆的状态表重建」绑进同一次交付；② 把「不可逆」隔离到单次且有防御的迁移：将来若真有存量数据，失败形态是「中止」而不是「悄悄删数据」；③ 迁移语义保持「要么整体生效，要么库完全没变」（`applyMigration` 单事务 + 前置检查）。

**代价**：① 两个迁移版本号而非一个，读 `db.go` 需理解拆分原因；② 防御只保证「空表才重建」，若将来需要真正的 `document_id` → uid 数据映射，仍须另写数据迁移；③ 本仓库现状是「服务端未部署、无存量数据」，故直接 `DROP` 而非映射。

## 2026-10-18 · Emacs 客户端 uid 适配采用「双值」而非全面替换

**决策**：Emacs 侧不做 `document_id` → `uid` 的全面替换，而是**双值并存**——`doc-id`（`<标签>:<相对路径>`）只用于 buffer 显示与 `seshat:` 链接文本，`uid` 只用于调 REST API。批注列表 buffer 同时持 `seshat-reader-annotation-list-document-id`（doc-id，供显示与 `reference.el` 取用）与 `seshat-reader-annotation-list-uid`（uid，供列表刷新与删除发请求）；uid 经新增的 `seshat-rest-resolve-uid`（`root` + `path` → uid）解析并缓存。

**理由**：① 让 `seshat-reader-reference.el` **零改动**——`seshat:` 链接的生成与反向解析仍以 doc-id 文本工作，既有笔记中的链接保持可读、可跳转；② 用户看到的是可读路径而非 26 位随机串；③ 身份权威留在服务端，客户端只在发请求处切换，改动面与回归风险最小。

**代价**：① 多一个 buffer-local（`list-uid`）与一次 resolve 缓存，两值需各自维护（doc-id 变了 uid 通常不变，但 uid 可能因资源重建而变）；② uid 需联网解析，离线时首次使用退化（已记 tech-debt）；③ 「doc-id 已随文件改名而变、链接文本未同步」这类不一致在 UI 上不可见。

## 2026-10-18 · WebDAV 与 REST 写共用 `registry.Apply`，事件顺序固定；rescan 用 CAS 不排队

**决策**：① WebDAV 写钩子与 REST 文件端点**共用同一个** `registry.Apply`（不各写一套登记逻辑），事件顺序固定为「落盘 → commit → registry → refs 刷新」；② `POST /api/resources/rescan` 用 `Server.rescanRunning`（`atomic.Bool`）CAS 抢占，抢不到立即 `409 rescan_in_progress`，不排队等待。

**理由**：① 事件顺序决定 `rev` 与 `seq` 的正确性——先落盘才有内容、先 commit 才有可写进 `rev` 的 commit id、登记完成后 `changes.seq` 才与磁盘状态一致；两条写入路径若顺序不同会产生不同含义的 `rev`；② 单点实现保证第三方 PUT/MOVE 与自有 REST 写产生同构事件（含墓碑与复活语义）；③ rescan 的语义是「抢不到即报错」——它是维护端点，排队等待会掩盖调用方误用，也会让等待者拿着过期结果返回。

**代价**：① 钩子失败窗口内事件缺失（登记失败只记日志），需 rescan 兜底；② rescan 是全局互斥，多客户端同时触发时后者报 409，客户端需自行重试或忽略；③ 「落盘成功但 commit/登记失败」的中间态只能靠 rescan 收敛，无自动补偿。

## 2026-10-18 · PDF 手写批注用归一化坐标 + 仅本地存储（M10.5）

**决策**：① 手写笔迹以**归一化坐标（0..1，相对页面 FIT_CENTER 显示矩形）**存储与传输，线宽同样归一化；像素坐标只在绘制/触摸瞬间由纯函数 `InkGeometry` 换算。② 手写批注**只存本地**（`PdfInkStore`，键 `pdf_ink_<docId>`），不接入服务端；`location` 的 ink 协议（`page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`，页面坐标）写入 `docs/api.md` 4.5.1 作为预留。③ 交互采用「阅读 / 手写」双模式，不做笔/手指区分；手写时浮层显示「上一页 / 下一页」。

**理由**：① 归一化坐标使横竖屏切换、不同 `renderWidth`、不同缩放比下笔迹位置都正确，且无需数据迁移；若用 PDF point 空间则要在每次渲染宽度变化时重算（且依赖页面原始尺寸）。② 服务端 `location` 是单字段不透明字符串，一笔一 annotation 的 ink 串可直接复用批注表；但当 Android 侧批注同步 UI 尚未建立、Emacs 端只渲染 `rect` 时，上传只会产生「看不见的批注」，故本次仅本地 + 协议预留。③ 双模式比 `MotionEvent.getToolType` 更可靠（多数用户无触控笔，且无设备无法验证笔/手指行为）；手写时点击与滑动都被落笔占用，因此必须提供浮层翻页按钮，否则用户会以为卡死。

> 本决定的第 ② 点（**手写批注只存本地**）已由 2026-10-22 决定反转，见下文「2026-10-22 · ink 批注接入服务端同步（反转 M10.5）」。

**代价**：① 笔迹无法跨端查看（Emacs 端只显示 `rect`），也暂不进服务端备份；② 归一化坐标依赖「图片以 FIT_CENTER 显示」这一前提，若将来 item 改用其他 `scaleType` 必须同步改 `InkGeometry`；③ 手写模式与翻页互斥（需切换模式或点浮层按钮），不如「笔写、手指翻」自然；④ 横屏 + 横向模式下 `renderWidth` 用**首页**宽高比代表全书，混合横竖页面的 PDF 非首页分辨率为近似值。

## 2026-10-18 · Android 服务端改为可选配置（M10.6 B1）

**决策**：服务端（地址 + 令牌）是**可选**配置。`SettingsValidator` 引入 `UrlValidation.Empty` 作为合法状态（替代原 `UrlError.EMPTY` 错误）；`SettingsActivity.save()` 分三路——地址合法 → 写服务端配置；地址留空 → **只写本地偏好**（远程目录/字号/翻页模式），令牌若填写则经新增的 `SettingsStore.saveTokenOnly()` 单独写入（仍走 `writeSecret` 加密通道）；地址非法 → 内联报错。清空地址**不删除**已存服务端配置。

**理由**：用户明确「服务器是可选项」。原实现把空地址当错误并在 `save()` 最前 early-return，导致未配置服务端时**任何设置都存不进去**——真机实测：点「竖向连续滚动」+「保存」→ 提示「服务端地址不能为空」、Activity 不退出、prefs 无 `reader_page_mode`，属可用性阻断。

**代价**：① 「地址留空 + 令牌有值」是半配置状态（同步不可用但不报错），需在文档提示；② `SettingsStore` 的写入路径从 1 条变 2 条（`save` / `saveTokenOnly`），测试面扩大；③ 删除 `UrlError.EMPTY` 后需同步清理 `urlErrorText` 分支与 `settings_err_url_empty` 文案（已做）。

## 2026-10-18 · M9.2 A 批：本地资源索引用 prefs 单文件 JSON；SyncEngine 与 SyncManager 分层；A 批不接线

**决策**：① 本地资源索引（uid ↔ `root`/`path`、`blob`/`size`/`mtime`、墓碑、`dirty`、单一 `cursor`）用 `SharedPreferences`（`seshat_resource_index`）的**单文件 JSON**（键 `index`）。② `SyncEngine` 负责「**游标 / 增量 / 批量落盘**」，`SyncManager` 保持「**按单个 uid 做一次双向同步**」的两层职责。③ 阅读器「**有 uid 且 `SettingsStore.toConfig() != null`**」才接线同步；无 uid 时完全离线（**不做任何网络调用**，也不构造 `RestClient`）。④ A 批**不接线** `SyncEngine`（书架 B 批再接入），因此 `ResourceIndex` / `SyncEngine` 目前是「**可测但无调用方**」的能力储备。

**理由**：① 单文件 JSON **零新增依赖**（不引入 Room / SQLite），且索引是**派生状态**——可随时 `clear()` + `bootstrap()` 从 `/api/changes` 重建，不需要事务与数据迁移；② 两层职责切分让「跨多 uid 的增量编排（游标推进、崩溃幂等、批量落盘）」与「单文档双向同步（进度/批注字段映射、`location + text` 去重）」各自可独立单测，`SyncManager` 无需感知游标与墓碑的存在；③ 守卫 + A 批不接线共同保证「服务端未配置 / 无 uid 时零网络行为」，不破坏 M10.6「服务端可选」与 M9.1「令牌只经 `putSecret`」两条既有不变量。

**代价**：① 单文件**全量重写**（`rename` / `markDeleted` / `setCursor` 仍序列化整份 JSON），条目上万后写放大与 GC 压力明显，需评估迁移 Room/SQLite；② `ResourceIndex` 假定**单线程串行调用**、内存缓存不加锁——B 批一旦跨线程接线必须先补锁或强制单 dispatcher；③ 能力储备期间 `SyncEngine` 无法端到端验证，只能靠 fake `SyncApi` 的单测覆盖。

## 2026-10-18 · M10.6 B3 书架

**决策**：书架数据源仅本地 `filesDir/books/`；元数据与封面走「磁盘缓存 + 内存 LruCache」而非新增数据库；EPUB 的进度键用内容哈希（与阅读器 `uid ?: docId` 的无 uid 分支一致），PDF 接受 `file://`（书架）与 `content://`（SAF）两套进度分离。

**理由**：零新增依赖；书架只读本地，服务端同步留给 B 批（`SyncEngine` 接线）；内容哈希是唯一能仅凭文件复现的稳定键。

**代价**：首次扫描需逐本解析（慢）；有 uid 的书查不到进度；PDF 两套进度不共享；EPUB 首次上架解析 2 次（`BookMeta` 无 `opfDir`）。

## 2026-10-18 · M10.6 B4 Notes 与 GTD 并入

**决策**：Notes 与 GTD 统一读 `filesDir/notes/*.org`（旧 `filesDir/sample.org` 保留但不读）；树构建用「解析下标」作节点 id；编辑页只允许改标题/正文/状态，其余 metadata 只读；同步逻辑抽成 `NotesSync`（阻塞、无 Toast）。

**理由**：消除双副本分叉（Notes 写 `filesDir/notes/sample.org`、GTD 写 `filesDir/sample.org`，两边改动互不可见）；下标 id 零成本且与 `OrgEditor` 的行号约定同源（解析顺序 = headline 顺序，一一对应）；metadata 写回需重写 headline 与计划行，收益低风险高（见 `openspec/tech-debt.md` 的 headline 规范化条目）。

**代价**：① 重新解析后折叠状态可能漂移（已用 `pruneCollapsed` 裁剪失效下标，仍无法跟随条目移动）；② 单文件限制（只读第一个 org，多文件切换未做）；③ metadata 编辑需用户在外部编辑器完成。

## 2026-10-18 · M10.7 笔记库与渲染

**决策**：Notes 改为「多文件笔记库 + 渲染阅读」；渲染用 WebView + 自研 org/markdown → HTML 渲染器（零新增依赖）；数据源为私有目录 + 可选 SAF 外部目录（framework `DocumentsContract`，不引 `androidx.documentfile`）；编辑走新增的文件级 `NoteEditActivity`，不复用 entry 级编辑器。

**理由**：用户笔记是整份 org/md 文档（部分无 TODO），需要阅读而非任务管理；WebView 的 CSS 能力可同时服务两种语法且排版可控；自研渲染器避免引入 markdown 库并保证「先转义再解析」的安全顺序。

**代价**：渲染只覆盖语法子集（无表格/图片/大纲）；SAF 只遍历一层；Agenda 降级为只读；多文件逐个解析无缓存。

## 2026-10-19 · M9.2 B 批文件同步

**决策**：不引 WorkManager / SwipeRefreshLayout（前台可见时触发同步，`onResume` 30s 限流）；`ResourceIndex` 用 `@Synchronized` + 全进程单实例（`SyncHolder`）；上传限 32 MiB 不分片；`SyncResult` 扩展 `renames` 并由 `SyncCoordinator` best-effort 跟随本地文件名。

**理由**：零新增依赖；`ResourceIndex` 的锁是实例锁，必须单实例才能保护同一 prefs 键；分片上传需服务端配合，超出本批。

**代价**：无后台同步；>32 MiB 无法上传；同名不同目录的 move 跟随会跳过；`ondemand` 根的书无法重命名。

## 2026-10-20 · 破例引入 PdfBox-Android（M10.8，零新增依赖的唯一例外）

**决策**：引入 `com.tom-roush:pdfbox-android:2.0.27.0`，**仅**用于读 PDF 书签树（`/Outlines`）与单页文本提取；使用范围限定在 `reader/` 包内（`PdfOutlineReader` / `PdfTocEntries` / `PdfTextExtractor`），`PDFBoxResourceLoader.init(applicationContext)` 在 `PdfReaderActivity.onCreate` 调用一次且早于任何 `PDDocument` 使用。

**理由**：系统 `PdfRenderer` 只暴露页数与逐页渲染，**不提供 outline API**，PDF「真目录」（用户 U4 的硬需求）没有任何系统路径可达；自研 PDF 书签解析要实现 xref / 对象流 / 压缩流解码与类型推断，成本与出错面都远大于一个成熟库。用户在 2026-10-20 明确授权这是「零新增依赖」强约束下的**唯一例外**（理由：不划算）。

**影响**：① APK 约 +10 MB；② 依赖停在 fork 的最后一版（2.0.27.0，2023 年发布），上游 Apache PDFBox 后续对不可信输入解析健壮性的修复不会自动带入，需主动跟踪版本（记 `openspec/tech-debt.md`）；③ 库解析不可控 → 所有输入先过 50 MiB 大小闸门、`BoundedInputStream` 与节点数/深度预算，失败一律降级为空表或空串、不抛异常；④ 「只在 `reader/` 内使用」目前靠评审守住，无编译期约束。

## 2026-10-20 · 阅读器浮层必须是 overlay，padding 随可见性动态联动（M10.8）

**决策**：浮层保持**纯 overlay**（半透明叠加、不占布局），阅读区永远全屏，靠 `applyContentPadding()` 按「浮层是否 `VISIBLE` + 当前 height」动态设置阅读区上下 padding（隐藏即归零）；幂等闸 `appliedTopPadding` / `appliedBottomPadding`（EPUB 另加 `appliedContent` 比对 RecyclerView 身份）保证「值未变不写」；布局监听常驻而非一次性。

**理由**：U1「浮层隐藏后底部留白」的根因不是「没算 padding」，而是两件事叠加——① M10.6 B2 的 padding 只按高度**一次性**写入，`toggleChrome()` 只切可见性、不参与计算，隐藏后空白必然留着；② 只在「浮层高度变化」时重算，漏掉 insets / 字体缩放 / 旋转等触发。把浮层改成占布局是更差的解（阅读区永久缩小）。代价是写 padding 会触发重布局，故必须用幂等闸把写入收敛到「值真的变了」。

**影响**：① 任何新增浮层（如将来的阅读内设置面板）都必须走同一套 padding 计算，否则重新引入留白；② EPUB 侧 padding 变化后**必须**主动 `reportVisibleChapter()`——padding 变化不派发 `onScrolled`，不重算会让持久化的章内偏移漂移，破坏 M10.6 的进度不变量；③ 显隐浮层时仍可能有一次重布局抖动，实际可接受度待真机验收确认。

## 2026-10-20 · 手写笔型存在 `InkStroke.style` 上、默认 `PEN`（M10.8）

**决策**：笔型 `InkStyle { PEN, MARKER, HIGHLIGHTER }` 作为 `InkStroke` 的**per-stroke 字段**（默认 `PEN`），不做文档级「当前笔型」持久化设置；`PdfInkStore.defaultJson()` 开启 `coerceInputValues = true`。

**理由**：笔型是每一笔的属性——同一页可能既有荧光笔高亮又有钢笔笔记，文档级设置无法表达；字段带默认值使 M10.5 的旧 JSON **零迁移**（缺字段即 `PEN`），不需要迁移脚本或双写过渡；`coerceInputValues` 让未知枚举值回退默认值，而不是整份笔迹反序列化失败（宁可丢笔型，不可丢笔迹）。

**影响**：① 笔型只在渲染层生效（线宽倍率 1× / 2.2× / 3.5×、不透明度 255 / 170 / 90，且 `Paint.setColor` 后必须补 `setAlpha`），不改变归一化坐标语义；② 用户选中的笔型不跨文档记忆、无「最近使用」（记 tech-debt）；③ 未来加笔型只需扩枚举 + 渲染映射，但**不得**依赖枚举序号做持久化（默认序列化用名字）。

## 2026-10-22 · Emacs 阅读器采用 side window 三分栏（M12）

**决策**：信息面板与目录面板改用 `display-buffer-in-side-window`（`(side . left|right)` + per-kind `slot`），目录固定左侧、批注/译文固定右侧，`seshat-reader-sidebar-position` 的默认位置由 `below-selected` 改为 `right`；目录另用 `seshat-reader-outline-sidebar-position`（默认 `left`）。`seshat-reader-sidebar--slot-for-kind` 按 kind 分槽（同侧 0/1/2、不同侧各自从 0），`sidebar-show` 只重建目标 kind，`sidebar-toggle` 增可选 `kind` 参数并新增 `C-c C-o` → `seshat-reader-sidebar-toggle-outline`。

**理由**：① 自建 `split-window` 会在 kind 切换时反复 split/delete，导致主窗口逐次变窄；side window 由 Emacs 维护独立窗口树，同侧同 `slot` 复用，主窗口宽度不受增删面板影响。② 单窗口承载（M11 的底部弹出）无法同屏对照目录与批注——底部单窗口下后显示者接管同一窗口，M11.7 起即为已知限制。③ 底部模式（`below-selected` / `at-bottom`）作为兼容值保留，用户可一键回退旧版式。

**代价 / 约束**：① 默认值变更是**破坏性**行为变更（面板从底部移到右侧、尺寸语义从高度变为宽度），docstring 已给回退写法（设 `seshat-reader-sidebar-position` 为 `below-selected`）。② per-kind 尺寸记忆需带**方向标签**——宽度与高度语义不同，同一 alist 混存会让左右栏与底部面板互相污染。③ `window-toggle-side-windows` 是 frame 级全量开关，仍禁用（会连带删除 eca-chat / which-key 的侧窗）。

## 2026-10-22 · 批注页面高亮在 C 渲染层实现而非 elisp 叠加（M12）

**决策**：在 `draw_page_thread` 的反色（`fz_invert_pixmap_luminance` / `fz_gamma_pixmap`）之后、PNM 编码之前，用 `fz_new_draw_device` + `fz_rectto` + `fz_fill_path` 在页面 pixmap 上绘制高亮，复用该页 rasterize 用的同一个 `ctm`；elisp 侧只解析 `location` 的 `rect:` 段并按页投喂（`seshat-reader-dyn--clear-highlights` → `seshat-reader-dyn--add-highlight` × N → `seshat-reader-dyn--refresh-highlights`），不参与绘制。

**理由**：① **Emacs 中同一文本区域的 `display` 属性互斥、不能叠加**——一处只有一份 `display` 规格生效，仓库内已有两次独立结论：`openspec/completed/2026-10-12-m11.2b-reader-selection.md`（M11.2b 选区实现记录）与 `seshat-reader-select.el` 的注释（只做文本属性、不做矩形绘制）。② `(space :width ...)` / `:box` / face 背景只作用于**文字所在位置**，会挤开 image 而不是叠在其上——阅读器每页是一整个 image，任何 elisp 侧「叠加」都会把页面推走。③ 复用 `ctm` 使缩放与旋转自动对齐，无需在 elisp 侧重复坐标推导（`rect_to_page_space` 是唯一的「Emacs rect → MuPDF 页面空间」换算点，渲染线程与 `seshat-reader-dyn--text-in-rect` 共用）。

**代价 / 约束**：① 改 C 必须 `make clean all` 重建 `.so`，并在 `VENDORED.md` 登记本地改动（F23 不变量）。② 高亮表需在派发渲染任务时**快照**进 `DrawThreadArgs`（容量倍增表，每条退出路径释放）——渲染线程不碰 `DocState`，elisp 侧只改表并置 `highlights_dirty`。③ 旋转页的 `rect` 本身采不准（`seshat-reader-select.el` 明确不支持旋转页，属既有限制），高亮在旋转页可能错位（记 tech-debt）。④ 颜色与透明度当前是编译期常量（`HIGHLIGHT_COLOR_*` / `HIGHLIGHT_ALPHA` = 0.35），不可配置（记 tech-debt）。

## 2026-10-22 · 批注契约扩展为 v8（`kind` + `selected_text`，服务端幂等）（M10.3）

**决策**：`annotations` 表新增两列——`kind`（批注形态，约定 `note` / `highlight` / `ink`，**服务端不做枚举校验**）与 `selected_text`（选中原文），迁移为**纯 `ALTER TABLE ... ADD COLUMN`**（`DEFAULT 'note'` / `DEFAULT ''` 回填存量行）。`text` 语义保持不变（备注正文 / 显示摘要），但校验改为**按 `kind` 分支**：`kind=note` 时必填非空，`highlight` / `ink` 以及任何未知 `kind` 允许空串；`kind` 缺省（空串或全空白）由**存储层**在**校验之前**兜底为 `note`。同时 `CreateAnnotation` 增加**内容幂等**：按 `(uid, kind, location, text)` 查既有记录（`selected_text` **不参与**键），命中则原样返回、不插新行、不刷新 `updated_at`，API 层据此把新建映射 `201`、幂等命中映射 `200`。

**理由**：① 单列 `text` 无法表达「只选中原文、没写备注」（高亮）与「一笔手写」（ink）——前者需要把选中原文与备注分开存，后者两者都为空；新增两列比复用 `location` 塞文本语义更干净，也与 Emacs/Android 两端已有的本地模型（`BookAnnotation.selectedText` / `PdfAnnotation.kind`）一一对应。② **不做枚举校验**是刻意的：`kind` 的取值集合会随阅读形态演进（未来可能有 `underline` / `strikeout`——**bookmark 是位置而非标注，永不进入 annotations**），服务端强校验会把「新增形态」变成「服务端发版」，而服务端的职责只是保存与回传不透明串——未知 `kind` 由客户端归入「其它」分组（Android）或按 `note` 兜底（Emacs）。③ 兜底必须在下层且先于校验：请求体反序列化后 `kind` 是空串，显式 `INSERT` 时 SQL 的 `DEFAULT 'note'` **不生效**；若兜底在校验之后，缺省 `kind` 的请求会被当成「未知 kind」，从而错误地允许 `text` 为空。④ 幂等键不带 `selected_text`：同一处选中原文的多次补登（Android 打开书时补登历史笔迹、Emacs 离线队列重放）应命中同一条记录，否则「补登」会变成「复制批注」；键带 `kind` 则保证同 `location` 上的一条 `highlight` 与一条 `note` 是两条独立批注。⑤ 两张迁移都只用 `ADD COLUMN`（可逆、无数据重写），故 `preMigrationChecks` **不登记 v8**——该钩子只服务不可逆迁移（v7 的 DROP + 重建）。

**影响**：① `schemaVersion` 8 必须恒等于 `len(migrations)`（`TestMigrationsLengthMatchesVersion` 守卫）；② `UpdateAnnotationAt` 与 `CreateAnnotation` 同口径（`kind` 兜底 + 按 kind 校验），故「note → highlight」「highlight → note」的形态改造由调用方显式给出 `kind` 与 `text`；③ `selected_text` 在更新上是**整体替换**语义（不传即清空），客户端必须每次带上；④ 未知 `kind` 由三端各自兜底（服务端原样存、Android 归「其它」组、Emacs 当 `note`），因此**新增形态无需服务端改动**，但需要三端同时确认显示回退链。

## 2026-10-22 · EPUB 批注 location 定稿为 `chapter:<i>@<s>-<e>`（M10.3）

**决策**：EPUB 的 `location` 定稿为 `chapter:<spineIndex>@<startOffset>-<endOffset>`——`spineIndex` 为 **0-based spine 序号**，`startOffset`/`endOffset` 为**章内字符偏移、半开区间** `[start, end)`，单位是 **UTF-16 code unit**（与 WebView 侧 `String.length` / Kotlin `String.length` 同口径）；偏移以 `document.body` 文本流的**前缀长度**计算（`Range.toString().length` 双向算，不假定 `end - start == text.length`）。偏移不可用时退化到 `chapter-<n>`（只记章）。**不再采用 CFI**，HTML CFI 需解析 `EpubBook` 的包文档结构、且两端都要实现一套路径语法，收益不及「章序号 + 字符偏移」。

**理由**：① 服务端 `location` 是不透明串，形态只需两端自洽；`chapter:<i>@<s>-<e>` 的解码是三个整数，Android（`LocationCodec`）与 Emacs（`--chapter-from-location`）各几十行即可，CFI 的 `epubcfi(/6/4!/4/2/2:0)` 则要两端各实现一套路径解析 + 边界语义。② 章序号与 `EpubBook.chapters` / `ViewPager2` 页序天然一致，跳转只需「跳章 + 滚到偏移」，无需在 XML DOM 里重新定位节点。③ 用前缀法算两端（而不是 `start + text.length`）：跨块级元素时浏览器会规范化空白，`Selection.toString()` 的长度与 body 文本流长度可能不等，两端同法算才保证 `[start, end)` 恰好切在文本流上。④ 退化形态 `chapter-<n>` 让「偏移采集失败」不至于变成「批注丢失」，且解析侧只取首段数字，新增字段无需改解析器。

**代价 / 约束**：① 单位是 UTF-16 code unit，BMP 之外的字符（emoji 等）在按「字符数」处理的端（Emacs）会 ±1 偏移（记 tech-debt）；② spine 序号依赖 EPUB 的阅读顺序而非文件名，同一本书改版（增删章）后旧 location 会指向错的章——批注不跨版本迁移，属已知限制；③ 偏移采集在 WebView 注入脚本内完成，无 instrumentation 覆盖（纯 JVM 只能测 `SelectionRange` / `LocationCodec` 的解析与编码），真实 DOM 口径待真机验收。

## 2026-10-22 · ink 批注接入服务端同步（反转 M10.5「仅本地保存」）

**决策**：**反转 2026-10-18「PDF 手写批注用归一化坐标 + 仅本地存储（M10.5）」的第 ② 点**——手写笔迹不再是纯本地数据：`PdfInkStore` 仍是渲染唯一真相，同时把每一笔以 `kind=ink` 的**镜像批注**接入批注同步（`location = page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`，**一笔一条**，依据 `docs/api.md` §4.5.1；`text` 与 `selected_text` 均为空串，靠 v8 的按 kind 放宽校验放行）。落笔完成即登记一条待上传；打开带 uid 的书时把本地既有笔迹**一次性补登**，客户端先按 `(kind, location, text)` 跳过已有项，服务端 `(uid, kind, location, text)` 幂等命中返回 `200` 为第二道兜底。M10.5 的第 ① 点（归一化坐标存储）与第 ③ 点（阅读/手写双模式）**不变**。

**理由**：① 反转的直接原因是 M10.5 时的前提已消失——它的理由是「Android 侧批注同步 UI 尚未建立、Emacs 端只渲染 `rect`，上传只会产生看不见的批注」；M10.3 建了批注抽屉（按 kind 分组 + ink 折叠汇总），M12 让 Emacs 能看到 `rect` 与 `ink` 聚合文案，笔迹不再「看不见」。② **跨端一致 + 换设备不丢**：手写是阅读成果的一部分，只存 `SharedPreferences` 意味着卸载/换机即永久丢失，且 Emacs 侧永远看不到「这页有手写」。③ 协议零改动即可承载：`location` 是单字段不透明串、一笔一 annotation，服务端 schema v8 的 `kind` 恰好用来标记形态，`(uid, kind, location, text)` 幂等恰好兜住「补登可重放」——不需要新增表或端点。

**代价 / 约束**：① **量级风险**：大页面笔数多时批注表行数会显著膨胀（一笔一行），列表接口按 uid 全量返回，记 tech-debt；② 坐标必须按不可变口径换算（页号 `+1`、pt、`#AARRGGBB`），任一处错都会跨端错位，故换算逻辑集中在 `InkAnnotationMapper` + `LocationCodec.encodeInk` 两个纯函数并对所有非法输入做夹紧/净化（编码结果必然可被解析）；③ 页面尺寸未就绪或点集为空时只发 `page:<n>;ink:<color>,<widthPt>`（降级但可解析），空点集在 Android 侧直接不登记；④ Emacs 端仍**不渲染** `ink:` 笔迹（只做聚合显示），该缺口保留在 tech-debt。

## 2026-10-23 · 阅读器自动 fit 改为 contain（页面完整可见优先）

真机验收发现 `fit-to-height` 只按高度算 scale，窗口变窄（打开目录/侧栏）后
页面渲染宽度可达窗口 2 倍，而 `--center-page` 以 `unconstrained = t` 写入负
hscroll，导致页面左右各裁掉约一半；首次 fit 走同一路径，故打开文档即复现。

决定：新增 `seshat-reader--contain-scale`（取按高与按宽的较小者），自动 fit
（首次 + 尺寸变化后）一律走它；`--center-page` 的 `scroll-offset` 夹到
`>= 0`，超宽时页面左对齐而不是两侧裁切。

取舍：选择「页面变小但完整可见」而非「保持尺寸 + 横向滚动」。理由是默认
场景（打开目录）下页面宽达窗口 2 倍，横向滚动等于看不全。代价是
`seshat-reader-default-fit` 在两维冲突时失去区分度（只在两者都放得下时
决定优先填满哪一维）；显式命令 `H`/`W` 保持原语义。

**补充（实施复核）**：`min(按高, 按宽)` 之下 `seshat-reader-default-fit` 在自动
fit 路径上已无任何调用点（`grep` 只剩 defcustom 自身）——想让该选项「覆盖」
contain 就必然让另一维溢出，故其区分度实际为零。是否删除该用户选项属破坏
性变更，留待用户决定（记 tech-debt / D6「待确认」）。

## 2026-10-23 · 阅读器缩放来源用 window parameter 区分 fit/manual

真机验收暴露的观感问题之一是「用户手动调过的缩放，会在窗口尺寸一变时被自动
refit 覆盖」。自动 fit 与显式缩放命令走同一个 `seshat-reader-doc-scale-page`，
函数本身无从区分调用者意图。

决定：载体选 window parameter `'scale-source`（取值 `fit` / `manual`，未设置时
按 `fit` 处理）；写入面收窄为 `seshat-reader-doc-scale-page` 的可选 `source`
参数——只有 5 个缩放命令传值（`enlarge-size` / `shrink-size` / `reset-size` 传
`manual`，`fit-to-height` / `fit-to-width` 传 `fit`），4 个恢复路径（退出恢复
`--restore-display-on-quit`、revert 的 reload、`--window-create-function`、书签
恢复）保持 1 参调用，不覆盖已记录的来源、也不凭空记成 `manual`。不新增
defcustom，参数随窗口走，不进入全局状态。

取舍：恢复路径不写来源意味着跨会话一律视为 `fit`——宁可重新贴合（可能改变用户
上次的手选比例），也不保留一个在当前窗口尺寸下可能已不合适的旧缩放。代价是
「手动缩放 + 书签/会话恢复」这一组合的比例不跨会话保持（记 tech-debt）。

## 2026-10-23 · 尺寸变化重贴合用 idle timer，并附差异论证与降级路径

`seshat-reader-annotation-queue.el:437-438` 留有「daemon 下 idle timer 不可靠」的
告诫。若照抄该条而放弃 idle timer，重贴合只能退化为「只居中、不重算缩放」，
窗口变窄时页面依然被裁切。

差异论证：该告诫针对**无人交互的后台同步**——进程可能长期停在非 idle 状态，
idle timer 永不到期；本场景是**前台用户动作之后的 UI 重排**（开关面板、拖分割
线、新建窗口），动作结束必然伴随「从非 idle 回到 idle」，idle timer 恰是合适的
触发点。延迟仅 `0.15` 秒，最坏情形是「用户持续操作期间不重贴合」，这正是期望
行为。

决定：refit 走 `run-with-idle-timer`（`seshat-reader--resize-refit-delay`），并在
其上叠 1% 偏差闸与 `--refitting` 防重入。降级路径（按优先级）：① 偏差闸——
已实现为默认，缩放差异不足 1% 时只 clamp + 居中、不重渲染；② 若 idle timer 在
某环境（含 daemon）下确实不触发，可整体退化为「只 `--clamp-window-vscroll` +
居中、不 refit」（记 tech-debt），视觉上页面仍在，但可能被裁切。

## 2026-10-23 · 居中同步化：hook 内先 recentre 再排 refit

上游 emacs-reader（Codeberg `MonadicSheep/emacs-reader` master）在尺寸变化 hook
内**同步**调用 `reader--center-page`，因而不存在中间帧；本项目在
`--window-size-change` 里只排了一个 timer，开关目录/批注面板后会先出现 0.15 秒
「页面偏向一侧」的中间帧（实例几何实测可复现）。

决定：拆成两步——**同步 recentre（几何）+ 异步 refit（重渲染）**。hook 内对每个
受影响窗口立即 `--recenter-window`，重渲染仍去抖，以免拖分割线时逐帧重渲染。

代价：页面尺寸确实变化的那一次缩放仍然保留（0.15 秒后才发生），这是 contain 需求
的固有代价——不重渲染就无法让变窄窗口里的整页完整可见。

## 2026-10-23 · 边界修复：换 buffer 补居中 + hscroll nil 守卫

两处缺陷均由真机验收暴露，且都不在「尺寸变化」路径上，故在 D8 单独修复。

① `set-window-buffer` 归零 hscroll：已用「零 seshat 代码的普通 buffer」反证为
Emacs 固有行为（hscroll 5 → 同 buffer 重设窗口 → 0）。新窗口 / 新 frame 显示同一
文档时既不触发 `window-size-change-functions`（无尺寸变化），也不重建页 overlay
（`'overlay` 窗口参数仍在），于是没有任何路径重新居中：实测基线 `page-left 261 /
dev 0`，重设后 `hs-raw 0 / page-left 522 / dev +261`，`redisplay` 与 `sit-for 1s`
都不自愈。改在 `--handle-window-buffer-change` 末尾按互斥双分支处理。

② `--right-most-window-hscroll` 在页面尚未渲染时 `image-width` /
`pixel-per-col` 均为 nil，首次打开 PDF 抛 `(wrong-type-argument
number-or-marker-p nil)`；加 `numberp` 守卫、未见渲染时返回 0，4 个横向滚动命令的
image-width 读取补 `(or … 0)`。

代价：把**同一条文档**重新指给**同一个窗口**（`(set-window-buffer win
(current-buffer))`）同样会让 Emacs 归零 hscroll，但不触发
`window-buffer-change-functions`，D8 的 recentre 兜不住；根治需 advice
`set-window-buffer`，会侵入所有调用方，暂不采用（记 tech-debt）。

## 2026-10-23 · 显示层缩放替代同步重渲染以消除两帧

**问题**：窗口尺寸变化时页面「先跳动一下、再重新绘制」。根因是结构性的——页面
显示尺寸原先只能靠 C 侧 `doc-scale-page` 重渲染改变，而同步重渲染会拖死
redisplay，只能排在 idle（0.15s 去抖）之后；于是「同步改位置」（`--recenter-window`
按**旧**渲染尺寸夹 vscroll）与「异步改尺寸」（idle refit）之间必然出现两帧。

**选项**：A = 尺寸变化 hook 内同步调用 `doc-scale-page`（一帧到位，但同步渲染阻塞
redisplay，拖分割线时会逐帧重渲染卡死）；B = 在 elisp 层直接改写 image spec 的
`:width` / `:height` 做显示层缩放（纯 elisp、微秒级），把 C 侧重渲染降级为 idle
的「事后提升清晰度」。

**选择 B。**

**依据**：Emacs image spec 的 `:width` / `:height` 是**显示尺寸**而非图像数据尺寸
——2026-10-23 在 pure 实例实测：spec 200×100 → 100×50 → 400×200，`image-size` 与
`window-text-pixel-size`（真实布局像素）同步线性变化，原地改属性**立即生效且无需
`image-flush`**。既有的 `--get-current-doc-image-size` 读的正是这两个属性，故
`--center-page`、`--clamp-window-vscroll`、`--page-max-vscroll-pixels` 全部自动按新
几何工作，无需改动。「spec 尺寸 / `scale` = native 尺寸」这一不变式由
`--apply-display-scale` 同时更新 spec 与窗口 `scale` 维持，`--contain-scale` 与
vscroll 上限因此不会算错。

**代价**：① 位图放大是插值缩放，几何到位后画面在 idle 重渲染前偏模糊（用户可接受
「模糊→清晰」替代「跳动→重绘」，真机观感待 T6 验收，假设 H5）；② image cache 以
spec 内容（含 `:width` / `:height`）为键，原地改尺寸会让旧键条目滞留到
`image-cache-eviction-delay`（默认 300s），拖分割线可在数秒内造出几十个 2 MB 级条目
——已在改写前 `ignore-errors (image-flush spec)` 缓解，长时间真机内存观测仍缺（记
tech-debt）；③ 改写属性必须用 `image-property` / `(setf (image-property …))`：spec
是 `(image . PLIST)`，整表不是 plist，`plist-put` 会报 `wrong-type-argument plistp`（实测）。

## 2026-10-23 · `fit-mode` 取代单一 `fit` 来源

**问题**：按 `W`（按宽度适配）后按 `o` 打开目录，页面变成按高度适配。根因是**适配
维度信息在写入时被丢弃**：`fit-to-width` 与 `fit-to-height` 都把 `scale-source` 记成
同一个 `'fit`，而尺寸变化后的 refit 对任何非 `manual` 窗口一律用 `--contain-scale`
重算 `min(按宽, 按高)`；按宽适配时页面通常纵向溢出（`scale_h < scale_w`），contain
必然退化成按高度。

**选择**：新增 window parameter `fit-mode`（`contain` / `width` / `height`，未设置按
`contain`），由 `fit-to-width` / `fit-to-height` 末尾各写一行（`presentation-mode`
因内部调 `fit-to-height` 自动得到 `height`）；`--fit-scale` 按模式求目标 scale，
`contain` 分支转调 `--contain-scale`。`scale-source = manual`（`+` / `-` / `0`）
**优先于** `fit-mode`——手动缩放过的窗口不因尺寸变化被自动适配改写。载体选 window
parameter 而非全局变量：适配模式是「这一窗口的显示意图」，随窗口生灭，不跨窗口串味，
也不新增 defcustom。

**取舍**：**不改** `--contain-scale` 本体。它是纯计算函数、被既有 16+ 例测试直接锁定，
新路径只需在 `contain` 分支复用它即可；保持其一字不动，既有断言零回归，语义上也让
「contain 是三种模式之一」而非「唯一的适配算法」。代价是同一语义有了两个入口
（`--fit-scale` 的 contain 分支与 `--contain-scale` 本体并存，记 tech-debt）；另外
首次打开与书签恢复不写 `fit-mode`，故默认仍是 `contain`（与改造前行为一致），
「跨会话记住 `W` / `H`」不在本次范围。

## 2026-10-23 · 居中改为 redisplay 求值（`before-string` + `:align-to`）

**问题**：窗口尺寸变化时页面「先跳到一侧、再居中」。旧实现用「buffer-wide
overlay 的 `line-prefix` = 全余量 + `set-window-hscroll` 回滚半余量」两步拼出
居中，两段数值都得在 Lisp 侧算完再写下去；而 `window-size-change-functions`
在 redisplay **之后**才跑，命令内与 `pre-redisplay-functions` 里的重算同样赶不上
正在进行的 redisplay，于是新宽度下的第一帧必然带着旧前缀（实测窗口变窄后首帧
错位 −524px，要等下一次 redisplay 才归位）。

**选项**：A = 继续在 Lisp 侧重算，只把时机提前（试过 `window-size-change-functions`
内重算、命令内居中、`pre-redisplay-functions` 内重算，都只能把误差压到「一帧内的
某处」，消不掉）；B = 把居中交给 redisplay——页面 overlay 加 `before-string`，其
`display` 为 `(space :align-to (+ center (-0.5 . IMAGE)))`，位置在布局时求值；
C = 半余量 `line-prefix`（`line-prefix` 本身改成半宽）——仍要先知道当前窗口宽度、
仍是 Lisp 侧数值，尺寸变化的同一帧里算不出来。

**选择 B。**

**依据**：`:align-to` 的偏移量在 redisplay 布局阶段求值：`center` 是「窗口正文宽度
的一半」，`(-0.5 . IMAGE)` 是「负半个图像宽」，两者相加即页面左边应处的像素位置，
**Lisp 侧不需要知道窗口宽度**，所以窗口变窄的同一帧就已经正确。实测（隔离实例逐帧
测量）：开关目录、`W` / `H` 之后、新窗口首次显示，首帧误差均 ≤0.5px。

**关键坑**：IMAGE 位**必须传图像 spec 对象本身**，不能传数值。传数字时 Emacs 会把
`(-0.5 . N)` 解释成「N 个字符宽」的倍数（实测前缀宽度算成 0、页面贴左）；写成
`(cons -0.5 spec)`（即点对 `(-0.5 . SPEC)`）才是文档语义里的「图像宽度的 -0.5 倍」。

**代价**：① 超宽页（页面比窗口宽）不能用 `:align-to` 居中——那种情形要左对齐 +
横向滚动，所以 `line-prefix` 机制**不能删**，`--center-page` 变成「能放下走
`before-string`、超宽走 `line-prefix`」两套机制并存（记 tech-debt）；② 重渲染会换掉
image spec 对象，`before-string` 里存的是旧 spec（身份已过期），靠 `--centered-p`
做 `eq` 身份比较发现并在下次 pre-redisplay 修复——多一次廉价检查，换来「不必在每个
改动点都记得调居中」。

## 2026-10-23 · 首次 fit 改用显示层缩放

**问题**：打开文档时页面先按默认比例画一张小图并居中，随后 idle 的 refit 按
`contain` 重渲染大图再重新居中——用户看到两次尺寸/位置变化（「先小后大」）。

**方案**：新增 `--first-fit`，`seshat-reader-mode` 末尾用它取代
`doc-scale-page (--contain-scale)`：先算目标 scale，再用 `--apply-display-scale` 只改
image spec 的 `:width` / `:height`（纯 elisp、不重渲染）把页面放到最终几何，随后
`--center-page` + `--schedule-refit`，由 idle 的重渲染把位图提升到该分辨率。
`--apply-display-scale` 返回 nil（拿不到 spec）时回退同步 `doc-scale-page`，保证首次
打开一定有正确几何。

**代价**：① 首帧位图是**旧分辨率的插值缩放**，在 idle（0.15 秒去抖）重渲染前略模糊、
随后转清晰——以「模糊→清晰」换「一次到位」，不再有「小→大」；②
`--apply-display-scale` 返回 nil 的两种原因（无 spec / 已在目标尺寸）无法区分，边角
会多一次重渲染（记 tech-debt）；③ batch 下 `window-body-width` 恒 80px，凡涉及
「页面放得下」语义的 ERT 必须显式桩窗口宽度，否则红灯与实现无关（记 tech-debt）。

## 2026-10-23 · 拖拽抑制（`--drag-threshold` 0.12 秒）

**问题**：拖分割线时尺寸变化事件密集，每次都在 hook 内同步改 image spec 尺寸，
redisplay 每帧都要重新缩放整页位图——真机拖一次卡 1–2 秒，手感完全丢失。

**方案**：新增 `defvar` `seshat-reader--drag-threshold`（`0.12` 秒，内部开关、非
defcustom）与 buffer-local `--last-size-change-time` / `--last-size-change-delta`；
`--window-size-change` 每次记录时间戳与间隔，`--recenter-window` 见「间隔小于阈值」
即视为拖拽：只做 vscroll clamp + 居中，**不改 spec 尺寸**；停手后 0.15 秒的 idle
refit 按当前窗口尺寸做一次几何适配 + 重渲染，一次到位。

**取舍**：拖动过程中页面尺寸**不跟手**（仍是上一次的几何，随窗口变窄被裁切或留白），
换取拖动全程流畅；阈值取 0.12 秒是「人手连续拖动的事件间隔」与「一次性面板开关」
之间的分界——面板开关只产生 1–2 次事件、间隔远大于阈值，所以仍走同步适配路径
（首帧即正确）。阈值硬编码不进 defcustom：它调的是交互手感而非功能语义，暴露成
用户选项只会被误调。

## 2026-10-23 · 阅读器适配默认值：defcustom 作新窗口初值，不做 W/H 自动持久

**问题**：`seshat-reader-default-fit` 在自动 fit 路径上已无调用点（首次打开与尺寸变化后的 fit 一律走 `--contain-scale` / `--fit-scale` 的 contain 分支），成为「可配置但无效」的选项；同时 `fit-mode` 是 window parameter，`W` / `H` 的选择随窗口销毁丢失，与文档里「持久适配模式」的措辞不符。

**方案空间与取舍**：① **M1（选定）**——把该 defcustom 重定义为「新窗口的初始适配模式」，`W` / `H` 只改窗口；不改用户 init、不新增状态文件，代价是「按一次 `W`，下次开新窗口仍回初值」。② M2——新增 `~/.local/share/seshat/reader-state.eld`（仿 `annotation-queue.eld`）记 `W`/`H` 选择，真跨会话，但引入新持久化面与容错/迁移成本。③ M3——`W`/`H` 时 `customize-save-variable` 写用户 init，违反最小惊奇，否决。用户 2026-10-23 明确选 M1。

**旧值映射（契约）**：`fit-to-width` → `width`；`fit-to-height`（旧默认）→ `contain`；其它任意值 → `contain`。旧默认映射为 `contain` 而非 `height` 的理由：绝大多数配置从未改过该项，映射为 `height` 会让所有人打开文档后纵向溢出；「显式想要按高」与「沿用旧默认」在值上不可区分，只能保现状，并在 CHANGELOG 给出绕法（显式设 `height`）。

**代价与边界**：`W`/`H` 仍不跨会话；书签仍不携带 `fit-mode`（与既有技术债「书签恢复不携带缩放来源」同族，不在本次扩大范围）；新窗口首帧可能沿用恢复的 scale，0.15s 后由 idle refit 按 mode 校正（不做创建时同步重算，避免 `native` 尺寸不可得时把页面设成 1.0）。

## 2026-10-24 · Emacs 传输层分层与统一契约（M8-A）

**决策**：新增 `seshat-transport.el`，把 HTTP 请求收敛为 `(:status N :headers ALIST :body STRING)` / 失败 `(:status nil :error SYM)`，后端可在 `rest`（`url.el` + Bearer）与 `webdav`（`curl` + Basic）间切换；**transport 层永不抛错**；`seshat-rest--request` 保留为薄包装，维持旧 `(status . body)` 契约与「网络失败抛 error」语义。

**理由**：改造前两套传输契约互不兼容（curl 返回 `(exit-code . output)`、url.el 返回 `(status . body)`），且 `/dav` URL 拼接散落三处，改一处漏两处即静默失败。统一契约是 M8 引擎重写的前置条件。**薄包装不直接下沉**，因为 4 处生产调用方（`seshat-conflict--remote-head`、`--merge-three-way`、`seshat-reader-annotation--fetch`、`seshat-reader-annotation-queue--sync-delete`）与 4 个 reader 测试文件依赖它的抛错行为与桩点。抛错责任分层：transport 只回报、API 层决定是否抛。

## 2026-10-24 · Emacs 同步状态库形态（M8-A）

**决策**：新增 `seshat-state.el`，用单个 `~/.local/share/seshat/sync-state.eld`（`prin1` 序列化、同目录临时文件 + `rename-file` 原子写）承载：全局 `cursor`、`:uids`（per-uid 的 `:root/:path/:base-blob/:size/:mtime/:dirty/:deleted-at/:orphan`）、`:paths` 派生索引、`:roots`（`(tag dir mode)`）。旧的单文件 head `~/.emacs.d/seshat-head` **不迁移**。

**理由**：旧 head 是全局单值，多文件同步互相覆盖（写入点不按 path 分键），且没有 cursor / uid 映射 / dirty / 墓碑，无法承载 M7 的 uid 模型与增量协议。选单 `.eld` 而非 SQLite：与既有 `annotation-queue.eld` 同风格、零新依赖、原子写模式已验证。**不迁移旧 head** 是因为单值无法无损散到多文件，强行迁移会把同一 hash 当成所有文件的 base，导致误判冲突；代价是首次同步可能触发一次冲突（有 `diff3` 兜底）。

## 2026-10-24 · Emacs 增量同步：首同步两阶段且职责分离

**决策**：首同步先用 `/api/resources` 分页预建索引，再用 `changes?since=0` 追平并取游标。**权威全集是 changes**；索引只是尽力而为的预建。

**理由**：`/api/resources` 的分页参数 `since` 语义是 `mtime >= since` 且无 offset，同秒内超过一页的记录会被跳过（`since+1` 才能前进，否则死循环），因此索引本身就**不保证完整**。而 `changes` 的 `seq` 是全局单调游标，分页无损且事件应用幂等，可安全重放。若反过来声称「索引兜底 changes」，会在「事件因钩子失败缺失 + 索引丢同秒」叠加时静默丢资源。

## 2026-10-24 · Emacs 增量同步：rename 双向检测与 size+mtime 判据

**决策**：rename 双向处理——服务端 `rename` 事件驱动本地改名；本地快照比对（同根下 `size` 与 `mtime` **都相同**的「消失 + 新增」配对）驱动 `POST /api/resources/{uid}/move`。不做 inotify。

**理由**：单侧不够——服务端改名不会自动反映到本地磁盘，本地 `mv` 也不会被服务端感知。用 `size + mtime` 而非内容 hash 是为避免全量读盘；代价是「rename 后立即编辑」会被判为删+建（uid 不稳定），以及「同尺寸同 mtime 的不同文件」会被误配——两者都记入 tech-debt，精化留后续。

## 2026-10-24 · 直接替换旧同步引擎，不做双引擎开关

**决策**：`seshat-sync-pull-all` / `seshat-sync-push-all` 改为调用新引擎（保持命令名与签名为兼容入口）；旧的 WebDAV 全量实现与 PROPFIND XML 解析删除（`seshat-sync.el` 的底层 WebDAV 函数保留，灰度期作传输后端仍可能需要）。

**理由**：双引擎意味着两套状态模型（单文件 head vs 状态库）、两套冲突语义（WebDAV 静默忽略条件头 vs REST 真乐观锁）长期并存，必然漂移。回滚靠 git 而非运行时开关更干净。

## 2026-10-24 · 抽出 seshat-merge.el 承载合并原语

**决策**：新增 `seshat-merge.el`（diff3 三方合并 + 冲突标记正则判定），依赖方向固定为 `seshat-conflict → seshat-sync → seshat-merge`。

**理由**：`seshat-conflict.el` 已 `require 'seshat-sync`，而 push 的 412 分支需要 diff3——若 `seshat-sync` 反向 require conflict 就成环（`require` 环在字节编译期不报错，运行期拿到未定义函数，故障难定位）。同时借此修掉既有 bug：`diff3` 的位置语义是 `-m MINE OLDER YOURS`，旧实现把共同祖先放在第一位，两侧独立改动被误报为冲突。冲突判定用正则扫 `<<<<<<<`/`>>>>>>>` 而非 `smerge-mode`，因为自动流程可能由定时器触发，不能依赖交互状态。

## 2026-10-24 · 阅读能力与库身份解耦：派生 major mode + 显式入库

**决策**：新增 `seshat-reading-mode`（`define-derived-mode` 自 `seshat-reader-mode`），由它接管 `auto-mode-alist`；库身份解析**只读本地状态（零网络）**，唯一触网入口是显式 `seshat-reading-refresh`；入库由显式命令 `seshat-library-add` 完成（**复制上传、保留原件**）。

**理由**：改造前「能否同步」由文件位置隐式决定（`seshat-reader-annotation--doc-id` 命中根即可同步），用户既无法把库外文档加进来，又会在通用阅读时被「降级为 local:」反复警告。派生而非叠加 minor mode，是为了让「打开即阅读」只有一个入口、且 mode-line 能直接表达库身份；`auto-mode-alist` 接管是「入库后再打开自动显示 `[库]`」的前提，代价是第三方依赖 `(eq major-mode 'seshat-reader-mode)` 的代码会失效（本仓已全部改为 `derived-mode-p`，仓库外未知，故在文档给出回退写法）。**零网络**是硬约束：`seshat-rest-resolve-uid` 是同步 HTTP，若在 mode 体里调用会在服务端不可达时阻塞打开，直接毁掉「打开即阅读」。入库用「复制」而非「移动」，是不动用户的文件布局（代价是本地可能有两份）。

## 2026-10-25 · 阅读器术语定案（annotation / bookmark / outline / progress）

**决策**：三端（服务端字段与文档、Android、Emacs）统一按行业惯例分四类概念，**互不借用名称**：① **批注 / 标注（annotation）** 是总称，子类型为 `highlight`（高亮）/ `underline`（下划线）/ `strikeout`（删除线）/ `note`（便签）/ `ink`（手写），载体是 `annotations` 的 `kind` 字段与 `seshat-reader-annotation.el`；② **书签（bookmark）** 是**位置标记**（无内容、无几何），载体是 `PdfBookmark` / `seshat-reader-bookmark.el`；③ **目录 / 大纲（outline / TOC）** 是**文档结构**，载体是 `PdfOutlineReader` / `seshat-reader-outline.el`；④ **阅读进度（reading progress）** 是**断点**，载体是 `reading_progress` 端点与 saveplace。已定语义但**尚未实现**的只有 `underline` / `strikeout`（暂无人产这两个值）；`bookmark` **永不进入** `annotations.kind`。

**理由**：改造前三端存在实质性的 term drift，且漂移方向一致地指向同一个错误——**把 outline 叫成书签**：Android `PdfOutlineReader.kt` 通篇用「书签树 / 书签」描述 PDF outline（该类实际读的是 PDF 的大纲结构），`TocDrawer` 名义上是目录却同时装目录与书签，状态行把「第 N/M 页」与「N 个书签」拼成一句；`openspec/decisions.md` 的 v8 条目与 Go/Kotlin 测试夹具把 `bookmark` 当作 `kind` 的候选取值；分组文案在「批注 / 备注 / 标注 / 列表」之间混用。术语一旦互相借用，**同一句话在三端指的不是同一件事**（「加个书签」在 PDF 里可能指加位置标记、也可能指跳目录项），bug 报告与文档因此无法对齐。选这四组定名而非自造词，是因为它们与 PDF 规范（outline = 文档大纲）、主流阅读器（annotation 含 highlight/underline/strikeout/note/ink、bookmark = 位置）以及 Web Annotation Data Model 的层级一致，用户无需学习新词。

**代价与约束**：① Android 侧的注释与用户可见文案必须同步改（`strings.xml` 的菜单项、`PdfOutlineReader.kt` 全部注释、`AnnotationGrouping.kt` 分组标题、`AnnotationDrawer.kt` 菜单项），未同步的一处就会留下两套词；② `TocDrawer` 的语义**扩大为「导航面板」**——它同时承载目录与书签两个 Tab，故不能说「`TocDrawer` = 目录」，文档与代码注释须写成「导航面板（目录 + 书签）」；③ 类名 / 资源键名**不改**（`PdfOutlineReader`、`pdf_toc_status` 等保持原样）——改名会穿透测试与存档数据，收益只在内部命名一致性，不值；④ `underline` / `strikeout` 只定语义、不实现：服务端不做枚举校验，客户端会把未知 `kind` 归入「其它」组，因此**新增形态无需服务端发版**，但三端的显示回退链必须同时确认。

**影响**：`docs/api.md` §4、`docs/android.md`（§6.4 目录 / §6.8 批注抽屉）、`docs/emacs-reader.md` §5、`openspec/tech-debt.md` 措辞同步；Android 分组标题定为「便签 / 高亮 / 手写 / 其它」，PDF 顶栏的 `pdf_menu_highlight` 菜单项文案改为「添加本页备注」（该入口实际产 `kind=note` + `page:<n>`，旧文案把它称作「高亮」本就是错的）。

## 2026-10-25 · `kind` 改为单维类型 + 备注由 `text` 表达

**决策**：`kind` **只表示标注类型**（`note` / `highlight` / `underline` / `strikeout` / `ink`），与「有无备注」**正交**；「有无备注」由 `text` 的空 / 非空表达，「选中了哪段原文」由 `selected_text` 表达。三端落地规则：**选中文本 → `kind=highlight` + `text=""` + `selected_text`=选区原文；加备注时 `kind` 不变、只写 `text`；纯页级备注 → `kind=note` + `text`（无几何）**。Emacs `seshat-reader-annotation-create` 据此改为：无备注发 `highlight` + `selected_text`，`C-u` 输入备注发 `note` + `text` + `selected_text`；Android EPUB 改为「选中即 `highlight`，编辑备注**不改** `kind`」，PDF「添加本页备注」产 `note` + `location=page:<n>`。

**理由**：改造前 `kind` 同时编码两个维度，导致两端在同一操作上给出不同答案——`EpubReaderActivity` 在「编辑备注并保存」时把 `kind` 从 `highlight` 改写成 `note`（高亮被降级成便签），而 `PdfReaderActivity` 的编辑路径不动 `kind`；Emacs 建标注**完全不发** `kind`，由存储层兜底为 `note`，于是「只选中原文、不写备注」在 Emacs 侧永远进不了「高亮」分组。单维类型是唯一自洽的模型：类型由用户动作决定（选/划线/手写），备注是可选的附注，两者没有因果关系。

**代价与约束**：① **存量 `note` 不迁移**——无法可靠判定哪些旧 `note` 其实是高亮（Emacs 旧记录带 `rect:` 但 `kind=note`，Android 旧 `note` 无几何），强行推断会把用户的真实便签改写成高亮；记 `openspec/tech-debt.md`。② **幂等键 `(uid, kind, location, text)` 不变**，因此同一位置上「旧 `note`」与「新 `highlight`」会成为两条独立记录——这是刻意的（去重键带 `kind` 的原文语义不变），可接受。③ **REST 契约不变**：路径、字段名、已存 `kind` 字面量、`location` 四种串格式（`page:<n>` / `page:<n>;rect:...` / `page:<n>;ink:...` / `chapter:<i>@<s>-<e>`）全部原样，服务端仍不做枚举校验、仍只强制「`kind=note` 时 `text` 非空」。④ Emacs 侧**本期无编辑批注路径**（`seshat-rest-update-annotation` 的唯一调用者是测试），故 PUT 未改；将来接入编辑时必须显式带上原 `kind`，否则 `UpdateAnnotationAt` 会把空 `kind` 兜底成 `note`，「高亮加备注」会被降级。⑤ EPUB 当前 UI 下**没有**页级 `note` 创建入口（入口要求 `selectedText` 非空），`note` 分支为存量与未来入口预留。

**影响**：`docs/api.md` §4.5 的 `kind` 说明与填充矩阵、`docs/emacs-reader.md` §5「建批注」、`docs/android.md` §6.8 分组语义、`CHANGELOG.md` 同步；新增 ERT 断言 payload 含 `kind` / `selected_text` 与离线队列往返；Android 侧 `AnnotationGroupingTest` 增加「加备注后 `kind` 仍为 `highlight`」用例。

## 2026-10-25 · 装饰表（Decoration）替代单色 highlight 表

**决策**：C 渲染层的 `Highlight`（单一填充色）升级为 **`Decoration` 表**，一条记录表达「几何 + 颜色 + alpha」，几何分两类——`DECORATION_KIND_RECT`（填充矩形，几何为四角）与 `DECORATION_KIND_STROKE`（折线，几何为 `fz_point *pts` + `pt_count` + `width`），两类**共用一张表**（渲染线程只遍历一次）。表在派发时**快照**进 `DrawThreadArgs`，stroke 的点列**逐条深拷贝**（不共享指针）。旧入口 `--add-highlight(page x0 y0 x1 y1)` 的**名字、arity（5,5）与行为全部不变**，内部映射为「rect + 默认黄 1.0/0.85/0.0 + α 0.35」，因此默认配置下的渲染结果与改造前**像素级相同**。新增三个入口：`--add-decoration(page x0 y0 x1 y1 r g b alpha)`（9 参，带颜色）、`--add-stroke(page r g b alpha width points)`（7 参，扁平点列表 `(x0 y0 x1 y1 …)`）、`--rects-in-rect(page x0 y0 x1 y1)`（返回矩形内每个命中字符的 quad，与 `--text-in-rect` 共享同一份 stext 遍历；空结果返回 nil 且**不发消息**——「矩形内没有文本」是正常答案）。

**理由**：高亮、下划线/删除线细条与（将来的）手写轨迹必须**共存于同一份页面位图**，且必须能区分颜色——已定的 `kind` 语义（`highlight` / `underline` / `strikeout` / `ink`）在单色表里无法表达：单表恒用同一填充色，underline 与 strikeout 要么画成高亮方块（错），要么另建一张表（则绘制顺序、清空、快照、释放四处都要分叉）。装饰表把「几何」与「样式」放进同一条记录，`kind` 的解释权留在 Lisp（C 不认识 `kind`），于是新增一种装饰只需在 elisp 的 `--decoration-for` 加一个分支，渲染层零改动。颜色分组进同一 path 一次填充，还顺带保住了「同色重叠不叠深」这一既有视觉语义。

**代价与约束**：① **所有权**——stroke 的点列是堆分配，浅拷贝会让渲染线程与 `DocState` 共享指针（`--clear-highlights` 释放后 use-after-free，或与 `free_draw_thread_args` 双 free），因此快照必须逐条深拷贝；所有权规则写进 `Decoration` 结构体注释（谁持有结构体谁释放 `pts`，恒只有一份所有权）并由**唯一释放函数** `free_decoration_table` 强制（`--clear-highlights` / `free_doc_state` / `free_draw_thread_args` 共用，后者仍是 `draw_page_thread` 全部 7 条退出路径的唯一漏斗）。② **上限**：`DECORATION_MAX_STYLE_GROUPS = 64` 个样式分组（越过组上限的 rect 各自单独填充，语义不变、只是多几次 fill）；沿用 `DECORATION_MAX_COUNT = 100000`、`DECORATION_MAX_ABS_COORD = 1e6`、新增 `DECORATION_MAX_POINTS = 1024`（每笔超限**截断而非拒绝**）。③ **dash 未支持**：`fz_stroke_state` 由栈副本构造且 `dash_len = 0`（柔性数组 `dash_list[]` 永不被读），虚线要动态分配 dash 数组并改所有权，本期不做。④ 内存正确性只能靠「所有权约定 + 唯一释放路径 + 压力循环」，**未做 valgrind / ASan**（记 tech-debt）。

**影响**：Lisp 侧按 `kind` 选装饰规格（`seshat-reader-annotation--decoration-for` → 8 元素「几何 + RGB + alpha」），`highlight` 在默认配色下继续走 5 参 `--add-highlight`（像素等价），`underline` / `strikeout` 或自定义配色走 9 参 `--add-decoration`；`--rects-in-rect` 支撑字级框选高亮（字符 quad 按行合并），而多段 `rect:` 受写入端 **500 段**上限约束，因此 `character` 粒度只写前 500 段并提示一次。`docs/architecture.md`（装饰表小节、防御上限表）、`docs/api.md` §4.5.2、`docs/emacs-reader.md`（字级高亮、粒度与间隙选项、下划线/删除线配色表）、`emacs/seshat-reader/VENDORED.md`（C 改动登记）、`CHANGELOG.md` 同步。

## 2026-10-25 · C 侧页号基数约定

**决策**：C 动态模块里**按页索引的入口分两组、基数固定且必须显式声明**——① **装饰与搜索组，一律 1-based**：`--add-highlight` / `--add-decoration` / `--add-stroke` / `--search-page` 都经 `resolve_page_arg` 取页号（校验整数、范围检查、并完成**唯一一次** `-1` 换算到内部 0-based `DocState` 索引）；② **选区几何组，保持 0-based**：`--text-in-rect` / `--rects-in-rect` 继续直接取页索引（它们服务于已在页索引空间工作的选区代码）。今后**新增任何按页索引的 C 入口必须在函数注释首段显式写出基数**，默认跟 ①（1-based）。

**理由**：`--search-page` 初版直接 `extract_integer` 取 **0-based**，与三个装饰入口的 **1-based** 相反——同一模块内两类按页入口语义相反，跨页搜索的命中整体错一页，而 Lisp 侧用 `(1- page)` 把错误掩盖掉了，任一侧改动即静默失效。Elisp 调用方手上**永远**是用户可见的 1-based 页码（`seshat-reader-current-page` / 状态行 / 批注的 `page:` 段），所以减一的边界应当落在模块内、只落一次，而不是让每个调用方各自记得换算。「与装饰入口统一」的实测依据：把 `--search-page` 改为 1-based 后，`--search-page p "的"` 与 `--text-in-rect p`（按其 0-based 口径传入同一页）逐页命中矩形完全相等，跨页搜索不再偏移。

**代价**：两套基数在同一模块内并存，读者必须看注释才能确定某入口的页号语义；`--text-in-rect` / `--rects-in-rect` 的 0-based 属历史遗留，统一它们要同步改 `seshat-reader-select.el` 与 4 个测试文件的桩与断言，收益只在命名一致性，故本轮不动，代价是长期存在一个「例外组」。防退化只能靠注释约定 + 测试锁定：`seshat-reader-search-test` 的桩按 1-based 断言页号，`seshat-reader-select-*` 的桩按 0-based 断言，任一侧基数被改都会有用例失败。

**影响**：`seshat-reader-search.el` 去掉全部 `(1- page)` / `(1+ page)` 换算（页码直接透传）；`render/render-core.c` 的 `emacs_search_page` 改走 `resolve_page_arg`，四个 1-based 入口的注释首段逐个写明基数；`openspec/tech-debt.md` 登记「两套基数并存」；`docs/architecture.md`（渲染层入口清单、搜索流程）与 `docs/emacs-reader.md` 同步。

## 2026-10-25 · 阅读器面板承载由 side window 改为 child frame 覆盖

**决策**：阅读器面板（`outline` / `annotations` / `translate`）的承载由「窗口」（side window / 底部窗口）默认改为 **child frame 覆盖**：child frame 贴在父 frame 右上角、**不参与窗口树**，尺寸由 `seshat-reader-panel-width`（`0.34` × 父 frame 像素宽）/ `seshat-reader-panel-height`（`0.45` × 父 frame 像素高）/ `seshat-reader-panel-margin`（`16` px）在**打开那一刻**固定，内容超出后在面板内滚动。承载方式由 `seshat-reader-panel-carrier`（默认 `childframe`）统一决定，`seshat-reader-panel-carrier-alist`（默认 `((annotations . window))`）逐 kind 覆盖；窗口承载及其全部旧配置（`seshat-reader-sidebar-position` / `-width` / `-height` / `-min-height` / `-max-height` 一族）原样保留。非图形环境强制回退 `window`。完整论证见 `docs/adr/0005-reader-panel-carrier.md`。

**理由**：根因是**阅读器版面与窗口像素尺寸耦合**——页面居中、`fit` 缩放、`--refit-window` 全部按当前窗口的像素尺寸计算，而窗口承载的面板一旦显示 / 收起 / 改尺寸，就在同一个 frame 的窗口树里挤压阅读窗口，触发 `window-size-change-functions` → 重新适配 → 用户看到页面「跳一下」；译文面板在流式输出期间反复自适应高度时，这种跳动会被放大成持续抖动。child frame 不占窗口树，面板的开合、刷新、滚动因此**在结构上不可能**改变阅读窗口尺寸——等于把「面板刷新不得改动阅读窗口尺寸」这条不变量编码进承载模型，而不是继续在窗口体系里加去抖 / 抑制动画的特例。

**代价与约束**：① **非图形环境不可用**（tty / 终端没有 child frame），必须回退窗口承载，且要有两条回退路径（`display-graphic-p` 判否 + `--cf-show` 返回 nil 的软回退）；② **多面板需纵向堆叠防重叠**——三个 kind 同时显示时不能都贴同一个角，`--cf-position` 按已有面板逐个下移；③ **popper 失效**——popper 经 `display-buffer-alist` 接管 popup，child frame 面板不经过 `display-buffer`，`C-'` 只对窗口承载的面板有效（面板内 buffer 仍可用 popper 打开成普通窗口）；④ 面板尺寸全部固定，长内容只能内部滚动，读者失去「把面板拖高一点」这种手工调法（改用 `seshat-reader-panel-height`）；⑤ child frame 不属于任何窗口树，切走 buffer 后必须靠 `window-buffer-change-functions` 显式关闭（`seshat-reader-panel-hide-on-buffer-change`），否则会盖在别的窗口上。

**影响**：`seshat-reader-sidebar.el` 新增承载分派（`--carrier-for-kind`）与 childframe 后端（`--cf-show` / `--cf-position` / `--cf-size` / `--cf-suppress-mode-line` / `--cf-close`），`seshat-reader-sidebar-quit` 统一面板内 `q`（child frame 走 `delete-frame`），`C-c C-o` 改绑无参的 `seshat-reader-sidebar-toggle`；`docs/emacs-reader.md`「面板承载」节、`docs/configuration.md`「阅读器面板」表、`docs/adr/0005-reader-panel-carrier.md`、`CHANGELOG.md`（破坏性 + 回退写法）同步。

## 2026-10-25 · 译文面板流式增量输出 + 面板尺寸固定

**决策**：译文 / 解释面板改为**边生成边显示**（`seshat-reader-translate-stream` 默认 `t`）：首个增量到达时按模板渲染一次**骨架**（正文 `%t` 为空）并记录正文起点 marker，后续增量只**替换 marker 之后的正文区**，完成时只更新 `header-line`、不 `erase-buffer` 重写；同时面板几何**打开即固定**（childframe 承载下由 `seshat-reader-panel-width` / `-height` 决定，全程不 resize），内容超出在面板内滚动，`seshat-reader-panel-follow-bottom`（默认 `t`）在流式期间跟随底部、用户上滚后停止跟随。

**理由**：LLM 输出长（单次解释常见数百到上千字、耗时数十秒），「等全部生成完再显示」让面板在整段时间里只有占位内容，用户既无法判断是否卡住、也无法提前读到开头。增量渲染解决实时反馈，但只有在**遮挡区域恒定**时才成立——如果面板还按内容行数自适应高度，每来一段增量就改一次 frame 布局，等于把阅读器拖进持续 refit；「固定尺寸 + 内部滚动 + 跟随底部」把「新内容进入视野」与「阅读窗口尺寸不变」两件事解耦。骨架只写一次而非每次增量重排，是为了避免完成瞬间整块跳变（也顺带避开 `erase-buffer` 会丢 point / marker 的问题）。

**代价与约束**：① **gt 升级可能静默退化为完成时渲染**——实现依赖 `gt-buffer-render-output-hook` 的增量语义与引擎的 `stream` 槽，gt 改动后可能不报错、只是不再流式，排查只能看 header-line 是否在生成期间更新（已写入 `docs/emacs-reader.md` 的「已知退化路径」）；② 面板不再按内容自适应高度（`--fit-height-for-content` 只服务窗口承载的 `translate` 面板），长译文必须滚动查看；③ 增量替换依赖 marker，任何重建正文的路径都要重建 marker（新一次翻译会重置骨架与正文起点，并清空追问状态）；④ 跟随底部是「用户上滚即停」，不是严格锁底——滚回底部才恢复。

**影响**：`seshat-reader-translate.el` 新增增量同步与追问状态机，`seshat-reader-sidebar.el` 新增 `seshat-reader-panel-follow-bottom` 与 childframe 固定尺寸；`docs/emacs-reader.md`「译文流式渲染」与「继续追问」节、`docs/configuration.md`「阅读器翻译 / 解释」表、`CHANGELOG.md` 同步。

## 2026-10-25 · 复制回显改行列统计 + 多引擎结果标注来源

**决策**：① 框选回显**不再显示正文**——echo area 只报 `已复制 N 行 · M 字`（`seshat-reader-select-copy-to-kill-ring` 非 nil）或 `已选中 N 行 · M 字`（`nil`），并删除截断常量 `seshat-reader-select-message-limit`；② 多引擎译文默认**全量展示并标注来源**——`seshat-reader-translate-engines-pick` 默认 `all`，每条结果前标 `【引擎名】`、段间用 `---` 分隔；`first` / `last` 只留一个**成功**结果且不带标签。

**理由**：① 回显正文既**干扰阅读**（选中内容与页面闪现高亮重复表达同一件事，还占用唯一的回显行），也**可能泄露内容**——选中文本会进入 `*Messages*`（以及任何 `message` 日志），而选区往往是敏感正文；行列数足以回答「我刚选到了多大范围」，真要读文本可查 `seshat-reader-select-last` 或 kill ring。② 多引擎预设（`reader` = youdao-dict + google）的价值就是**对比各家译文**，改造前的拼接让两段结果首尾相接、看不出哪段出自哪个引擎，比对价值为零；逐条标注来源后 `all` 才成立。`first` / `last` 不带标签是刻意的：只有一个结果时标注来源没有信息量，反而多一行噪声。

**代价与约束**：① 想知道选中的具体文字必须另取（`seshat-reader-select-last` / kill ring），回显层不再提供摘要；② `seshat-reader-select-message-limit` 删除后配置侧残留的 `setq` 不报错但**静默失效**（已在 `CHANGELOG.md`「移除」与 `docs/configuration.md` 写明）；③ `all` 的输出更长，多引擎 + 长原文时面板内容显著变长（由固定尺寸 + 内部滚动承接）；④ 失败引擎必须跳过（`gt-buffer-render-error-face`），否则错误块也会被标上来源，且 `first` 需**顺延**到下一个成功片段。

**影响**：`seshat-reader-select.el`（回显两分支、删常量）、`seshat-reader-translate.el`（`--format-engine-results`）、新增测试 `emacs/tests/seshat-reader-select-report-test.el`（7 例，含 `(should-not (boundp 'seshat-reader-select-message-limit))`）；`docs/emacs-reader.md` §5「框选取文」与 §6「多引擎结果」、`docs/configuration.md`、`CHANGELOG.md` 同步。

## 2026-10-25 · 阅读器 gt 预设归属改为 seshat 自有表（含回落）

**决策**：seshat 的两个 gt 预设（`reader` / `reader-explain`）改存 **seshat 自有的 `seshat-reader-translate-presets`**（元素 `(NAME . TRANSLATOR)` 或 `(NAME . THUNK)`），**不再 push 进 gt 的全局 `gt-preset-translators`**。查表统一走 `seshat-reader-translate--preset-translator`，顺序为 **seshat 表 → `gt-preset-translators`**（自有表命中优先，未命中回落全局表）。配套：`reader-explain` 的引擎 `:prompt` 改为纯透传 `"{{text}}"`；DeepSeek key 由配置侧引擎子类 `thomas-seshat-chatgpt-engine` 覆写 `gt-resolve-key` 从 `DEEPSEEK_API_KEY` 取，**删除** `(setq gt-chatgpt-key …)`。

**理由**：`gt-preset-translators` 是 gt **自用**的全局预设表，`gt-translate`（前缀选预设）与 `gt-setup` 都读它——把 seshat 的两个预设 push 进去，等于让 `reader` / `reader-explain` 出现在用户**所有** gt 用法的预设选择列表里，这是纯粹的命名空间污染：用户按 `M-x gt-translate` 看到「reader」不会知道那是阅读器专用、更不知道它取 `DEEPSEEK_API_KEY`。同理 `(setq gt-chatgpt-key (getenv "DEEPSEEK_API_KEY"))` 会让**任意** chatgpt 引擎（含用户自己对 OpenAI 的用法）拿着 DeepSeek key 打各自端点，属于跨功能副作用。**保留回落**而不是硬切，是为了让旧配置（预设仍在全局表里）继续工作、零迁移成本，也让既有大量引用 `gt-preset-translators` 的 ERT 无需改动。

**代价与约束**：① 查表变成两处（`--translator` 与追问路径 `--preset-chatgpt-engine` 必须共用同一辅助函数，否则迁出全局表后追问立刻 `user-error`，该坑在 T1.5 已修）；② 新增一层「thunk 形态」，因为配置加载时 gt 可能尚未加载、不能直接 `make-instance`；③ 隔离靠**配置侧不再 push** 保证，属跨仓库不变量，故在 thomas-emacs `AGENTS.md` 登记机械检查（`(assq 'reader gt-preset-translators)` 应为 nil、配置文本不得含 `(setq gt-chatgpt-key`）。

**影响**：`seshat-reader-translate.el` 新增 `seshat-reader-translate-presets` + `--preset-translator`，`--translator` / `--preset-chatgpt-engine` 各改一行查表；`thomas-emacs/lisp/init-tools.el` 两个预设的 push 目标改表并新增引擎子类；`test/init-smoke-test.el` 新增两条文件级断言；`docs/configuration.md` / `docs/llm.md` / `docs/emacs-reader.md` / 两仓 `CHANGELOG.md` 同步。

## 2026-10-25 · 不克隆、不改 gt 引擎槽：解释 prompt 走 taker text

**决策**：解释需要的结构化指令与上下文**全部装配成一段字符串，塞进 `gt-taker` 的 `:text`**（`--translator` 新增可选第 5 参 `request-text`，只做 `(oset trans taker (gt-taker :text (or request-text text) …))`），**不新建、不 `oset`、不克隆任何 gt 引擎实例的槽**；预设引擎的 `prompt` 槽由配置侧设为纯透传 `"{{text}}"`。

**理由**：① gt 的 engine / parser / render 都继承 `gt-single`，其 `make-instance` 以「槽参数的 sha1」为键做 **class 级实例缓存**——`eieio` 的 `clone` 是否绕过该缓存**未实测**（`describe-function clone` 只说是 generic 并带 PARAMS），一旦命中缓存，`(oset copy prompt …)` 改的就是**全局共享的那个引擎实例**，把 seshat 的解释指令泄漏给用户其它 gt 用法，且不会报错、只会「莫名多出一段中文指令」。② 新建引擎实例要求 seshat 硬编码引擎类与厂商参数（host / model / key），违反「seshat 只做桥接」的职责边界。③ 已验证安全的路径是 **translator 层克隆**：`gt-translator` 的类定义是 `(defclass gt-translator ())`，**不继承 `gt-single`**，故现有「克隆 translator 后只 `oset` `taker` / `render` 两个槽」不经过实例缓存，无污染风险——保留这条路径、把 prompt 需求也压进它的 `taker` 槽，是不动引擎的唯一自洽解法。④ `gt-chatgpt-engine` 的 `prompt` 支持字符串模板 + `{{text}}` 占位是公开用法，配置侧一行透传即可，不构成 hack。

**代价与约束**：① prompt 只能以 put-string 方式进入，无法使用引擎级多轮 `messages`（首轮解释不是 messages 形式，追问才用）；② 配置侧**必须**把 `reader-explain` 的 `:prompt` 写成 `"{{text}}"`，写长 prompt 会变成双层指令（已在 `docs/configuration.md` 与配置仓注释里显式约定）；③ 与 childframe 计划的 T4/T5（流式 / 追问）在 `--translator` 上有接口重叠，只能加**可选**参数、不得重排既有参数。

**影响**：`seshat-reader-translate.el` 新增 `seshat-reader-translate-explain-prompt` / `--document-title` / `--explain-request-text`，`--translator` 追加可选第 5 参 `request-text`；面板 `%q` 与 `last-result` 语义不变（仍取纯选区 / 模型输出）。

## 2026-10-25 · 解释上下文取「行矩形扩行」，带两级降级

**决策**：解释的上下文优先用「**选区触达的整行矩形 → 纵向按行高均值上下各扩 N 行 → 取该矩形 → 拆成「选区上方块」与「下方块」两次 `--text-in-rect`（天然不含选区，不做字符串剥离）→ 窗口截断**」这条链（`--expand-rect` / `--context-window` / `--context-text`），失败时降级为「**整页文本 + 以选区为中心的窗口截取**」，再失败返回 `nil`（退化为「纯选区 + 指令」）。页号取 `seshat-reader-select-last` 的 `:page`（1-based）后**转 0-based** 再喂 C 模块。总长上限 `seshat-reader-translate-context-max-chars`（默认 `1200`）。（修订 2026-10-25：初版用精确字符串删除选区原文，因 `--text-in-rect` 同段落内不插换行分隔导致剥离命中率为 0，真实 PDF 复验后改为上下块取法。）

**理由**：解释质量的瓶颈是「模型看不到上文」，而**同页邻近段落**是性价比最高的一档上下文——它把代词指代、术语首次定义、公式引用都带进来了，代价只有一页内的几百字符。选「行矩形扩行」而不是「整页文本」是因为整页文本在双栏 / 表格 / 脚注混杂的页面上是噪声，且长页会轻易吃掉几千字符；行矩形已经由 C 侧 `--lines-in-rect` 按行边界求出（整行宽度），扩行只是把一个紧贴选区的窄矩形变成「选区上下几行」的块，语义与阅读者的视野一致。降级链的两级是必要的：`--lines-in-rect` 在无文本层页面或旧 `.so` 上不可用，而 `--page-text`（按页取全文）几乎总可用——**没有它，用户机器上的行为会因是否构建了最新 `.so` 而分裂**。

**代价与约束**：① 行高取均值外扩是**启发式**（旋转页 / 竖排 / 极端行距下扩出的范围可能偏大或偏小），无法保证恰好「N 行」；② 每步都可能触碰 C 模块，全程 `condition-case` + 静默返回 `nil`——批处理与未构建 `.so` 是常态，**不得** `message` 报错；③ 上下文文本依赖 `--page-text` / `--text-in-rect` 的软换行粘接（行间无 `\n`），所以送模型前还要过上游 `gt-source-text-transformer` 归一化（见 `openspec/tech-debt.md`）；④ 隐私面扩大（见下条「影响」与 `docs/llm.md`）。

**影响**：`seshat-reader-translate.el` 新增 `seshat-reader-translate-context-enabled` / `-context-lines` / `-context-max-chars` 与 `--expand-rect` / `--context-window` / `--context-text`；`--context-text` 是**唯一**读 C 模块的新入口（内部把 `:page` 转 0-based）。隐私影响：解释发送数据由「仅选区」变为「选区 + 同页邻近上下文（≤1200 字符）」，`docs/llm.md`「隐私提示」与 `CHANGELOG.md`「变更」同步写明；关闭开关 `seshat-reader-translate-context-enabled` 可退回仅选区。

## 2026-10-25 · 与 childframe 计划的接口承接（T4/T5 已落地）

**决策**：本计划（预设隔离 + 解释质量）**不改造**流式（`--enable-stream` / `seshat-reader-translate-stream`）与多轮追问（`--follow-up-*`），二者由并行计划 `2026-10-24-emacs-reader-panel-childframe-and-ux` 的 T4/T5 实现并已随 commit `8d43480` 落地。两计划的接口约定为：① 追问首轮 user message **复用 `seshat-reader-translate--explain-request-text` 的产物**（即已装配好的「指令 + 上下文 + 原文」），不再另拼一份首轮提示；② 任何一方要改成「克隆引擎再改槽」的方案，**必须先做 `eieio clone` vs `gt-single` 实例缓存的行为 spike**，否则按本条 D2 一律禁止；③ `--translator` 的签名只能**追加可选参数**，不得重排或重命名既有参数（childframe 侧为 4 参调用，本计划加了可选第 5 参）。

**理由**：两计划在 `--translator`、`--render-object`、`--record-result` 三处必然交汇，各自独立演进会互相打脸；把「首轮 request-text 由谁生产」定成单向依赖（childframe 消费、本计划生产），可以避免出现两份首轮 prompt 定义。而「先 spike 再克隆」是 D2 的直接推论：`gt-single` 的 class 级实例缓存未验证时，克隆可能就是原地改全局对象——流式需要 `stream` 槽、追问需要 `prompt` 槽，两者都只能改引擎槽，因此这条前置对 childframe 侧是**阻断性**的，不是建议。

**代价与约束**：① childframe 侧的既有实现（`8d43480`）确实用了 `(clone engine)` + `oset stream` / `oset prompt`，该路径**至今无测试支撑**，属已知未验证面积（记 `openspec/tech-debt.md` 第 1 条）；② 追问的首轮消息来源被固定到 `--explain-request-text`，若将来该函数的契约（纯字符串、nil 模板时原样返回选区）变更，追问侧必须同步；③ 两条计划并行期曾出现「查表有两处」的冲突面（`--translator` 与 `--preset-chatgpt-engine`），已在 T1.5 统一为 `--preset-translator`。

**影响**：`seshat-reader-translate--translator` 保持兼容签名；`openspec/tech-debt.md` 新增「`eieio clone` vs `gt-single` 缓存未验证」条；本文档 D2 与本条共同构成「不克隆引擎」的决策依据。

## 2026-10-26 · 阅读器关闭 evil：键位由包内 mode-map 唯一承担

**决策**：① 阅读器全部 buffer（阅读 buffer、目录面板、批注列表、译文 / 解释面板、搜索结果侧栏、帮助页）**关闭 evil**——统一经 `seshat-reader--disable-evil` 调 `evil-local-mode -1`，由新增 defcustom `seshat-reader-disable-evil`（默认 `t`）控制；键位一律由包内 `seshat-reader-mode-map` 与各面板 mode-map 承担。② 新增 3 个 defcustom：`seshat-reader-disable-evil`、`seshat-reader-screen-context-lines`（默认 `1`）、`seshat-reader-keymap-preset`（默认 `vim`，`:set` 钩子幂等重装绑定），用户可仅用 `use-package … :custom` 配置。③ **vim 主键 + Emacs 补齐的双轨键位**——`vim` preset 在保留全部上游 Emacs 绑定（`n`/`p`、`SPC`/`DEL`/`S-SPC`、`C-v`/`M-v`、`C-a`/`C-e`、`M-<`/`M->`、`M-g g`、缩放 / 旋转 / `o`/`Q`/`?`）之外增挂 `j`/`k`、`h`/`l`、`^`/`$`、`gg`/`G`、`C-l`、`/`，并把 `C-f`/`C-b` 改为滚屏；`emacs` preset 完全等于上游语义。④ **翻屏重叠 1 行**——`seshat-reader-screen-context-lines` 在 `seshat-reader-mode` body 里 `setq-local` 到 `next-screen-context-lines`，翻屏步长 = 窗口高 − 1 行（原为窗口高 − 2 行）。

**理由**：① evil 的 normal state 经 `emulation-mode-map-alists` 挂在 major-mode-map **之前**，`C-v` / `C-f` / `j` / `k` / `n` / `p` 一律被 evil 抢走，因此「翻屏步长」「滚屏命令」这类 reader 语义**根本无法按设计生效**——翻屏步长要生效只能不改键而在键之外做，关掉 evil 才是根因修复。② 关掉 evil 之前，同一批键位需要**双份维护**：包内 evil 补绑实现（`--install-evil-bindings` ×2、`--ensure-panel-evil-keys`）加 `thomas-emacs/lisp/init-evil.el` 的 49 条绑定，任一侧改动都要同步另一侧，且「auxiliary keymap 需 `evil-normalize-keymaps` 才装载」这类时序坑反复出现（详见 M11.2c / M11.3 两条技术债）。关掉 evil 后 **mode-map 成为唯一事实源**，`keymap-set` 立即对已打开 buffer 生效，不需要 normalize。③ 三个 defcustom 让「是否关 evil / 翻屏重叠几行 / 用哪套键位」都成为用户可声明项，配置侧退化为 `use-package … :custom` 三行，不再需要大段 evil 绑定。

**代价与约束**：① `C-f` / `C-b` 由「横向滚动」改为「上下滚一屏」、`g`（重渲染）让位给 `gg`（首页，重渲染移到 `C-l`）——属 **breaking change**，横向滚动在 `vim` 下改用 `h`/`l` 与 `C-a`/`C-e`；`(setq seshat-reader-keymap-preset 'emacs)` 可完整回到上游语义。② 阅读器内不再有 evil 的移动 / 可视选择 / 文本对象——页面是只读单页位图，`hjkl` 与可视选择没有实际用途，损失可接受。③ 原 `init-evil.el` 的 `gg`/`G` 支持带前缀（`C-u 5 G`）跳**指定页**，该能力随 seshat 段删除而收窄：`G` 只跳末页，跳指定页用 `M-g g`（已记 `openspec/tech-debt.md`）。④ evil 在 buffer **显示路径**上会重新 enable，帮助页必须在 `pop-to-buffer` 之后再关一次（见下「被推翻的假设」）。⑤ `Package-Requires` 由 `26.1` 升到 `29.1`（`defvar-keymap` / `keymap-set` / `keymap-unset` 所需），放弃对 26–28 的兼容。

**被推翻的假设**：计划曾假设「在 mode body 里关一次即可」——实测把 buffer `pop-to-buffer` 显示之后 `evil-local-mode` 会**重新变回 `t`**，故帮助页改为「`special-mode` 就位时关一次 + 显示之后再关一次」；面板则由 `--display` 显示漏斗（window / childframe 两条承载路径）在显示前关闭、`show` 的 `pop-to-buffer` 回退分支各关一次覆盖，并有测试断言「re-enable 后重关」。

**影响**：`seshat-reader.el` 新增 `--disable-evil` / `--disable-evil-in-existing-buffers`（`(with-eval-after-load 'evil …)` 补扫已显示的 buffer，覆盖「evil 在本包之后才加载」）、3 个 defcustom、三张 preset 绑定表与 `--install-keymap-preset` / `--set-keymap-preset`，删除 `--install-evil-bindings`；`seshat-reader-outline.el` / `-annotation.el` / `-translate.el` / `-search.el` / `-help.el` 各在 mode body 或显示路径调 helper 并补 `j`/`k`（译文面板另有 `w`），`seshat-reader-sidebar.el` 删除 128 行面板补绑机制改为在 `--display` / `show` 调 helper；`seshat-reader-etaf.el` 仅改注释。配置侧 `thomas-emacs`：`lisp/init-evil.el` 删除 103 行 seshat 段、`lisp/init-reader.el` 改用 `:custom` 声明三个 defcustom。

## 2026-10-26 · 按需取书用「原子落位 + 显式刷新」，不做自动比对

**决策**：`seshat-library-fetch` 的契约是「保证本地有副本」，**不判断副本是否最新**——内容是否最新由用户**显式刷新**（书架 `u` 键，即以 `force` 非 nil 重新取书）。落盘一律经 `seshat-rest-download-file`（内部 `seshat-rest--write-binary-file` 用 `make-temp-file` 生成随机临时名 + `rename-file` 原子改名），library **不自写任何临时文件**（`.part` 是 Android 端的命名，Emacs 端不存在该机制；自写固定名会在并发取书时冲突、中断时残留半文件并污染三态判定）。取书前后**不做**全清单比对，也**不读服务端内容做校验**（直接下载覆盖）。

**理由**：`ondemand` 根的 `blob` 恒为空串、`changes` 事件不带 `size` / `mtime`，客户端**没有任何可检测的过期信号**——「本地副本是否过期」这个问题在协议层就没有答案。为「可能过期」引入全清单比对，会让每次打开书架都多一轮请求，而收益仅是省用户按一次 `u`；同理，下载前读内容比对是为一个不可判定的问题付出额外往返。原子落位复用 rest 层而非在 library 自写，是因为「中断不留半文件」与「并发不互相覆盖」两条不变量已经在那一层实现并测试过，第二份实现必然漂移。

**代价与约束**：① 服务端更新书库文件后，用户不按 `u` 就继续读旧副本——该边界写入 `openspec/tech-debt.md`「`ondemand` 副本过期无可检测信号」与 `docs/emacs-reader.md` 的透明性边界节；② 取书不进入 push 路径（`ondemand` 根只读），状态库只写 base-blob（空串）+ 落盘后的 `size` / `mtime`；③ 位置重申用 `seshat-sync--event-set-location`（merge 语义）而不是 `seshat-state-remap`——remap 是**改名语义**（清 `:orphan`、把占据同路径的旧属主标孤儿），取书不该改动其它 uid。

## 2026-10-26 · `seshat:` 链接改由 uid 承载身份，且全部插入路径统一

**决策**：`seshat:` 链接身份由服务端权威 uid 承载（新增形态 `seshat:uid:<uid>[#<location>]`），路径派生的 `doc-id`（`tag:relative-path`）降级为人类可读描述。**所有产生链接的路径**——`org-store-link`（`:store`）、`C-c C-r` 摘录（`--format-block`）、批注引用插入（`insert-annotation`）、`copy-link`——统一经**单一构造入口** `seshat-reader-reference--link-for` 决定形态，不得各自拼 `doc-id`。判别规则：剥掉 `seshat:` 后若以 `uid:` 开头**且** `uid:` 到第一个 `#` 之间的部分匹配 26 位 Crockford Base32 `[0-9A-HJKMNP-TV-Z]\{26\}`（排除 I/L/O/U）才判为 uid 形态，否则回落 `tag:path` 形态。`:complete` **不变**（候选仍是 `doc-id`）。

**理由**：路径派生的身份改名即失效，而 uid 是改名稳定的**唯一**身份（服务端 `refs` 早已支持两种形态）。各入口分别拼 `doc-id` 会让「同一文件在不同入口产出不同形态」，用户没法建立稳定心智；收敛到 `--link-for` 后形态只由「能否零网络解析出 uid」决定，一处改动即四条路径同时生效。`uid:` 前缀用 26 位 Crockford Base32 严格校验，是为了让**根 tag 名为 `uid`** 保持合法（`docs/configuration.md` 只要求 tag 非空、唯一、不含 `:`）——只有「tag 为 `uid` 且相对路径恰好是 26 位大写字母数字」这一极端组合会误判，接受该风险。`:` 前缀判别必须大小写敏感（`string-match-p` 默认 `case-fold-search` 为 `t`，会把小写 uid 误判成 uid 形态，T3a 已抓到该真实 bug）。

**代价与约束**：① **用户可感知的行为变更**——新产生的链接形态由 `doc-id` 变为 `uid`；未配置 `seshat-sync-roots`、或两套根配置 tag 不一致时自动回落 `doc-id`（不报错、不阻塞插入），因此回退路径必须长期保持可用；② uid 形态**不可读**，可读性由 org 链接描述承担（`[[seshat:uid:X][书名 第 3 页]]`）；③ `:export` 与链接描述对 uid 形态必须还原文件名，取不到时回落 `uid:<前 8 位>…`（如 `uid:01J8ZKQ2…`），**绝不输出空串**——回落判据除严格 26 位 uid 外还接受「裸 Crockford Base32 串」（见 T3b 执行期修正），因为回落标识本身要能处理非 26 位输入，而合法 `doc-id` 必含 `:`、两者不可能相撞；该放宽**只作用于描述/导出**，不作用于 `--parse-link` 的形态判别；④ 既有 `tag:path` / `local:` 形态的解析逐字不变（回归测试守护），`:follow` 双形态兼容。

## 2026-10-26 · 两套根配置暂不统一（`seshat-state-roots` 与 `seshat-reader-annotation-roots` 并存）

**决策**：`seshat-state-roots`（同步用，`(TAG DIR MODE)`）与 `seshat-reader-annotation-roots`（批注 / 引用用，`(TAG . DIR)`）**本计划不统一**，继续并存。uid 解析（`seshat-reader-reference--identity`）按后者得 `(tag . rel)` 后软依赖 `seshat-state-uid-for-path` 查 uid。

**理由**：统一会牵动批注 / 翻译 / 离线队列整条链路（三处都按 `seshat-reader-annotation-roots` 推导 `doc-id`），风险与收益不成比例；而本计划的目标（书名册化、链接改名稳定）在两套配置并存的现状下已能达成。

**代价与约束**：① 同一目录可能被配两次（两套配置各写一遍），配错时的症状是「某个入口查不到 uid」而不是报错；② `seshat:` 的 uid 解析要求两套 tag 一致——不一致时回落到 `doc-id` 形态（链接仍可用，只是失去改名稳定性），描述回落 `uid:<前 8 位>…`；③ 统一动作列入 `openspec/tech-debt.md`「两套根配置待统一」，将来的方向是把后者改为从前者派生（或提供同步命令），而不是再引入第三份配置。

## 2026-10-26 · 透明性验证用「白名单式反向断言」，不用「加载前后差分」

**决策**：`emacs/tests/seshat-transparency-test.el` 采用**加载后白名单式反向断言**——加载 `seshat-sync` / `seshat-reading` / `seshat-library` 之后，断言「不该出现的东西不出现」（`.org` 的实际 major mode、`dired-mode-map` 里的 seshat 命令、两个全局 hook、被 advice 的函数名集合、`auto-mode-alist` 注册），**不依赖任何「加载前」基线**；并为每条探测器附**变异自检 / 反向自我验证**（注入假侵入必须让断言失败），证明断言真的能抓到侵入。

**理由**：共享 ERT 单进程里模块在测试文件加载时早已 `require` 完成，`require` 幂等 → 加载前后差分恒为空 → 断言恒真（**假绿**）；`seshat-reading--take-over-auto-mode-alist` 又是就地改写，第二次执行零效果，差分法在这个代码结构下从根上不成立。「不该有什么」这类否定断言不需要基线，天然适配共享进程。变异自检是必需的：`dired-mode-map` 若只扫 `map-keymap` 顶层，前缀绑定与 `remap` 都落在子 keymap 里，注入假侵入也不会被检出（T5 实测）。

**代价与约束**：① advice 白名单初始为 `{save-place-to-alist, pcase--mutually-exclusive-p}`——前者是 vendored reader 包的既有侵入（`seshat-reader-saveplace.el` 的 `:around`，集成 saveplace 所需，非本计划引入），后者是 stock Emacs `cl-macs.el` 在 `cl-lib` 加载时自带的 advice（不纳入会因**无关原因**永久失败）；**新增任何 advice 都必须先更新该白名单**，断言失败时先问「为什么要 advice 第三方函数」而不是直接加白名单——白名单变更即侵入评审点。② `advice--p` 接受的是**函数对象**、不是符号（对符号直接调用恒返回 nil，会让集合恒空、断言恒真），实现须作用在 `(symbol-function SYM)` 上——这也让匿名 lambda advice 同样被覆盖。③ 两处已知边界：hook 内部的 lambda 若调用 seshat 函数查不到；keymap 断言只覆盖 `dired-mode-map`，未覆盖 `global-map` / `tabulated-list-mode-map`（均记 `openspec/tech-debt.md`）。

## 2026-10-26 · 服务端识别 `seshat:uid:<uid>`，与客户端 uid 形态对齐

**决策**：`registry.Service.Resolve` 增加 `uid:` 前缀识别（其后须为合法 26 位 Crockford Base32 `[0-9A-HJKMNP-TV-Z]`），并在不合法时回落 `tag:path`。裸 uid 形态继续支持。解析优先级固定为四段：① 空 key 报错 → ② 裸 uid（`IsUID`）→ ③ `uid:` 前缀 + 其后为合法 26 位 uid → ④ 其余按 `tag:path` / 默认根纯路径。

**理由**：客户端需要「显式前缀」以便与人类可读的 `tag:path` 共存（26 位 uid 与任意 tag 无法靠长度可靠区分，且根 tag 可以是任意不含 `:` 的字符串）。服务端若只认裸 uid，客户端产出的链接在 `refs` 图里会静默丢失，双向引用功能的服务端侧数据不完整——`RefreshRefs` 提取不到该形态，`GET /api/refs` 直接缺边，且失败没有任何报错信号（「解析不到即跳过」是既有契约），排查成本极高。两端对齐后，`seshat:uid:<uid>` 与 `seshat:<uid>` 指向同一 uid 的同一条边（去重键 `uid + location`）。

**代价与约束**：① 协议多一个前缀形态，服务端需识别两种 uid 形态（裸 uid + `uid:<uid>`），判别须大小写敏感（`[0-9A-HJKMNP-TV-Z]` 排除 `I`/`L`/`O`/`U`）；② `uid:` 之后不合法时**回落** `tag:path` 而不是报 `invalid_uid`——这是刻意选择：报错会让「根 tag 名为 `uid`」的既有配置直接失效，回落的代价仅是「`uid` + 26 位大写字母数字」这一极端组合被当成 uid；③ Android 端目前没有任何 `seshat:` 链接处理能力，不受影响；将来 Android 新增链接能力时按同一规则实现（产 `uid:` 前缀形态、解析两种 uid 形态）；④ 原计划的「服务端零改动」口径作废，服务端改动由计划的 T8 承载（`internal/registry/service.go` + 测试），协议与文档同步由 T9 承载。

## 2026-10-26 · 书库操作必须有「根归属」校验，下载必须有超时与大小上限

**决策**：`ondemand` 根的取书与删本地副本前，校验 uid 所属根在本地配置中的 mode 为 `ondemand`（`seshat-library--ondemand-root-p`）；非 ondemand 根一律 `user-error`。下载统一经 `seshat-rest-download-file` 的 `:timeout` / `:max-bytes`，按 `Content-Length` 写盘前预判。清单分页设 500 页上限。

**理由**：`seshat-sync--local-path` 只保证「不越出根目录」，不保证「这个 uid 该由这个根处理」——路径安全 ≠ 归属安全。书架的 `d`（删本地副本）与 `u`（刷新）在语义上都很"安全"，若清单来源不可信（被攻陷的服务端、或本地状态库因根重配而过期），它们就能删掉 / 覆盖 `mirror` 根下用户未提交的笔记。同理，`:follow` 一条链接会触发同步网络与磁盘写，若无超时与大小上限，一个不可信 org 文件就能让 Emacs 主线程无限阻塞或 OOM。

**代价与约束**：书架只服务 `ondemand` 根（`mirror` 根的笔记仍需用同步/编辑器处理，这是正确的分工）；`u` 在本地已有副本时会打断用户一次；`Content-Length` 不可解析时上限不生效（兜底仍靠服务端与自己人）——该残余风险记入 `openspec/tech-debt.md`。

## 2026-10-26 · 阅读器译文/解释面板正文宽度跟随窗口 + valign（部分取代 2026-10-18「沿用全局 fill-column」）

**决策**：① 正文宽度由新增 defcustom `seshat-reader-translate-visual-fill-column-ratio`（默认 `0.94`）决定，并**跟随面板窗口尺寸实时重算**——buffer-local `visual-fill-column-width` = 面板可用文本宽 × ratio，窗口变化时由 buffer-local `window-state-change-functions` 触发（本包 prepend 注册、vfcm 自身 append，保证「先写宽度、后算 margin」），并在 `--render-panel` 显示面板之后再刷新一次以收口首帧。② 新增 defcustom `seshat-reader-translate-valign`（默认 `t`），折行模式下用 `valign-mode` 对齐 Markdown 表格列（软依赖；非图形环境静默跳过）。③ 保留 `seshat-reader-translate-visual-fill-column-ratio` 为 `nil` 的**回退路径**（正文固定为全局 `fill-column`、不跟随窗口），作为对旧行为的逃生口。**本条部分取代 2026-10-18 决策中「宽度沿用全局 `visual-fill-column-width`（nil → `fill-column`）」一句**：那一句描述的宽度来源作废，其余部分继续有效——vfcm 的**总开关仍是** `seshat-reader-translate-visual-fill-column`、批注列表仍不启用、软依赖与降级口径不变。

**理由**：① `C-c w`（`seshat-reader-sidebar-toggle-width`）给用户的语义是「面板变宽」，而 vfcm 的默认语义是「按全局 `fill-column` 限宽」——两者直接对立：面板扩到 0.75 屏宽时正文仍是 80 列，用户看到的是「面板宽了、字还是窄的、右边一片空白」，属于可用性缺陷而非配置问题。② M11.14 引入「沿用全局宽度」的动机是**复用用户已有的 vfcm 配置、避免引入第二套宽度设置**，但那套动机的前提是「面板窄、正文本来就该限宽」；面板宽度可切换之后这个前提失效，第二套宽度设置已是必需。③ 可用宽必须与 vfcm **同源**：vfcm 内部按 `--window-max-text-width`（`remap` 单位 + margin 折算 + `text-scale`）判断，本包若用 `window-body-width` 起算会与它差 2–4 列，两套口径打架会让正文宽度在 resize 后抖动。④ prepend/append 是**零侵入的最小解**：不改 vfcm 任何代码、不动它的 hook 注册方式，只保证自己的回调先跑；且 `--vfcm-follow-window` 内部再调一次 vfcm 的**公开命令** `visual-fill-column-adjust` 作双保险，即使某天 vfcm 改了 hook 细节也能靠这次显式调用兜住。⑤ 表格对齐复用 `valign-mode` 而非自研：`markdown-mode` 的表格渲染本身不保证列宽，像素级对齐是一类独立且易错的问题（CJK 宽度、比例字体、行内标记），自研等于把一个成熟包的领域重做一遍。

**代价与约束**：① 两个软依赖开关都可能静默降级（vfcm / valign 未安装时不报错、不提示），用户看到的是「没效果」而非「缺依赖」——手册与 CHANGELOG 都已显式写明。② 宽度跟随只对**窗口承载 + 左右分栏**的面板有意义：childframe 承载不按窗口宽排版、底部模式是高度语义，这两条路径的可用宽不具代表性。③ 非图形环境下 `valign-mode` 在启用前就被 `display-graphic-p` 短路跳过，因此**图形效果只能靠 GUI 手工验收**（L3 六项待用户执行），ERT 只能断言「调用了/没调用」而不能断言对齐后的观感。④ 译文与解释**共用同一个面板 buffer**，valign 无法只对解释生效——这是共用 buffer 的结构性代价，不做 per-context 拆分。⑤ `valign-mode` 用 `:align-to` 绝对像素对齐，**面板里的宽表格会被右缘裁切**（不可见、不能折行也不能横滚），本轮不解决，只保证不加剧，记入 `openspec/tech-debt.md`「面板宽表格溢出被裁切（valign 绝对像素对齐）」。⑥ `seshat-reader-sidebar.el` **零依赖边界保持**、`C-c w` 的实现**零改动**：resize 事件经 `window-state-change-functions` 自然传导，不需要承载层参与，这条边界一旦打破就会把宽度知识与面板显示逻辑耦合在一起。⑦ 若将来 vfcm 升级改变 `append` 注册方式或 `--window-max-text-width` 的宽度口径，需同步修改本包的 prepend 顺序假设与同源计算——双保险路径（内部再调 `visual-fill-column-adjust`）就是为此留的缓冲。

## 2026-10-26 · PDF 多页连续布局（路线 3）与 P0 接口形态

**决策**：放弃「一个窗口一张位图、翻页即换图」的单页模型，改走**路线 3：多页 buffer 纵向连续布局**（用户 2026-10-26 确认）。定论逐条：

1. **多页 buffer 纵向布局**——同一 buffer 内纵向排列多页图像，滚动即跨页，不再有「翻页 = 换掉唯一那张位图」的动作。
2. **页号由视口顶页派生**——不再把「当前页」当作独立可变状态（既有实现是 window 参数 `page`），而由窗口起点落在哪一页推出当前页号，相关命令与页号语义都改读这个派生值。
3. **`set-window-start` 为主 + vscroll 微调**——整页跳转用 `set-window-start` 定位（行级、精确、不受图像高度取整影响），页内细滚继续用 `window-vscroll`；两者并存但职责分离，不再用 vscroll 表达「到第几页」。
4. **不双轨保留单页模式**——不做「单页 / 多页」两套并存：开关式双轨意味着渲染路径、页号语义、滚动落点、批注坐标全都要维护两套。单页视图若将来需要，只做「多页布局下视口恰好只装一页」的结果，而不是第二套实现。
5. **第一期禁止跨页选择**——框选取文 / 建批注仍只允许在单页矩形内完成；跨页选区涉及跨页坐标拼接与 `location` 分段语义，是独立议题，先禁掉比做一个半正确的跨页选区便宜。
6. **接受「同内容不同滚动位置」**——布局改变后同一文档在不同窗口可以停在不同滚动位置，这是多页布局的必然结果，不再要求「同一文档在多个窗口里必须同一页」（旧模型靠 window 参数同步，新模型不以之为真相来源）。

**P0 接口形态**：新增「**渲染任意页并返回 image spec** 的纯函数」（C 入口 `seshat-reader-dyn--page-image-spec`，arity `2..3`，页号 1-based；elisp 包装 `seshat-reader--page-spec` + 上限 8 的会话内缓存），而不是先重构 per-window 缓存模型。

**理由**：① 现有 **11 槽 per-window 缓存**（`render-core.h` 的 `PAGE_CACHE_SIZE`）以「窗口 + 当前 scale/rotate」为键，`resolution` / `rotate` 一变整窗失效，键里**没有页号维度**——无法表达「一个窗口同时持有 N 页」。② 同步渲染与异步预取的矛盾要先拆开：既有翻页路径是「排 10 个后台 job → `wait_for_cached_page` 同步等」，多页布局需要的是「按需同步取少量页 + 后台预取相邻页」，两者共用一套缓存必然互相踩。③「隐藏窗口预渲染」方案代价过高：每个窗口独占 11 张位图、每次翻页再排 10 个后台任务、要写 `selected-window` 的页号，还会被 `--manage-window-overlays` 反复重建——用窗口当缓存容器等于把 per-window 缓存模型再复制一份。④ 先做「纯查询接口」是**可独立验证、零行为变更**的最小一步：不碰 overlay / 窗口参数 / 页缓存，因此全部既有 ERT 无需改动，且它为 P1 的虚拟化提供定量基础（实测单页 0.7–11 ms、20 页 `VmRSS` +17.9 MB，见 P0 计划「实测数据」）。

**代价与约束**：① **同步阻塞**——入口在 Emacs 主线程渲染，耗时与一次 `wait_for_cached_page` 同量级，故 P0 不接入任何显示路径，P1 必须自己做视口虚拟化（只渲染可见页 + 少量预取）。② **双份内存**——spec 的 `:data` 是 PNM 的 Lisp 堆副本，C 侧 `CachedPage.img_data` 与 MuPDF image cache 各自另存，单页 72 dpi 1.42 MB / 150 dpi 6.16 MB；缓存上限因此固定 8 且不许调过 16；实测顺序访问超过 8 页时命中率跌到 0（先进先出淘汰），P1 的视口驻留页数必须 ≤ 上限或改淘汰策略。③ **hscroll 仍是窗口级**——宽页横向滚动会让整栏（含邻页）一起左右移动，多页布局下是观感缺陷，本期不解决。④ **`--refresh-highlights` 只重绘当前窗口 ±5 页**——多页布局下视口可能跨更多页，装饰刷新范围要重算。⑤ **多窗口「各看不同页」的能力将丢失**（决策 6 的直接代价）：同一文档在多个窗口的滚动位置互相独立，旧的 window 参数同步机制不再是真相来源。

## 2026-10-26 · 主动内容策略选「静态白名单内联」而非「枚举黑名单强制下载」

**决策**：`GET /api/files/{path...}` 的 `Content-Type` 判定从「枚举 14 项主动内容黑名单 → 命中则强制 `octet-stream` + `attachment`，其余按宿主 MIME 推断内联」改为「**17 项静态白名单（ext → 固定 `Content-Type`）→ 命中才内联，名单外一律 `octet-stream` + `attachment`**」（`internal/api/files.go` 的 `inlineContentTypes`）。表内**不查**宿主 MIME 数据库。白名单：`.txt` `.md` `.markdown` `.org` `.csv` `.json` `.pdf` `.epub` `.png` `.jpg` `.jpeg` `.gif` `.webp` `.bmp` `.ico` `.tif` `.tiff`。**WebDAV 出口不采用白名单**，改由 `Content-Security-Policy: sandbox` 缓解（`internal/webdav/security.go` 的 `SandboxContent`）。

**理由**：① **默认安全**——黑名单是「枚举坏东西」，Go 或厂商新增的 MIME 映射（`.shtml`/`.ehtml`/`.xht` 一类）一旦漏在名单外，服务端就会**显式声明**主动类型，而 `nosniff` 不阻止显式声明的类型被当作 HTML 执行，于是 `PUT` 一个 `evil.shtml` + `GET` 即可在服务端源下执行脚本（可读 `localStorage` 里的令牌）；白名单下「没列出来」自动等于「强制下载」，漏项不再是安全缝隙。② **不依赖宿主 MIME 数据库**——`mime.TypeByExtension` 会读 `/usr/share/mime/globs2` 或 `/etc/mime.types`，同一文件在不同机器/不同 MIME 库版本上得到不同 `Content-Type`（`.org` 就可能是 `text/org` / `text/plain` / `application/vnd.lotus-organizer`）；静态表使「哪些类型可内联」在任何机器上答案一致。③ **安全属性可判定**——表里只列「确定被动」的类型，评审时看表即可，不需要推理「还漏了哪些可执行扩展名」。

**代价**：**`.org` 的 `Content-Type` 从 `text/org; charset=utf-8` 变为 `text/plain; charset=utf-8`**（本机 `globs2` 此前给的是前者）。这是唯一的行为变更，其余 16 项取值与改造前一致；Emacs 与 Android 的下载/阅读路径都不依赖 `Content-Type`，故无客户端改动（见 CHANGELOG「变更」条）。

**WebDAV 出口为何不套白名单**：该出口的 `Content-Type` 由 `x/net/webdav` 按扩展名推断并**内联**返回，第三方客户端（Calibre、Obsidian、文件管理器挂载）按 `Content-Type` 处理文件——强制 `attachment` 会让这些客户端行为异常；而只对浏览器生效的白名单又不适用于「客户端自行解释类型」的协议出口。改用 `CSP: sandbox`：文档进入**不透明源**，脚本与同源 DOM 访问被禁（读不到 Web UI 的令牌），`Content-Type` 与字节内容都不变，客户端无感。**这不是白名单**——能内联的类型仍是任意扩展名，只是无法执行脚本，故残余风险与「装配点无集成断言」记入 `openspec/tech-debt.md`。

## 2026-10-26 · HSTS 不由服务端下发

**决策**：服务端**不设置** `Strict-Transport-Security`，也不提供「HSTS 开关」配置项；HSTS 一律由反向代理下发。`docs/deploy.md` §7 给出 nginx 与 Caddy 的配置行，§11 检查清单有对应核对项。

**理由**：TLS 在反向代理终止，服务端看到的永远是环回地址上的明文 HTTP——它**无法判断**真实 scheme（`X-Forwarded-Proto` 可被伪造，也没有可依赖的信任边界），因此任何「服务端自动下发 HSTS」的实现都只能是「按配置项无条件发」。加一个**永远默认关闭**的开关只增加配置面与文档面（多一个会被误配的旋钮、多一处「为什么我配了但没生效」的排查点），而不带来任何收益：反代已经在终止 TLS，它本来就知道 scheme。

**代价与约束**：① 部署者必须自己在反代加 HSTS 行，漏了就是一个「未被提醒的缺口」——因此 `docs/deploy.md` 的检查清单新增了显式核对项（`curl -sI` 应能看到该头），并在 nginx 示例里注明 `always` 的作用（`add_header` 默认只作用于 2xx/3xx，不加 `always` 则 401/4xx/5xx 不带该头）。② 服务端**其余基础安全头**（`nosniff` / `X-Frame-Options: DENY` / `Referrer-Policy: no-referrer`）与 HSTS 走相反路线——由 `internal/api/security.go` 的中间件对全部路由下发，因为这三条与 scheme 无关、服务端能正确判断；只有 CSP 仍归 Web UI（中间件不设，避免覆盖含 `script-src 'self'` 的那份）。

## 2026-10-26 · 路径规则抽取到 `internal/pathguard` 的等价性核验

**决策**：把「仓库内相对路径」的五份实现（`api.files.cleanRelPath`、`registry.service.normalizeResourcePath`、`webdav.policy.hasDotSegment`、`registry.bootstrap.isDotName`、`gitver.version.resolve/resolveAny`）收敛到新建 `internal/pathguard`（`CleanRel(rel, Options)` / `IsDotName` / `HasDotSegment`），五个入口改为**薄包装**（保留原函数名与签名）。`Options` 的**零值即最严格**（拒空、拒 `..` 段、拒点段），三个开关只能放宽。

**等价性核验（本次重构的唯一验收判据）**：抽取前后用 **12 个输入**逐条比对改动前后的**输出字节**——`a/../b`、`../x`、`a/b/..`、`.git/x`、`.hidden`、含 NUL、纯空白、`//a.org`、`/a.org`、`a/./b`、`a//b`、`./a`，五个入口的「接受/拒绝 + 规范化结果」**逐字节一致**，12/12 等价。`HasDotSegment` 改传 `AllowDotSegments: true` 后另跑 **13 个输入**，**0 差异**（其中 `A.GIT/x` 是**放行**项——`A.GIT` 少了前导点，既非 `.git` 的大小写变体也不以 `.` 开头；真正的变体是 `.GIT/x`，判拒绝）。

**结论**：本次是**零行为变化的重构**——对外错误码与中文文案一字未改（`docs/api.md` / `docs/errors.md` 的契约不动），既有测试零改动通过，**不需要用户迁移**。两处「折叠 `..` 而非拒绝」的特例改为**显式传参**（`HasDotSegment` 与 `gitver.resolve` 传 `AllowParentSegments: true`），不靠零值兜底：把「折叠」写成显式选项，才不会有人误以为收紧成拒绝是「顺手的改进」（那会是 WebDAV 出口与 gitver 的行为变更）。

**代价与约束**：① 「新增路径入口必须调 pathguard」成为不变量，但三处纯折叠（`gitver/merge.go:cleanTreePath`、`webdav/symlink.go:cleanRel`、`webdav/versioned.go:blobPath`）尚未收敛，记入 `openspec/tech-debt.md`；② `pathguard` **不做 TrimSpace**（api/registry 侧 TrimSpace、gitver 侧不 TrimSpace 的历史差异留在调用方），也不产出用户可见文案（错误以 5 个哨兵返回，由调用方按各自错误码包装）——这两条都是刻意的边界，写进包注释以免下次被「统一化」。

## 2026-10-27 · 阅读器暗色开关与配色升为进程级用户偏好（取代「dark-mode 是文档级」的隐含语义）

**决策**：暗色开关与 5 档配色预设不再存放在 `DocState`（文档级、随 `reset_doc_state()` 清零），改为 `render/render-theme.c` 的进程级 `static` 状态（4 个字段：`g_dark_enabled`（`bool`，初值 `false`）、`g_tint_set`（`bool`，初值 `false`）、`g_tint_bg` / `g_tint_fg`（`unsigned`，初值均 `0`）；由 `render-theme.h` 暴露 `theme_dark_enabled` / `theme_tint_set` / `theme_tint_bg` / `theme_tint_fg` 四个只读访问器给 `render-core.c`）。`seshat-reader-dyn--doc-invert` 的注册名与 arity（`1,1`）不变，语义改为「翻转进程级暗色开关」；新增 `seshat-reader-dyn--doc-tint`（arity `2,2`，`0xRRGGBB` 背景/文字，负值 = 清空 tint 回旧 invert+gamma 路径）。像素变换仍在 `render_page_to_buffer()` 一处（栅格化后、装饰 wash 前、PNM 编码前），按「tint 已设置 → `fz_tint_pixmap`；否则 → `fz_invert_pixmap_luminance` + `fz_gamma_pixmap 1/1.4`」二分支。`DocState.invert` 字段随之删除，「暗色是否开启」只有一个真相来源。

**理由**：① 配色是用户偏好，不是文档属性——同一台机器上看任何一本书都该是同一个观感；② 消灭已知不一致「重载 / 新开文档后回白底、而 elisp 侧 `seshat-reader-dark-mode` 仍为 t」（`reset_doc_state()` 只保留 `active_jobs` / `is_reloading`，`invert` 恒被清零），该不一致正是 thomas-emacs 配置里 `advice-add 'seshat-reader--render-buffer` 的唯一存在理由；③ 多页布局 P1 的 T4 即将重构 `--render-buffer` / `--redisplay-all-windows`，对外部 advice 的依赖越少，重构风险越低；④ 保留 `DocState.invert` 字段却无人读，会成为下一轮的误导源。

**代价与约束**：① 语义变更——上游或第三方若依赖「dark-mode 是文档级」，重载后会看到「仍是暗色」；② 进程级意味着同一 Emacs 内所有 reader buffer 共享同一配色，不能逐 buffer 设置（与「用户偏好」自洽，已写入 `docs/emacs-reader.md`）；③ 单独调用 `--doc-invert 1` 而不下发 `--doc-tint` 的代码会沿用上一次的 tint：**生产代码**该调用点只有 1 处（`seshat-reader-dark-mode` 的 body，`seshat-reader.el:2893`），总是紧随其后下发 tint（含 `graphite` 的 `-1 -1`）；**测试侧**另有 2 文件 3 处 `cl-letf` stub（`seshat-reading-test.el:182`、`seshat-reader-multipage-test.el:706` / `:715`），T3 后需同步补 `--doc-tint` 桩；④ `graphite` 必须与改动前逐位一致（同一 invert + gamma 序列），以 `--page-image-spec` 的 PNM `sha256` 相等为判据；⑤ 多页计划 T4 的「dark-mode invert 定为 C 侧 `--doc-invert`（文档级）」表述只加一行注记，其「重渲染全部可见页」的任务内容不变。

（来源计划：[openspec/active/2026-10-27-reader-dark-tint-presets.md](active/2026-10-27-reader-dark-tint-presets.md) 的 D2，用户 2026-10-27 拍板选 A。）

（实现位置/字段已按批次 1 实际代码校正，2026-10-27）

## 2026-10-27 · PDF 多页连续布局 P1 落地记录

**决策**：P1 按计划 T1–T10 全部落地，单页 overlay 模型退役（elisp 侧 `(window-parameter … 'overlay)` 读取点为 0）。

**落地要点（与计划的差异已逐条记录）**：
1. **D3 被真机推翻并修正**：原方案「滚动改原生行滚动」不成立——每页是 buffer 一个行、行高=整页位图高，`scroll-up`/`scroll-down` 按缓冲行滚动等于一次跨整页（用户实测 `j` 与 `n` 同效）。改为像素级 `window-vscroll` + `set-window-start` 的 `--multipage-scroll`。
2. **行滚动量取值**：`line-pixel-height` 在页行上返回整页高度（实测 2414px），导致一次按键跨整页；改为 `frame-char-height`（`--default-line-pixels`）。
3. **滚动步长可配置**：`seshat-reader-scroll-step-ratio`（默认 0.15，窗口文本区高度比例）与 `seshat-reader-scroll-step-pixels`（默认 nil，绝对像素优先）。
4. **居中手法**：逐页行内 `(space :align-to (+ center (-0.5 . SPEC)))` 引导空格，align-to 引用 spec 对象本身，原地改尺寸自动跟随；超宽页摘除引导空格贴左（D5b 已知缺陷：hscroll 仍是窗口级、整栏平移）。
5. **缩放**：`base-scale` 由「打开文档那一页」的 native 尺寸锚定（`--multipage-reference-native` 缓存，reload/rotate 清空）；`+`/`-` = base × 系数、`W`/`H` = 基准页 width/height-fit、`0` = 重新首屏适配；refit 闸门用 0.005 容差（native 取整漂移）。
6. **缓存与虚拟化**：上限 = 视口驻留 + 1（K=2 → 6，夹 4..16）、视口外优先淘汰、回收保留相邻一页、方向感知预取只暖缓存不插行；内存告警线 `seshat-reader-multipage-memory-warning-mb` 默认 75 MB。
7. **书签字段变更**：`vscroll` → `offset`（页内像素偏移），新增 `fit-mode`；旧记录按 `vscroll` 近似迁移。
8. **装饰刷新**：C 侧 `--refresh-highlights`（依赖 overlay/win-state）在 elisp 侧退役，改为「清 spec 缓存 + 重渲染全部驻留页」。
9. **测试基建**：`make -C emacs/tests ert` 固化判据（`0 unexpected` 且无 `skipped`）；`page-join-test.el` 随 strip 机制整体删除。
10. **保留的已知缺陷**：跨页选区首期 `user-error`（D7）；横向滚动整栏平移；P1 不做异步预取。

（来源计划：[openspec/completed/2026-10-26-reader-multipage-p1-layout.md](completed/2026-10-26-reader-multipage-p1-layout.md)；实现与逐批偏差见该计划「## 执行记录」）

## 2026-10-27 · 阅读器跨页落点采用「两帧序列」，末页偏移上限受窗口高约束

**决策**：① 跨页时按「清旧页偏移（`set-window-vscroll win 0 t`）→ `set-window-start` → `seshat-reader--multipage-sync` → 强制 `(redisplay t)` 落一帧 → 写像素偏移 → 落 `point`」的两帧序列执行；② 跨页后 `point` 落到**邻居页行首**（顶页行首已被偏移切出视口，落在那里会让偏移被丢弃）；③ 末页的页内偏移上限取 `页高 − 窗口文本区像素高`，中间页仍为 `span − 1`。

**理由**：真机四条探针确证 Emacs 会丢弃「与**新设 `window-start` 同一帧**设置」的像素偏移——同帧设置时 3090 经一次 redisplay 变 0；先让新 start 落一帧、再设同一数值则保留 3090（窗高仅 1345，说明与窗口高度无关）。末页没有下一页填满视口，其上限必须受窗口文本区高约束，否则整页被推出视口、露出空白「假页」。跨页落点之所以取「邻居页行首」而不是 `forward-line` 的下一行：`seshat-reader-page-gap-lines > 0` 时下一行是顶页自己的空行，屏幕 y 可能为负。

**代价与约束**：① 跨页多一次强制 redisplay（约一帧开销），并存在一帧「新页 + 偏移 0」的中间态；实测未观察到用户可感的中间帧跳动，正常翻页速度下不可见。② 该序列反直觉，理由必须固化在代码注释与本日志中——**任何「省掉这次 redisplay」的优化都会让 `k` 回到跳页首的旧缺陷**，改动前先跑真机探针。③ ERT 只能守住命令内的顺序与数值（`window-start` / `set-window-vscroll` / `redisplay` 均被桩替），跨 redisplay 的行为只能真机验证（见 `openspec/tech-debt.md`）。④ `pagecount` 未就绪期间末页上限退化为非末页公式（瞬态，已在 tech-debt 登记）。

（来源计划：[openspec/completed/2026-10-27-reader-cross-page-scroll-fix.md](completed/2026-10-27-reader-cross-page-scroll-fix.md)；该计划的「真机诊断记录」保存四条探针的原始读数与 L3 迭代 1/2 的两次修正过程）

**推广（批次 A，2026-10-27）**：同一约束同样适用于**书签 / saveplace 的恢复路径**——`seshat-reader-bookmark-jump` 第 ③ 步原先在 `seshat-reader--multipage-goto`（内部 `set-window-start`）之后**同一帧**写 `set-window-vscroll`，故记录里 `offset > 0` 时必然只回到页首（saveplace 经 `seshat-reader--saveplace-find-file` 复用同一 handler，一并受影响）。现两条渠道统一走新增的 `seshat-reader--multipage--apply-offset`：先 `(redisplay t)` 落帧、再 `set-window-vscroll`；`WINDOW` 传 `nil` 表示 selected window（内部按 `(if (window-live-p window) window (selected-window))` 解析，与 `--multipage-scroll` / `--multipage-sync` 同口径，**不对入参直接判活**）；解析后的窗口非 live 或 `OFFSET` 非正数时既不写偏移也不落帧。**约束不变**：跨页路径（`--multipage-scroll`）与恢复路径（`--multipage--apply-offset`）是同一约束的两种形态，**任何「省掉这次落帧」的优化都会让各自的行为退回「跳页首」**；ERT 只能钉住事件顺序（`redisplay` 早于 `set-window-vscroll`）与实参，偏移能否跨 redisplay 存活仍只能真机验证（见 `openspec/tech-debt.md` 该条与 `openspec/active/2026-10-27-reader-bookmark-offset-restore.md`）。

## 2026-10-27 · 书签恢复的 fit-mode 只在「新开文档」时应用

**决策**：`seshat-reader-bookmark-jump` 的第 ① 步（`fit-mode` / `scale`）只在**跳转前不是阅读 buffer**时执行——新开文档（saveplace 重开、从书签打开未读文档）按记录的 `fit-mode` + `scale` 恢复；在**同一阅读 buffer 内**跳书签时整段跳过，保留用户此刻的 `W` / `H` / manual 与缩放，只恢复页号（②）、页内像素偏移（③）与横向位置（④）。判定点在 `(bookmark-default-handler bookmark)` **之前**取 `(derived-mode-p 'seshat-reader-mode)` 存入局部变量——handler 会切 buffer，切完就再也看不出「跳转前」是哪个 buffer。

**理由（用户偏好，2026-10-27 用户确认）**：跳转不应改动用户正在使用的视图。书签里的缩放是**保存那一刻**的选择，与当前窗口尺寸无关；把它套回当前窗口等于每次跳书签都强制改一次缩放，用户刚按 `H` 调好的适配会被几天前的记录推翻。新开文档没有「当前视图」可继承，记录值才是不二选择（否则打开后停在与记录无关的默认适配）。

**代价与边界**：① 判据是「跳转前 buffer 的 major mode」，故在文档 A 的阅读 buffer 里跳到**文档 B 的书签**（未打开）也会跳过 ①——与「新开文档」的字面语义有偏差，属本决策**已知边界**；若要精确区分，判据应改为「跳转前后是否同一 buffer」（本轮按用户确认的语义实现，不扩大范围）。② 记录格式不变，`fit-mode` / `scale` 仍照旧写入，只是同一 buffer 内跳转不消费它。③ ERT 只能断言「① 步是否出手」与位置实参，观感仍由真机确认；变异自检（恒应用 / 恒不应用）各自能打红对应用例。

（用户来源：2026-10-27 会话确认「书签跳回后，缩放模式（W/H/manual）跟**当前视图**走，不被书签记录覆盖」。）

## 2026-10-27 · 阅读器 fit / render 的窗口解析永不使用 minibuffer 窗口

**决策**：① 页面几何的窗口解析收敛到单一函数 `seshat-reader--multipage--display-window`——候选顺序「显式入参 → `get-buffer-window` → `selected-window`」，每个候选必须同时满足「活窗口 + 不是 minibuffer 窗口（`window-minibuffer-p`）+ 显示当前 buffer」，都不满足时返回 `nil`，由调用方按「几何未知」处理（`--multipage-target-scale` 先返回基准 scale、`--multipage-fit-scale` 返回 nil、`--multipage-current-fit-mode` 只报 buffer-local 值）。**minibuffer 窗口永不作为返回值。** ② `--multipage-render-page` 增可选 `WINDOW` 参数并向下传给 `--multipage-target-scale` / `--multipage-resize-spec`，`--multipage-rerender-page` 与 `--redisplay-all-windows` 显式补传。③ 新增 `seshat-reader-freeze-layout-during-minibuffer`（默认 `t`）作为**纯 UX** 的版面冻结开关：`--refit-window` / `--schedule-refit` 在 minibuffer 激活期间直接返回，`--recenter-window` 跳过 `--apply-display-scale`（它内部会改 spec 尺寸）只保留居中，`--multipage-sync` 不冻结。

**理由**：① minibuffer 激活时 `(selected-window)` **就是** mini window（结构事实），旧写法 `(if (window-live-p window) window (selected-window))` 在三处 fit 计算里等于「按提示符窗口排版」。② 实测证据（主实例探针，722 条事件）：mini window `window-body-height` = **102 px**（4 行字符高）→ `height` fit = `102 / 792 = 0.1288` → 被 `--multipage-clamp-scale` 的 0.25 下限提到 **0.25** → `--multipage-resize-spec` 把 612×792 的 spec 改写成 **153×198**；`resize-spec` 翻转序列 `985 → 153`（8 条一组）、`153 → 153`、`153 → 985`（8 条）与「退出后要等一次尺寸变化事件才恢复」的现象一致。③ `--multipage-rerender-page` 原先调 `--multipage-render-page page t` 时**丢弃了 window**，内部只能回落 `selected-window`——故「调用方已显式传参」并不成立，一致性要求必须落到签名上。④ exit-hook 时序实测（Emacs 31.1，verify 隔离实例）：`minibuffer-exit-hook` 执行时 `(minibuffer-depth)` 仍为 **1**、`(selected-window)` 仍是 mini window、`(minibuffer-selected-window)` **非 nil**（与「hook 跑在深度归零之后」的直觉相反），故恢复走「`minibuffer-selected-window` 优先 + `selected-window` 兜底」取 buffer，并用 one-shot idle timer（`run-with-idle-timer 0 #'--run-pending-refit`）而**不是** `--schedule-refit`——后者的冻结判据（`window-minibuffer-p` 作用于 selected window）在 hook 内此刻仍为真，会把自己挡掉；`emacs --batch` 不触发该 hook（走 `read_minibuf_noninteractive`），相关实测必须用交互式实例。⑤ 冻结只关掉「提示符展开 → 页面缩成一条 → 退出再放大」的闪烁，不承担正确性（不冻结时 `--window-size-change` 分支传给 refit 的本来就是 reader 窗口），故做成可关闭的 defcustom 而非硬编码。

**影响面**：① 所有 fit / 渲染路径（首次 fit、尺寸变化 refit、`W` / `H`、`+` / `-`、书签恢复、演示模式）的窗口来源统一；正常路径（显式传窗口且显示当前 buffer）结果逐字不变。② **行为改进（A1b）**：不传窗口且 `selected-window` 不显示当前 buffer 时，解析结果由 `selected-window` 变为 `get-buffer-window` 命中的窗口——方向正确但属行为改变，已写入 `CHANGELOG.md`。③ minibuffer 期间默认冻结几何，代价是页面底部约 416 px 被裁切（minibuffer 展开 17 行 ≈ 400 px / 1275 px 阅读窗口），退出后由 `--after-minibuffer-exit` 自动 refit；设 `seshat-reader-freeze-layout-during-minibuffer` 为 nil 即恢复「跟随缩放」。④ 仍有 `--multipage-base-fit-scale` / `--apply-display-scale` / `--multipage-resize-spec` / `--multipage-refresh-decorations` 等旧写法未改（靠 `--multipage-target-scale` 内部解析兜底），已登记为 `openspec/tech-debt.md` 观察项。⑤ 回退单点：三处 fit 调用改回旧写法（新函数保留不调用）即回退 D1，把 defcustom 设为 nil 即回退 D2。

（来源计划：[openspec/active/2026-10-27-reader-fit-minibuffer-window.md](active/2026-10-27-reader-fit-minibuffer-window.md) 的 D1 / D2 与「## 事实来源」「## 审查修订记录」；探针原始读数见该计划）

## 2026-10-27 · 阅读器页间分隔采用「三段结构」+ face `:height` 压缩 + 拉满窗口的线

**决策**（4 点）：

| # | 决策 | 理由 |
|---|---|---|
| 1 | 页间视觉分隔采用**三段结构**——上空行 / 线 / 下空行，共 3 个 buffer 行，而非整行色带或页面边框 | 三段都能用 face `:height` 精确表达亚行高度，且「线多粗」（`-separator-thickness`）与「隔多远」（`-separator-height`）可独立调参；整行色带只能给出默认行高的整数倍，页面边框则要额外处理每页四边，并与居中用的 `before-string` + `:align-to`、横向滚动的 `line-prefix` 机制纠缠 |
| 2 | 行高压缩用 face `:height` 的相对倍率（`目标像素 / frame-char-height`），**否决 `line-height` 文本属性** | T0 实测 `line-height` **只能加高、不能压矮**（0.25 / 1 / 8 全部渲染为 24px，下限 = 默认行高；1.5 → 30px、2 → 40px），face `:height` 是唯一能把行压到亚行高度的路径（下限约 2px）。由此**1px 线不可达**，`seshat-reader-page-separator-thickness` 的默认值由 1 改为 **2** |
| 3 | 线宽用 `(space :align-to (- right 0))` 的 stretch space，而非按 `window-body-width` 算固定像素宽度、也不用填充 U+2500 字符 | 实测该行宽度**精确等于** `window-body-width`（713 == 713，多种 frame 宽度下均相等），随窗口自适应，无需监听 `window-size-change-functions` 重建，也不需要重写整行字符；填充字符方案在窗口缩放时必须重算行内容，改动面最大 |
| 4 | **几何单一来源**：`seshat-reader--multipage-separator-segments` 返回 `(TOP LINE BOTTOM)` 像素三元组，同时供像素高度（滚动几何：`--multipage-page-span` / `--multipage-page-max-offset` / 跨页滚动）与行构造（三行行高）使用，**禁止两处独立计算** | P1 已在 `--multipage-page-max-offset` 的注释里记录过同类缺陷——两处口径分叉会在页底产生滚动死区、在末页凭空多出「假空白」。分隔区参与的是同一个 span，分叉即复发。**代价（明确接受）**：face `:height` 是阶梯取整，实际渲染与名义像素差 ±1–2px（实测名义 12px 渲染 13px），滚动几何一律使用**名义值**，不追求逐像素对齐，ERT 也不得对 ±1px 做严格断言 |

**默认值变更属可见行为变更**：升级后默认页间出现 0.5 行分隔区（内含一条 2px、横贯窗口的线），与改造前「两页紧贴」的观感不同。**回退路径**：`(setq seshat-reader-page-separator nil)` 且 `seshat-reader-page-gap-lines` 保持 `0` → 不产生任何附加像素，行为与改造前一致。

**约束**：① 分隔区选项在**页行插入时**读取，改动后需重开文档或触发一次重排（`seshat-reader--multipage-relayout`），本轮**不做** defcustom `:set` 自动重排——避免「改一个选项就整本重排」的隐式副作用，另立任务再议；② ERT 只断言文本结构与属性（行数、`display`、`face`），`emacs --batch` 无 redisplay，像素正确性由 GUI 探针与真机目视承担。

（来源计划：[openspec/completed/2026-10-27-reader-page-separator.md](completed/2026-10-27-reader-page-separator.md) 的 D1–D4 与「T0 实测结论」小节；`line-height` 阶梯、face `:height` 下限、`(space :align-to)` 行宽的原始读数见该计划的实测表格。）

## 2026-10-27 · 跨页选区的 location 形态与引用链接降级

**决策**（4 点）：

| # | 决策 | 理由 |
|---|---|---|
| 1 | 跨页锚用**新前缀** `pages:<a>-<b>;rect@<page>:x0,y0,x1,y1;…`，单页锚（含同页多矩形）**继续写旧形态** `page:<n>;rect:…` 且逐字节不变 | 旧前缀 `page:` 的语义是「这条批注属于第 n 页」——一个页锚。跨页选区没有唯一的页可归，另立前缀才能让「读不懂新形态」的旧解析器可靠地**认出自己读不懂**（见决策 2）。`<a>`/`<b>` 取**实际有矩形**的页号最小/最大值而非「起点页 + 页数」：首尾页整页落在框外时跨度会自动收窄，避免写出 `pages:3-5` 却只有第 3、5 两页有几何的误导性串。单页路径不动是硬要求——存量批注数以千计，任何「顺手统一格式」都会让旧客户端把老数据读成 nil |
| 2 | **否决**「同串多 `page:` 段」（如 `page:1;rect:…;page:2;rect:…`） | 旧解析器会把它读成**画错**而不是降级：`--page-from-location` 取串内**第一个** `page:<n>`（正则未加锚点）、`--rects-from-location` 只按 `;` 切段且只认 `rect:` 前缀、**与页号无关**——于是第二页的 `rect:` 段会被全部收集到第一页，高亮叠在第 1 页的错误位置，且没有任何报错线索。新前缀的好处正在于「旧解析器取不到页号 → 整条跳过」（装饰路径 `when page` 分支不进入），代价是旧客户端不画，收益是它不会画错。**这是一条不变量：任何新 location 形态对旧读取方必须是「跳过」而非「误读」。** |
| 3 | 选区 plist 的 `:rects` **保持 4 元组**语义不变，跨页信息放新字段 `:page-rects`（`(PAGE X0 Y0 X1 Y1)` 列表），而非把 `:rects` 元素扩成 5 元组 | `:rects` 的唯一生产读取点（`seshat-reader-annotation--selection-rects`）把元素直接交给 `--anchor-segments`，而后者按 `(nth 0..3 rect)` 判合法——5 元组会被当成 4 元组解析（PAGE 当 x0、Y1 被丢弃），是**确定性数据损坏**。改元素形态就必须同批改造解析端，回归面覆盖 `translate` / `reference` / 装饰 / 测试桩十几处读取方；新增字段可让**旧消费者零改动**，单页时 `(mapcar #'cdr :page-rects)` 与 `:rects` 逐值相等（有 ERT 断言），跨页时 `:rect` / `:rects` 仍是起点页几何（供只支持单 bbox 的消费方使用）。 |
| 4 | `seshat:` 引用链接在跨页时**降级为纯页锚** `page:<起点页>`（不带 `rect:`、不带 `pages:`）并 `message` 提示 | 引用链接的职责是「可复现落点」，不承载选区几何（`seshat-reader-reference.el` 的既有哲学：链接串短更利于阅读）。写 `pages:` 形态的收益为零（读端 `--goto-location` 只取页号），却会让旧客户端的链接**无法跟随**（页号取不到 → 落点丢失）。降级为纯页锚则在任何版本都能跳、且跳到的正是用户开始拖选的那页。两处写端（`--current-location` 与 org `:store`）**共用**同一判定函数 `--selection-cross-page-p`（`:page-rects` 去重页号 > 1），不做两份判定以防漂移；单页路径逐字节不变、读端零改动 |

**上限与降级的取舍**：写入端上限仍是 500 段（`--anchor-max-segments`），但跨页形态按「**页数 + 段数**」计数——每段要多带 `rect@<page>:` 前缀，串长由两者共同决定，只数段数会低估。超限时**降级为只保留首页矩形**（单页形态）并 `display-warning`（不是 `message`：降级是确定性数据丢失，需要留在 `*Warnings*` 里可追），批注正文同时截断到首页，避免「正文含第二页、高亮只在第一页」的不一致。选择「降级」而不是「截断到前 N 段」：截断会在页中间突然失去高亮且用户无法判断哪页被丢，降级则给出「这是一次跨页选区、已被压缩到首页」的完整叙事。

**兼容与零改动边界**：服务端不解析 `location`（只校验非空），**零改动**；Android `LocationCodec.parsePage` 在 `segments.size > 2` 时返回 `Parsed.Unknown`（多段 `rect:` 今日同样落这里），表现为**无高亮但不崩溃**，已记入 `openspec/tech-debt.md`；**C 侧零改动**（`render/*.c` / `*.h` 一行未动，`VENDORED.md` 未变）——跨页取文只是逐页调用既有的单页 0-based 接口后在 elisp 侧拼接。

**残余限制**（同记 tech-debt）：跨页 explain / 翻译的上下文只覆盖起点页（`:rect` 是起点页 bbox 的必然结果，翻译对象本身仍是全文）；跨页选区确认时的高亮闪现只落在起点页（`--flash-selection` 仍只吃 `:rects`）；Android 不渲染 `pages:`。

（来源计划：[openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md](completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md) 的 D1–D7、D5b 与「事实基线」F7/F8/F11；变异自检（把 `--page-from-location` 改成也认 `pages:`）记录见该计划「批次 3」小节）

## 2026-10-28 · canvas 图像对象可行性（Emacs 32 S0 spike 结论）

**决策**：canvas 可作为 seshat-reader 渲染后端的替代载体；实现分两步走——先「传输层替换」（PBM/PNM → ARGB32 直写 canvas 缓冲），再评估「底图 + 装饰合成」。三项未验证项已于同日补齐（见下方「补充验证」），实现阶段可启动。

**理由（全部为 2026-10-28 真机实测，Emacs 32.0.50 pgtk/WSLg，独立 `emacs -Q` 进程）**：
1. canvas spec 参与 `(space :align-to (+ center (-0.5 . SPEC)))` 居中计算，与 pbm spec 归一等价：pbm `offset 160` vs `(body-px 720 − 400)/2 = 160`、canvas `offset 156` vs `(713 − 400)/2 = 156.5`，差 4px 完全由两次测量间窗口宽差 7px 解释。
2. **`:width` / `:height` 对 canvas 有效**（手册 `Canvas Images` 节点未列该二属性）：`setf :width 200 :height 150` → `image-size` = `(200 . 150)`，且居中按缩放后宽度重算（`offset 256 ≈ (713−200)/2`）。因此 2026-10-23「显示层缩放替代同步重渲染以消除两帧」的决策在 canvas 后端**继续成立**，传输层替换无缩放退化风险。
3. 跨线程写法安全：主线程取 `canvas_data` 指针 → pthread 写满 400×300 缓冲 → join → 主线程 `canvas-refresh`，100 次读回 100/100 一致、中位 89µs（80–211µs）、无崩溃无 NULL。主线程阻塞在 C 调用内时不跑 Lisp，故 GC 不会回收缓冲。
4. 改 `:data-width` / `:data-height` 会重建像素缓冲并**使旧指针失效**（400×300→800×600 后指针 `98410851808144` → `98410854208224`，+2.4 MB）。**硬约束**：`canvas_data` 每次调用必须重新获取，禁止跨调用缓存。
5. `canvas-refresh` 签名仅 `(image &optional reload-data)`，**无局部区域刷新**（传区域参数报 `wrong-number-of-arguments`）→ 刷新粒度 = 整张 canvas，故「按页切分 canvas」是唯一的增量刷新手段。

**补充验证（2026-10-28，同环境真机，截屏 + 整块像素统计 + 逐字节比对）**：
1. **缩放像素质量**：canvas 与 pbm 的 `:width`/`:height` 缩放**逐字节相同**（`compare -metric AE = 0`）——两者走 Emacs 同一 image transform 路径，**无退化**。默认（`transform-smoothing=nil`）放大 2x 与缩小 0.5x 均为最近邻（整块仅 2 色，格子周期 16px / 4px 硬边）；显式 `:transform-smoothing t` 则平滑生效（放大 6–10 色、缩小 18 色）。**缩小不是裁剪**（0.5x 后四角色块红/绿/蓝/黄齐全）。
2. **ARGB 通道序与 alpha**：通道序正确（`0xFFFF0000` 整块读数 `255,0,0`、`0xFF00FF00`→`0,255,0`、`0xFF0000FF`→`0,0,255`）；alpha 正常与背景混合（50% 红叠白底 = `#FF7F7F`，即 255/127/127）；`0x00000000` 区域露出背景（唯一色数 1，等同背景色）。
3. **异步渲染 + GC**：worker 延迟 300ms 写缓冲期间，主线程执行 4×`garbage-collect` + 2 万次 cons 制造垃圾 + 2×`redisplay`（实测施压窗口 421ms / 561ms，覆盖写入时刻），两轮 `join-check` 读回均精确等于写入值 `0xFFAABBCC`，`canvas-refresh` 无错 → **Lisp 侧持 spec 强引用期间，GC 与 redisplay 都不会让缓冲失效**，P2-1 异步渲染路径可用。
4. **新增实现期硬约束**：`setf :data-width`/`:data-height` 重建缓冲后内容清零（实测重建后首像素读回 `0`）→ **改尺寸后必须重画整页像素，不能假设内容保留**。

**方法论提示**：以上像素结论均来自「整块统计 + 以已知参照（8px 棋盘 → 周期 run）反推样本身份 + 逐字节模板匹配确认落点」；用固定尺寸采样窗（如 60×60）判定缩放行为会因系统偏移（实测 dx=−26, dy=−23）采到相邻变体而得出错误结论（本 spike 首轮即因此误判一次，已在复核中纠正）。

**代价与边界**：canvas 是 Emacs 32 的编译期特性（batch 下 `image-type-available-p 'canvas` 亦为 t，但 `image-size` 需真实 GUI frame）。若需继续支持 Emacs 31 及以下，必须保留 pbm 后端形成双路径；该取舍待实现计划阶段由用户决定。现有 `seshat-render-core.so` 由旧版 Emacs 头部编译，其与 32 的 ABI 兼容性未验证，属实现阶段的独立门禁。

**证据**：`openspec/completed/2026-10-28-reader-canvas-s0-spike.md`（含 `result2.sexp` 原始数据与判据修正说明）。

## 2026-10-28 · canvas 迁移落地记录（PBM/PNM → canvas，Emacs 32 单后端）

**决策回顾**：上文「canvas 图像对象可行性（Emacs 32 S0 spike 结论）」判「可分两步走，先换传输层」。本条目记录实现阶段**实际怎么落地的**、与原计划的差异，以及实测得到的边界——不再重复 spike 的方法论。

**实际做法（与计划的逐条对照）**：

1. **像素路线比计划更简**：计划 v2 写的是「先 `fz_clear_pixmap_with_value(pix, 0)` 铺不透明底（alpha=255）→ 渲染 → 逐行扩展」。实现直接采用 **`fz_new_pixmap_from_display_list(…, fz_device_bgr(ctx), 0)`**——第五参 `alpha=0` 即**不分配 A 通道**（3 分量 BGR），MuPDF 把页面直接合成到不透明背景（初始像素 0 = 黑）；`fz_device_bgr` 的通道序（B,G,R）与 canvas 的 `0xAARRGGBB`（小端 B,G,R,A）天然吻合，**零重排**。计划里那一步「单独 clear 铺底」因此**整条不需要**：起点本就不透明 ⇒ 预乘渲染与直通值等价 ⇒ 无反预乘问题。计划中「用 `fz_new_pixmap_with_data` 直接绑 canvas 缓冲做零拷贝」被否（`fz_drop_pixmap` 对外部缓冲的所有权未明）。
2. **canvas spec 构造**：`create-image nil 'canvas t` + `:data-width` / `:data-height`（设备像素）/ `:width` / `:height`（逻辑像素），**省略 `:id`**、**`:data` 留 nil**——Lisp 侧零常驻。建后做「`imagep` 非 nil + `canvas_data` 非 NULL」双自检，任一失败返回 nil 并打 stderr（不静默产出假 spec）。填充完像素后 `canvas-refresh`（第二参 nil）。
3. **尺寸双轨制写成硬约束**：`:data-width` / `:data-height` **只允许渲染函数写一次**（改它会重建缓冲并清零）；`:width` / `:height` 才能随时 `setf`（显示层缩放）。这条不只写在文档里，也写进了 `seshat-reader.el` 的注释与 C 侧注释，作为 review 检查点。
4. **退役按「elisp 生产调用点为空」判据执行**：11 个 C 入口（10 个无引用 + `--window-close`）、worker 线程池（`render/render-threads.c` / `.h` 整文件删除）、`CachedPage`、`EmacsWinState`、overlay 机制、`image-flush` 调用全部删除；`--load-doc` 只建 `DocState`；渲染完成标志 `set_current_render_status` 从 `--load-doc` 移到 `--page-image-spec` 的成功路径（先建 spec 后置位的时序），保留 14 个入口。`render/` 净删 **1714** 行（全仓 21 文件 **+786/−2423**）。

**与计划的差异（执行期调整，均已回写计划「验证记录」）**：

| 计划 | 实际 | 原因 |
|---|---|---|
| T2 / T3 / T4 / T5 四个独立批次 | 合并为**一个原子批次**（T2+T3，随后 T4+T5 同批） | 输出契约一变（PNM→BGRA），中间态无法既过编译又过 ERT；分批判定没有可用的绿点 |
| T6（elisp 侧）与 T7（C 侧）分两批、各自回滚 | **合并为一批** | 两边的删改互为编译前提（elisp 侧删了调用点，C 侧才能删入口；反过来 C 侧删了入口，旧 elisp 会 void-function），拆开只会造出「两边都不绿」的中间态 |
| 像素起点用 alpha=1 + 显式 clear 通道 | `fz_device_bgr` + `alpha=0`（3 分量 pixmap，不分配 A 通道，**没有** clear 调用） | 更少的调用与更少的通道搬运，语义等价（详见上节第 1 条） |
| 「性能优化可留到后续」 | 补做 **T2b**（`CFLAGS` 加 `-O2`）与 **T2c**（`fz_try` 跨块变量 `volatile`） | `-O0` 下 1.57/3.90/1.57 ms 的性能数据不具代表性；`-O2` 又暴露 `-Wclobbered` 背后的真实隐患，必须加 `volatile` 而不是压告警 |

**实测结果**：

- **逐字节等价**：三组 `(scale, rotate)` = `(1.0, 0)` 612×792、`(1.5, 0)` 918×1188、`(1.0, 90)` 792×612，与旧 PNM 基线比较**差异 0**（剥 PNM 头、取 B,G,R 重排，并断言 A 全 255）。canvas 与 pbm 的 `:width` / `:height` 缩放亦**逐字节相同**（Emacs 同一条 image transform 路径）。
- **内存**：每页 612×792 从旧 ≈3.4 MB（Lisp 字符串副本 + C 侧副本）降到 ≈1.9 MB（**−43%**）；Lisp 侧 `:data` 为 nil，常驻只剩 Emacs 的 canvas 缓冲。
- **性能（取舍已明示）**：单页 `--page-image-spec` 中位 **0.589 → 1.22 ms**（1.0）、**1.732 → 2.77 ms**（1.5）、**0.742 → 1.16 ms**（r90），即 **+0.6~1.0 ms/页**。**不做结构重构**：三种写法（`memset`+3 字节写、64 位块写、`-O3`）实测均无收益，瓶颈是「3 分量 pixmap → BGRA 中间缓冲 → memcpy 进 canvas 缓冲」的往返；要回补只能让渲染端直出 4 分量，属大改。
- **观感**：`transform-smoothing` 默认未开（nil）→ 放大/缩小均最近邻（硬边，缩小不裁剪）；显式 `t` → 平滑（放大 6–10 色、缩小 18 色）。
- **验证基线**：L1 C **0 error 0 warning**、elisp warning **20**（基线，零新增，全量 `make -B` 口径）、checkdoc 0；L2 **37 文件 / 1327 例 / 0 unexpected / 0 skipped** + `check-criteria` PASS。

**遗留（详见 `openspec/tech-debt.md`）**：P2-5「内存与驻留策略」降级为**部分缓解**（Lisp 字符串副本与 `CachedPage.img_data` 已消除；Emacs canvas 缓冲、渲染期 MuPDF pixmap + BGRA 中间缓冲仍在）；新增四项——`--page-text` 0 参路径引入 C→elisp 反向依赖、`.so` 未用 `-fvisibility=hidden`（仍导出 60+ 内部符号）、`transform-smoothing` 默认未开、单页渲染比旧版慢 0.6~1.0 ms。真机 L3 七项验收未做（见计划「验证标准」）。

**来源**：`openspec/completed/2026-10-28-reader-canvas-backend-migration.md`（T0–T8 执行记录）+ `openspec/completed/2026-10-28-reader-canvas-s0-spike.md`（可行性实测）。

## 2026-10-29 · 书架清单主源从远端切到本地状态库（离线优先）

**决策**：Emacs 书架的清单主源由远端 REST 清单改为**本地状态库**（`seshat-state-entries`，读 `:uids` 索引，零网络）；远端清单降级为**可选增强**并落盘缓存 `~/.local/share/seshat/library-cache.eld`（仅显式 `g` 刷新时原子写）。本地事实（是否已下载）由 `file-exists-p` + `file-attributes` 判定。合并策略：以状态库为准，缓存项仅在 uid 不在状态库时以「未登记」状态出现。远端刷新失败静默进日志，书架永不因网络失败而空表；状态库与缓存都为空（从未同步过）时书架**显式提示** `M-x seshat-sync-now`，不显示空表假装书库是空的。

**理由**：① 「断网即空表」是数据源选错——本地状态库本就持有 uid 全集，「有哪些书」不该依赖网络；② 远端清单的剩余价值（服务端全集里本地未登记的项、远端 size）正是「增强」的定义，可缓存、可缺失、失败不影响主功能；③ 若把缓存当主源，书架内容会随网络状态与缓存新旧漂移，而状态库是**权威的本地事实**。

**代价**：① 首次使用前必须先成功同步过一次（否则书架只有提示）；② 状态库损坏时书架与启动汇总都必须降级为「提示 + 空表」，需显式区分「损坏」与「从未同步」两种空态；③ 远端全集信息（本地未登记项）在未刷新前不可见。**回退**：删 `library-cache.eld` 即回到「只用状态库」。

（来源计划：[openspec/completed/2026-10-29-emacs-offline-library.md](completed/2026-10-29-emacs-offline-library.md) 的 D1 与 T2 / T5；ADR：[docs/adr/0006-offline-first-library.md](../docs/adr/0006-offline-first-library.md)）

## 2026-10-29 · 书架 UI 自建 buffer + 显式分页，禁用 ETAF 与 tabulated-list 行内图（OOM 有界）

**决策**：书架视图**重写为自建 buffer**（`special-mode` 派生），每条目一行 = 行内封面 image（`display` 文本属性 + 固定像素高）+ 书名 + 根 + 大小 + 进度 + 待同步 + 状态徽章；`seshat-library-page-size`（默认 30）控制每页条目数，`n`/`p` 翻页、`M-<`/`M->` 首末页、`g` 重算并回第一页。**只为当前页条目创建 image**，翻页 / `q` 时对离开页调 `image-flush`；**不变量 I-OOM**：任一时刻驻留 image 数 ≤ `page-size`，对非当前页条目的封面文件/文档解析次数为 0。非图形环境（`display-graphic-p` 为 nil，含 ERT 批处理）一律跳过 image，用书名首字占位。

**理由**：① `tabulated-list-mode` 的列宽按字符计、行高按字符行计，行内 image 会撑破列对齐，且每次重排重建整表，与「只为当前页创建 image」的节流目标冲突；② ETAF 在测试期常 OOM（用户实测结论），其内部缓存与重绘策略无法表达「驻留 image ≤ 一页」这一硬上限；③ 自建 buffer 把「行 = 一条目、行内一个 image」写成结构，再用分页把同时存在的 image 数钉死——这是唯一不依赖 GC 时机就能保证的内存上限；④ 排序/过滤/翻页因自建而必须自写，但它们同时变成**可测纯函数**（隐性收益）。

**代价**：① 排序 / 过滤 / 翻页 / 标记全部自维护，代码量与回归面比 `tabulated-list` 大；② 分页牺牲连续滚动观感（`page-size` 调大可近似「一屏到底」，但 I-OOM 上限随之放宽）；③ 行高与封面尺寸需按像素自行控制，非图形环境必须有守卫否则 ERT 批处理失败。**验证**：I-OOM 与 I-NONET 两条机械不变量在 ERT 内判定（`create-image` 计数 / `seshat-rest--request` 绑成抛错）。

（来源计划：[openspec/completed/2026-10-29-emacs-offline-library.md](completed/2026-10-29-emacs-offline-library.md) 的 D2 / D3 与 T4 / T5 / T8；ADR：[docs/adr/0006-offline-first-library.md](../docs/adr/0006-offline-first-library.md)）

## 2026-10-29 · 日志收口：自动路径静默进 `*Seshat Log*`，启动时一次汇总提醒

**决策**：新增 `emacs/seshat-log.el`（`seshat-log-level` 默认 `info` / `seshat-log-quiet` 默认 `t` / ring 上限 2000 行的 `*Seshat Log*` / `seshat-show-log` / `seshat-log-clear`），把 `seshat-sync.el`、`seshat-sync-cmd.el`、`seshat-library.el`、`seshat-reading.el`、`seshat-reader-annotation-queue.el` 的**自动路径**（定时器、书架渲染、阅读器打开、批注队列同步）全部改走 `seshat-log`；**显式交互命令**（`M-x seshat-sync-now`、`u`、`d`、`x`）保留单行 echo 反馈。新增 `emacs/seshat-status.el`：在 `emacs-startup-hook` 延迟 `seshat-status-startup-delay`（默认 2s）做**一次**汇总（书库 N 本 / 本地已下载 M、待同步笔记 X / 批注 Y、上次同步时间与结果、状态库是否损坏、从未同步提示），服务端可达性用状态库新增的 `:runtime` 键（上次运行结论），**不在启动时探测网络**。

**理由**：① 项目层 el 文件已有约 **210 处**用户可见输出点（2026-10-29 实测：`(message` 155 + `(display-warning` 55），其中 `seshat-sync.el` 一个文件 103 行含 message/warning，且由两个后台定时器持续触发——echo area 长期刷屏，真正重要的信息被冲掉；② 用户不反对信息存在，反对的是**自动路径**刷屏，因此「自动路径写日志 + 启动汇总一次 + 显式命令保留回显」三条同时成立；③ 启动探测网络会让「启动变慢/卡住」成为新投诉面，用上次运行结论表达「上次同步失败了」已足够。

**代价**：① 静默化后「不看日志就不知道出过问题」成为新默认，必须靠启动汇总与 `M-x seshat-status` 兜住；② 既有大量断言 `message` 的测试（`seshat-library-test.el` / `seshat-sync-cmd-test.el`）必须同批改断言——这是预期改动而非回归；③ `:runtime` 让状态库格式多一个键，旧文件需在 `seshat-state--normalize` 补 nil 兼容。**回退**：`seshat-log-quiet` 设 nil 即恢复 echo 输出。

（来源计划：[openspec/completed/2026-10-29-emacs-offline-library.md](completed/2026-10-29-emacs-offline-library.md) 的 D6 / D7 与 T1 / T2 / T6 / T7；ADR：[docs/adr/0006-offline-first-library.md](../docs/adr/0006-offline-first-library.md)）

## 2026-10-29 · 阅读器两阶段异步渲染：不做 worker 线程池（P2-B D1）

**决策**：像素渲染的异步化**不**重建后台线程/线程池，改为「同步查页尺寸 + idle/周期 timer 补像素」两阶段。同步路径只调 C 入口 `--page-size`（`fz_load_page → fz_bound_page → fz_drop_page`，实测中位 4.5–10.3 µs），像素仍由主线程在 timer 回调里渲染（每轮 ≤ `render-idle-batch` 页）。

**理由**：① 布局真正需要的只有**页高**，它来自页面 bounds（MediaBox/CropBox × scale × rotate），与栅格化无关——「异步」不必等于「后台线程」；② 线程池的既有设施已不存在：`render-threads.c/.h`、`CachedPage`、`EmacsWinState` 在 2026-10-28 的 canvas 迁移中**整族删除**，重建等于重做调度器 + 快照 + 生命周期；③ `DocState` 有单线程纪律、装饰表由主线程拥有、`canvas_data` 指针不可跨调用缓存（每次必须重取），跨线程共享这些结构属高危改动；④ 收益对比：S1 实测单页 p95 最高 49 ms（扫描书），把渲染移出命令路径即可把这条延迟从「每条滚动命令」降为「timer 拍子里的分片」，无需线程。

**代价**：① 渲染仍在主线程 ⇒ 每轮必须**有界**（`render-idle-batch`，默认 2 页；扫描书单轮可达 ~100 ms）；② 需要三条兜底（视口内同步 / 超时强制同步 / 周期推进），因为 timer 在 daemon 与忙碌时都不可靠；③ 引入「已定尺寸未渲染」第三态，页高一致性成为必须机械断言的不变量（占位态 vs 已渲染态逐像素相等，实测差 0 px）。

（来源计划：[openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md](completed/2026-10-28-reader-multipage-p2b-async-render.md) 的 D1 与非目标表第 1 条）

## 2026-10-29 · 三层兜底：idle 只作首轮启动，队列推进靠 `run-at-time`（P2-B D5）

**决策**：异步队列的驱动 = ① 视口内同步（point 页 + 沿 `--multipage-scroll-direction` 相邻的一页）；② 超时强制同步（`render-async-timeout` 默认 1.0 s，唯一不依赖 timer 的保险）；③ **idle timer 用 `nil REPEAT` 只作首轮启动** + `run-at-time` 周期 timer（周期 = `render-idle-delay`）承担持续推进。

**理由**：批次 0 的 S3 探针实测（daemon + `emacsclient -c`，手离开键鼠静置）——`run-with-idle-timer` 在一个 idle 窗口**只 fire 一次**（ticks=1，无新输入不 re-arm），普通 `run-at-time` 正常重复。因此把 idle 当自续驱动会让队列在首轮后**静默停摆**、占位页长期空白；而完全不用 idle 又会让「用户停手后立刻补像素」退化成固定延迟。三层各自覆盖不同的失败面：同步兜住「正在看的页」，超时兜住「timer 全都没跑」，周期 timer 兜住「idle 不 re-arm」。

**代价**：① 两个 timer 需要成对 cancel / 重排，任何新出口都必须同时处置它们与计时起点（态 C 的幸存队项若不重启计时会立刻再判超时，导致每条命令全量同步）；② 参数语义被拉伸——`render-idle-delay` 既是 idle 延迟又是周期，docstring 必须写明「它是**周期推进间隔**，不是 idle 延迟」；③ `render-async-timeout` 的判据是**单一 buffer 时间戳**的粗粒度近似，多窗口下 A 的超时会连带影响 B 的判定（已记 tech-debt）。

（来源计划：[openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md](completed/2026-10-28-reader-multipage-p2b-async-render.md) 的 D5、批次 0 的 G3/G3b 与「S3 daemon idle」记录）

## 2026-10-29 · pending 队列是 buffer 级并集，强制同步是窗口级操作（P2-B D8 的两处出口）

**决策**：`seshat-reader--multipage-pending-renders` 的语义定为「**所有**显示该 buffer 的窗口请求的并集」，因此两个出口都按并集/窗口级口径实现：① 态 B 的裁剪用 `--multipage-all-visible-pages`（遍历 `frame-list` → `window-list FRAME` → 过滤显示本 buffer 的窗口 → 各窗口可见范围取并集）；② 态 C 的强制同步只把**本窗口这一轮同步渲染的页**出队（`--multipage-clear-synced-pending`，range 取 `--multipage-sync-blocking` 的返回值 = 同步前 range），幸存队项保留并重启计时起点 + 重排 timer；只有出队后队列为空才整清（态 A 仍用 `--multipage-reset-async-state` 全清）。

**理由**：队列是 buffer 级资源、强制同步是窗口级动作，两者粒度不同——任何一方按单窗口实现都会让**另一窗口的占位页失去唯一驱动源**（真机表现：另一窗口变成背景色且永不恢复）。这条与 P1 L3-⑪（双窗口各自滚动）同源，但本项只修**队列级**违规；布局模型级问题（单 buffer 行驻留集、一份 buffer-local `--multipage-last-range`、`--ensure-window-layout` 对非当前窗口 `set-window-start`）**不在本项范围**，另立 P1 follow-up 计划。

**代价**：① `--multipage-prune-pending` 的 nil 语义必须改成「不动队列」（nil 在并集口径下表示「没有窗口报出范围」，清队会丢掉仍有效的工作）；② 出队集合依赖 `--multipage-sync-blocking` 的返回值，该函数早退时返回 nil ⇒ 不出队（这个副作用是刻意保留的正确性）；③ 并集口径在「窗口长期不可见」时可能长期非空 ⇒ 每条命令都可能因超时走强制同步（**性能退化，不会渲染错**，已记 tech-debt）。

（来源计划：[openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md](completed/2026-10-28-reader-multipage-p2b-async-render.md) 的 D8、「T8 执行记录」与「T9 D8 清空路径修复」两节）

## 2026-10-29 · 布局是基准、算术跟随：分隔区 span 按实测高度补偿

**决策**：页间分隔区的**实际**像素高度由 `--multipage-page-gap-pixels` 回答（gap 行 + 名义分隔区 + `--multipage-separator-extra-pixels` 补偿），`--multipage-page-span` / `--multipage-page-max-offset` / 跨页累减距离一律消费它；**不为算术而改观感**——分隔行的构造、face、`:height` 三段分配逐字未改。

**理由**：规则行是 `(space :align-to (- right 0))` 的 stretch space，行高恒为一个 `frame-char-height`、不吃 face 的 `:height` 相对高度，故实际高度恒比名义多 `frame-char-height − thickness`（char-h 20 → +18 px/页）。此前把「名义值」当实际值用，等于让滚动算术与真实布局分叉——**分叉本身就是缺陷**，正确方向是让算术去测布局，而不是反过来压布局去凑算术（压缩规则行是观感变更，用户已排除）。修后独立 GUI 实测 span vs row→row 差 0 px（修前 +18/页、5 页累计 +90 px）。

**代价**：① `--multipage-page-gap-pixels` 的 docstring 从「名义值」改为「实测值」，任何依赖名义值的未来消费方必须改用 `--multipage-separator-pixels`；② 补偿量依赖 `frame-char-height`，多 frame 且字体不同时仍有 ±1–2 px 的残余（`--multipage-page-span` 未透传 window，已记 tech-debt）；③ 既有两条几何用例的期望值按新语义更新（gap 25 → 33、span 525 → 533 等），属补偿的直接后果而非顺手改断言。

（来源计划：[openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md](completed/2026-10-28-reader-multipage-p2b-async-render.md) 的「T9 分隔区 span 修复」）

## 2026-10-29 · 双窗口独立滚动另立项：P2-B 只修队列级 D8，布局模型级问题归 P1 follow-up

**决策**：P2-B 的真机验收第 ⑥ 项（双窗口各自滚动）判**不通过**，但**不**在本项内修。边界划分：本项只交付「D8 的两处出口」（队列级并集 / 窗口级强制同步，已修）；「单 buffer 行驻留集、`--multipage-last-range` buffer 一份、`--ensure-window-layout` 对非当前窗口 `set-window-start`、居中/贴左决策写 buffer 全局文本属性」属 **P1 布局模型**，另立 `openspec/active/2026-10-29-reader-multiwindow-independent-scroll.md`（草案，候选池，未走 Phase 1/2 门禁）。

**理由**：① 两件事的失败面不同——队列级修复只能保证「另一窗口的占位页仍有驱动源」（不永久空白），无法保证「另一窗口的位置不塌陷」，后者要改驻留集与每窗口布局状态；② 混在一批会让 P2-B 的验收口径失焦（异步机制的验收被布局缺陷拖成不通过）；③ 布局模型重构涉及内存（驻留行数可能翻倍，每页 canvas ≈1.9 MB，需复核 75 MB 告警线）与 T9 的全部几何断言，属独立风险面。

**代价**：① 用户侧「双窗口」体验在 follow-up 落地前仍不达标（已知缺陷，写入 `docs/emacs-reader.md` §7 与 `openspec/tech-debt.md`）；② 两条线索（队列级已修 / 布局级待修）需要文档同时交代，否则后人会把「已修 D8」误当成「双窗口已可用」。

（来源计划：[openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md](completed/2026-10-28-reader-multipage-p2b-async-render.md) 的「T9 真机主观验收」与「T9 D8 清空路径修复」；follow-up：[openspec/active/2026-10-29-reader-multiwindow-independent-scroll.md](active/2026-10-29-reader-multiwindow-independent-scroll.md)）

## 2026-10-29 · I-OOM 反假绿：显示判断必须在构造之前

**决策**：`seshat-library--insert-cover` 里 `display-graphic-p` 的判断**先于** `seshat-library--make-cover-image` 调用——非图形环境**根本不构造** image（不是「构造了但不显示」）。

**理由**：计划原文（D2）要求「先构造、再判断是否显示」，理由是「构造不受 `display-graphic-p` 约束，构造计数才可测」。但那样写出来 I-OOM 的反假绿自检**形同虚设**：把测试里的 `display-graphic-p` 桩去掉（回到批处理真实值 `nil`）后，构造次数仍等于「页内可用封面数」，**正断言 P 不会失败**——而 P 失败正是「断言非空」的唯一证明。把判断提前后语义变成「看不见就不构造」，去桩 ⇒ 构造 0 次 ⇒ P 必然失败，自检才有判别力（实测：去桩后 `(should (> created 0)) :form (> 0 0) :value nil`）。

**代价**：非图形环境完全不做构造，失去了「构造但不显示」这一中间态（也因此少了一条「构造路径在批处理下也可执行」的间接覆盖）；但这正是想要的结果——看不见的 image 不该占驻留预算。相应地，I-OOM 的三条守恒式（上界 / 收支 / 无泄漏）必须在**桩 `display-graphic-p` 为 `t`** 的前提下才跑得动，桩与去桩两个版本都固化成了用例（`seshat-library-i-oom-scenario-a/b/c` 与 `seshat-library-i-oom-positive-assertion-fails-without-graphic-stub`）。

（来源计划：[openspec/completed/2026-10-29-emacs-offline-library.md](completed/2026-10-29-emacs-offline-library.md) 的 D2 与 T8「OOM 有界断言（去假绿）」）

## 2026-10-29 · 启动汇总零副作用：只查 `featurep`，不主动 require 批注队列

**决策**：`seshat-status--pending-annotations` **只在** `(featurep 'seshat-reader-annotation-queue)` 为真时读取队列计数，否则返回 `nil`（汇总行显示「不可用」）。启动汇总**不 require** 该模块，也不 require 任何其它非必需模块。

**理由**：`seshat-reader-annotation-queue.el` 顶层在 `seshat-reader-annotation-auto-sync` 非 `nil` 时会**立即注册 300 秒周期定时器**。启动汇总若为了拿一个数字去 `require` 它，等于**顺带启用了批注自动同步**——启动路径改变了运行态，属于隐蔽副作用：用户没开过阅读器却开始有后台同步在跑，且日志里会出现没人预期来源的条目。启动汇总的契约是「只读快照、零副作用、零网络」，任何「为了取数而加载模块」的写法都破坏这条契约。

**代价**：会话中从未加载过队列模块时，启动汇总的批注数显示「不可用」而非 `0`——比「显示 0」信息量低，但诚实（`0` 会被误读成「确实没有待同步批注」）。同理，`seshat-status` 对 `seshat-state` / `seshat-reads` 也走「已加载才查、未加载不催」的口径；确需完整数据时由用户显式打开 `*Seshat Status*`（交互命令，可接受加载成本）。

（来源计划：[openspec/completed/2026-10-29-emacs-offline-library.md](completed/2026-10-29-emacs-offline-library.md) 的 D7 与 T6）

