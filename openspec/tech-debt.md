# 技术债

记录已知技术债与待办。

## SQLCipher 降级（M0.4，2026-10-11）——已解决（-tags sqlcipher 启用加密驱动）
- 背景：原判断为「系统未安装 libsqlcipher，无法使用 CGO 绑定 github.com/mutecomm/go-sqlcipher」，故 DB 层降级为纯 Go 明文驱动（open 的 key 被忽略）。
- 澄清（根因纠正）：github.com/mutecomm/go-sqlcipher/v4 **自带 SQLCipher amalgamation**（包内 sqlite3.c + tomcrypt 源码），编译只需 CGO + gcc，**不依赖系统 libsqlcipher-dev**。此前的降级基于误解，无需安装系统库即可启用加密。
- 解决：internal/storage 改为 build tag 双驱动（driver_modernc.go / driver_sqlcipher.go）：
  - 默认构建（无 tag）：modernc.org/sqlite，驱动名 "sqlite"，明文，非空 key 被忽略并告警（向后兼容，保持可部署回退）。
  - `-tags sqlcipher`：go-sqlcipher，驱动名 "sqlite3"，key 经 DSN `_pragma_key` → `PRAGMA key` 启用 DB 层加密。
  - 注意：加密构建须同时启用 FTS5（迁移 v4 创建 FTS5 虚表，go-sqlcipher 默认未编入 FTS5），故完整构建 tag 为 `sqlcipher sqlite_fts5`；仅 `-tags sqlcipher` 会在运行期报 `no such module: fts5`。
- 验证：默认 `go test ./...` 全过；`CGO_ENABLED=1 go test -tags "sqlcipher sqlite_fts5" ./internal/storage/...` 全过，含新增加密测试（错误 key 打开失败 / 空 key 打开加密库失败 / 密文文件不含明文 SQLite 头）。
- 部署构建命令：`CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" ./cmd/...`（需 gcc）。
- 遗留：① 生产启用需在配置层接入 key（M0.6 密钥管理）；② 启用加密后新建库即为密文，既有明文库需一次性迁移（导出/导入或 SQLCipher `sqlcipher_export`），迁移脚本待补；③ 若无 gcc 环境，回退默认明文构建 + 磁盘 LUKS 兜底。

## LLM 双后端未打通（M6，code-reviewer major #2）——已明确分工（契约文档化，见 docs/llm.md）
- 现象：internal/llm/local.go 的 LocalNodeClient 直连 Ollama（localhost:11434），与 cmd/llmnode + storage/llmtask 的任务队列轮询是两套互不相干的机制。
- 决策（方案 B「明确分工」：保留两套机制并界定边界）：
  - 同步直连（LocalNodeClient）：本地节点与服务端同机、或需即时返回结果的短任务；能力函数（AnalyzeDocument / Summarize / ReviewNotes / AnalyzeReading / GenerateCards）经 Router.Chat 走此路径。
  - 异步任务队列（llm_tasks + cmd/llmnode）：本地节点在另一台机器（家庭网络）+ 长耗时任务；提交流程为「入队 → 节点轮询 → 推理 → 回传 → 客户端异步取」。
- 落地：internal/llm/backend.go 定义双后端契约与选择依据；新增 Router.LocalDirectAvailable()（报告本地直连 URL 是否显式配置）供能力层判断能否同步直连；定义 TaskSubmitter 接口（由 api 层注入实现，本包不反向依赖 storage/api）。契约文档见 docs/llm.md「后端选择契约」。
- 遗留：能力函数当前仍统一走同步直连，异步入队路径待 api 层注入 TaskSubmitter 实现后由上层按场景接入。

## REST 状态同步缺时间戳冲突检测（M1.4，minor #6）——已解决（乐观冲突检测，2026-10-11）
- 现象（历史）：storage/state.go 的 SetProgress/UpdateAnnotation 是纯 UPSERT 后写覆盖，未比较客户端 updated_at 与已存值。
- 现状（历史）：计划同步协议声称「后写覆盖 + 时间戳冲突检测」，实现只有后写覆盖。
- 解决：新增 assertNotStale 乐观冲突检测——客户端传入的 updated_at 早于服务端已存值时拒绝覆盖并返回 ErrConflict，API 层映射为 HTTP 409（internal/api/server.go）；相等或更新则正常覆盖并采用客户端时间戳。覆盖 SetProgress 与 UpdateAnnotationAt。
- 验证：internal/storage（TestProgressConflictDetection / TestAnnotationConflictDetection）与 internal/api（TestProgressConflictReturns409 / TestAnnotationConflictReturns409）均有测试覆盖。

## 单令牌无角色区分（minor #8）——已解决（独立节点令牌，2026-10-11）
- 现象：LLM 节点复用同一个 SESHAT_AUTH_TOKEN，poll/result 端点无节点身份绑定，任何持令牌方可领取任务并读取 payload（可能含发往 LLM 的敏感笔记片段）。
- 解决：引入独立节点令牌 SESHAT_NODE_TOKEN（Config.LLM.NodeToken），节点端点（GET /api/llm/tasks/poll、POST /api/llm/tasks/{id}/result、POST /api/llm/nodes/register）改由 auth.NodeMiddleware 以节点令牌校验：主令牌不能访问节点端点，节点令牌也不能访问普通端点，实现节点与客户端的最小权限隔离。
- 向后兼容：服务端未配置节点令牌时，节点端点回退接受主令牌；cmd/llmnode 优先使用 SESHAT_NODE_TOKEN，未配置时回退 SESHAT_AUTH_TOKEN。
- 验证：internal/auth（AuthenticateNode/NodeMiddleware 的回退与隔离）、internal/api（节点端点接受节点令牌、主令牌访问 401、未配置回退）、cmd/llmnode（令牌选择优先级与回退）均有测试覆盖。

## Android 令牌明文存 SharedPreferences（minor #9）——已解决（EncryptedSharedPreferences，2026-10-11）
- 现象（历史）：gtd/GtdActivity.kt 把 auth_token 存普通 MODE_PRIVATE 文件。
- 解决：新增 sync/SecurePrefs.kt，令牌经 EncryptedSharedPreferences（MasterKey AES256_GCM，来自 Android Keystore；键 AES256_SIV、值 AES256_GCM）加密保存。首次读取时把旧明文文件（seshat_sync）中的同名键迁移到加密文件（seshat_sync_secure）并清除明文旧值；设备不支持硬件密钥库 / 密钥库损坏 / 解密失败时回退普通 SharedPreferences 并告警（isEncrypted=false），保证可用性。
- 依赖：androidx.security:security-crypto（见 android/app/build.gradle.kts）。
- 验证：assembleDebug / testDebugUnitTest 通过。EncryptedSharedPreferences 依赖 Android Keystore 无法在 JVM 单测实例化，故 SecurePrefsTest 注入内存 SharedPreferences 覆盖读/写/迁移/回退逻辑（含 FakeSharedPreferences）。

## elisp 令牌经 curl 命令行传递（minor #10）——已解决（curl --config，2026-10-11）
- 现象（历史）：emacs/seshat-sync.el 用 `-u "user:token"` 传递令牌，令牌短暂暴露于进程列表；seshat-sync-token/seshat-rest-token 以 defcustom 明文存 Emacs 配置。
- 现状（历史）：单用户桌面可接受。
- 解决：seshat-sync.el 的 WebDAV 请求改为把 Basic 凭据写入 0600 权限的临时 curl 配置文件，经 `curl --config` 传入，`-u "user:token"` 形式已移除，令牌不再出现在命令行 / 进程列表；请求结束（含出错）后经 unwind-protect 立即删除临时文件。seshat-rest.el 的 REST 请求走 Emacs 内置 `url-retrieve-synchronously`（进程内，非 curl），令牌在请求头中传递，不进入命令行。
- 遗留：`seshat-sync-token` / `seshat-rest-token` 仍为 defcustom，令牌以明文存于 Emacs 配置，属单用户桌面客户端既有约定；本项仅消除「命令行 / 进程列表短暂暴露」。

## 部署即明文风险（code-reviewer 安全专项）——已解决（部署清单硬性 LUKS 步骤，2026-10-11）
- 现象（历史）：SQLCipher 降级下，若运维未启用 LUKS，数据库与笔记明文落盘，威胁模型失效。
- 解决：docs/deploy.md 第 2 节标题即为「磁盘加密（LUKS，硬性）」，明确「任何部署都必须对数据盘启用 LUKS」；部署检查清单（第 10 节）含「LUKS 已启用」「服务端已构建（加密构建 `-tags "sqlcipher sqlite_fts5"`，或非加密回退 + LUKS 兜底）」等硬性勾选项。同时 docs/security.md 更新 SQLCipher 为 build tag 启用加密（go-sqlcipher 自带 amalgamation），无该 tag 时为明文 + LUKS 兜底。

## 上游对照能力丧失（M11.2c，2026-10-12）
- seshat-reader 改名后与上游 emacs-reader 无逐文件映射，上游修复无法机械合并，须人工比对。

## evil 键位自维护（M11.2c，2026-10-12）
- evil-collection 的 reader 支持绑定硬编码于 `reader-mode-map`（且以 `eval-after-load 'reader` 触发），改名后不再生效；本地在 `thomas-emacs/lisp/init-evil.el` 重建 49 条绑定（含 outline 6 条），上游更新不会自动同步。

## C 源名与产物名不一致（M11.2c，2026-10-12）
- 源码仍为 `render/render-core.c`，产物却为 `seshat-render-core.so`（有意保留以缩小改动面）。

## native-comp 旧缓存残留（M11.2c，2026-10-12）
- `thomas-emacs/.local/cache/eln-cache/*/` 与 `~/.emacs.d/eln-cache/*/` 下存在 `reader-*.eln` 等旧包缓存（无害垃圾，可随时删除或由重新编译自然替换）。

## savehist 中的旧命令名（M11.2c，2026-10-12）
- `thomas-emacs/.local/cache/savehist` 的 `extended-command-history` 中残留一条 `reader-mode`（历史数据，无害；用户可用 `M-x` 历史清理）。

## docstring 列宽告警（M11.2c，2026-10-12）
- 前缀变长使个别 docstring 超过 80 列（byte-compile warning，非 error；checkdoc 无告警）。
- 补充（M11.9，2026-10-17）：`seshat-reader-saveplace.el` 仍有 docstring 超 80 列（vendor 文件，`make all` 的 checkdoc 会报）；三个自研文件为零 warning，vendor 文件保持可对照上游故不擅改。

## define-derived-mode 内重复运行 mode hook（M11.2c，2026-10-16）
- `seshat-reader.el` 的 `define-derived-mode` 体内手工 `(run-hooks 'seshat-reader-mode-hook)`（由来：上游原样带入，经与上游源码逐行对照确认）；`define-derived-mode` 本身已自动执行 mode hook，理论上会执行两次。现有 hook 均幂等、无可见危害，改名未触碰该逻辑；若要修须单独评估行为影响。

## 批注缺备注字段（M11.3，2026-10-16）
- 服务端 annotations 表只有 `text`，Emacs 侧用「选中文本」作正文；高亮 + 备注的完整语义需 schema 扩展。

## EPUB location 未定（M11.3，2026-10-16）
- 本步只定义 PDF 的 `page:<n>;rect:…`；EPUB 约定（CFI vs `chapter:x`）仍待 M10.3。
- 影响延伸（M11.4，2026-10-17）：`seshat:` 链接复用同一 location 约定，故 EPUB 的引用目前只能定位到**书**、定位不到章节/段落；待 M10.3 定稿后链接自动获得精确定位（解析端无需改动）。

## 页面高亮缺口（M11.3，2026-10-16）
- 批注在页面上无可视化，只能通过列表查看与跳页；需改 C 渲染器（另立里程碑）。

## 离线队列缺失（M11.3，2026-10-16）
- REST 失败即报错，无本地暂存与重试。

## REST 封装的非 2xx 语义（M11.3，2026-10-16）
- `seshat-rest--json` 对非 2xx 返回 nil 而非抛错，调用方无法区分「空结果」与「失败」；批注模块已绕开（自行判状态码），但该局限仍在封装层。

## http_proxy 隐患（M11.3，2026-10-16）
- 环境设置了 `http_proxy`，Emacs `url.el` 对本地地址会打印 "Using a proxy for http..."；依赖 `no_proxy` 才正确直连，配置本地服务端时需注意。

## L3 端到端待补（M11.3，2026-10-16）
- M11.3 的服务端闭环验证因服务端不可用而未执行，启动方式见 `docs/configuration.md` 与 `deploy/`（密钥不入库）。

## evil 遮蔽 major-mode 的鼠标绑定（M11.3，2026-10-16）
- evil 经 `emulation-mode-map-alists` 把 `[down-mouse-1]` 解析到 `evil-mouse-drag-region`，优先于 major-mode-map；`seshat-reader-mode-map` 上既有的 `<remap> mouse-drag-region → ignore` 亦无法拦截（evil 走的是 `evil-mouse-drag-region`，不是 `mouse-drag-region`）。
- 影响所有依赖 `down-mouse-1` 的 major-mode 级交互（如 seshat-reader 的鼠标拖拽选区取文）。
- 当前在 `thomas-emacs/lisp/init-evil.el` 侧以 normal state 显式重绑规避。
- 根治需上游 evil 提供更细的 state 映射策略或改用 aux keymap 的更明确写法。

## 服务端 LLM 端点缺口（M11.5，2026-10-16）
- `internal/llm` 的 5 类能力（含云端/本地节点混合路由）尚未暴露任何客户端 HTTP 接口（`internal/api/server.go` 中零命中）；Emacs 侧因此暂时绕过服务端直连本地 gt。
- 服务端补齐同步/异步对话端点后，应评估把阅读器翻译/解释切回统一入口。

## 第三方翻译端点可用性（M11.5，2026-10-16）
- 阅读器翻译默认走 gt 的 youdao-dict + google 免费端点，其可用性、限流与返回结构均由第三方决定，可能随时变化或需要代理（用户已自行配置 `gt-http-proxy`）。

## `gt-chatgpt-engine` 的 key 管理（M11.5，2026-10-16）
- 解释功能的 key 经 `gt-chatgpt-key`（本项目从环境变量 `DEEPSEEK_API_KEY` 注入）或 authinfo 提供；Emacs 侧存在明文 key 的运行时副本，与「密钥不落盘」原则存在张力，后续可评估改用 authinfo 专项目录条目。

## 全局 render hook 的时间窗局限（M11.5，2026-10-16）
- `seshat-reader-translate--capture-result` 挂在 gt 的全局 output hook 上；为防其它 gt 用法污染 `seshat-reader-translate-last-result`，采用「活动标记 + 时间窗（默认 120s）」守卫。局限：窗口内若用户使用其它 gt 功能（同样走 posframe 渲染），仍可能误捕获其译文；根治需子类化 gt 的 render 或改用请求级回调（上游若无此扩展点则需较大改造）。
- **sidebar 路径已消除（M11.10，2026-10-18）**：面板路径的结果捕获改在 gt 的 `:then` 回调内直接进行（`seshat-reader-translate--panel-result`），不依赖任何全局 hook，零误捕获；上述时间窗守卫**仅对 `pop` / `pin` 的 posframe 路径仍存在**。

## 签名材料黑名单覆盖不全（2026-10-16）
- `no-secret-files` 未覆盖 `.pk8`（Android 平台私钥）、`.der` 等格式；且 `.pem` 无法区分私钥与公钥证书，若将来提交 TLS 公钥证书（如 `deploy/cert.pem`）会被误拦。待实际需要时扩展正则或改用内容判定。

## 远端 CI 兜底未部署（2026-10-16）
- 本地 pre-commit 钩子可被 `git commit --no-verify` 绕过，且不覆盖其他克隆者与历史遗留内容；`openspec/decisions.md`（2026-10-16 条目）已声明该边界，远端 CI（如 GitHub Actions 调用 `gitleaks git --log-opts="--all"`）待后续决策。

## 去重语义的局限（M11.6，2026-10-16）
- create 幂等依赖服务端现有 `(location, text)` 比对，对「用户有意在同一位置提交相同文本两次」不敏感（视为同一条）；根治需服务端新增 `client_uuid` 字段。

## 无服务端 client_uuid（M11.6，2026-10-16）
- 离线队列的重试去重只能靠内容比对；若未来支持多端离线，需要服务端提供客户端幂等键。

## 阅读进度未纳入离线（M11.6，2026-10-16）
- 本步只覆盖批注；`/api/progress/{document_id}` 的离线缓存与自动同步仍待实现。

## 队列无自动清理策略（M11.6，2026-10-16）
- 队列有上限（`-max-entries`，默认 1000）并在达上限时拒绝入队，但**无自动清理/过期策略**；长期离线可能触达上限并拒绝新条目，需人工干预。

## 队列写为无锁 read-modify-write（M11.6，2026-10-16）
- 队列的 `-enqueue`/`-remove`/`-sync` 均为「读取 → 改内存 → 原子写回」，`--write` 只保证「不写坏文件」，**不保证「不丢更新」**：两个 Emacs 实例并发写同一队列文件时，后写会覆盖先写（单实例假设）。根治需文件锁（`lock-file`）或读回比较（CAS）；当前不做，仅记录。

## `rect` 无高亮承载（M11.4，2026-10-17）
- 影响：`seshat:` 链接与摘录可携带 `;rect:<x0>,<y0>,<x1>,<y1>`，但阅读器页面上没有任何矩形可视化，用户只能看到「第 n 页」。
- 现状：页面高亮缺口与 M11.3 同源，需改 C 渲染器（另立里程碑）；当前 rect 仅作数据保留，为将来的高亮与精确定位留位。

## `:complete` 未实现（M11.4，2026-10-17）
- 影响：笔记里输入 `seshat:` 链接无法补全 doc-id / location，只能手写或从阅读器 `org-store-link` 存出。
- 建议：`org-link-set-parameters "seshat"` 增 `:complete`，候选来自 `seshat-reader-annotation-roots` 下的文件清单（或 M7 的 uid 目录接口）；当前不在范围。

## 摘录固定末尾插入（M11.4，2026-10-17）
- 影响：`seshat-reader-reference-insert` 一律把摘录块**追加到目标笔记文件末尾**，不识别 headline/光标位置，长笔记中会越积越乱。
- 建议：加目标定位（交互选 headline 或 `org-capture` 模板）；当前靠用户配置固定落点文件 + 事后整理规避。

## 含 `#`/`%` 的文档名不支持引用（M11.4，2026-10-17）
- 影响：`doc-id`（`<标签>:<相对路径>`）含 `#` 或 `%` 时生成链接直接 `user-error`（提示重命名），这类电子书无法建立 `seshat:` 引用。
- 理由：本实现刻意不做百分号转义（`url-hexify-string` 会转义 `:`/`/`，org 又对 `%` 二次转义）。根治需协议层引入转义或改用 uid 承载身份（M7）。

## `:export` 未定制（M11.4，2026-10-17）
- 影响：导出（HTML/LaTeX 等）时 `seshat:` 链接走 org 默认行为，输出为无法点击的原始协议串。
- 现状：本步只需要在 Emacs 内跳转，未注册 `:export`；将来如需导出阅读笔记，再补 `:export`（可导出为 `seshat:<doc-id>#<location>` 文本或转成脚注）。

## `--parse-link` 对尾部 `#` 返回空串 location（M11.4，2026-10-17）
- 影响：`seshat:ebook:a.pdf#` 解析出 `location` 为空串而非 nil，与「无 location」语义不一致（对称性小瑕疵）。
- 现状：不影响功能（空串与 nil 在下游都当作「无 location」处理）；修法是把解析结果空串归一为 nil。

## 反向解析按 tag 精确匹配（M11.4，2026-10-17）
- 影响：`seshat-reader-reference--file-from-doc-id` 用 doc-id 首段 tag 精确匹配 `seshat-reader-annotation-roots`，**同 tag 配置多个根时只取第一个**命中的根，可能解析到错误文件。
- 约定：tag 需唯一（配置侧自律）；M7 uid 化后此限制自然消失。

## 底部单窗口下批注与译文互斥（M11.7，2026-10-17）
- 影响：面板为单窗口，后显示者接管同一窗口——打开译文面板会顶掉批注列表，反之亦然；无法同屏对照。
- 现状：已确认为设计行为（会话内切换）；若需同屏可见，需引入 section 统一渲染（一个窗口内分节），另立方案。
- 补充（M11.10，2026-10-18）：译文/解释已改为**同一面板内的 Markdown 文本 buffer**（不再经 ETAF 排版），但仍走同一个 `seshat-reader-sidebar-show` 窗口，故**互斥语义不变**；「同屏对照」仍需 section 统一渲染方案。

## `window-height` 只对新建窗口生效（M11.7，2026-10-17）
- 影响：改 `seshat-reader-sidebar-height`（或调 per-kind 高度）不会让**已显示**面板重排，需先关闭再打开。
- 建议：如需即时生效，可在设置后对已存在窗口调 `window-resize`；当前不做。
- **部分缓解（M11.10，2026-10-18）**：译文/解释面板现由 `seshat-reader-sidebar--fit-height-for-content` 按内容自适应高度（上限 `seshat-reader-sidebar-max-height`），重新执行翻译/解释即自动贴合内容，无需重开；**批注列表仍需关闭再打开**才能应用新的固定高度。

## 包内窗口语义不统一（M11.7，2026-10-17）
- 影响：`seshat-reader-outline` 与 `seshat-reader-reference`（以及 M11.4 的 `:follow` 跳页）仍用 `pop-to-buffer`，不受 `seshat-reader-sidebar-enabled`/`position` 管辖；用户在不同命令间会遇到两套窗口行为。
- 建议：后续把 outline/目录类 buffer 也接入 sidebar 承载层（需先确认 nav 类面板与阅读区的布局关系）。

## `seshat-reader-sidebar-toggle` 无法重开译文面板（M11.7，2026-10-17）——已解决（M11.10，2026-10-18）
- 原因（历史）：译文由 gt 自行 `display-buffer`，不经过 `sidebar-show`，故不记录 `--last-kind=translate`；`toggle` 只能在批注面板上往返。
- 解决：译文/解释统一经 `seshat-reader-translate--render-panel` → `seshat-reader-sidebar-show` 显示并记录 `--last-kind=translate`，关闭后 `toggle` 可原样重开译文面板。仅 `pop` / `pin` 两条 posframe 回退路径不经过面板（此时不涉及本面板 toggle）。

## per-kind 高度仅会话内记忆（M11.7，2026-10-17）
- 影响：`seshat-reader-sidebar--state` 是内存 alist，重启 Emacs 后各 kind 高度回到 `seshat-reader-sidebar-height` 默认值。
- 建议：如需持久化可存 custom/savehist；当前接受（面板高度常随使用场景变化，持久化收益有限）。

## popper 名单为硬编码正则（M11.8，2026-10-17）
- 影响：`thomas-emacs` 的 `+popper-reference-buffers-select` 用字面正则 `"\*Seshat Annotations\*"` / `"\*Seshat Sidebar\*"` 登记面板；用户若改 `seshat-reader-sidebar-translate-buffer-name`（defcustom），popper 将不再登记，`C-'` 开关失效。
- 建议：面板改名时同步改配置侧正则；或在包内暴露「当前面板 buffer 名列表」由配置侧读取。

## popper 关闭不捕获 per-kind 高度（M11.8，2026-10-17）
- 影响：popper 的 `popper--delete-popup` 走 `quit-window`，不调本包 `--capture-state`；用户在 popper 关闭前手动 resize 的高度不会被记住（best-effort，接受为已知差异）。
- 建议：若需精确记忆，可在 `window-size-change-functions` 或关闭钩子里捕获；当前不做。

## 全局入口 `SPC o P` 未实现（M11.8 遗留，2026-10-17）
- 影响：面板只能从阅读器/批注命令内拉起，没有跨 buffer 的全局开关键（`seshat-reader-sidebar-toggle` 需 `M-x` 或 buffer 内 `q` 键）；面板内键位已由 M11.9 的 ETAF `:keys` 承担，但 `:keys` 只作用于面板 buffer 内部，技术上无法承担全局入口。
- 建议：在 `thomas-emacs/lisp/init-keybind.el`（或 `init-reader.el`）加 `SPC o P` 前缀与 4 个绑定（`p` 批注 / `a` 添加 / `t` 翻译 / `e` 解释，以最终配置为准）；仅在 evil 的 normal/visual/motion 态生效（`leader!` 定义域）。

## ETAF 在 pty/终端 frame 下挂起（M11.9，2026-10-17）
- 影响：`script -qec … emacs -Q -nw` 等 **pty / 终端 frame** 下 `etaf-mount` 会挂起不返回；真机 GUI frame 正常（用户已 smoke 验证 `ETAF-SMOKE: OK 43`）。
- 现状：终端用户可能无法使用 ETAF 渲染层（需把 `seshat-reader-etaf-enabled` 设 `nil`），建议在 GUI frame 使用；根因在上游 `etaf-mount` 对终端 frame 的尺寸/字体处理，未在包内绕过。

## ETAF 配色不跟随主题变量（M11.9，2026-10-17）
- 原因：渲染层只用按 `background-mode` 取值的**内置双色板**（明/暗两套），不读用户主题变量——`etaf-theme-token :ui-*` 实测**不随明暗主题变化**（palette 为单一色值），且 `etaf-ui` 的 label/badge 文字色写死并覆盖父 Host。
- 影响：切换明暗主题后需重新打开（重新渲染）面板才会用上新色；细粒度主题（如改 `default` 前景色）不反映到面板。

## ETAF 0.x API 变动风险（M11.9，2026-10-17）
- 影响：渲染层依赖 `etaf-view`/`etaf-mount`/`etaf-ref`/`:keys`/`:on-press`/`etaf-runtime-update-host-content` 等 public API，ETAF 仍处 0.x，签名或宏展开可能变动；ETAF 未 vendored（用户侧 clone + `make compile`），升级不受控。
- 建议：升级 ETAF 后跑 `emacs/tests/seshat-reader-etaf-test.el` 做回归；渲染层已全程 `condition-case` 兜底，API 断裂时自动回退纯文本渲染。

## ETAF 条目规模上限（M11.9，2026-10-17）
- 现状：渲染层用 `:overflow 'scroll` 裁剪（实测 200 条以内 mount 40.7ms、选中切换 ≤4.5ms，交互无感）；条目数远超 200（脏数据/批量导入）时滚动裁剪生效，但初始化与选中定位仍会变慢。
- 建议：条目规模异常时先检查批注数据；如需分页，再引入「按页加载」而非一次渲染全部。

## `seshat-reader-saveplace.el` docstring 超 80 列（M11.9，2026-10-17）
- 现状：`make all` 的 checkdoc 仍报该文件 docstring 列宽 warning（vendor 文件，属既有告警，非本批引入）；`seshat-reader-etaf.el`/`-sidebar.el`/`-reference.el` 三个自研文件为零 warning。
- 处理：vendor 文件不擅自改动（保持与上游可比），如需清零可在 `make` 的 checkdoc 列表中豁免该文件。

## markdown-mode 为软依赖（M11.10，2026-10-18）
- 现状：译文/解释面板用 `gfm-view-mode` 渲染 Markdown，缺失时降级 `markdown-view-mode`，两者都缺失时降级 `text-mode`（不折行美化、不隐藏 `**`/`#` 等标记）。降级链使面板在未安装 markdown-mode 的 Emacs 上仍可用，但观感与折行效果下降。
- 现状（依赖声明）：`seshat-reader-translate.el` 的 `Package-Requires` 未声明 markdown-mode（保持软依赖，不因观感功能强制安装）；`docs/configuration.md` 的「阅读器面板」说明已标注该软依赖与降级行为，可在此核对。

## 面板测试的状态隔离与空列表表现（M11.10，2026-10-18）
- 测试隔离：`seshat-reader-etaf-test` 的若干用例未对 `seshat-reader-etaf--doc-id` / `--doc-source`、`seshat-reader-sidebar--last-kind` / `--last-buffer` 做 `let` 绑定，退出后残留。当前不影响结果（后续用例均自行绑定/覆盖），但违反测试隔离原则，后续补 `let`。
- 空列表表现不一致：批注为空时，纯文本路径显示「（该文档没有批注）」，ETAF 路径渲染空卡片列表 + 徽章「0 条」。行为可接受（M11.9 既有），属测试盲区，后续统一或补测。

## Android L3 设备验证缺口（M9.1，2026-10-18）
- 现象：本机 `adb devices` 为空、AVD 数量为 0、`$ANDROID_SDK/system-images/` 无镜像文件（仅空目录），无法用模拟器或真机做 UI 交互验证。
- 影响：三区骨架、tab 切换状态保留、设置页保存/回填、4 个阅读入口与 GTD 入口的可达性只能人工真机验收；CI 也无法覆盖。
- 缓解：L3 降级为静态校验（`aapt2 dump badging` / `apkanalyzer manifest print` 校验包名、launcher 与 5 个 Activity）+ 人工验收清单（见 `openspec/completed/2026-10-18-m9.1-android-shell.md`「验证标准」）。
- 根治：安装系统镜像并创建 AVD（`sdkmanager "system-images;android-35;google_apis;x86_64"` + `avdmanager create avd`），或接入真机 / 云设备农场。

## BottomNavigationView 无图标（M9.1，2026-10-18）——已解决（M9.2，2026-10-18 补自绘矢量图标）
- 现象：底部双 tab 只有文字标签（`nav_notes` / `nav_reader`），无矢量图标，`app:labelVisibilityMode="labeled"`。
- 原因：本机无设备可验证图标渲染，为降低「自绘 vector path 出错却无法发现」的风险，M9.1 刻意不引入 drawable。
- 影响：视觉弱于 Material 规范（NavigationBar 通常 icon + label），功能完整。
- 建议：真机验证环境具备后补两枚 24dp 矢量图标，并在 `res/menu/menu_main_tabs.xml` 加 `android:icon`。
- 解决（M9.2）：新增 res/drawable/ic_tab_notes.xml / ic_tab_reader.xml（自绘几何），menu_main_tabs.xml 两个 item 加 android:icon。

## Notes / Reader tab 为占位（M9.1，2026-10-18）
- 现状：`ui/NotesFragment` 只有占位文案与「打开 GTD」按钮；`ui/ReaderFragment` 只有 4 个既有阅读入口。
- 影响：三区骨架已就位但内容区尚空；Notes 的 orgzly 风格列表（M9.3）与 Reader 的书架（M10.1）未接入；数据源接入（M9.2 的 uid + 增量 + 本地缓存）仍依赖 M7 服务端地基。
- 约定：这两个 Fragment 是后续里程碑的唯一落点——M9.3 把 Notes 列表挂进 `NotesFragment`，M10.1 把书架挂进 `ReaderFragment`，不另建 Activity。

## androidx.security 仍为 alpha 版（M9.1，2026-10-18）
- 现状：`androidx.security:security-crypto:1.1.0-alpha06` 是预览版，`EncryptedSharedPreferences` 的解密时机（`create()` 内 vs 首次 `getString()`）与异常类型在版本间存在差异。
- 缓解：M9.1 已在 `getString`/`putString`/`putSecret` 三层做异常兜底，且 `isEncrypted=false` 时拒绝写入机密。
- 建议：等 1.1.0 稳定版发布后升级，并回归 `SecurePrefsTest` 与真机「恢复备份后打开设置页」场景。

## Android 设置页输入健壮性（M9.1，2026-10-18）
- 现状：`SettingsValidator` 用 `java.net.URI` 解析，IDN 域名（如 `https://例え.テスト`）与无方括号 IPv6（`fe80::1`）会被判为 `MALFORMED` 而拒绝；不支持用户填写带方括号的 IPv6 之外的等价写法。
- 影响：属可用性限制，非安全问题；绝大多数自托管场景使用 ASCII 域名或 IPv4。
- 建议：如需支持，用 `java.net.IDN.toASCII` 预处理 host 并显式处理方括号 IPv6。

## 保存配置非原子且失败不可感知（N1，M9.1 安全复审，2026-10-18）
- 现象：`SettingsStore.save()` 分两次写入令牌与地址，且 `putString` 内部吞异常返回 `Unit`，地址写入失败时仍返回 `SaveResult.Ok`，UI 提示「配置已保存」并退出。
- 影响：失败后可能留下「新令牌 + 旧地址」组合（有效令牌被发往用户本想迁离的主机）；写入失败对用户不可见。
- 建议（M9.2 前处理）：`SecurePrefs` 暴露 `saveConfig(url: String, token: String?): Boolean`，内部 `prefs.edit().putString(URL).putString(TOKEN).commit()` 一次落盘（`commit()` 有返回值），`SettingsStore` 据此返回真实结果。

## 加密存储损坏后无法自愈（N3，M9.1 安全复审，2026-10-18）
- 现象：`SecurePrefs.open()` 失败回退为 legacy 实例后，损坏的 `seshat_sync_secure.xml` 不被删除；`clear()` 只清 legacy，故「重置本地配置」无法恢复加密能力，而 UI 会隐藏告警并提示已重置（文案已在 T9 修正为「需在系统设置中清除应用数据」）。
- 影响：设备可能永久处于「无法保存令牌」状态；此前版本会引导用户执行无效的破坏性操作（丢失已存服务器地址）。
- 建议（M9.2 前处理）：`SecurePrefs` 持有 `applicationContext`，新增 `resetAll(): Boolean`（清 prefs + `deleteSharedPreferences(ENCRYPTED_PREFS)`），`SettingsActivity` 仅在成功时隐藏告警。

## 校验通过值与保存值不一致（n4，M9.1 安全复审，2026-10-18）
- 现象：`SettingsValidator.validateServerUrl` 返回 `withScheme.trimEnd('/')`（原始串）而非 URI 重组结果，故 `https:/a.com` 被接受并保存为 `https://https:/a.com`；空端口 `a.com:`、`:0`、含控制字符、`/../` 路径均被接受。
- 影响：畸形地址进入 `SeshatConfig.serverUrl` 并拼进请求，可能导致请求失败或打到意外的 host/path（未构造出主机级绕过，userinfo/host 校验闭合）。
- 建议：拒绝 `[\x00-\x1f\x7f]` 与控制字符、拒绝 `port == 0`、用 `scheme://host[:port]path` 重组后再返回。

## 设置页输入与状态副作用（n2/n5/n6，M9.1 安全复审，2026-10-18）
- n2：`onUnreadable` 不改变 `isEncrypted`，若解密异常发生在 `EncryptedSharedPreferences.create()` 之后，`putSecret` 仍返回 true，fail-closed 仅由 UI 承担。建议增加 `@Volatile usable` 标志并纳入 `putSecret` 判断。
- n5：令牌无长度上限（建议 4096，超限返回独立错误原因）。
- n6：`onPause` 清空令牌输入框且 `saveEnabled=false`，旋转屏幕/来电返回后已输入未保存的令牌静默丢失且无提示。建议清空时若输入非空则提示。

## 备份与可用性取舍待文档化（n8/n9/n10，M9.1 安全复审，2026-10-18）
- n8：`GtdActivity` 调 `SecurePrefs.open(this)` 未传 `onUnreadable`，加密不可用时静默使用 legacy 明文令牌（无新增泄露面，但无提示）。
- n9：B2 的备份排除规则缺 lint 与真机证据（`com.android.tools.lint:lint-gradle:31.13.2` 未缓存 + 网络不可达）；`reader_annotations` / `reading_progress` / `pdf_reader` 会随云备份上传（不含凭据，属用户内容隐私），该取舍需在 `docs/security.md` §7 记录。
- n10：设置页 `FLAG_SECURE` 为全窗口，用户无法截图求助；属刻意的安全/可用性权衡，需在 `docs/android.md` 记录以免后续被当作 bug 移除。

## 批注列表全量渲染无虚拟化（M11.13，2026-10-18）
- 现象：去分页后列表一次性渲染全部条目，条目数极大（数百条以上）时首次渲染成本线性增长，且 ETAF viewport 高度按条目数放大。
- 可选优化：按可视区域渲染（虚拟滚动）或恢复「分批加载」但保留连续流语义。
- 现状：当前不阻塞日常使用（批注通常几十条）。

## EPUB 竖向模式的 WebView 高度测量（M9.2，2026-10-18）
- 现状：每章 item 高度依赖 `onPageFinished` 后一次 JS 往返（取 `scrollHeight` 与 `window.innerHeight`，按「视口物理高/视口 CSS 高」换算），测量完成前用屏高占位。
- 未验证：真机上字体/图片晚于 `onPageFinished` 到位时，高度可能偏小导致章末内容被裁；当前只在测量后对**当前可见章**重锚，其余章高度修正可能引起轻微滚动跳动。
- 根治方向：在 `loadDataWithBaseURL` 前注入 `viewport` meta 并等待 `document.fonts.ready` 再测量；或改用单 `WebView` 加载全书以避免逐章测量。

## 连续滚动的设备级验证缺口（M9.2，2026-10-18）
- 现状：本机无 AVD / 无连接设备 / system-images 为空，滚动流畅度、吸附手感、EPUB 高度测量与重锚、tab 图标渲染、主题切换观感均未在真机验证。
- 影响：M9.2 的核心体验（连续滚动）只有编译与单测保证，属已知风险。
- 建议：安装 `system-images;android-35;google_apis;x86_64` 建 AVD，或接入真机，按 `openspec/completed/` 里的人工验收清单逐项核对。

## codegraph 无法索引 Kotlin 符号（M9.2，2026-10-18）
- 现象：`codegraph index` 对 `android/` 的 Kotlin 源码提取不出符号节点（实测 0 nodes / 28–64 edges，仅解析文件与少量引用），索引对本 Android 模块无检索价值。
- 影响：Android 侧的代码探索只能靠 `grep`/逐文件阅读，效率低于 Go 侧。
- 建议：Android 侧改用 LSP（`eca__editor_definition`/`editor_references`）或后续评估支持 Kotlin 的索引工具。

## PDF 竖向模式的进度无页内偏移（M9.2，2026-10-18）
- 现状：`PdfProgress` 只有 `page` 字段，竖向连续滚动恢复时固定 `scrollToPositionWithOffset(page, 0)`，只能恢复到页首；EPUB 则能恢复到章内精确偏移。
- 影响：长页 PDF（如扫描件）竖向滚动退出再进入会回到页顶，体验略差于 EPUB。
- 建议：给 `PdfProgress` 增加 `offset` 字段并迁移（按 `openspec/decisions.md` 的 C 数据契约域纪律：复制 + 观察期）。

## PDF 渲染线程的销毁竞态依赖 catch 兜底（M9.2，2026-10-18）
- 现状：`PdfPageAdapter.shutdown()` 用 `shutdownNow()`，但 `interrupt` 对 `PdfRenderer.openPage/render` 无效；真正兜底是 `renderer.close()` 后抛异常被 `renderPage` 的 `catch (Exception)` 吞掉。`renderPage` 里的 `synchronized(renderer)` 无法保护不在锁内的 `close()`，属无效防御。
- 影响：极端时序下可能出现 native 层崩溃（Kotlin catch 兜不住），无设备无法验证。
- 建议：`onDestroy` 改为 `shutdown()` + `awaitTermination(500ms)` 后再 `renderer.close()`，并去掉无效的 `synchronized`。

## 连通性测试的并发与取消（M9.2，2026-10-18）
- 现状：探测在裸 `Thread` 执行，按钮未在探测期间禁用，`onDestroy` 也没有取消标志；连点会并发多个带令牌请求，旧结果可能覆盖新结果。
- 影响：仅影响 UI 正确性与资源浪费，无凭据泄露。
- 建议：探测期间禁用按钮 + 用请求序号丢弃过期回调；或改用 `Future`/`ExecutorService` 并在 `onDestroy` 取消。

## GtdActivity 的 remoteDir 有两个来源（M9.2，2026-10-18）
- 现状：`readSyncConfig()` 把 `remoteDir` 放进 `SeshatConfig`，`syncToServer()` 又用 `joinPath(remoteDir, "seshat/sample.org")` 手动拼接路径。当前 `WebDavClient` 的 `davUrl` 不使用 `config.remoteDir`，行为正确。
- 影响：若将来 `WebDavClient` 改为用 `config.remoteDir` 参与拼接，会出现重复拼接。
- 建议：统一为一处（要么只传 `config.remoteDir` 由传输层拼，要么只在调用层拼并把 `remoteDir` 从 `SeshatConfig` 移除）。

## 手写笔迹无跨端显示（M10.5，2026-10-18）
- 现状：手写批注只存 Android 本地（`PdfInkStore`），未上传服务端；Emacs 端（M11.3）只支持 `page:<n>;rect:...`，无法渲染笔迹。
- 影响：同一 PDF 在 Emacs 与 Android 上看到的批注不一致；换设备后手写笔迹丢失。
- 建议：M10.3 统一批注同步时，按 `docs/api.md` 4.5.1 的 ink 协议上传（一笔一 annotation）；若要跨端可见，需 Emacs 端补笔迹渲染或降级显示为「第 n 页有一处手写批注」。

## `updateInkChrome()` 每次切页解析整份笔迹 JSON（M10.5，2026-10-18）
- 现状：`PdfReaderActivity.updateInkChrome()` 在每次页面切换时调用 `inkStore.hasInk(...)`，其内部会读取并 JSON 解析整份 `PdfInkDocument`。
- 影响：笔迹数量多（数百笔）时可能有毫秒级主线程开销，滚动中反复触发。
- 建议：Activity 内缓存一份 `PdfInkDocument` 快照（写入时更新），或让 `PdfInkStore` 提供按页索引的轻量查询。

## 横屏 renderWidth 用首页宽高比代表全书（M10.5，2026-10-18）
- 现象：横屏 + 横向翻页模式下，`renderWidth` 由首页宽高比估算；含混合横竖页面的 PDF，非首页的渲染分辨率可能偏大或偏小。
- 影响：仅影响清晰度/内存，不影响布局（`FIT_CENTER` 负责显示）。
- 建议：如需精确，可按每页宽高比分别渲染（`PdfPageAdapter` 已按页存 `pageHeights`，扩展为按页存 `pageWidths` 即可），代价是 LRU 缓存键需改为 `(page, width)`。

## MOVE 到墓碑路径返回 409（M7，2026-10-18）
- 现象：目标路径上存在墓碑（已删除资源的登记行仍占用 `UNIQUE(root, path)`），`POST /api/resources/{uid}/move` 的登记步骤撞唯一约束返回 409，而物理移动此时**已经发生**。
- 影响：调用方看到「移动失败」，但磁盘上的文件已在新路径——登记与磁盘不一致，只能靠 `POST /api/resources/rescan` 收敛。
- 建议：在 storage 层实现「复活目标墓碑」（把目标行的 uid 改为被移动资源的 uid），或 Move 前先查目标墓碑并走复活路径（create 路径已有 `tombstoneAt` 复用逻辑，可直接对齐）。

## `--refresh-list` 兼容路径零 ERT 覆盖（M7，2026-10-18）
- 现象：`grep refresh emacs/tests/*.el` 命中 0——批注列表的 `--refresh-list` 兼容路径（ETAF 未挂载时走的重渲染分支）没有任何 ERT 用例。
- 影响：该分支无回归保护，只能靠人工观察；此前「ETAF 已挂载时不再 `erase-buffer`」的缺陷正出在相邻路径。
- 建议：补 2 例——① 未启用 ETAF 时 `--refresh-list` 重渲染后条目数与内容正确；② 启用 ETAF 时走渲染层分支（用 `seshat-reader-etaf-enabled` 绑定区分两条路径）。

## `seshat-reader-annotation.el` docstring 仍写 `document_id`（M7，2026-10-18）
- 现象：`seshat-reader-annotation.el:109,111` 的 docstring 仍以 `document_id` 描述取值；wire 字段已零命中（代码不再发 `document_id`）。
- 影响：纯术语残留，不影响行为；但会让后来者误以为服务端仍接受 `document_id`。
- 建议：统一为「显示用 doc-id、请求用 uid」的措辞，与 `seshat:` 链接文档保持一致。

## `make all` 不保证刷新 `.elc`（M7，2026-10-18）
- 现象：`emacs/seshat-reader/Makefile` 的 `all` 按 mtime 判定是否重编；跨文件依赖变更或时钟异常时可能保留旧 `.elc`。
- 影响：改源码后仍加载旧字节码，表现为「改了没效果」或测试假失败（本次已踩坑，属假失败）。
- 建议：改源码后固定执行 `rm -f *.elc && make all`；若要根治，把 `.elc` 目标改为 `.PHONY` 或按源码哈希判定重编。

## ERT 假绿判据（M7，2026-10-18）
- 现象：跑 ERT 时若缺少 `-L` 加载路径，测试里的 `skip-unless` 会静默跳过整批用例，ERT 仍报 `0 unexpected`，看起来全绿。
- 影响：会误判「测试通过」并掩盖真实回归。
- 建议：把 `skipped=0` 作为通过判据（不能只看 unexpected 计数），并把完整 `-L` 集合固化进脚本或 Makefile 目标，避免手敲遗漏。

## Codegraph 对 Go 与 Elisp 均无效（M7，2026-10-18）
- 现象：`codegraph index` 在本仓库输出 `0 nodes`（Go 与 Emacs Lisp 均不产出符号节点）。
- 影响：Codegraph 工具在本项目无检索价值；「查无结果」不等于代码里没有。
- 建议：Go 侧依赖 `go vet` / LSP（`eca__editor_definition` / `editor_references`），Elisp 侧用 elisp-dev-mcp（`elisp-get-function-definition` / `elisp-describe-function`）；索引更新步骤可跳过。

## 离线创建批注退化（M7，2026-10-18）
- 现象：批注请求需先 `GET /api/resolve` 解析 uid；首次打开某文档且离线时无法新建批注（已缓存 uid 的文档不受影响）。
- 影响：推翻路线图假设 H1——M11.6 的离线队列只覆盖「服务端可用但请求失败」，不覆盖「从未解析过 uid」；M11.6 的离线能力因此受限。
- 建议：本地持久化 `doc-id → uid` 缓存，或离线入队时延后解析（同步阶段补 uid），使首次离线也能入队；短期在文档中说明该边界。

## `roots[1..]` 不代建目录（M7，2026-10-18）
- 现象：`webdav.roots` 中除首根外的根目录不存在时启动 fail-fast，不自动 `MkdirAll`。
- 影响：部署时多根配置易因漏建目录导致服务起不来，且失败点在启动期。
- 建议：在运维文档（`docs/configuration.md` / `docs/deploy.md`）明确「每个根目录需预先创建」，或改为启动时 `MkdirAll`（`ondemand` 根仍可保留 fail-fast）。

## `ListResources` 的 `prefix` 是未转义 LIKE（M7，2026-10-18）—— 已解决（M7 修复轮，2026-10-18）
- 现象：`GET /api/resources?prefix=` 原先拼成 `path = ? OR path LIKE ? || '/%'`，prefix 里的 `%` / `_` 作为 LIKE 通配符生效。
- 影响：含 `%` 或 `_` 的路径前缀会多命中（返回不属于该前缀的资源），客户端需自行过滤。
- 解决：`internal/storage/resource.go` 的 `ListResources` 已改用定长比较 `path = ? OR substr(path, 1, length(?) + 1) = ? || '/'`（先去掉 prefix 尾斜杠），语义是「精确字节前缀 + `/`」——**大小写敏感**且 `%`/`_` 不再有通配符含义；`GET /api/resources?prefix=` 的返回不再是超集，客户端无需二次按 `path` 过滤（`docs/api.md` §15 与 `docs/sync-protocol.md` §10 已同步）。

## MOVE 到已存在目标时静默丢事件（M7，2026-10-18）
- 现象：目标路径已有存活资源时，`registry.Apply` 撞 `UNIQUE(root, path)` 只记日志，`changes` 事件未写入。
- 影响：登记与磁盘不一致且客户端收不到该变更（游标推进后无法靠增量补齐），需 rescan 兜底。
- 建议：Move 前先检查目标是否存活，存在即返回 409 并拒绝移动；同时把 Apply 失败上抛给调用方，而不是仅记日志。

## 端到端盲区（M7，2026-10-18）
- 现象：三处只有单测、未进 E2E——① FTS 只索引首根；② B4 的错误码与 v7 `COUNT(*)` 防御；③ B6 并发 rescan 的 409。
- 影响：单测覆盖的是函数/处理器级行为，跨服务链路（SQLite 迁移 + WebDAV 钩子 + 启动 Bootstrap）未被真实验证。
- 建议：服务端可部署后补 3 个 E2E 场景（书库根不进索引、非空状态表的 v7 迁移中止、并发 rescan 一 200 一 409）。

## `seshat:` 裸文本尾部标点未剥离（M7，2026-10-18）
- 现象：服务端从裸文本提取 `seshat:` 引用时未剥离尾部标点，`seshat:a.org.` 会把句末的 `.` 计入 target。
- 影响：解析出的路径/uid 多一个字符，`refs` 中出现无效引用；org 链接形态（`[[seshat:...]]`）不受影响。
- 建议：裸文本提取时剥离尾部标点（`.,;:!?)` 等），并补对应单测。

## 目录级写非原子批量（M7，2026-10-18）
- 现象：目录级写（删除/移动目录时处理其下资源）逐条调用 `registry.Apply`，不是单事务批量。
- 影响：中途失败会留下「部分登记」中间态（部分资源已墓碑、部分未），客户端看到不完整的变更流。
- 建议：短期以 rescan 兜底；根治需 storage 层提供批量 Apply，把目录级变更收进一个事务，保证「全成功或全不生效」。

## Android 连通性探测使用旧 document_id 参数（M7，2026-10-18）
- 现象：`android/app/src/main/java/com/seshat/app/settings/ConnectivityTester.kt` 的 `PROBE_DOCUMENT_ID = "__connectivity_probe__"` 仍请求 `GET /api/annotations?document_id=...`；M7 起状态端点只接受 `uid`，该请求必然 400，设置页「连通性测试」会误报失败。
- 影响：Android 现版本的连通性测试不可用（其它功能不受影响，因尚未部署且状态 API 本就要在后续里程碑适配）。
- 建议：改用 `GET /api/roots` 或 `GET /api/changes?since=0&limit=1` 作为探测端点（只验证认证与连通性，不依赖具体文档），并与 Android 端 uid 适配（M9.2 数据源/M10）一并落地。

## 安全响应头覆盖不全（M7 安全复审，2026-10-18，部分解决）
- 现象（原）：服务端自身不设 `X-Content-Type-Options: nosniff`、`X-Frame-Options`、`X-XSS-Protection`、CSP，也没有 `Strict-Transport-Security`；这些头全部依赖反向代理添加（`docs/security.md` §5）。
- 现状（2026-10-18 复核，S2 落地后）：**已覆盖**的两处——Web UI（首页与 `/static/`）由 `internal/api/embed.go` 的 `setWebUISecurityHeaders` 设 `nosniff` + `X-Frame-Options: DENY` + CSP（`default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'`）；`GET /api/files` 的所有下载设 `nosniff`，主动内容（`.html`/`.svg`/`.js` 等）强制 `application/octet-stream` + `Content-Disposition: attachment`。**仍缺**：`/api/` 的其它响应（全部 JSON 端点与统一错误响应）不带任何安全头，`Strict-Transport-Security` 一概留给反代。
- 影响：直连服务端端口（或反代配置遗漏）时，JSON 端点与错误响应仍无浏览器侧防护（错误响应可被 MIME 嗅探、API 可被跨站嵌入）；HSTS 缺失让首次明文请求可被降级。与 Web UI 把访问令牌存在同源 `localStorage`（`internal/api/web/static/app.js` 的 `seshat.token`）叠加时，尚未覆盖的入口构成残余 XSS 面。
- 建议：把安全头做成包住**全部**路由的统一中间件（而非分散在 Web UI 与文件端点两处），HSTS 按域名/TLS 就绪度决定是否由服务端下发；或在启动时检测「非环回监听且无反代标记」并告警。

## Emacs 端 uid 缓存不随服务端重建失效（M7 安全复审，2026-10-18 复核，仍未解决）
- 现象：`seshat-rest.el` 的 `seshat-rest-resolve-uid` 结果按文档键缓存；缓存既不设 TTL，也不随服务端登记表重建（DB 从零重建、uid 重新生成）或切换 base-url 而失效。
- 复核（2026-10-18）：批注模块另有一层 `seshat-reader-annotation--uid-cache`，以 `file-truename` 为键、**永不失效**，且不绑定 `base-url`——两层缓存都缺失效机制。
- 影响：服务端重建后，客户端持续用旧 uid 请求，得到 `404 unknown_uid`，表现为「批注/进度全部消失」；用户需手动清缓存或等某条路径触发重新解析。切换服务器时更隐蔽：旧 uid 会被发到**另一台**服务器，可能命中无关资源。
- 建议：① 缓存键包含 base-url；② 缓存值改为 `(base-url uid . 时间戳)`，遇到 `unknown_uid` 时失效该键并重解析一次（幂等，代价一次 `GET /api/resolve`）；③ 提供显式的清缓存命令。

## 路径规范化逻辑在四处重复（M7 安全复审，2026-10-18 复核，仍未解决；复核后实为五处）
- 现象：同一套「拒 `..`/NUL/`.` 段/`.git` 段」的规则在 `internal/api/files.go`（`cleanRelPath`）、`internal/webdav/policy.go`（`hasDotSegment`）、`internal/registry/service.go`（`normalizeResourcePath`）、`internal/registry/bootstrap.go`（`isDotName` + `SkipDir`）各写一遍。前三处已加「两处必须同步修改」注释。
- 复核（2026-10-18）：`internal/gitver/version.go` 的 `resolve` / `resolveAny` 另有第五份「拒绝点段 / 越出根」判定，注释同样只写「两处必须同步」。五份实现的集合口径并不完全一致（WebDAV 侧允许挂载根本身，`gitver` 侧按名字解析版本表达式）。
- 影响：规则演进时容易只改一处，产生「API 能写、登记层拒绝」或「出口可读、登记不可见」的死角；新增入口（如后续的 COPY/版本恢复入口）极易漏掉规则；注释只能提醒，不能阻止。
- 建议：抽出一个共享包（`internal/pathguard`，或文中的 `internal/pathspec`）提供 `Clean(rel) (string, error)` 与 `IsDotName(name) bool`，五处改为调用；并让 REST / WebDAV 两个出口共用**同一套不变量测试**（表驱动，作为唯一真源）。WebDAV 侧的 `hasDotSegment` 还需保留「挂载根不算点路径」的差异，用选项参数表达。

## `registry.Apply` 的读-改-写非原子（M7 安全复审，2026-10-18 复核，仍未解决）
- 现象：`Apply` 先用 `db.GetResourceByUID`（**事务外**）读现状判定新 uid / 事件类型，再在同一事务里 upsert 登记 + append 事件；读取点与写入点不在同一事务。
- 复核（2026-10-18）：`ApplyResourceChange` 事务之外另有 `GetResourceByUID` 读取，并发 create/delete 同一 uid 存在竞态。当前 SQLite 为单连接串行执行、且 uid 随机（16 字节 `crypto/rand`），碰撞概率极低，故实践中几乎不可复现——属「理论上成立、现实中罕见」的一类。
- 影响：并发写同一路径时两次 Apply 可能基于同一旧快照判定，导致事件类型（create/update）重复或丢失、uid 复用判断错位；与「文件已落盘」的顺序叠加后只能靠 rescan 收敛。
- 建议：把读取与写入收进同一事务（`GetResourceByUID` 增加 tx 变体），或在 storage 层提供 `ApplyIf` 形式的原子条件写；同时用并发用例（两个 goroutine 写同一路径）锁定「恰好一条 create 事件」。

## bootstrap 跳过点文件后旧登记行会被写墓碑（M7 修复轮新增记录，2026-10-18）
- 现象：`scanRoot` 把点路径（`.git` 与任何以 `.` 开头的名字）排除在 `seen` 之外；登记表里若残留修复前的点文件行，Rescan 会按「就登记而言磁盘上已不存在」为它**写墓碑**，从而产生一条 `delete` 事件。
- 影响：这是**预期的历史清理**，不是数据丢失；但客户端会看到「从未感知过的资源的 delete 事件」，若客户端把 delete 当异常告警会误报。同理，rescan 的 `deleted` 计数会 +N（N = 遗留点文件行数）。
- 建议：客户端应把「delete 一个本地不存在的 uid」视为无操作（幂等忽略）；服务端可在首次清理时记一条带计数的日志，便于运维解释 `deleted` 突增。

## WebDAV 出口不支持条件写（M7 安全复审，2026-10-18）
- 现象：`x/net/webdav` v0.61.0 的 `handlePut` 未实现 `If-Match` / `If-None-Match`，标准 WebDAV 客户端用它们做乐观锁时会被**静默忽略**（退化为无条件覆盖）。服务端自己的 `bufferedFS` / 版本化包装层也没有补上这两个头的判定；条件写只在 REST `PUT /api/files/{path...}` 上生效（见 `docs/api.md` §8.2）。
- 影响：客户端以为锁生效、实际是无条件覆盖，冲突检测完全失效且**没有任何错误信号**——比直接报错更危险（用户会信任「已加锁」假象）。经 `/dav/` 或 `/public/` 写笔记的第三方编辑器（Obsidian、calibre、文件管理器挂载等）都落在这个盲区里。
- 建议：客户端侧冲突检测改走 REST，或用 `ETag` + `GET /api/merge-base` 自行检测；根治需自定义 `bufferedFS`——写缓冲到内存/临时文件，在 `Close` 时于 `repo` 锁内调用 `WriteAndCommitIf(rel, content, msg, wantBlob, wantAbsent)`，把 WebDAV 的条件头映射成 `wantBlob` / `wantAbsent`。

## `rescan` 无频率限制（M7 安全复审，2026-10-18）
- 现象：`POST /api/resources/rescan` 只有 `Server.rescanRunning`（`atomic.Bool` CAS）做并发互斥，抢不到返回 `409 rescan_in_progress`；这只防「同时两次」，不防「串行地反复触发」——令牌持有者可以循环触发全库重扫。
- 影响：成本随「文件数 × 内容哈希」增长，单个客户端即可把机器占满（重扫期间 DB 与磁盘都在忙）；且没有审计记录可追溯谁触发了多少次。
- 建议：加最小间隔（如 60s，窗口内返回 `429` 或带 `retry_after` 的 `409`），或改为后台任务队列 + 任务 id 查询；同时记审计日志（时间、耗时、`scanned`/`deleted`/`failed` 计数）。

## `deleteListLimit = 100000` 截断（M7 安全复审，2026-10-18）
- 现象：`internal/api/files.go` 的目录删除用 `deleteListLimit = 100000` 一次列举登记行（`Limit: deleteListLimit`），超出部分不再列举。
- 影响：超大目录（>10 万条登记行）删除时，超出部分**不写墓碑**，登记表留下孤儿行；`GET /api/changes` 因而缺 `delete` 事件，客户端保留已不存在的资源，直到下一次 rescan 才收敛。
- 建议：改为分批删除（按 uid 游标循环，直到取空），或提高上限并**在截断时记警告日志**（当前是静默截断）；`docs/security.md` §8.4 的「目录删除列举上限」条目应同步说明截断后果。

## 根内软链的部署假设（M7 安全复审，2026-10-18）
- 现象：整条防护链（REST 的 `physicalPathChecked` / `rejectSymlinkAncestors`、WebDAV 的 `symlinkGuardFS`、登记层 `IsRegular` 过滤）都建立在「软链可被识别并拒绝」之上。两个出口现已各自落实守卫（WebDAV 侧见 `internal/webdav/symlink.go`，接入 `/dav/` 与 `/public/`），但**启动期仍不检查根内是否存在软链**，`docs/configuration.md` 也没有「根内不得放置软链」的前置条件。
- 影响：防护已不依赖「根内没有软链」这一假设（有软链时两侧都拒），但拒绝是**静默的**——根内一条合法用途的软链会让 WebDAV 列目录少一项（PROPFIND 对权限错误静默跳过）、REST 读到 `404`/`400`，运维难以定位原因。另：`newSymlinkGuardFS` 在根不存在或无权限时退化为 `filepath.Abs`，此时「根自身是软链」仍依赖构造期 `EvalSymlinks` 成功。
- 建议：启动时扫描每个根，发现根内软链即告警（`mirror` 根建议 fail-fast，`ondemand` 根 warn），并在 `docs/configuration.md` 写明「根内不放置软链」；同时给 `symlinkGuardFS` 的 `EvalSymlinks` 失败路径补一条启动日志。

## WebDAV 写与 REST 写的锁不对称（M7 安全复审，2026-10-18）
- 现象：REST 走 `WriteAndCommit` / `WriteAndCommitIf`——「写文件 → commit → 登记」全在 `repo` 锁内完成；WebDAV 由 `webdav.Dir` 自行把内容落盘，之后才由钩子调 `repo.Commit`，`repo` 锁只保护「暂存 + 提交」，**不覆盖落盘**。
- 影响：同一文件被 REST 与 WebDAV 并发写时存在时间窗——REST 侧在锁内读到的内容可能正被 WebDAV 侧改写，或反之；结果是一个写入被另一个静默覆盖，且事件流的 `blob` 可能与磁盘最终内容不一致（需 rescan 收敛）。
- 建议：与「WebDAV 出口不支持条件写」同根因，用同一个 `bufferedFS` 统一写路径（缓冲 → `Close` 时在锁内 `WriteAndCommitIf`），让两个出口共用同一临界区。

## 主动内容内联黑名单为枚举式（M7 安全终审，2026-10-18）
- 现象：`internal/api/files.go` 的 `activeContentExts` 是一张**枚举式**黑名单（`.html`/`.htm`/`.xhtml`/`.shtml`/`.ehtml`/`.xht`/`.svg`/`.svgz`/`.xml`/`.xsl`/`.js`/`.mjs`/`.mht`/`.rdf`）。判定只按 `path.Ext` 精确匹配，名单之外的扩展名一律按「被动内容」内联返回（带按扩展名推断的 `Content-Type`）。
- 影响：**漏项即形成 XSS 缝隙**。Go 内建 MIME 表会把 `.shtml`/`.ehtml` 映射为 `text/html`、`.xht` 映射为 `application/xhtml+xml`——这类扩展名一旦漏在名单外，服务端就会**显式声明**主动类型，`nosniff` 不阻止显式声明的类型被当作 HTML 执行，于是 `PUT` 一个 `evil.shtml` 再接 `GET /api/files/evil.shtml` 即可在服务端源下执行脚本（可读 `localStorage` 里的令牌）。本轮已补齐 6 项，但「下次 Go 新增映射」「其它厂商扩展名（如 `.xhtmlz`、`.htc`）」仍会重复此问题；WebDAV 出口连这层强制下载都没有。
- 建议：反转为「安全类型**白名单**才内联」——只有明确的被动类型（文本笔记、图片、PDF 等）按其推断类型返回，其余一律 `application/octet-stream` + `attachment`；同时 WebDAV 侧对同一份名单同样强制 `attachment`（当前 `Content-Type` 由客户端自行解释，浏览器在 Basic 认证后可能按扩展名内联渲染），并把名单抽成单一真源供 REST / WebDAV 共用。

## 阅读器进度推送仅在 onStop 触发一次（M9.2 T4c，2026-10-18）
- 现状：Android 阅读器（EPUB / PDF）的进度推送只在 `onStop` 触发一次，没有定时/防抖队列；`lastPushedPosition` 的同值跳过只是防抖，不是严格节流。
- 影响：进程被强杀（从最近任务划掉、系统低内存回收）时 `onStop` 可能不执行，最后一次位置可能不同步；下次打开时若本地有进度不会自动拉取远端（见 M9.2 A 批的「本地无进度才 pull」限制），远端会停留在旧值。
- 建议：改为「离开时合并推送 + 失败重试」的后台任务（如 WorkManager 单次任务），并把 pull 策略从「本地无进度才拉」升级为「比较 `updated_at` 后取较新者」。

## `ResourceIndex` 缓存无锁（M9.2 A 批代码审查，2026-10-18）
- 现状：`ResourceIndex` 用一个惰性 `cached` 文档字段做读写缓存，读写全程加锁为 0 次；A 批明确假定「单线程串行调用」（同步流程在单一协程/线程内跑完），KDoc 已标注该前提。
- 影响：一旦 B 批接线让同步流程跨线程（如 `SyncEngine.pull` 在 IO 线程、书架 UI 在主线程查 `findByUid`），`cached` 的「读—改—写」会互踩：条目丢失、`cursor` 回退，甚至整份文档被旧快照覆盖；`SharedPreferences` 自身的线程安全救不了这个内存缓存。
- 建议：B 批接线时二选一——给 `ResourceIndex` 补 `@Synchronized` / `ReentrantLock`（简单，但与 IO 落盘同锁会拉长临界区），或强制所有访问串行到单一 dispatcher（`Dispatchers.Main.immediate` 或单线程 IO），并在文档里写成不变量 + 加一个跨线程测试。

## 索引仍是单文件全量重写（M9.2 A 批代码审查，2026-10-18）
- 现状：`upsertAll` 已把「一批 create/update 一次落盘」的写放大消掉（原逐条 `upsert` 是 O(N²)），但 `rename` / `markDeleted` / `setCursor` 依然是**单次全量重写**：一次 bootstrap 若被 rename/delete 事件打散成很多段，写盘次数仍随事件数增长。
- 影响：面向「数千条资源 / 数百 KB」设计，条目上万后每次重写都要序列化整份 JSON 并 `apply()` 到 `SharedPreferences`，主线程外也会明显卡顿，且 GC 压力随条目数线性上涨。
- 建议：万级以上（或需要按 `root`/`path` 索引查询、按 root 局部更新）时迁移到 Room/SQLite：`entries(uid PRIMARY KEY, root, path, blob, size, mtime, deleted, dirty)` + 单行 `cursor` 表，`upsertAll` 走单事务；迁移前可在 `rename`/`markDeleted` 上先做「批量版本」（同 `upsertAll` 思路）。

## 离线键仍是旧形态，与 legacy 键无法区分（M9.2 A 批代码审查，2026-10-18）
- 现状：无 uid（离线未登记）时，Store 的键仍是旧形态——32 位 hex 内容哈希，或含 `:` 的 uri 形态；这类键与迁移前的 legacy 键**在形态上完全一致**，无法从键本身判断「这是合法离线数据」还是「迁移遗留垃圾」。
- 影响：清理逻辑的安全性完全依赖 `legacy_cleared` 这一次性标记。标记一旦被清除（用户清数据后重装、迁移中途崩溃后重跑、或有人手动清 prefs），下次启动就会把合法的离线进度/批注当成 legacy 一并删掉——**静默丢用户数据**，且无任何日志线索。
- 建议：给离线键加可识别前缀（如 `local:` 或 `offline-<hash>`）并保留旧形态的**只读兼容读取**；`legacy_cleared` 从「布尔标记」升级为「带时间的版本号」，清理只针对版本低于当前迁移版本的键，且清理前记录一条将被删除的键数量日志。

## `ConnectivityTester` 对旧服务端只报 `ServerError(404)`（M9.2 A 批代码审查，2026-10-18）
- 现状：连接测试打的是 `/api/roots`；旧版本服务端没有该路由，返回 404，客户端统一映射为 `ServerError(404)`，与「路由存在但路径写错」无法区分。
- 影响：用户升级 Android 端后连旧服务端，只会看到一条语焉不详的 404 错误，排查方向容易跑偏（去查 URL/令牌，而真实原因是服务端版本过旧）。
- 建议：设置页对 `ServerError(404)` 给出专门文案「服务端版本可能过旧（需支持 `/api/roots`）」，并优先改用带版本号的探测端点（如 `/api/health` 或 `/api/version`）判断兼容性；条件允许时返回明确的状态码/错误码而非裸 404。

## `pushAnnotations` 的 N+1 请求与 epub/pdf `updatedAt` 语义不一致（M9.2 A 批代码审查，2026-10-18）
- 现状：`SyncManager.pushAnnotations` 每次同步都先 `listAnnotations` 拉全量再逐条 `createAnnotation`，新增 N 条批注即 N+1 次请求，且无增量游标；同时两侧进度的 `updatedAt` 语义不同——`ReadingProgressStore.save` 在 `updatedAt == 0` 时自动补当前时间（冲突检测恒生效、且每次保存都推进时间戳），`PdfProgressStore` 原样保留 0 → `mapUpdatedAt` 返回 `null` → 服务端不做冲突检测，「最后写胜」。
- 影响：批注多的书同步耗时与流量随条数线性增长，弱网下极易半途失败（已推送的一部分留在远端、下次重跑靠 `location + text` 去重才收敛）；两侧冲突检测行为不一致会让「同一台设备上 epub 冲突被拒、pdf 冲突被覆盖」成为难以复现的怪现象。
- 建议：批注推送改批量端点（`POST /api/annotations/batch`）或带 `since` 的增量拉取 + 客户端待推队列；`updatedAt` 语义统一为「0 = 未知、一律传 `null`」，把「补当前时间」的逻辑从 `ReadingProgressStore` 上移到 `SyncManager` 显式决策（并在 KDoc 写明两侧一致性约束）。

## B 批文件同步未开工（M9.2 A 批，2026-10-18）
- 现状：A 批只交付只读协议（`/api/roots`、`/api/resources`、`/api/resolve`、`/api/changes`）+ 本地索引 + 增量引擎，**未做任何文件读写**：`GET|PUT|DELETE /api/files`、`POST /api/resources/{uid}/move`、`GET /api/resources/{uid}`（补 `size`/`mtime`）均未接入，书架也尚未接线 `SyncEngine`（`ResourceIndex`/`SyncEngine` 当前无调用方）。
- 影响：应用**不能通过服务端读写书籍文件**——只能打开本机 SAF 选择或导入的文件；远端新增的书不会出现在书架，`/api/changes` 带来的新条目 `size=0/mtime=0` 无法回填，按大小/时间排序与展示会失真；改名/移动后的路径也无法跟随。
- 建议：B 批另立计划——先回填元数据（`GET /api/resources` 或 `GET /api/resources/{uid}`，回填后清 `dirty`），再实现 `/api/files` 的按需下载/上传与 `move`，最后把 `SyncEngine.bootstrap/pull` 接到「书架打开 + 下拉刷新」，并同步补 `ResourceIndex` 的并发保护（见「`ResourceIndex` 缓存无锁」条）。

## 旧数据不迁移，`clearLegacy` 是真删除（M9.2 A 批，2026-10-18）
- 现状：五个 Store（`ReadingProgressStore`、epub `AnnotationStore`、`PdfProgressStore`、`PdfAnnotationStore`、`PdfInkStore`）的 `clearLegacy()` 按「32 位十六进制 / 含 `:`」判定旧键并**物理删除**，不做迁移、不做双读，由各 prefs 文件的 `legacy_cleared` 一次性标记控制。
- 影响：升级后旧键名下的本地进度、批注、PDF 笔迹**永久丢失**且无备份、无回滚路径。当前可接受（服务端与客户端均未部署，存量数据为零），但一旦有真实用户数据，「首启静默删除」就是不可恢复的数据事故；若删除时不记日志，事后连「丢了什么」都无从查证。
- 建议：正式发布前二选一——① 改为「旧键保留只读 + 惰性迁移到 uid 名下」；② 保留删除语义但先写一条可审计日志（含删除键数量）并在首次启动给出可关闭的提示。另需配合「离线键仍是旧形态」条，避免清理逻辑误伤无 uid 的合法离线数据。

## `/api/changes` 不含 `size` / `mtime`（M9.2 A 批，2026-10-18）
- 现状：`GET /api/changes` 的事件只有 `seq`/`uid`/`op`/`root`/`path`/`old_path`/`blob`/`rev`/`changed_at`；`SyncEngine.buildEntry` 只能继承索引里已有的 `size`/`mtime`，全新 `create` 条目写 `size=0`、`mtime=0` 并置 `dirty=true`。
- 影响：书架按大小或修改时间排序、展示「最近添加」都会失真（全部为 0 或顺序错乱）；`dirty` 条目的回填依赖一次额外的 `/api/resources` 查询，B 批若漏做，会表现为「新书全排在最前/最后」这类难以归因的 UI 现象，且 `dirty` 标记本身没有消费方时永远不清。
- 建议：B 批在 `pull` 后对 `dirty` 条目批量调 `GET /api/resources?root=&limit=` 回填并清 `dirty`；或推动服务端在 `changes` 事件里附带 `size`/`mtime`（代价是事件体积与墓碑语义的额外定义）。

## `PUT /api/files` 单次上限 32 MiB，`GET` 的 `Range` / `If-None-Match` 未接入（M9.2 A 批，2026-10-18）
- 现状：服务端 `PUT /api/files/{path...}` 单次请求体上限 **32 MiB**，`GET` 支持单区间 `Range` 与 `If-None-Match`（304）；Android 客户端尚未实现文件上传/下载，`RestClient` 里也没有这两个端点的封装。
- 影响：B 批实现上传时，超过 32 MiB 的 PDF/EPUB 会被服务端直接拒绝（需分片或改走 WebDAV），若客户端不预先检查就会表现为「大文件上传神秘失败」；不实现 `Range` 则无法断点续传，不实现 `If-None-Match` 则每次都要整份重下——书库场景下流量与耗时都不可接受。
- 建议：B 批按「小文件直传 `PUT`，超限回退 WebDAV 或分片；下载用 `Range` + `If-None-Match`/ETag 做增量与断点续传」实现，并把 32 MiB 上限写成客户端常量（错误前置到选文件阶段）并写入 `docs/android.md`。

## `SyncEngine` 丢弃了 `rev`（M9.2 A 批，2026-10-18）
- 现状：`ChangeDto` 有 `rev`（40 位 git blob sha1），但本地 `ResourceEntry` 没有该字段，`SyncEngine.apply` 直接丢弃；`/api/resources` 返回的 `ResourceDto.rev` 同样未持久化。
- 影响：**无法做条件更新**——`PUT /api/files` 的 `If-Match` 需要 ETag/`rev`，本地没有 `rev` 就只能无条件覆盖，并发写会互相静默覆盖（服务端 `412 etag_mismatch` 的乐观锁形同虚设）；也无法用「`rev` 未变」跳过重复下载，一致性判定只能依赖 `size`/`mtime` 这类弱信号。
- 建议：B 批给 `ResourceEntry` 增加 `rev` 字段，create/update 时写入，上传/下载时用作 `If-Match` 与「是否已最新」的判据；schema 变更需处理旧索引 JSON 的缺省值（`rev = ""`）与依赖 `clear()` + `bootstrap()` 的重建路径。

## EPUB 目录无层级（M10.6 B2，2026-10-18）
- 现状：`TocEntry` 只有标题/位置，没有 `depth` 字段；`parseNav` 与 `parseNcx` 在解析时已把树形目录**扁平化**为一级列表，目录对话框因此只能平铺展示。
- 影响：技术书/小说常有多级目录（卷→章→节），扁平化后层级信息丢失，用户无法看出归属关系；且这是**解析期**丢失，UI 侧无法补救（要恢复层级必须重解析）。
- 建议：给 `TocEntry` 增加 `depth: Int`（解析 nav 的嵌套 `<ol>` 或 NCX 的 `playOrder`/嵌套 `navPoint` 时记录），目录对话框按 `depth` 做缩进；`parseNav`/`parseNcx` 的扁平化逻辑需补单测（含 3 层嵌套算例）。

## PDF 无 TOC 数据源（M10.6 B2，2026-10-18）
- 现状：Android 内置 `PdfRenderer` 只暴露页数与逐页渲染，**不提供 outline/书签（TOC）**；未引入第三方 PDF 解析库（零新增依赖约束）。
- 影响：PDF 阅读器没有「目录」入口，长文档只能靠 `SeekBar` 或输入页号跳转；与 EPUB 侧交互不对称。
- 建议：若要补，需引入能解析 `/Outlines` 的库（如 PdfBox-Android，违反零新增依赖）或自行解析 PDF 对象（成本高、易错）；短期维持不做，在 `docs/android.md` 明示「PDF 无 TOC」。

## 浮层隐藏后阅读区 padding 仍保留（M10.6 B2，2026-10-18）
- 现状：`applyChromePadding()` 一次性（高度变化时）把浮层高度写入阅读区底部 padding，`toggleChrome()` 只切浮层可见性，**不回收** padding。
- 影响：沉浸阅读（隐藏浮层）时底部仍留一条与浮层等高的空白，竖向模式下「页尾到底」的观感与真正全屏不同；且浮层显隐后内容不重新铺满，用户可能误以为内容没加载完。
- 建议：若要真正全屏，需在 `toggleChrome()` 里按可见性重设 padding（0 / 浮层高度）——代价是每次显隐都触发 RecyclerView 重新布局，滚动位置与 `PagerSnapHelper` 吸附会出现抖动；可考虑用 `setPadding` + `requestLayout` 前后记录并恢复 `scrollToPositionWithOffset` 抵消抖动，需真机实测是否可接受。

## SeekBar 精度受章节/页数上限约束（M10.6 B2，2026-10-18）
- 现状：底部 `SeekBar` 的 `max` = 章数-1 / 页数-1，`SeekBar` 的可用像素宽度有限（手机横屏约 200–300px）。
- 影响：章节/页数超过约 1000 时，一像素跨多项，轻拖就跳好几章/页，精细定位不可行；页数极小的文档（2–3 页）又几乎无拖动余地（单页时已禁用）。
- 建议：保留「点标题/页码输入数字」作为精确跳转兜底（已实现）；若后续需要更细粒度，可改为「拖动时按比例预显示目标章/页（不改位置）+ 松手跳转」并允许拖动超出 `max` 的连续取值（自定义 slider），或增加「上一章/下一章」快捷按钮。

## 浮层化改变阅读区高度带来的进度语义偏移（M10.6 B2，2026-10-18）
- 现状：B2b 起阅读区改为全屏 + 底部 padding = 浮层高度（约 40–56dp）。旧进度 `scrollY` 语义（相对章内 `WebView` 滚动量）不变，但「中心章」判定基准变为可见区中心，中心点相对旧实现下移约 40dp。
- 影响：章边界附近（末尾约 40dp 的内容）可能被判定为「已进入下一章」，与旧版本记录的章节号出现 ±1 偏差；跨版本续读时表现为「打开后标题显示的章比上次记录的多一章」。
- 建议：短期可接受（只在章尾窄带内出现）；若要严格一致，可在 `ScrollProgressMath` 的中心章判定里把 padding 计入并写单测固定语义；或在进度里显式记录「计算基准版本」，迁移时按版本换算。
