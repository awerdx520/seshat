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

## define-derived-mode 内重复运行 mode hook（M11.2c，2026-10-16）
- `seshat-reader.el` 的 `define-derived-mode` 体内手工 `(run-hooks 'seshat-reader-mode-hook)`（由来：上游原样带入，经与上游源码逐行对照确认）；`define-derived-mode` 本身已自动执行 mode hook，理论上会执行两次。现有 hook 均幂等、无可见危害，改名未触碰该逻辑；若要修须单独评估行为影响。

## 批注缺备注字段（M11.3，2026-10-16）
- 服务端 annotations 表只有 `text`，Emacs 侧用「选中文本」作正文；高亮 + 备注的完整语义需 schema 扩展。

## EPUB location 未定（M11.3，2026-10-16）
- 本步只定义 PDF 的 `page:<n>;rect:…`；EPUB 约定（CFI vs `chapter:x`）仍待 M10.3。

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
