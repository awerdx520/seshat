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
