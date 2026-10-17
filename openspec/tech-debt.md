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
