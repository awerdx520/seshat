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

## evil 键位自维护（M11.2c，2026-10-12）——已解决（2026-10-26，阅读器关闭 evil、键位改由包内 mode-map 承担）
- evil-collection 的 reader 支持绑定硬编码于 `reader-mode-map`（且以 `eval-after-load 'reader` 触发），改名后不再生效；本地在 `thomas-emacs/lisp/init-evil.el` 重建 49 条绑定（含 outline 6 条），上游更新不会自动同步。
- 解决：2026-10-26 起阅读器全部 buffer 关闭 evil（`seshat-reader--disable-evil` / `evil-local-mode -1`，受 `seshat-reader-disable-evil` 控制），键位由包内 `seshat-reader-mode-map` 与各面板 mode-map 唯一承担，evil 侧不再需要任何 seshat 绑定；包内三处补绑实现（`--install-evil-bindings` ×2、`--ensure-panel-evil-keys`）与 `thomas-emacs/lisp/init-evil.el` 的 49 条绑定一并删除，双份维护消失。

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

## 页面高亮缺口（M11.3，2026-10-16）——已解决（M12，2026-10-22）
- 批注在页面上无可视化，只能通过列表查看与跳页；需改 C 渲染器（另立里程碑）。
- 解决：M12 在 C 渲染层绘制 `rect` 高亮——`draw_page_thread` 在反色之后、写 PNM 之前用 `fz_new_draw_device` + `fz_rectto` + `fz_fill_path` 绘制半透明矩形，复用页面同一 `ctm`（缩放/旋转自动对齐）；elisp 侧 `seshat-reader-annotation--apply-highlights` 按 `location` 的 `rect:` 段投喂。
- 遗留：`ink:`（手写笔迹）段仍不显示，另见「Emacs 端仍不显示手写笔迹（`ink:` 段）」条目。

## 离线队列缺失（M11.3，2026-10-16）
- REST 失败即报错，无本地暂存与重试。

## REST 封装的非 2xx 语义（M11.3，2026-10-16）
- `seshat-rest--json` 对非 2xx 返回 nil 而非抛错，调用方无法区分「空结果」与「失败」；批注模块已绕开（自行判状态码），但该局限仍在封装层。

## http_proxy 隐患（M11.3，2026-10-16）
- 环境设置了 `http_proxy`，Emacs `url.el` 对本地地址会打印 "Using a proxy for http..."；依赖 `no_proxy` 才正确直连，配置本地服务端时需注意。

## L3 端到端待补（M11.3，2026-10-16）
- M11.3 的服务端闭环验证因服务端不可用而未执行，启动方式见 `docs/configuration.md` 与 `deploy/`（密钥不入库）。

## evil 遮蔽 major-mode 的鼠标绑定（M11.3，2026-10-16）——已解决（2026-10-26，阅读器相关 buffer 关闭 evil）
- evil 经 `emulation-mode-map-alists` 把 `[down-mouse-1]` 解析到 `evil-mouse-drag-region`，优先于 major-mode-map；`seshat-reader-mode-map` 上既有的 `<remap> mouse-drag-region → ignore` 亦无法拦截（evil 走的是 `evil-mouse-drag-region`，不是 `mouse-drag-region`）。
- 影响所有依赖 `down-mouse-1` 的 major-mode 级交互（如 seshat-reader 的鼠标拖拽选区取文）。
- 当前在 `thomas-emacs/lisp/init-evil.el` 侧以 normal state 显式重绑规避。
- 根治需上游 evil 提供更细的 state 映射策略或改用 aux keymap 的更明确写法。
- 2026-10-26 两次修正：① 只在 mode body 里 `evil-local-mode -1` 无效（evil 的 globalized 启用更晚）；② 在 `after-change-major-mode-hook` 末尾 append 再关一次也无效（实测 evil 仍在其后开启）。最终做法：给 reader 系四个 major mode 设 `emacs` initial state（`seshat-reader--evil-set-initial-states`），判据 `(key-binding [down-mouse-1])` = `seshat-reader-select-drag` 且 `evil-state` = `emacs`。

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

## `rect` 无高亮承载（M11.4，2026-10-17）——已解决（M12，2026-10-22）
- 影响：`seshat:` 链接与摘录可携带 `;rect:<x0>,<y0>,<x1>,<y1>`，但阅读器页面上没有任何矩形可视化，用户只能看到「第 n 页」。
- 现状：页面高亮缺口与 M11.3 同源，需改 C 渲染器（另立里程碑）；当前 rect 仅作数据保留，为将来的高亮与精确定位留位。
- 解决：同「页面高亮缺口（M11.3）」——C 层绘制 `rect` 半透明高亮，`seshat:` 链接与摘录携带的 `rect:` 段现在既有格式校验也有页面可视化。

## `:complete` 未实现（M11.4，2026-10-17）——已解决（M12，2026-10-22）
- 影响：笔记里输入 `seshat:` 链接无法补全 doc-id / location，只能手写或从阅读器 `org-store-link` 存出。
- 建议：`org-link-set-parameters "seshat"` 增 `:complete`，候选来自 `seshat-reader-annotation-roots` 下的文件清单（或 M7 的 uid 目录接口）；当前不在范围。
- 解决：M12 T11 注册 `:complete`，候选来自 `seshat-reader-annotation-roots` 的文件清单（doc-id 形态，可选补 `#page:<n>`）；含 `#`/`%` 的文档名仍按既有约定报错（另见「含 `#`/`%` 的文档名不支持引用」）。

## 摘录固定末尾插入（M11.4，2026-10-17）——已解决（M12，2026-10-22）
- 影响：`seshat-reader-reference-insert` 一律把摘录块**追加到目标笔记文件末尾**，不识别 headline/光标位置，长笔记中会越积越乱。
- 建议：加目标定位（交互选 headline 或 `org-capture` 模板）；当前靠用户配置固定落点文件 + 事后整理规避。
- 解决：M12 T13 新增 defcustom `seshat-reader-reference-insert-position`（`end-of-file` 默认 / `headline` / `point`）与纯函数 `seshat-reader-reference--insert-position`；`headline` 模式插到**当前子树末尾**（含子标题之后、下一个同级/更高级 headline 之前），无 visiting buffer 时回退 `append-to-file`。

## 含 `#`/`%` 的文档名不支持引用（M11.4，2026-10-17）
- 影响：`doc-id`（`<标签>:<相对路径>`）含 `#` 或 `%` 时生成链接直接 `user-error`（提示重命名），这类电子书无法建立 `seshat:` 引用。
- 理由：本实现刻意不做百分号转义（`url-hexify-string` 会转义 `:`/`/`，org 又对 `%` 二次转义）。根治需协议层引入转义或改用 uid 承载身份（M7）。

## `:export` 未定制（M11.4，2026-10-17）——已解决（M12，2026-10-22）
- 影响：导出（HTML/LaTeX 等）时 `seshat:` 链接走 org 默认行为，输出为无法点击的原始协议串。
- 现状：本步只需要在 Emacs 内跳转，未注册 `:export`；将来如需导出阅读笔记，再补 `:export`（可导出为 `seshat:<doc-id>#<location>` 文本或转成脚注）。
- 解决：M12 T12 注册 `:export`（`seshat-reader-reference-export-link`），输出「文件名 第 N 页」可读文本而非裸协议串；形态取「可读文本」不取 org 脚注——脚注会在表格/标题等受限上下文插入 `[fn:]` 引用并产生排版噪声，而该链接本身没有可跳转目标，纯文本更诚实。所有后端（`html` / `latex` / `ascii` / `md`）输出同一份纯文本，不生成假 URL。

## `--parse-link` 对尾部 `#` 返回空串 location（M11.4，2026-10-17）——已解决（M12，2026-10-22）
- 影响：`seshat:ebook:a.pdf#` 解析出 `location` 为空串而非 nil，与「无 location」语义不一致（对称性小瑕疵）。
- 现状：不影响功能（空串与 nil 在下游都当作「无 location」处理）；修法是把解析结果空串归一为 nil。
- 解决：M12 T14 把解析结果的空串归一为 nil，`seshat:ebook:a.pdf#` 现返回 `location` = nil；ERT 覆盖该用例。

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

## 包内窗口语义不统一（M11.7，2026-10-17）——已解决（M12，2026-10-22）
- 影响：`seshat-reader-outline` 与 `seshat-reader-reference`（以及 M11.4 的 `:follow` 跳页）仍用 `pop-to-buffer`，不受 `seshat-reader-sidebar-enabled`/`position` 管辖；用户在不同命令间会遇到两套窗口行为。
- 建议：后续把 outline/目录类 buffer 也接入 sidebar 承载层（需先确认 nav 类面板与阅读区的布局关系）。
- 解决：M12 T4 把目录面板接入 `seshat-reader-sidebar-show`（`sidebar-show buf 'outline`，`sidebar-enabled` 为 nil 时由 `sidebar-show` 内部回退 `pop-to-buffer`），并新增 `seshat-reader-outline-sidebar-position`（默认 `left`）+ `C-c C-o` → `seshat-reader-sidebar-toggle-outline`。目录、批注、译文现同受 sidebar 承载层管辖（三栏 side window 共存）。

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

## 全局入口 `SPC o P`（M11.8，2026-10-17）——已解决（M11.8 T6，2026-10-27）
- 影响：面板只能从阅读器/批注命令内拉起，没有跨 buffer 的全局开关键（`seshat-reader-sidebar-toggle` 需 `M-x` 或 buffer 内 `q` 键）；面板内键位已由 M11.9 的 ETAF `:keys` 承担，但 `:keys` 只作用于面板 buffer 内部，技术上无法承担全局入口。
- 建议：在 `thomas-emacs/lisp/init-keybind.el`（或 `init-reader.el`）加 `SPC o P` 前缀与 4 个绑定（`p` 批注 / `a` 添加 / `t` 翻译 / `e` 解释，以最终配置为准）；仅在 evil 的 normal/visual/motion 态生效（`leader!` 定义域）。
- 解决：落在 `/home/thomas/thomas-emacs/lisp/init-reader.el` 的 `use-package seshat-reader` `:general` 段——`oP` 前缀 + 4 个绑定：`SPC o P p` → `seshat-reader-sidebar-toggle`（开合全部面板，无面板时重开最近一个）、`SPC o P a` → `seshat-reader-annotation-list`（批注列表）、`SPC o P t` → `seshat-reader-translate-selection`（翻译最近选区）、`SPC o P e` → `seshat-reader-translate-explain-selection`（解释最近选区）；包内零改动（四个命令早已存在）。键义与上述「建议」略有出入：`p` 落地为开合、`a` 为批注列表。生效域沿用 `leader!` 定义域（`:states '(normal visual motion)` + `:keymaps 'override`），故只在 evil 的 normal/visual/motion 态生效，insert/emacs 态无绑定；阅读 buffer 内仍用包内 `C-c C-o`，面板内 `q`。放在 `use-package seshat-reader`（无 `:defer`，启动即加载）的 `:general`，而非 `use-package seshat-reader-sidebar`（`:defer t`，绑定要等包加载才建立，首次打开面板前 `SPC o P` 是空的）。验证：`make -C /home/thomas/thomas-emacs full-check` EXIT=0（括号检查「所有文件括号检查通过。」/ `mcp-register-check` MCP registration OK（20 自定义 spec）/ ERT `Ran 271 tests, 270 results as expected, 0 unexpected, 1 skipped`）；verify 隔离实例四条 `key-binding` 断言全 PASS 且 `SPC o P` 前缀 `keymapp = t`。

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
- 解决（M10.6 B3/B4）：`ReaderFragment` 已接书架（B3），`NotesFragment` 已接 org 列表 / 搜索 / 编辑 / Agenda（B4）；本条的「占位」现状不再成立，仅留作历史记录。

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

## ERT 假绿判据（M7，2026-10-18）——已解决（2026-10-27 已随 P1 多页布局改造失效/解决：由 `make -C emacs/tests ert` 固化为不变量）
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

## 安全响应头覆盖不全（M7 安全复审，2026-10-18，部分解决）——已解决（A 批，2026-10-26，除 HSTS）
- 现象（原）：服务端自身不设 `X-Content-Type-Options: nosniff`、`X-Frame-Options`、`X-XSS-Protection`、CSP，也没有 `Strict-Transport-Security`；这些头全部依赖反向代理添加（`docs/security.md` §5）。
- 现状（2026-10-18 复核，S2 落地后）：**已覆盖**的两处——Web UI（首页与 `/static/`）由 `internal/api/embed.go` 的 `setWebUISecurityHeaders` 设 `nosniff` + `X-Frame-Options: DENY` + CSP（`default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'`）；`GET /api/files` 的所有下载设 `nosniff`，主动内容（`.html`/`.svg`/`.js` 等）强制 `application/octet-stream` + `Content-Disposition: attachment`。**仍缺**：`/api/` 的其它响应（全部 JSON 端点与统一错误响应）不带任何安全头，`Strict-Transport-Security` 一概留给反代。
- 影响：直连服务端端口（或反代配置遗漏）时，JSON 端点与错误响应仍无浏览器侧防护（错误响应可被 MIME 嗅探、API 可被跨站嵌入）；HSTS 缺失让首次明文请求可被降级。与 Web UI 把访问令牌存在同源 `localStorage`（`internal/api/web/static/app.js` 的 `seshat.token`）叠加时，尚未覆盖的入口构成残余 XSS 面。
- 建议：把安全头做成包住**全部**路由的统一中间件（而非分散在 Web UI 与文件端点两处），HSTS 按域名/TLS 就绪度决定是否由服务端下发；或在启动时检测「非环回监听且无反代标记」并告警。
- 已解决（A 批，2026-10-26）：新增 `internal/api/security.go` 的 `securityHeaders` 中间件，套在 `handler()` 返回的整棵 mux 外层——`/api/`（含 200 JSON、401/4xx/5xx 错误响应）、Web UI 首页、`/static/`、mux 产生的 404/405 全部带 `X-Content-Type-Options: nosniff` + `X-Frame-Options: DENY` + `Referrer-Policy: no-referrer`。中间件**刻意不设 CSP**（会覆盖 Web UI 含 `script-src 'self'` 的那份、拦掉 `app.js`），CSP 仍由 `setWebUISecurityHeaders` 负责。`/dav/` 与 `/public/` 另由 `internal/webdav/security.go` 的 `SandboxContent` 加 `nosniff` + `CSP: sandbox`。
- 未解决部分（明确保留）：`Strict-Transport-Security` **仍不由服务端下发**——TLS 在反向代理终止，服务端判断不了真实 scheme；加一个永远默认关闭的配置项只会增加配置面与文档面。反代的 HSTS 配置行与检查清单项见 `docs/deploy.md` §7 / §11，决策理由见 `openspec/decisions.md` 2026-10-26 条。

## Emacs 端 uid 缓存不随服务端重建失效（M7 安全复审，2026-10-18 复核，仍未解决）
- 现象：`seshat-rest.el` 的 `seshat-rest-resolve-uid` 结果按文档键缓存；缓存既不设 TTL，也不随服务端登记表重建（DB 从零重建、uid 重新生成）或切换 base-url 而失效。
- 复核（2026-10-18）：批注模块另有一层 `seshat-reader-annotation--uid-cache`，以 `file-truename` 为键、**永不失效**，且不绑定 `base-url`——两层缓存都缺失效机制。
- 影响：服务端重建后，客户端持续用旧 uid 请求，得到 `404 unknown_uid`，表现为「批注/进度全部消失」；用户需手动清缓存或等某条路径触发重新解析。切换服务器时更隐蔽：旧 uid 会被发到**另一台**服务器，可能命中无关资源。
- 建议：① 缓存键包含 base-url；② 缓存值改为 `(base-url uid . 时间戳)`，遇到 `unknown_uid` 时失效该键并重解析一次（幂等，代价一次 `GET /api/resolve`）；③ 提供显式的清缓存命令。

## 路径规范化逻辑在四处重复（M7 安全复审，2026-10-18 复核，复核后实为五处）——已解决（A 批，2026-10-26，抽 `internal/pathguard`）
- 现象：同一套「拒 `..`/NUL/`.` 段/`.git` 段」的规则在 `internal/api/files.go`（`cleanRelPath`）、`internal/webdav/policy.go`（`hasDotSegment`）、`internal/registry/service.go`（`normalizeResourcePath`）、`internal/registry/bootstrap.go`（`isDotName` + `SkipDir`）各写一遍。前三处已加「两处必须同步修改」注释。
- 复核（2026-10-18）：`internal/gitver/version.go` 的 `resolve` / `resolveAny` 另有第五份「拒绝点段 / 越出根」判定，注释同样只写「两处必须同步」。五份实现的集合口径并不完全一致（WebDAV 侧允许挂载根本身，`gitver` 侧按名字解析版本表达式）。
- 影响：规则演进时容易只改一处，产生「API 能写、登记层拒绝」或「出口可读、登记不可见」的死角；新增入口（如后续的 COPY/版本恢复入口）极易漏掉规则；注释只能提醒，不能阻止。
- 建议：抽出一个共享包（`internal/pathguard`，或文中的 `internal/pathspec`）提供 `Clean(rel) (string, error)` 与 `IsDotName(name) bool`，五处改为调用；并让 REST / WebDAV 两个出口共用**同一套不变量测试**（表驱动，作为唯一真源）。WebDAV 侧的 `hasDotSegment` 还需保留「挂载根不算点路径」的差异，用选项参数表达。
- 已解决（A 批，2026-10-26）：新增 `internal/pathguard`（`CleanRel(rel, Options)` / `IsDotName` / `HasDotSegment`），五处改为薄包装——保留原函数名与签名，只做 TrimSpace（部分入口）+ 把哨兵错误包成本入口既有的错误码与中文文案，**对外错误码与文案零变化**。`Options` 零值即最严格（拒空、拒 `..` 段、拒点段），三个开关只能放宽；WebDAV 出口（`hasDotSegment` 的挂载根放行 + `..` 折叠）与 `gitver.resolve`（三个开关全开）两处特例改为**显式传参**。抽取前后用 12 个输入（`a/../b`、`../x`、`a/b/..`、`.git/x`、`A.GIT/x`、`.hidden`、含 NUL、纯空白、`//a.org`、`/a.org`、`a/./b`、`a//b`）逐条比对，输出**逐字节一致**；`HasDotSegment` 改传 `AllowDotSegments: true` 后 13 个输入 0 差异。见 `openspec/decisions.md` 2026-10-26 条与 `openspec/completed/2026-10-26-server-techdebt-batch-a.md`。
- 本条的**残余**（新增记录，A 批，2026-10-26）：三处仍是纯折叠（只 `path.Clean` 去前导斜杠，不判点段、不判 `..`）——`internal/gitver/merge.go` 的 `cleanTreePath`（git tree 条目名规范化）、`internal/webdav/symlink.go` 的 `cleanRel`（软链守卫里的请求路径规范化）、`internal/webdav/versioned.go` 的 `blobPath`（版本化包装层的 blob 路径拼接）。三者的入参都先经各自出口的 pathguard 判定、或来自 git tree（非客户端直传），当前**不构成绕过**；但「新增路径入口必须调 pathguard」这条不变量对它们尚未成立，故本条不作完全关闭。
- 不变量（A 批确立）：新增任何路径入口都必须调用 `pathguard`，不得自写 `path.Clean("/"+…)`。判据是「入参是否来自客户端或文件名」——新增 HTTP 端点、新的 WebDAV 包装层、新的版本查询入口都算。

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

## `rescan` 无频率限制（M7 安全复审，2026-10-18）——已解决（A 批，2026-10-26，60s + 429）
- 现象：`POST /api/resources/rescan` 只有 `Server.rescanRunning`（`atomic.Bool` CAS）做并发互斥，抢不到返回 `409 rescan_in_progress`；这只防「同时两次」，不防「串行地反复触发」——令牌持有者可以循环触发全库重扫。
- 影响：成本随「文件数 × 内容哈希」增长，单个客户端即可把机器占满（重扫期间 DB 与磁盘都在忙）；且没有审计记录可追溯谁触发了多少次。
- 建议：加最小间隔（如 60s，窗口内返回 `429` 或带 `retry_after` 的 `409`），或改为后台任务队列 + 任务 id 查询；同时记审计日志（时间、耗时、`scanned`/`deleted`/`failed` 计数）。
- 已解决（A 批，2026-10-26，最小间隔部分）：新增错误码 `rate_limited`（`internal/logging` 的 `ErrRateLimited` → `statusForCode` 的 `http.StatusTooManyRequests`）+ `Retry-After`（秒，向上取整且 ≥1）；包级 `var rescanMinInterval = 60 * time.Second`（**非配置项**，仅测试覆写）。`Server.rescanLastAt`（`atomic.Int64`）记「上一次重扫**结束**的时刻」，故并发到达的请求看到旧值 → 只有 1 个抢到 CAS、其余 `409`（正在进行中 ≠ 被限流），串行第二次在结束后 60s 内才 `429`。`429` 分支**不抢占互斥锁、不写 lastAt**：重试既不能延长禁用窗口，也无后端成本；失败的重扫同样写 lastAt，防止用注定失败的请求刷频。单实例部署下进程内限流等价于全局。
- 未解决部分：**审计记录没做**（仍是常规 `slog` 日志，无「谁在何时触发了几次」的独立审计）；后台任务队列方案未做。

## `deleteListLimit = 100000` 截断（M7 安全复审，2026-10-18）——降级（A 批，2026-10-26：截断已可见，分批删除留 B 批）
- 现象：`internal/api/files.go` 的目录删除用 `deleteListLimit = 100000` 一次列举登记行（`Limit: deleteListLimit`），超出部分不再列举。
- 影响：超大目录（>10 万条登记行）删除时，超出部分**不写墓碑**，登记表留下孤儿行；`GET /api/changes` 因而缺 `delete` 事件，客户端保留已不存在的资源，直到下一次 rescan 才收敛。
- 建议：改为分批删除（按 uid 游标循环，直到取空），或提高上限并**在截断时记警告日志**（当前是静默截断）；`docs/security.md` §8.4 的「目录删除列举上限」条目应同步说明截断后果。
- 已降级（A 批，2026-10-26，只做了「可见」这一半）：`deleteListLimit` 由 `const` 改为包级 `var`（注释写明「仅测试覆写，生产恒 100000」），并抽出纯函数 `truncationReached(returned, limit)` 判定；撞上限时记 `slog.Warn`（含 `root` / `prefix` / `limit`）。`docs/security.md` §8.4 与 §8.7 第 8 条已同步说明截断后果（漏写墓碑 → 客户端保留本地副本 → 需 rescan 校准）。
- 未解决部分：**分批删除仍没做**（留 B 批）；响应体也**没有** `Truncated` 之类的字段，客户端无法自助发现（见本文「`deleteListLimit` 截断无 `Truncated` 响应字段」条）。

## 根内软链的部署假设（M7 安全复审，2026-10-18）
- 现象：整条防护链（REST 的 `physicalPathChecked` / `rejectSymlinkAncestors`、WebDAV 的 `symlinkGuardFS`、登记层 `IsRegular` 过滤）都建立在「软链可被识别并拒绝」之上。两个出口现已各自落实守卫（WebDAV 侧见 `internal/webdav/symlink.go`，接入 `/dav/` 与 `/public/`），但**启动期仍不检查根内是否存在软链**，`docs/configuration.md` 也没有「根内不得放置软链」的前置条件。
- 影响：防护已不依赖「根内没有软链」这一假设（有软链时两侧都拒），但拒绝是**静默的**——根内一条合法用途的软链会让 WebDAV 列目录少一项（PROPFIND 对权限错误静默跳过）、REST 读到 `404`/`400`，运维难以定位原因。另：`newSymlinkGuardFS` 在根不存在或无权限时退化为 `filepath.Abs`，此时「根自身是软链」仍依赖构造期 `EvalSymlinks` 成功。
- 建议：启动时扫描每个根，发现根内软链即告警（`mirror` 根建议 fail-fast，`ondemand` 根 warn），并在 `docs/configuration.md` 写明「根内不放置软链」；同时给 `symlinkGuardFS` 的 `EvalSymlinks` 失败路径补一条启动日志。

## WebDAV 写与 REST 写的锁不对称（M7 安全复审，2026-10-18）
- 现象：REST 走 `WriteAndCommit` / `WriteAndCommitIf`——「写文件 → commit → 登记」全在 `repo` 锁内完成；WebDAV 由 `webdav.Dir` 自行把内容落盘，之后才由钩子调 `repo.Commit`，`repo` 锁只保护「暂存 + 提交」，**不覆盖落盘**。
- 影响：同一文件被 REST 与 WebDAV 并发写时存在时间窗——REST 侧在锁内读到的内容可能正被 WebDAV 侧改写，或反之；结果是一个写入被另一个静默覆盖，且事件流的 `blob` 可能与磁盘最终内容不一致（需 rescan 收敛）。
- 建议：与「WebDAV 出口不支持条件写」同根因，用同一个 `bufferedFS` 统一写路径（缓冲 → `Close` 时在锁内 `WriteAndCommitIf`），让两个出口共用同一临界区。

## 主动内容内联黑名单为枚举式（M7 安全终审，2026-10-18）——REST 侧已解决（A 批，2026-10-26，白名单）；WebDAV 侧改由 `CSP: sandbox` 缓解（≠ 白名单）
- 现象（历史）：`internal/api/files.go` 曾有一张**枚举式**主动内容黑名单（14 项：`.html` / `.htm` / `.xhtml` / `.shtml` / `.ehtml` / `.xht` / `.svg` / `.svgz` / `.xml` / `.xsl` / `.js` / `.mjs` / `.mht` / `.rdf`，符号名见 git 历史）。判定只按 `path.Ext` 精确匹配，名单之外的扩展名一律按「被动内容」内联返回（带按扩展名推断的 `Content-Type`）。该名单在 A 批被删除。
- 影响：**漏项即形成 XSS 缝隙**。Go 内建 MIME 表会把 `.shtml`/`.ehtml` 映射为 `text/html`、`.xht` 映射为 `application/xhtml+xml`——这类扩展名一旦漏在名单外，服务端就会**显式声明**主动类型，`nosniff` 不阻止显式声明的类型被当作 HTML 执行，于是 `PUT` 一个 `evil.shtml` 再接 `GET /api/files/evil.shtml` 即可在服务端源下执行脚本（可读 `localStorage` 里的令牌）。本轮已补齐 6 项，但「下次 Go 新增映射」「其它厂商扩展名（如 `.xhtmlz`、`.htc`）」仍会重复此问题；WebDAV 出口连这层强制下载都没有。
- 建议：反转为「安全类型**白名单**才内联」——只有明确的被动类型（文本笔记、图片、PDF 等）按其推断类型返回，其余一律 `application/octet-stream` + `attachment`；同时 WebDAV 侧对同一份名单同样强制 `attachment`（当前 `Content-Type` 由客户端自行解释，浏览器在 Basic 认证后可能按扩展名内联渲染），并把名单抽成单一真源供 REST / WebDAV 共用。
- REST 侧已解决（A 批，2026-10-26）：删除 `activeContentExts` / `isActiveContent`（14 项枚举黑名单），改为 17 项静态映射表 `inlineContentTypes`（ext → `Content-Type`，**不查宿主 mime 表**）：`.txt` `.md` `.markdown` `.org` `.csv` `.json` `.pdf` `.epub` `.png` `.jpg` `.jpeg` `.gif` `.webp` `.bmp` `.ico` `.tif` `.tiff`；**名单外一律** `application/octet-stream` + `Content-Disposition: attachment`。三个收益：默认安全（新增/未知扩展名自动强制下载，不再「漏项即缝隙」）、不依赖宿主 MIME 数据库（跨机一致）、安全属性可判定。**行为变更**：`.org` 的 `Content-Type` 由 `text/org; charset=utf-8`（宿主 `globs2` 给的值）改为 `text/plain; charset=utf-8`，其余 16 项不变。
- WebDAV 侧改为 `CSP: sandbox` 缓解，**但没有采用白名单**（A 批，2026-10-26）：新增 `internal/webdav/security.go` 的 `SandboxContent`，`/dav/` 与 `/public/` 的全部响应加 `nosniff` + `Content-Security-Policy: sandbox`。理由是强制 `attachment` 会破坏 Calibre / Obsidian 等按 `Content-Type` 处理文件的第三方客户端；`sandbox` 让文档进入不透明源、禁掉脚本与同源 DOM 访问（关闭「`PUT` 一个 `.html` 再诱导浏览器导航」的同源脚本执行通道），而字节与 `Content-Type` 都不变。**残余差异**：该出口能内联的类型仍是任意扩展名（只是无法执行脚本），与 REST 侧的「白名单内联」不等价。
- 该条目**不关闭**：WebDAV 侧的剩余风险与「装配点无集成断言」见本文 A 批新增条目。

## `/api/files/` 的内联响应无 `CSP: sandbox`（服务端技术债 A 批代码审查，2026-10-26）
- 现状：白名单内的 `.pdf` / `.epub` / 图片按声明类型内联返回，浏览器以原生解析器渲染**攻击者可控的二进制**（任何能 `PUT` 的客户端都能上传一个构造过的 PDF/EPUB）；响应**没有** `Content-Security-Policy: sandbox`，也没有 `X-Content-Type-Options` 之外的隔离手段。
- 影响：主风险是**解析器漏洞**（PDF/EPUB/图片解码器的内存安全），不是同源脚本执行——`nosniff` + 按声明类型的固定 `Content-Type` 已经堵掉了「当 HTML 执行」。一旦浏览器解析器被攻陷，脚本运行在同源下即可读 Web UI 存在 `localStorage` 里的令牌，故不是零风险。
- 建议（**评估后决定不加**）：加 `CSP: sandbox` 会让 PDF 预览失效（Chrome/Firefox 的内置阅读器在 `sandbox` 指令下被禁），代价大于收益——这些文件的核心用途就是内联预览。缓解手段保持「白名单内联 + `nosniff`」。若将来出现「必须内联但不能执行脚本」的需求，可对 `Content-Type: text/html` 类（白名单外，本就走 `attachment`）单独评估。

## `pathguard.HasDotSegment` 对 `..` 折叠的安全性依赖下游契约（服务端技术债 A 批代码审查，2026-10-26）
- 现状：`HasDotSegment` 内部传 `AllowParentSegments: true`，即 `..` 走**折叠**而非拒绝（`a/../b` → `b`，放行）。这在 WebDAV 出口是安全的，但安全性来自**下游**：`x/net/webdav` 的 `stripPrefix` 恒给路径加前导 `/`，且 `webdav.Dir` 的 `resolve` 还会再 `path.Clean` 一次，因此「折叠后仍在根内」由库保证。
- 影响：若有人把这个函数用于「传相对名」的调用方（如自己拼 `root + rel` 再打开文件），折叠语义会让 `..` 逃出该相对名的父目录，而这层保证**不在** pathguard 里。函数签名（`func(rel string) bool`）不表达这个前提。
- 建议：在 `HasDotSegment` 的注释里写明「入参必须是已带前导 `/` 的挂载路径，或调用方自行保证折叠后不越界」（现注释已提「与历史实现逐字等价」，但没写这个下游前提）；若要彻底消除，可新增 `CleanRel` 严格版的导出包装供「相对名」调用方使用，把两者语义在 API 上分开。

## `/dav/` 与 `/public/` 出口加固的装配点无集成断言（服务端技术债 A 批代码审查，2026-10-26）
- 现状：`webdav.SandboxContent` 只有**中间件单测**（`internal/webdav/security_test.go` 直接构造 handler 断言响应头），但「`cmd/server/main.go` 确实把它包在两个出口上」没有集成测试——装配在 `package main`，现有测试无法覆盖。
- 影响：新增第三个 WebDAV 出口（或重构 `main.go` 的包装链）时不会有测试提醒漏包装；漏了就是「该出口的 `.html` 可内联执行脚本」，而这正是本批修掉的风险。
- 建议：给 `main.go` 的包装链抽出可测函数（如 `buildWebDAVHandler(cfg, …) http.Handler`），在 `package main` 里加一个 httptest 用例：对 `/dav/` 与 `/public/` 各发一个请求，断言响应含 `nosniff` + `CSP: sandbox`；或用「包装链顺序」的表驱动断言（顺序一旦漏一环即失败）。

## `/api/` 响应无 `Cache-Control`（服务端技术债 A 批代码审查，2026-10-26）
- 现状：`/api/` 的成功响应与错误响应都不设 `Cache-Control`（只有 `GET /api/files` 的 `http.ServeContent` 走标准缓存语义，会按 `Last-Modified` / `ETag` 协商）。
- 影响：若在反代启用 `proxy_cache`（或 CDN），私密笔记内容与批注可能被**共享缓存**保存并按 URL 分发给其他请求者——单用户部署下影响有限，但一旦有第二个客户端/租户，这是数据越界。401 响应同样没有 `Cache-Control: no-store`，某些代理会缓存错误响应。
- 建议：对 `/api/` 统一加 `Cache-Control: no-store`（或至少对 `/api/` 的 JSON 响应加），在安全头中间件里顺手加（同一处装配点）；反代侧显式 `proxy_no_cache` 作为第二道。

## `deleteListLimit` 截断无 `Truncated` 响应字段（服务端技术债 A 批代码审查，2026-10-26）
- 现状：撞到列举上限时只记服务端 `slog.Warn`，`DELETE /api/files/{path...}` 的响应体仍是 `{"uid","uids","root","path","seq"}`，没有任何「本次删除不完整」的标记。
- 影响：客户端无法自助发现「这个目录没删干净」——它会认为该子树已全部删除，但登记表里仍有存活行（未写墓碑 → 无 `delete` 事件），于是本地保留副本直到下一次 `rescan`。运维只能靠翻日志发现。
- 建议：响应体加 `"truncated": true`（或 `"skipped": N`）并在 `docs/api.md` §8.3 写明客户端动作（发现 `truncated` 应触发一次 `rescan` 或分批重试）；与「分批删除」（B 批）一起做最自然。

## 错误 message 反射客户端可控 path（服务端技术债 A 批代码审查，2026-10-26）
- 现状：多个 handler 用客户端传入的 `path` 直接拼错误文案，例如 `文件 %s 在版本 %s 中不存在`（`ErrNotFound`），该 message 原样回到客户端；`docs/security.md` §8.5 的口径是「响应只含稳定错误码 + 固定中文文案」。
- 影响：文案里出现攻击者可控的字符串，意味着可注入换行/控制字符（若下游有日志或终端渲染）、也可用于探测「服务端如何规范化我的输入」（回显的是清洗后的还是原始的）。当前**不构成**路径泄漏（回显的是客户端自己的输入，不是服务端物理路径），但与「固定文案」的不变量不一致。
- 建议：错误 message 里不回显原始 `path`（改成「目标文件在该版本中不存在」这类固定文案），或把 `path` 经 `%q` 转义后再回显；同时补一条断言「错误 message 不含换行/控制字符」。

## `rescanLastAt` 用墙上时钟，NTP 回拨会让限流窗口变长（服务端技术债 A 批代码审查，2026-10-26）
- 现状：`rescanLastAt` 存 `time.Now().UnixNano()`，限流判断用 `time.Since(...)`——依赖墙上时钟。
- 影响：NTP 向前跳变时 `since` 变大（限流失效一次）；向后回拨时 `since` 可能为负 → `remaining` 变大 → `Retry-After` 报出很大的值，限流窗口被**被动延长**（但不会崩溃，也不会永久锁死：`Retry-After` 只是建议值，客户端按它退避会等更久）。属「安全侧失效 / 可用性侧劣化」，不是漏洞。
- 建议：改用单调时钟（`time.Since` 已基于 `monotonic` 读数是正确做法，但 `Store(UnixNano())` 丢了单调部分）——可存 `time.Time`（含 monotonic 读数）而非 UnixNano；或保留现状但把 `since < 0` 视为「窗口已过」。**不改也不影响正确性**，记此条是为了下次改动时不被 NTP 现象误导。

## `rescanMinInterval` / `deleteListLimit` 为包级 `var`，`-race` 下存在数据竞争面（服务端技术债 A 批代码审查，2026-10-26）
- 现状：两者从 `const` 改为包级 `var` 以便测试临时覆写（配合 `t.Cleanup` 恢复）。测试在 `package api` 内部直接赋值，生产代码只读。
- 影响：并行测试（`t.Parallel()`）或多个测试文件同时覆写同一个包级变量时，读写之间没有同步 → 开 `-race` 跑全量测试可能出现数据竞争告警（当前测试未用 `t.Parallel()`，故实践上未观察到）。生产路径不改这两个变量，无实际竞争。
- 建议：若将来开启 `-race` 门禁或引入 `t.Parallel()`，把两个变量换成「`Server` 字段 + 构造函数默认值」或 `atomic.Int64`，测试改用 fixture 注入而不是改包级变量；或明确约定「覆写包级 var 的测试禁止 `t.Parallel()`」并写进测试注释。

## `handleVersion` / `handleFileContent` / `handleFileHistory` 仍不过 pathguard（服务端技术债 A 批代码审查，2026-10-26）
- 现状：三个只读端点（版本查询 / 历史版本内容 / 版本历史列表）仍只用 `path.Clean` 折叠，不调 `pathguard.CleanRel`；与 §8.1 的文件端点不同，它们不判点段、不判 `..` 段。
- 影响：**当前无风险**——三者都只读 git tree 内的 blob（不打开工作区文件、不写盘），且 `gitver` 的 `resolve` 已在版本表达式解析处调用 pathguard；`.git/` 一类路径即使被接受，读到的也只是仓库内 blob，不构成越界或写穿。但这是「新增路径入口必须调 pathguard」不变量的例外。
- 建议：B 批统一补上（把三个 handler 的路径处理改为 `pathguard.CleanRel`，错误文案保持现状），或在注释里显式写明「只读 git tree，故不做点段判定」的理由，避免下一个人以为是漏改。

## `gitver.Revert` 本身仍是宽松解路径（服务端技术债 A 批代码审查，2026-10-26）
- 现状：`gitver.Revert(path, hash)` 内部对 `path` 只做宽松处理（不含点段/`..` 判定）；唯一的生产调用点 `handleRevert` 现已先过 `cleanRelPath`（A 批补齐）。
- 影响：**新增调用者不会自动受保护**——`gitver` 是独立包，直接调 `Revert` 的代码（将来的 CLI 工具、批处理脚本）会绕过路径校验，把隐藏文件或 `.git/` 下的内容写回工作区。
- 建议：把校验下沉到 `gitver.Revert` 内部（调 `pathguard.CleanRel`，与 `resolve` 同口径），使「怎么调都安全」；或在函数注释首段写明「调用方必须先做路径校验，本函数不做」。

## `/api/files/` 截断端到端断言偏浅（服务端技术债 A 批代码审查，2026-10-26）
- 现状：`internal/api/files_internal_test.go` 的端到端用例把 `deleteListLimit` 设为 1、删除含 2 个登记行的目录，只断言「仍返回 200」+「目录已删」；截断的可观测性由纯函数 `truncationReached` 的断言承担，未断言「漏写墓碑的那条仍存活」。
- 影响：`truncationReached` 与真实调用点的**接线**（`List` 返回条数 → 判定 → 日志）只被间接覆盖；若有人把判定挪到「子树收敛后的 entries 长度」上（收敛会丢条数，永远判不出截断），纯函数用例仍全绿而实际行为已退化。
- 建议：补一条端到端断言「截断发生时，未被列举的那条资源在 `resources` 里仍是存活行（墓碑未写）」——这同时锁住「判定基于 `List` 返回条数」这个关键接线。日志本身仍不捕获（包级 `slog` 无可注入点，捕获 stderr 会让用例脆弱）。

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

## PDF 无 TOC 数据源（M10.6 B2，2026-10-18）——已随 M10.8 解决（2026-10-20）
- 原问题：Android 内置 `PdfRenderer` 只暴露页数与逐页渲染，**不提供 outline/书签（TOC）**；彼时受「零新增依赖」约束，PDF 侧没有目录入口，与 EPUB 交互不对称。
- 解决：经用户 2026-10-20 明确授权破例引入 `com.tom-roush:pdfbox-android:2.0.27.0`（`openspec/decisions.md`），新增 `reader/PdfOutlineReader`（读书签树）+ `reader/PdfTocEntries`（条目构造 / `indexForPage` 定位当前项），顶栏「目录」弹出单选列表；无 outline 或解析失败回退「第 N 页」页码目录；`pageIndex < 0` 的书签只关对话框不跳页。
- 残余风险：见下文「`pdfbox-android` 版本停更」「病态 PDF 可占死主进程 `ioExecutor`」两条，勿在本条重复排查。

## 浮层隐藏后阅读区 padding 仍保留（M10.6 B2，2026-10-18）——已随 M10.8 解决（2026-10-20）
- 原问题：`applyChromePadding()` 一次性（高度变化时）把浮层高度写入阅读区底部 padding，`toggleChrome()` 只切浮层可见性、**不回收** padding → 沉浸阅读时底部留一条与浮层等高的空白。
- 解决：两侧改为 `applyContentPadding()`，按「浮层是否 `VISIBLE` + 当前 height」实时计算上下 padding（**隐藏即归零**）；用 `appliedTopPadding` / `appliedBottomPadding`（EPUB 另加 `appliedContent` 比对 RecyclerView 身份）做幂等闸，**只写变化值**，把「每次显隐都重布局」的抖动压到最小；布局监听改为常驻，insets / 字体缩放 / 旋转变化都会重算。
- 附带要求（别踩回去）：EPUB 的 padding 变化**不派发 `onScrolled`**，故 `applyContentPadding()` 末尾必须调 `reportVisibleChapter()`，否则持久化的章内偏移会漂移（决策见 `openspec/decisions.md`「阅读器浮层必须是 overlay」）。

## SeekBar 精度受章节/页数上限约束（M10.6 B2，2026-10-18）
- 现状：底部 `SeekBar` 的 `max` = 章数-1 / 页数-1，`SeekBar` 的可用像素宽度有限（手机横屏约 200–300px）。
- 影响：章节/页数超过约 1000 时，一像素跨多项，轻拖就跳好几章/页，精细定位不可行；页数极小的文档（2–3 页）又几乎无拖动余地（单页时已禁用）。
- 建议：保留「点标题/页码输入数字」作为精确跳转兜底（已实现）；若后续需要更细粒度，可改为「拖动时按比例预显示目标章/页（不改位置）+ 松手跳转」并允许拖动超出 `max` 的连续取值（自定义 slider），或增加「上一章/下一章」快捷按钮。

## 浮层化改变阅读区高度带来的进度语义偏移（M10.6 B2，2026-10-18）
- 现状：B2b 起阅读区改为全屏 + 底部 padding = 浮层高度（约 40–56dp）。旧进度 `scrollY` 语义（相对章内 `WebView` 滚动量）不变，但「中心章」判定基准变为可见区中心，中心点相对旧实现下移约 40dp。
- 影响：章边界附近（末尾约 40dp 的内容）可能被判定为「已进入下一章」，与旧版本记录的章节号出现 ±1 偏差；跨版本续读时表现为「打开后标题显示的章比上次记录的多一章」。
- 建议：短期可接受（只在章尾窄带内出现）；若要严格一致，可在 `ScrollProgressMath` 的中心章判定里把 padding 计入并写单测固定语义；或在进度里显式记录「计算基准版本」，迁移时按版本换算。

## 书架 EPUB 进度键 = 内容哈希，有 uid 的书查不到进度（M10.6 B3，2026-10-18）
- 现状：`BookMeta.progressKey` 对 EPUB 恒为内容哈希（`EpubParser.documentIdOf`，SHA-256 前 16 字节），PDF 恒为 `file://` uri；书架据此查 `ReadingProgressStore.all()` / `PdfProgressStore.loadAll()`。阅读器端则是 `effectiveKey = uid ?: docId`——同一本书若有服务端 uid，进度存在 **uid** 键下。
- 影响：凡通过服务端登记（有 uid）读过的书，书架按内容哈希查不到进度，徽标恒显示 0%（或按「未读」过滤掉），与用户在阅读器里看到的位置不一致；用户会误以为书架丢失了阅读记录。
- 建议：B 批接线 `SyncEngine` / `ResourceIndex` 时改为**两键查找**——先用文件路径经 `ResourceIndex.findByPath`（或 `GET /api/resolve`）拿 uid，命中则按 uid 读进度，未命中再退回内容哈希；`BookMeta` 需携带可选 uid 或由书架层补一次索引查询。

## PDF `file://`（书架）与 `content://`（SAF）两套进度不共享（M10.6 B3，2026-10-18）
- 现状：书架打开的 PDF 用 `Uri.fromFile(file)`（`file://...`）作 `docId`，SAF 选择器打开的是 `content://...`；`PdfProgressStore` / `PdfAnnotationStore` / `PdfInkStore` 全部以 `docId` 字符串为键，两者是不同的键。
- 影响：同一份 PDF 从书架读到的位置、批注、手写笔迹，从 SAF 再次打开时**全部看不到**（反之亦然），用户会认为数据丢失；且两套数据各自累积，无合并路径。
- 建议：统一为按**内容或规范化路径**派生的稳定键（例如书架与 SAF 都取 `DocumentsContract` 的真实文件路径，或用内容哈希），并对既有两套键做一次惰性迁移；至少在 UI 上提示「来源不同，进度独立」。

## EPUB2 封面不支持（M10.6 B3，2026-10-18）——已随 M10.8 解决（2026-10-20）
- 原问题：`BookMeta` 的封面只认 EPUB3 manifest 里带 `properties="cover-image"` 的项；EPUB2 惯用的 `<meta name="cover" content="<id>"/>` 不识别 → 存量旧书书架只有灰占位。
- 解决：`EpubParser.pickCoverHref(manifest, epub2CoverId)` 三级回退（EPUB3 `cover-image` → EPUB2 `<meta name="cover">` 按 id 取 href → manifest 中第一个 `media-type` 以 `image/` 开头的 item）；仍无封面（或解码失败）时卡片叠 `coverInitial`（`CoverKeys.initialOf(title)` 取书名首字，空书名 `?`）。
- 残余：第三级是**启发式**，首图若为出版社 logo 会显示错图 —— 已另立条目「封面第三级回退取首图可能取错」，勿重复排查本节。

## `covers/` 无自动清理（M10.6 B3，2026-10-18）
- 现状：`filesDir/covers/` 只写不删——`CoverCache` 提供 `clearAll()` 但无任何调用方；书籍从 `filesDir/books/` 删除后，其 `<key>.jpg` 与 `<key>.json` 永久滞留；缓存键含文件 `length` + `lastModified`，同名文件被替换会产生**新键**，旧键文件成为孤儿。
- 影响：缓存目录随「删除次数 + 文件替换次数」单调增长，长期可占数十至数百 MB；手机存储紧张时表现为「应用体积不明原因变大」，且用户无入口自助清理。
- 建议：加扫描后的 sweep——遍历 `covers/` 与当前书库的有效键集合求差集并删除孤儿（可在书架扫描的同一后台线程末尾执行），再叠加容量上限（如 64 MB）或「最多保留 N 张」的 LRU 磁盘淘汰。

## 书架首次扫描需逐本 readBytes + 解压 + SHA-256（M10.6 B3，2026-10-18）
- 现状：`EpubBookMetaReader.read()` 对每本 EPUB 执行 `file.readBytes()` → `EpubParser.parse`（解压 OPF 等条目）→ `documentIdOf(bytes)`（整包 SHA-256）；`BookMeta` 只有 `coverHref`（相对 opfDir 的路径）而**没有 `opfDir`**，`CoverCache.epubCover()` 生成封面时必须重新解析一遍 EPUB 才能定位条目。
- 影响：首次进入书架（或缓存失效后）耗时与峰值内存随书库规模线性增长——每本书都整包进堆再算哈希，大 EPUB（数百 MB）可触发 OOM；每本 EPUB 解析 **2 次**（元数据 1 次 + 封面 1 次），是首次加载慢的主因。
- 建议：① `BookMeta` 增加 `opfDir`（或直接给 `coverEntry` 完整路径），消除封面二次解析；② 把「整包读入」改为流式摘要（`DigestInputStream` 边读边哈希），只对需要解析 OPF 的条目做局部解压；③ 首次扫描结果写入磁盘缓存（已有 `<key>.json`）后期次扫描只读缓存，需保证缓存失效判据（`length` + `lastModified`）可靠。

## 封面与扫描共用同一单线程 executor，刷新被解码拖后（M10.6 B3，2026-10-18）
- 现状：`ReaderFragment` 只有 `scanExecutor = Executors.newSingleThreadExecutor()` 一个后台线程，书库扫描与 `CoverCache.load()` 的封面解码/落盘都投在它上面（`PdfRenderer` 非线程安全是需要串行的原因，但封面解码并不需要与扫描串行）。
- 影响：书库较大时（实测约 240 本）「扫描完成 → 网格可见」之后，新封面仍排队等在 executor 上，滚动过程中格子陆续变色，用户感知为「书架一卡一卡地加载」；而且扫描刷新（切回 Fragment / 从阅读器返回）必须排在已入队的封面解码之后，刷新延迟被放大。
- 建议：拆两个后台线程——扫描（含 `PdfRenderer` 取页数、元数据解析）仍单线程，封面解码另用独立 executor（2 线程即可，解码本身是 CPU 密集且互相独立）；或在同一 executor 上给扫描任务加**优先级**（用 `ThreadPoolExecutor` + 优先队列），保证刷新永远先于历史封面任务。

## 切 tab 不刷新书架（M10.6 B3，2026-10-18）
- 现状：Shell 用 `FragmentTransaction.show/hide` 切换 tab，两个 Fragment 只创建一次；`show/hide` **不改变生命周期**，`onResume` 不会再次触发。书架只在 `onViewCreated`、`onResume`（从阅读器返回）与过滤/排序变更时 `refresh()`。
- 影响：在「笔记」tab 期间书架内容可能已变化（例如导入流程/外部写入），切回「阅读」tab 仍显示旧列表（缺新书、进度徽标过期），用户需要退出重进或改一次过滤条件才能看到更新。
- 建议：`ReaderFragment` 覆写 `onHiddenChanged(hidden: Boolean)`，`hidden == false` 时按需 `refresh()`（可加时间窗节流，例如距上次刷新 <3s 则跳过）；若将来改为 `ViewPager2`/Navigation 组件，则对应改为 `onResume` 或 `onStart` 语义。

## `OrgEntry` 无稳定 id，折叠状态用解析下标（M10.6 B4，2026-10-18）
- 现状：`OrgParser` 产出的 `OrgEntry` 没有身份字段；`OrgTreeBuilder` 的 `OrgNode.index`、`NotesFragment.collapsed` 的折叠键、`NotesEditActivity` 的编辑目标都取自「条目在本次解析结果中的下标」。
- 影响：任何一次重新解析（保存、切文件、Agenda 段切状态返回）后下标可能变化，折叠状态按旧下标残留或错位——`pruneCollapsed` 只能清掉已失效的下标，无法让折叠状态跟随条目移动；跨会话持久化折叠状态更无从谈起。
- 建议：给 `OrgEntry` 补稳定 id（内容指纹：`层级 + 标题 + 同标题出现序号`，或解析时记录 headline 行号并配内容哈希）；折叠键改用 id，`OrgEditor` 的写回继续用行号（两套坐标解耦）。

## Notes 只读 `filesDir/notes/` 下的第一个 org 文件（M10.6 B4，2026-10-18）
- 现状：`NotesFragment.loadNotes()` 取 `listFiles{...}.sortedBy { name }.firstOrNull()`，只解析一个文件；同步上传也是这个文件。
- 影响：目录里放多个 org 文件时，除按文件名排序第一个之外全部不可见、不可编辑、不会同步，多文件用户实际不可用；界面也无任何提示说明「只显示了一个文件」。
- 建议：加文件切换（工具栏下拉或抽屉），选中文件名存 `AppPreferences`；`loadNotes` / `NotesSync.upload` 统一按选中文件工作。

## 搜索不含 tags 与 metadata，命中视图强制展开（M10.6 B4，2026-10-18）
- 现状：`OrgSearchMatcher` 只匹配标题与正文；命中行由 `OrgTreeBuilder.flattenFiltered` 强制展开祖先链。
- 影响：搜 `:work:` 这类标签必然无结果（用户会误判条目不存在）；命中视图里点折叠箭头会被下一次 `rebuild` 立刻展开回来，看起来像按钮失效。
- 建议：匹配范围补 tags / priority / scheduled / deadline（复用 `OrgEntryDisplay` 的展示口径）；区分「搜索强制展开」与「用户手动覆盖」两套状态（命中行优先显示折叠箭头并允许覆盖），或命中时暂时隐藏折叠箭头。

## 编辑页 metadata（优先级/计划/截止/标签/属性）只读（M10.6 B4，2026-10-18）
- 现状：`NotesEditActivity` 仅允许改标题 / 正文 / TODO 状态；其余字段只展示。
- 影响：调整优先级、计划、截止、标签必须离开 App 用外部编辑器，移动端「随手改」的场景缺失；且改标题会触发 headline 重建的字段顺序规范化（见下一条）。
- 建议：先做高频且局部可改的三个——计划（`SCHEDULED:` 行）、截止（`DEADLINE:` 行）、标签（行尾 `:tag:`），都只需改写单行；优先级放在 headline 内、需与 TODO 关键字顺序协调，最后做。

## `OrgEditor` 重建 headline 会规范化字段顺序（M10.6 B4，2026-10-18）
- 现状：`OrgEditor.setTitle` / `setTodoState` 以 `stars + TODO + rest` 重组 headline，`* [#A] TODO x` 保存后变成 `* TODO [#A] x`。
- 影响：与 org-mode / orgzly 的书写习惯不一致；只改一个标题就会产生用户没预期的行级 diff，容易被误认为编辑器改坏了别处。
- 建议：解析时记录 TODO 关键字的位置与其余部分，重建时按原位置回填（仅「原本无 TODO、本次新增」时才前置）；同步补 CRLF 与多关键字算例的单测。

## 编辑页与 GTD/Agenda 并发写同一文件无锁与版本校验（M10.6 B4，2026-10-18）
- 现状：`NotesEditActivity` 保存、`NotesFragment` Agenda 段切状态、`GtdActivity` 切状态都是「`readText` → 内存改写 → `writeText` 全量覆盖」，无文件锁、无 mtime / 内容哈希校验。
- 影响：两个写者先后写会互相覆盖（例如编辑页还在返回栈里、用户在 Agenda 段切了一条状态），后写者把前者改动整段丢弃且无人提示。
- 建议：写前记录并校验 `lastModified` / 长度（或内容哈希），不匹配则提示「文件已被修改」并重载；长期把写操作收敛到单一写者（串行 executor + 内存当前文本）。

## Notes 列表无 `DiffUtil`，整表重绑致滚动跳动（M10.6 B4，2026-10-18）
- 现状：`NotesListAdapter.submit()` 直接 `notifyDataSetChanged()`；折叠 / 搜索输入 / 分段切换每次都整表重绑。
- 影响：条目多时每次折叠都全表刷新并丢失滚动位置，RecyclerView 复用被打断，长列表出现肉眼可见的跳动与闪烁。
- 建议：`VisibleRow` 已是不可变数据类，加 `DiffUtil.ItemCallback`（id = `node.index`，内容比较状态/标题/标签/摘要/缩进/折叠标记）成本低，改用 `ListAdapter` 承接。

## 正文摘要取首行，常显示计划行（M10.6 B4，2026-10-18）
- 现状：列表行的正文摘要取 `OrgEntry` body 的首个非空行。
- 影响：org 文档里正文常以 `DEADLINE:` / `SCHEDULED:` 计划行开头，摘要就显示成「DEADLINE: <2026-10-20 周三>」，信息量低且误导（用户以为标题被换掉了）。
- 建议：摘要跳过 `DEADLINE:` / `SCHEDULED:` / `CLOSED:` / `:PROPERTIES:` 等结构行，取首个纯文本行；无纯文本行时回退首个非空行。

## Agenda 段点击降级为只读、笔记列表取消单文件同步（M10.7 T7，2026-10-19）
- 现状：`NotesFragment` 改为「一个文件一行」的笔记库后，Agenda 段的行来自多个 org 文件的合并解析，`VisibleRow.node.index` 用全局计数器而非文件内下标（跨文件下标会冲突），点击已无法定位回原文件，因此降级为 Toast 提示；同时原「同步当前 org 文件」按钮随 `localOrgFile` 一并移除。
- 影响：B4 的「Agenda 段点击切换 TODO 状态」与「单文件上传」两项能力在当前 UI 中不可达（状态改动只能进阅读页源码编辑；上传入口只剩 `GtdActivity`）。
- 建议：给 `NoteItem` 建立 `entry → NoteItem` 的反查表（解析时记录每个条目的来源文件与文件内下标），点击时按「来源 item + 文件内下标」写回；同步按钮改为「同步全部本地 org」或按列表项长按上传，并补 `OrgEditor` 的跨文件算例。

## 渲染保真度边界：表格按普通文本、图片不内联、org 语法子集（M10.7，2026-10-18）
- 现状：`notes/render/OrgHtmlRenderer` / `MarkdownHtmlRenderer` 只覆盖「笔记阅读够用」的子集——`|a|b|` 表格按普通段落输出、图片语法不内联（不产出 `<img>`）、无大纲与跳转；`#+BEGIN_SRC` 缺少 `#+END_SRC` 时块扫描跑到文件末尾，余下全文被吞进代码块。
- 影响：含表格/图片的笔记排版退化（信息可用但不可读）；一个漏写的 `#+END_SRC` 会让整篇后半段的标题、列表全变成代码块原文，用户会误以为笔记损坏。
- 建议：表格后续可选渲染为 `<table>`（仍是纯 JVM 字符串拼接，可单测）；图片先只支持本地相对路径（需要 `baseUrl`，与「`baseUrl=null`」条目联动）；`BEGIN_SRC` 未闭合时降级为「按普通段落输出并补一行提示」，不要吞余下内容。

## denote 解析失败时读文件首个 heading（逐文件 IO，未限读前 N KB）（M10.7，2026-10-18）
- 现状：`NoteScanner` 的标题回退链是「denote 文件名 → 文件首个 heading → 文件名」，denote 命中可省一次 IO；未命中时为了找第一个 heading 会 `readText()`**整个文件**（`NoteReader` 无长度上限）。
- 影响：非 denote 命名的大文件（数十 MB 的日志式 org）在扫描阶段被整份读入内存；SAF 目录下每个文件都要 open 一次流，首次扫描明显变慢、且有 OOM 风险。
- 建议：改为「限读前 N KB（如 64 KB）」的分块读取，只解析到首个 heading 即停；本地文件用 `BufferedReader` 逐行读、SAF 用 `openInputStream` + 前缀缓冲，两者共用同一「读到 heading 就停」的纯函数。

## 大目录扫描成本：全量、无缓存/增量，`onResume` 每次重扫（M10.7，2026-10-18）
- 现状：`NotesFragment.loadNotes()` 每次都把私有目录 + SAF 目录**全量**扫一遍（`listFiles` / `DocumentsContract` 查询 + 逐文件标题回退），无缓存、无增量；`onResume` 无条件触发（从设置页、阅读页返回都重扫）；Agenda 段另需对所有 org 文件逐个 `read + parse`，目前用「只取前 50 个（按修改时间倒序）」止血。
- 影响：笔记库达到数百文件后，每次返回笔记 tab 都有可见延迟；大 SAF 目录（云盘 provider）查询本身就要秒级，且 Agenda 段的前 50 个文件不一定是用户关心的那 50 个（无「全部 TODO」保证）。
- 建议：引入基于 `(name, size, lastModified)` 的扫描缓存（内存 Map 即可，进程内有效），未变更文件跳过；Agenda 改为按需懒加载 + 增量解析（记录每文件的 `lastModified` 与解析结果）；`onResume` 改为「仅在外部目录设置变更或阅读页返回 `RESULT_OK` 时重扫」。

## 正文搜索未做（只搜标题与标签）（M10.7，2026-10-18）
- 现状：`NotesFragment.filterNotes` 只对 `NoteItem.title` 与 `NoteItem.tags` 做包含匹配，**不读正文**。
- 影响：用户记得某段内容却记不住标题/标签时搜不到；B4 的「标题 + 正文」搜索能力实际退化（虽然 B4 只覆盖单文件）。
- 建议：正文搜索做成显式入口（搜索框旁一个「含正文」开关）而非默认行为——默认全量全文搜索在大目录 + SAF 上的成本不可接受；实现上复用渲染器的文本提取（去掉标记）后建轻量倒排或直接线性扫（数百文件量级线性扫足够），仍保持纯 JVM 可测。

## SAF 授权失效静默降级为「无外部笔记」，无用户提示（M10.7，2026-10-18）
- 现状：`NoteScanner.scanSaf` 捕获 `SecurityException` 后返回空表；`NotesFragment` 把「外部目录读取失败」与「外部目录为空」视为同一状态（都只是没有外部笔记）。
- 影响：用户撤销授权、换机恢复备份、或 provider 卸载后，外部笔记列表直接消失且没有任何提示，容易被当成「笔记丢了」（实际上文件仍在原目录）。
- 建议：让 `scanSaf` 返回结果类型（`Ok(items)` / `PermissionLost` / `Failed(msg)`），UI 在 `PermissionLost` 时显示一条可点击的提示条（「外部目录授权已失效，点此重新选择」→ 跳设置页）；`Failed` 只记日志 + 提示「部分外部笔记读取失败」。

## SAF 只遍历一层（不递归子目录）（M10.7，2026-10-18）
- 现状：`scanSaf` 用 `buildChildDocumentsUriUsingTree` 查询所选树的直接子文档，遇到 `MIME_TYPE_DIR` 直接跳过，**不递归**。
- 影响：用户在外部目录里按文件夹组织笔记时，子目录里的笔记完全不出现，看起来像「只同步了一部分」。
- 建议：加一层可选递归（深度上限如 3 层）并在设置页说明；递归前先评估 provider 的查询成本（云盘 provider 每层都是一次远程调用），可用「用户显式开启 + 扫描进度提示」的方式权衡。

## `NotesEditActivity` 暂无调用方（entry 级编辑器成死代码）（M10.7，2026-10-18）
- 现状：M10.7 把编辑入口改为文件级 `NoteEditActivity`（整份源码纯文本编辑），B4 的 entry 级 `ui/NotesEditActivity`（`OrgEditor` 行区间改写）**已无任何启动点**（`AndroidManifest` 仍导出为应用内 Activity，代码与单测保留）。
- 影响：`gtd/OrgEditor` 的唯一 UI 消费方消失，后续改动它时无法通过手工路径验证；文件体积与维护成本空转，新人容易误以为有两条编辑路径可用。
- 建议：二选一收口——① 删除 `NotesEditActivity` 与 `OrgEditor`（连同单测），把「结构化编辑」作为未来需求重新设计；② 在渲染页长按标题项提供「编辑此条」入口，让 entry 级编辑器重新有调用方。在收口前先不动代码，只在文档标注现状（`docs/android.md` §8 已注明 SAF 只读、编辑走源码编辑）。

## 无 `DiffUtil`（`NoteFileAdapter` 整表重绑）与 `baseUrl=null` 使相对链接/图片失效（M10.7，2026-10-18）
- 现状：① `NoteFileAdapter.submit()` 用 `notifyDataSetChanged()` 整表重绑（与 `NotesListAdapter` 一致，搜索输入、刷新、扫描回调都全表刷）；② `NoteViewActivity` 用 `loadDataWithBaseURL(null, …)` 载入 HTML，页面内相对路径链接与图片没有可解析的基点。
- 影响：① 列表刷新时滚动位置与动画丢失，长列表有可见跳动；② 笔记里的相对链接（`./other.org`）与本地图片（`images/x.png`）点击/加载都失效（白屏或 `ERR_UNKNOWN_URL_SCHEME`）。
- 建议：① 两个 adapter 统一改用 `ListAdapter` + `DiffUtil.ItemCallback`（`NoteItem` 不可变，id 可用 `ref.toString() + modifiedAt`）；② 若要支持本地图片，用 `loadDataWithBaseURL(file://<父目录>/)` 提供基点并保留 `allowFileAccess=false` + `allowContentAccess=false` 的收紧策略（WebView 对 baseUrl 的 `file://` 读取需实测），或改为在渲染阶段把相对图片路径重写成 `content://` 并单独校验。

## Agenda 段条目不显示日期/时间，且混入无状态的父标题与 DONE 条目（M10.7 真机验收，2026-10-19）
- 现状：`NotesFragment` 的 Agenda 段把各 org 文件的条目交给 `GtdSorter.byEarliestDate` 升序排列，但复用的 `NotesListAdapter` 行只展示标题与标签，**不显示日期/时间**；同一份条目流里既有带 `DEADLINE`/`SCHEDULED` 的条目，也有无任何计划时间的父标题（如「项目：Seshat 应用」）与 `DONE` 条目，二者都按同一规则参与排序。
- 影响：用户看不出「为什么这条排在这条前面」（升序依据不可见），且无时间的父标题与已完成的 `DONE` 条目挤占了列表前部，真正待办的事项被推到滚动区之外；真机（2026-10-19）上表现为列表前几行全是无时间信息的分组标题。
- 建议：① 行内补日期/时间（`DEADLINE` 优先、其次 `SCHEDULED`，无时间显示占位），让排序依据可见；② 提供「只看有时间的待办」过滤（默认开启），把无计划时间的父标题降级为不可点击的分组行、`DONE` 条目默认折叠或加删除线标注；过滤逻辑放在纯 JVM 侧（`GtdSorter` / 新增 `AgendaFilter`）以便单测覆盖。

## 笔记列表不区分内部/外部来源（`NoteSourceKind` 已存在但 UI 未用）（M10.7 真机验收，2026-10-19）
- 现状：`NoteScanner` 为每条 `NoteItem` 填了 `source`（`PRIVATE` / `EXTERNAL`），但 `NoteFileAdapter` 的行只渲染「格式 + 修改时间 + 标签」，`source` 在 UI 层零消费（也无任何代码读它）。
- 影响：私有目录与 SAF 外部目录的笔记在同一列表里完全同形，用户无法判断某条笔记存在本机还是外部目录；排查「为什么这条只读」「为什么删除后还在」时缺少可见线索（`NotesSync` 只上传私有目录首个 org 文件，也与来源相关）。
- 建议：行内元信息追加来源徽标（如「本机」/「外部」两个短标签，或外部项用不同前景色），并对 `EXTERNAL` 项保持无编辑入口的既有事实在 UI 上显式化（例如灰显「编辑源码」菜单项并提示「外部目录只读」）；`source` 一并纳入搜索过滤维度（按来源筛选）。

## 列表页「选择目录」按钮直接跳设置页，与设置页内同名按钮行为不一致（M10.7 真机验收，2026-10-19）
- 现状：`NotesFragment` 顶部「选择目录」按钮的实现是 `startActivity(SettingsActivity.intent(...))`——先跳设置页，再由用户在设置页里点「笔记外部目录」才真正起 SAF 选目录；设置页内那个同名动作直接起 `OpenDocumentTree`。两处文案相同、行为差一层。
- 影响：用户点「选择目录」后看到的是一个设置页面（不在预期位置），容易以为按钮坏了或已进入错误页面；两个入口名字一样行为不一样，后续维护也容易只改一处。
- 建议：二选一收口——① 列表页按钮文案改为「笔记设置」（跳设置页的语义自洽），并在设置页内保留唯一的 SAF 起入口；② 列表页直接起 `OpenDocumentTree`（复用设置页的持久授权 + 写偏好逻辑，抽成共享 helper），设置页的同类按钮改为调用同一 helper。倾向 ①（SAF 授权 + 清除需要一个稳定的设置位置来承载）。

## WebView 疑似 text autosizing：同为 H1 的标题字号不一致（M10.7 真机验收，待复核）（2026-10-19）
- 现状：`NoteViewActivity` 用 `loadDataWithBaseURL(null, html, "text/html", "utf-8", null)` 载入渲染结果，未设置 `settings.textZoom`、也未在 `HtmlDocument` 的 CSS 里声明 `-webkit-text-size-adjust`；真机上观察同一篇笔记里两处同为 `<h1>` 的标题字号不一致。
- 影响：标题层级在视觉上失去可靠性（读者按字号判断层级会误判），长文档尤其明显；由于未复现到最小样例，目前不能排除是 CSS 选择器命中差异（例如段落内标题 vs 顶层标题）而非 autosizing。
- 建议：先复核——用固定 HTML（两个纯 `<h1>`，内容等长）在真机与模拟器各看一次，确认是否随视口宽度/内容长度变化（autosizing 的特征）；若确认，则在 `HtmlDocument` 的 CSS 里给 `html { -webkit-text-size-adjust: 100%; }` 并为 `h1..h6` 显式声明 `font-size`（rem 单位），必要时同时设 `settings.textZoom = 100`。

## 笔记列表行高偏大（横屏 3200 宽仅容纳 6–7 项）（M10.7 真机验收，2026-10-19）
- 现状：`item_note_file.xml` 为竖排两行（标题 15sp + 元信息/标签 12sp）且根布局 `padding="12dp"`，未按屏幕尺寸/密度分档；横屏（3200px 宽级别）实测一屏只容纳 6–7 项。
- 影响：宽屏下信息密度过低，笔记库稍多就需要大量滚动；横屏本来就为「一次看更多行」存在，当前实现把这块收益抵消掉了。
- 建议：把行内边距与行间距改为 `values` / `values-w600dp` 分档（横屏或宽屏降到 6–8dp、单位置两行合一），或改用 `?attr/listPreferredItemHeightSmall` 之类的高度约束；同时评估「标题 + 元信息」同行右对齐的紧凑版布局（宽屏一行即可容纳）。

## 上传 >32 MiB 不支持（M9.2 B 批，2026-10-19）
- 现状：`RestClient.MAX_UPLOAD_BYTES = 32 MiB` 与服务端 `PUT /api/files` 的单次请求体上限一致；`ReaderFragment` 在导入回调里前置判断，**超限只 Toast 提示「不上传」**，本地文件保留。原 M9.2 A 批条目（「`PUT /api/files` 单次上限 32 MiB，`GET` 的 `Range`/`If-None-Match` 未接入」）的「客户端尚未实现上传/下载」口径已不成立，此处记录 B 批交付后的**残余**缺口。
- 影响：大体积 PDF（扫描版画册、教材）只能留在本机，换设备或多端阅读取不到；用户看不到「为什么这本书没上云」以外的补救路径。
- 建议：两条路选一——① 客户端分片上传（服务端需新增「分片会话」端点，`PUT` 单块仍受 32 MiB 限制，最后合并）；② 超限时改走 WebDAV 通道（`WebDavClient.put` 已有，`mirror` 根同时挂 `PUT`，但书库根是 `ondemand` 只读，只能落到 mirror 根）。在实现之前保持「显式提示不上传」的现状，不要静默丢弃错误。

## 无后台定时同步（关闭 App 后不拉取）（M9.2 B 批，2026-10-19）
- 现状：同步只在书架**前台可见**时触发（首次进书架、`onResume` 30s 限流、刷新按钮）；刻意不引 WorkManager（零新增依赖）。进程被杀后既不拉取变更，也不重试失败的同步。
- 影响：服务端在其他设备上改动的书，要等用户下次主动打开书架才发现；「另一台设备刚导入的书」在书架上看不到，容易误判为同步坏了。
- 建议：若最终接受引入 WorkManager，用 `PeriodicWorkRequest`（最小 15 分钟）+ 网络可用约束做后台增量拉取，`SyncCoordinator` 已把「游标 / 幂等 / 单实例」三件事处理好，接成本主要在 WorkManager 的依赖与 `Constraints` 配置；不引依赖时的替代方案是 `JobScheduler` + 前台可见时补偿同步。

## 下载无断点续传、无进度回调（M9.2 B 批，2026-10-19）
- 现状：`RestClient.downloadFile` 用整份 `GET`，未发送 `Range`、也未用 `If-None-Match`；`BookDownloader.ensureLocal` 只有 `Ready` / `NotConfigured` / `Failed` 三态，**没有 `onProgress` 参数**，UI 只能显示「下载中…」。
- 影响：几十 MiB 的书在弱网下一次失败就要从头重来；用户无从判断是卡住还是在下（大文件 + 慢网络时尤其明显）；已下载的部分 `.part` 在失败路径被删，完全没有复用价值。
- 建议：① 断点续传——服务端已支持单区间 `Range`（206/416）与 `ETag`，客户端记录已落盘长度并发 `Range: bytes=<len>-` 续写同一个 `.part`，完成后再 rename；② 进度回调——`downloadFile` 从 `ResponseBody.contentLength()` 与逐块读取累计，回调节流到 100–200ms，`BookGridAdapter` 用 `ProgressBar` 或条目内百分比渲染（`downloading` 集合目前只有布尔语义，需扩展成 `Map<String, Int>`）。

## 封面旧键残留（下载/替换文件后旧 `<key>.jpg` 与 `<key>.json` 不清理）（M9.2 B 批，2026-10-19）
- 现状：`CoverKeys.keyFor(file)` = `文件名 + length + lastModified` 的 SHA-256 前 16 位 hex。远端书下载落盘后 `length` / `lastModified` 变化 → 新键，`CoverCache` 会生成新的 `<key>.jpg` + `<key>.json`，而旧键的两个文件没有任何删除路径（`covers/` 既无引用计数也无容量上限）。
- 影响：每下载一次同一本书就多留一份封面与元数据；书库反复下载/服务端改名后 `covers/` 单调增长且无法判断哪些是孤儿，只能整目录手删（删了会退化成下次重新解析）。
- 建议：短期在 `BookLibrary.load()` 结尾做一次「按当前书架上所有书的 key 集合求差，删掉不在集合里的 `<key>.jpg/.json`」（全量扫描时顺手做，O(n) 目录列举）；长期给 `covers/` 加 LRU 上限（按总字节数），与内存 `LruCache` 的策略对齐。

## `BookDownloader` 并发下载同一本书无保护（依赖调用方去重）（M9.2 B 批，2026-10-19）
- 现状：`ensureLocal` 自身**没有互斥**——两个线程对同一 `RemoteBook` 并发调用会同时写同一个 `<name>.part` 并竞争 `renameTo`。当前唯一保护是 `ReaderFragment` 的 `downloading: MutableSet<String>`（重复点击直接 return）与 `SyncHolder` 的单线程 executor，属**调用方约定**而非类内不变量。
- 影响：一旦将来有第二个调用点（例如后台预下载、批量「全部下载」按钮）或把下载挪到多线程 executor，就会出现 `.part` 交错写入产出损坏文件、或 `renameTo` 失败后一本好书被判为 `Failed`。
- 建议：把「同路径下载互斥」下沉到 `BookDownloader`（`ConcurrentHashMap<String, Future<DownloadResult>>` 按 `book.name` 合并同键请求，或在类内对 target 文件加锁），并让 `ReaderFragment` 的 `downloading` 集合退化为纯 UI 状态；顺带在单测里覆盖「两次并发调用只发一次请求」。

## 上传目标根用「mirror + default」启发式（M9.2 B 批，2026-10-19）
- 现状：`ReaderFragment` 选上传目标根的逻辑是 `roots.firstOrNull { mode == "mirror" && isDefault } ?: roots.firstOrNull { mode == "mirror" }`，都没有则静默跳过上传。默认根由服务端下发，客户端无法让用户指定。
- 影响：服务端一旦配置多个 `mirror` 根（例如「笔记」与「私人书库」都设为 mirror，默认根是笔记根），导入的书会落到笔记根而不是用户期望的书库根，且**没有任何提示**；排查时只能靠服务端日志看出路径不对。
- 建议：① 设置页加「上传目标目录（根）」下拉，选项来自 `GET /api/roots` 中 `mode == "mirror"` 的根（默认值仍取服务端默认根），存进 `AppPreferences`（非机密层）；② 上传成功的 Toast 里带上「已上传到 <root>」让目标可见；③ 在确定选择前保留当前启发式作为兜底，但要补一条 `Log.w` 记录实际选中的根。

## `size <= 0` 时无法判断本地文件是否需重下（M9.2 B 批，2026-10-19）
- 现状：`RemoteBookSource.localFileOf` 的判定是「文件存在 且（`book.size > 0` 时）长度相等」，`size <= 0` 时**只判存在、不校验长度**——这是为了避免元数据尚未回填（`/api/changes` 不返回 `size`）时把已下载的书误判成「未下载」。
- 影响：反过来的风险是——若本地文件被截断（下载中断后残留、外部工具改坏、磁盘满）而服务端 `size` 又恰好未回填，书架会把它当作「已下载」并直接打开，表现为解析失败或内容缺尾，且不会再触发下载修复。
- 建议：`ResourceEntry` 已有 `dirty` 位，可据此区分「`size` 未知是因为未回填」与「服务端真的没有 `size`（`ondemand` 根）」。优先方案：让 `BookDownloader.ensureLocal` 在 `size <= 0` 但条目 `dirty` 时**先触发一次回填/`GET /api/resources/{uid}`** 拿到真实 `size` 再判定；退而求其次提供「重新下载」长按菜单，让用户手动修复。

## 书架不区分内部/外部来源（`BookItem.remote` 已存在但 UI 未用）（M9.2 B 批，2026-10-19）
- 现状：`BookItem` 已有 `remote: RemoteBook?`（null = 纯本地书）与 `isDownloaded`，但 `BookGridAdapter` 只渲染「未下载 / 下载中」两个状态徽标，不提示条目的来源根（`remote.root`）与远端路径（`remote.path`）。
- 影响：多根场景下用户看不出某本书来自哪个根；排查「这本书为什么上传失败 / 为什么服务端改名后没跟随」时缺少可见线索（`ondemand` 根只读、`move` 只对 mirror 根生效，这些约束全靠文档）。
- 建议：封面占位或标题行下方追加来源徽标（如 `notes` / `ebooks` 的根 tag），长按条目弹出「来源 / 远端路径 / 重新下载 / 从书架移除」；`remote` 一并纳入书架过滤维度（按来源筛选）。同类问题见上文「笔记列表不区分内部/外部来源」（M10.7）——两处建议同一套 UI 方案，避免出现两种来源标注风格。

## `pdfbox-android` 版本停更，上游健壮性修复不会自动带入（M10.8，2026-10-20）
- 现状：引入的是 `com.tom-roush:pdfbox-android:2.0.27.0`（2023 年，`tom-roush` fork 的**最后一版**）；后续 Apache PDFBox 上游针对不可信输入（畸形 xref / 压缩流炸弹 / 循环引用）的解析健壮性与 CVE 修复不会流入该 artifact。
- 影响：解析攻击面随时间**只增不减**——用户导入的 PDF 是不受信任输入（可能来自任何来源），而这一层正是最容易被打穿的历史区域；同时无升级路径意味着「修不了」，只能被动回避。
- 建议：① 订阅上游 PDFBox 安全公告，出现影响 fork 的 CVE 时按「禁用目录/文本提取 + 仅保留 `PdfRenderer` 渲染」降级；② 评估迁移到仍在维护的 `pdfbox-android` 后继（或自建最小 outline 解析器）作为版本升级路径；③ 保持现有的输入闸门（50 MiB / `BoundedInputStream` / 节点与深度预算）不变，任何升级都不得放宽。
- 触发条件：上游发布 CVE 公告，或需要解析新特性 PDF 时。

## 病态 PDF 可占死主进程 `ioExecutor`，无法强杀（M10.8，2026-10-20）
- 现状：PDF 目录/文本解析跑在 App **主进程**的 `ioExecutor`（单线程）上；PDFBox 对 `/Next` 成环、超大对象图等病态输入没有强制中断手段，线程无法被强杀。
- 影响：一份恶意或损坏的 PDF 就能让解析线程长期占死——目录与文本提取永久无响应（UI 不崩但功能假死），且后续复用同一 executor 的其他 IO 会被排队阻塞；用户只能杀应用。
- 建议：彻底解法是**独立进程解析**（`android:process` 的单独 Service + `IProcessObserver` 兜底超时，超时即 `Process.killProcess`）；轻量方案是给解析线程加软超时（解析前记时间戳 + 解析器提供不了中断点，只能靠「换线程 + 结果丢弃」保护 UI）。
- 触发条件：解析耗时 > 数秒或用户反馈「PDF 打开后目录/复制文字无反应」。

## `PdfTextExtractorTest.extractsTextFromRealPdfPage` 在纯 JVM 下被跳过（M10.8，2026-10-20）
- 现状：`pdfbox` 的 glyphlist 等资源放在 AAR 的 `assets/` 里，纯 JVM 单测没有 `PDFBoxResourceLoader.init`，`PDFTextStripper` 取不到字形表 → 该用例用 `assumeTrue` 跳过（测试总数 721 中 1 例 skipped）。
- 影响：真实 PDF 的文本提取路径**在 CI 上没有自动化覆盖**，只有几何/边界类的纯函数断言；回归可能要到真机才能发现（届时表现为「复制本页文字」得到空串或乱码）。
- 建议：短期靠真机验收 + 人读覆盖，并在 CHANGELOG/tech-debt 保持这条显式记录；中期补 `androidTest`（仪器化，能 `PDFBoxResourceLoader.init(context)`）把该用例搬过去执行。
- 触发条件：改动 `PdfTextExtractor` 或升级 pdfbox 版本。

## EPUB 与 PDF 的 tap 单击延迟口径不一致（250ms vs `DoubleTapTimeout`）（M10.8，2026-10-20）
- 现状：EPUB 用常量 `TAP_TOGGLE_DELAY_MS = 250L`，PDF 用 `ViewConfiguration.getDoubleTapTimeout()`（系统值，通常 300ms 且厂商可调）。
- 影响：两端「单击响应速度」与「慢双击是否误触发翻页」的边界不同；用户在同一天内切两本书会感到手感不一致，也给后续把 tap 逻辑抽公共实现埋下分叉。
- 建议：把延迟来源统一为 `ViewConfiguration.getDoubleTapTimeout()`（PDF 侧已验证该口径对「双击切手写」是必需的），EPUB 侧只需把常量换成系统值并补一条单测断言「延迟源来自 ViewConfiguration」。
- 触发条件：下次触碰 EPUB tap 逻辑时。

## PDF 的 `INITIAL_CHROME_PADDING_DP` 与布局 XML `paddingVertical` 不一致（M10.8，2026-10-20）
- 现状：`PdfReaderActivity` 的 `INITIAL_CHROME_PADDING_DP = 6` 在 insets 回调里参与浮层初始 padding 计算，而布局 `activity_pdf_reader.xml` 给浮层的 `paddingVertical` 是 2dp / 4dp（既有行为，M10.8 未统一）。
- 影响：系统栏 insets 生效前后浮层视觉高度会有 2–4dp 的跳变；由于 padding 联动已按「实际 measure 高度」计算，阅读区不会错位，但浮层内容本身的留白在两种状态下不一致（观感细节）。
- 建议：把 6dp 的常量换成按布局实际 `paddingVertical` 推导（或直接从 `View.getPaddingTop()` 取值），删除重复定义；改动后需真机复核 insets 前后的浮层高度。
- 触发条件：下次调整 PDF 浮层样式时。

## 封面第三级回退取首图，可能取错（M10.8，2026-10-20）
- 现状：`EpubParser.pickCoverHref` 的第三级回退是「manifest 中第一个 `media-type` 以 `image/` 开头的 item」，纯启发式，不看文件名、不看尺寸。
- 影响：首图是出版社 logo / 装饰图的书会显示**错封面**（比没有封面更容易误导用户），且错图会被 `CoverCache` 缓存到磁盘，换书后仍显示旧图。
- 建议：给第三级加启发式过滤——文件名含 `cover` 的优先，其次排除 `logo` / `spine` / `titlepage` 等关键词；再退一步用「宽高比接近 2:3 且尺寸最大」判定（需要读图片头，成本可控）。也可在书架长按菜单加「更换封面」手动纠正。
- 触发条件：用户反馈封面张冠李戴时。

## 手写笔参数不跨文档记忆，无「最近使用」（M10.8，2026-10-20）
- 现状：手写面板的 6 色 × 3 档粗细 × 3 种笔型在打开每个文档时都回到默认值（`PdfInkStore`/`InkOverlayView` 不持久化「当前笔型」），也没有最近使用的快捷位。
- 影响：习惯用荧光笔做标注的用户每次开书都要重选一遍（3 次点击起），高频操作被重复劳动拖慢；也容易出现「以为还在用荧光笔，实际已回默认钢笔」的误画。
- 建议：把「上次使用的 color / width / style」存进 `AppPreferences`（非机密层，与阅读字号/翻页模式同级），打开手写模式时恢复；进一步可做「最近使用 3 组」的快捷行。注意这属于**默认值**记忆，不改变 `InkStroke.style` 的 per-stroke 语义（见 `openspec/decisions.md`）。
- 触发条件：手写使用频率上升或用户明确反馈。

## 阅读内设置面板未做：顶栏「设置」直接跳 `SettingsActivity`（M10.8，2026-10-20）
- 现状：M10.8 重排后顶栏保留「设置」按钮，点击即 `startActivity(SettingsActivity)`——**离开阅读器**；未做「阅读内浮层设置面板」（字号/翻页模式/主题的就地调节）。
- 影响：调一次字号就要退出阅读器（当前进度由 `onStop` 推送，虽不丢但会打断阅读心流）；与成熟阅读器「就地调参、实时预览」的体验有明显差距，也是 U3 需求的未完成部分。
- 建议：新增一个与顶部浮层同构的 `settingsPanel`（overlay + 同一套 `applyContentPadding` 计算），暴露三项最高频设置（字号 / 翻页模式 / 主题）；改动需复用 `AppPreferences` 写入路径并触发「重新加载」而非重启 Activity。
- 触发条件：用户反馈调参打断阅读时。

## `BookImporter` 导入无大小上限、非原子写入、仍在主线程执行（M10.8，2026-10-20）
- 现状：`BookImporter` 直接把 `ContentResolver` 的输入流复制到 `booksDir`——没有大小上限（不同于上传侧的 32 MiB 前置拦截）；先写目标文件名而非 `.part` + 原子改名；调用点（`ReaderFragment` 的 `pickImport` 回调）仍在**主线程**上做流拷贝。
- 影响：① 磁盘满或 provider 中断会留下**残缺文件**，且残缺文件与正常书同扩展名，会被书架扫描后当作坏书（静默跳过或打开失败）；② 拷一个 200 MB 的书足以触发 ANR；③ 无上限意味着一个「误选」的巨型文件可以把存储写满。
- 建议：参照 `RestClient.downloadFile` 的做法——写 `<name>.part` → `close()` 后 `renameTo` → 异常路径删 `.part`；加大小上限（与上传侧 32 MiB 对齐或另行设定并提示）；拷贝移到后台 executor（`scanExecutor` 或独立线程），完成后回主线程刷新书架。
- 触发条件：导入大文件或 provider 异常时（ANR / 坏书上报）。

## 手写模式下无法 tap 翻页（M10.8，2026-10-20）
- 现状：手写模式里 `InkOverlayView` 独占触摸（落笔优先），tap 分区不生效；M10.5 的「浮层上一页/下一页」按钮随 M10.8 工具栏改版一并取消，翻页只剩 `SeekBar` 与点页码。
- 影响：连续手写批注（例如逐页圈重点）时每翻一页都要退出手写或精准点/拖 `SeekBar`，是手写链路里最明显的效率瓶颈，也容易误触页码输入框。
- 建议：① 在手写浮层恢复「上一页 / 下一页」两个按钮（不与 tap 冲突，M10.5 已验证可行）；② 手写模式把 tap 分区的左右区改为翻页、中间区仍切浮层（落笔与 tap 用位移/时长阈值区分）；③ 支持「笔写、手指翻」——用 `MotionEvent.getToolType` 区分触控笔与手指（需真机验证设备覆盖）。
- 触发条件：手写功能被实际用于逐页批注时。

## 目录抽屉：父节点 href 映射不到 spine 时不可跳转（M10.9，2026-10-20）
- 现状：`TocRows.forEpub` 用 `chapters.indexOfFirst { it.href == node.href }` 定位落点，命中不到的一律 `targetIndex = -1`——包括容器节点（`href` 为 `null`）、指向锚点的 `ch1.xhtml#sec2`、指向非 spine 文件或跨文件目录的 href；`TocAdapter` 对这种行只允许「点标题 = 切换折叠」。
- 影响：**这是正确行为而非缺陷**——容器节点没有落点，硬跳只会跳到首个匹配项 / 第一页的错位置，比不能跳更糟。代价是用户看到父级标题「点了只是折叠」，需要学习成本；层级深的书父节点多，容易被误判成功能坏了。
- 建议：① 视觉区分——`targetIndex = -1` 且有子项的行用次要文字色、只留箭头，不给按下态；② 对「同文件不同锚点」的 href 可退化为跳到该文件的对应章（`href.substringBefore('#')` 再匹配），属**可选增强**而非缺陷修复；③ 文档保持显式记录（`docs/android.md` §6.4 已知限制 1），避免后来者把它当 bug 改坏。
- 触发条件：用户反馈「点父级目录没反应」，或实现锚点精确跳转（WebView 滚动到 fragment）时。

## `EpubBook.tocTree` 让书架扫描每本书多一次 nav/NCX DOM 遍历（M10.9，2026-10-20）
- 现状：`EpubParser.parse()` 除既有扁平 `toc`（`parseNav` / `parseNcx`）外，还会再读一次 nav（为空再读 NCX）建 `tocTree`——同一份 nav XML 被解析两遍，且 `tocTree` 在书架扫描里完全用不到（只有打开阅读器才需要）。
- 影响：书架扫描在后台单线程 executor 上跑，单本多一次 DOM 构建（开销小）；但书目上百时首次扫描的累计时间会线性增长，且这份纯为阅读器准备的数据拖慢了本不关心它的书架路径。
- 建议：改**惰性解析**——`EpubBook` 保留 nav / ncx 路径，`tocTree` 由 `EpubReaderActivity` 打开时按需解析（`EpubParser` 需暴露一个「只解析目录树」的入口）；`CoverCache` 的元数据 JSON 不缓存 `tocTree`（当前也未缓存）。注意 `parse()` 返回时 zip source 已关闭，惰性化必须重开 source，不能靠 `by lazy` 捕获已关闭流。
- 触发条件：书架首次扫描明显变慢，或书目规模到上百本。

## `EpubParser.buildChapters` 匹配 nav href 时用错 base（`opfDir` vs nav 文档目录）（既存缺陷，M10.9 发现，2026-10-20）
- 现状：`buildChapters(opf, opfDir, toc)` 以 `opfDir` 作 base 去匹配 `toc` 里 nav 的 href，而 nav 文档里的 href 实际相对 **nav 文档自身目录**。nav 在子目录（如 `OEBPS/text/nav.xhtml`）时，`ch1.xhtml` 被拼成 `OEBPS/OEBPS/text/ch1.xhtml`，匹配失败。
- 影响：章节标题回退成文件名 / 空标题，连带影响顶栏章节标题、底栏「第 n/N 章」提示、以及 `tocTree` 为空时的 `TocRows.forEpubFlat` 回退列表。**M10.9 新增的 `tocTree` 不受影响**（它在解析层用 nav/ncx 文档目录归一化，见 `docs/android.md` §6.4）。本次未修（超出 M10.9 范围，避免同时动 `parseNav` / `parseNcx` 与目录标题匹配）。
- 建议：优先方案——`parse()` 把 nav/ncx **文档路径**（含目录）传给 `buildChapters`，与 `parseNavTree` 用同一个 base；更彻底方案——`buildChapters` 直接吃 `tocTree` 的 `(href → title)` 映射，替掉一份重复解析，同时保留「nav 为空回退 NCX」的既有口径。
- 触发条件：改动 `buildChapters` / nav 解析时，或用户反馈「章节标题变成文件名」。

## `PdfTocEntries.kt` 与 `TocItemText.kt` 改为抽屉后已无生产引用（死代码，M10.9，2026-10-20）
- 现状：M10.9 把两端目录改为 `TocDrawer` 后，`reader/PdfTocEntries.kt`（PDF 条目构造 + `indexForPage` 当前项定位）与 `reader/TocItemText.kt`（目录行文案 `labels`）在 `main` 里**已无任何调用方**——PDF 侧改走 `PdfOutlineReader` + `TocRows.forPdf`，EPUB 侧改走 `TocRows`。两个文件仍留着，是因为**它们的单测还在跑**（`PdfTocEntriesTest` / `TocItemTextTest`），删源文件就得同时删测试，超出本次「只改文档」的范围。
- 影响：库里留下两个「活着但没人用」的类——后来者容易误以为它们是当前目录实现而改错地方；单测还在为已废弃行为背书（假绿）。另外 `PdfTocEntries.indexForPage` 的「当前项定位」语义已被 `TocDrawer.show(rows, currentTarget)` 取代，两套定位逻辑并存容易被混用。
- 建议：一次性清理——删两个源文件 + 两个测试类，把仍值得保留的断言（如「页码目录 1-based 文案 / 0-based 索引」）迁到 `TocRowsTest` / `PdfOutlineReaderTest`（后者已覆盖 `pageDirectory`）。清理前先全局 grep 确认零引用（含 XML 与反射调用）。
- 触发条件：下次触碰目录相关代码，或做死代码清理时。

## 旋转屏后目录抽屉的展开态与滚动位置丢失（M10.9，2026-10-20）
- 现状：抽屉的 `expanded`（展开节点 id 集合）与 `currentTarget` 只存在 `TocDrawer` 实例里；旋转重建 Activity 后 `TocDrawer` 重新构造，展开态回到「只展开当前项祖先链」，抽屉本身也是关闭的。
- 影响：横竖屏切换（或 `uiMode` 变化触发的重建）后要继续在深目录里找条目，得重新点「目录」再一路展开；多层目录的书上这是可感知的重复劳动。功能不丢（重开后仍定位到当前章 / 页），属体验损失。
- 建议：① 轻量方案——`onSaveInstanceState` 存 `expanded` 集合与「抽屉是否打开」，重建后重放；② 更彻底——把展开态提升到 `ViewModel`（纯 UI 状态，与书 / 页无关），配置变更天然存活；③ 若采纳 ②，顺手把「打开时滚动到当前项」也纳入同一状态，避免重开后跳回顶部。
- 触发条件：用户反馈旋转后目录难用，或下次改阅读器的配置变更处理时。

## 退出手写后第一次单击屏幕中央不弹工具栏（M10.9 追加，`c4a76d3`，2026-10-20）
- 现状：真机实测（`24091RPADC` / Android 16，PDF 阅读器）点右侧手写条的 `✕` 退出手写后，**第一次**单击屏幕中央（`TOGGLE` 区）无任何反应，**第二次**才调出顶部 / 底部浮层；此后单击恢复「一次即切换」。同一次会话内可复现，未在 EPUB 侧观察。
- 影响：退出手写后第一下点不亮工具栏，用户容易误以为「卡住了」而连点两下——而第二下恰好生效、第三下又收起，表现为浮层闪一下就消失。属交互时序缺陷，不是死锁（连点后可恢复），故只影响手感、不影响功能可用性。
- 建议：`c4a76d3` 把手写面板移到右侧浮条后，`✕` 的点击与 `InkOverlayView` 退场都发生在同一帧，怀疑是退出瞬间 `GestureDetector` 收到的仍是「落在已移除视图上」的旧事件序列（`onSingleTapUp` 被吞或 `pendingToggle` 被 `removeCallbacks` 清掉）。定位方向：① 在 `toggleInkMode()` 退出分支打点，确认退出后首个 `onSingleTapUp` 是否到达 Activity 的 `GestureDetector`；② 检查 `scheduleToggle()` / `toggleChrome()` 的待执行任务是否在模式切换时被取消而未重排；③ 修复后补一条回归用例（真机脚本连点 `1→2` 次断言浮层可见性），并顺手核对 ePub 侧是否同源。
- 触发条件：用户反馈「退出手写后要点两下才出工具栏」，或下次改动手写模式切换 / tap 分区逻辑时。

## 右侧手写条 96dp 覆盖正文右缘，未做右侧留白（M10.9 追加，`c4a76d3`，2026-10-20）
- 现状：手写参数面板是屏幕右侧竖排浮条（宽 96dp、`end|center_vertical`），在实测设备（density 2.75）占地 264px：面板 bounds `[2936,520][3200,1615]`，纵向居中；面板纵向区间内右侧暗占比 0.967。面板**不属于顶部浮层**，因此不参与 `ReaderChrome` / `applyContentPadding` 的计算——阅读区右侧 padding 仍为 0。
- 影响：手写模式下这一条 264px 宽的带子压在页面上，被遮住的正文既看不见也写不了（`InkOverlayView` 覆盖整页，但视觉上被面板挡住）；若用户想在该区域圈注，只能先平移/缩放页面（本版本未提供）。退出即恢复，不留残留（实测右侧暗占比回落到 0.00），故是模式内的可用性缺口而非数据问题。
- 建议：① 手写进入时给阅读区加右侧 padding（或 `clipToPadding=false` + `paddingEnd = 面板宽度`），与既有「浮层 padding 联动」同一套思路，但**必须考虑归一化坐标**——`InkGeometry` 的坐标相对「页面显示矩形」，若显示矩形变窄，已存笔迹的归一化坐标仍能正确对齐（这是 M10.5 的不变量），但需真机复验重进手写的笔迹位置；② 更轻的方案是把面板做成半透明 + 可拖动/可收起，让被覆盖区域仍可粗略判读；③ 补一条 `InkGeometryTest`，覆盖「显示矩形宽度因右侧 padding 变窄」的换算。
- 触发条件：手写被实际用于页面右侧批注，或下次调整手写面板形态时。

## 手写条「荧光笔」文案呈灰色，未确认原因（M10.9 追加，`c4a76d3`，2026-10-20）
- 现状：真机截图中，右侧手写条内「钢笔」「马克笔」为白色文字，仅「荧光笔」呈灰色；同一帧内 6 个色点与 `✕` / 细 / 中 / 粗的正常渲染无异常，面板功能可用（切换后新笔画按所选笔型绘制）。**未定位**是「选中态 alpha 渲染」还是「文字颜色未随状态刷新」。
- 影响：若为选中态渲染，则属正常（但「选中即变灰」与其余两项的选中表达不一致，容易被读成「不可用 / 已禁用」）；若为刷新时机问题，则用户在切到荧光笔后看到灰色文案，会怀疑没生效而重复点击，实际已在荧光笔模式（后果是误用低透明度笔迹）。两种解读的修法完全不同，故必须先定位。
- 建议：① 先区分——在 `inkPanel` 的笔型按钮上取实际 `currentTextColor` 与 `alpha`（或 `isSelected` / `isEnabled`）打点，对照 `InkStyle` 当前值判断是渲染值还是状态值；② 若属选中态：统一三种笔型的选中表达（例如全部改为描边 / 高亮底 + 文字保持白），或在文案旁加勾选标记，避免「灰色 = 禁用」的误读；③ 若属刷新时机：把状态刷新收敛到一处（切换笔型后统一 `refreshInkPanel()`），避免逐个控件手改。
- 触发条件：真机复现「荧光笔文案发灰」且能对照当前 `InkStyle`，或下次改动手写面板 UI 时。

## 沉浸只隐藏应用内浮层，系统状态栏仍可见（M10.9 追加，`c4a76d3`，2026-10-20）
- 现状：`c4a76d3` 的「进入即沉浸」只把顶部 / 底部两块自定义浮层置为隐藏（阅读区 padding 归零、正文铺满 `[0,0][3200,2136]` 之外的应用区），**没有**调用 `WindowInsetsController.hide(systemBars())` 或等价手段隐藏系统状态栏 / 导航栏；阅读区的 insets 避让逻辑仍然生效。
- 影响：与成熟阅读器的「全屏沉浸」相比，顶部仍留一条系统状态栏（时间 / 电量 / 通知图标），可用高度少一条状态栏；且状态栏图标颜色可能与阅读背景对比不足（深色主题下尤其）。功能上无影响，属「沉浸感差一口气」的体验缺口。
- 建议：接入 `WindowCompat.getInsetsController(window, window.decorView).hide(WindowInsetsCompat.Type.systemBars())` + `systemBarsBehavior = BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`，并处理三件事：① 浮层显示时应否恢复系统栏（阅读器习惯：浮层出现时状态栏一起回来，否则顶栏贴不到屏幕顶端）；② insets 变化会让 `applyContentPadding()` 重算，需复验「显隐浮层不漂移」（§6.3 的幂等闸）；③ 与既有 edge-to-edge（`targetSdk 35`）的 insets 监听合并，避免两套逻辑互相覆盖。
- 触发条件：用户反馈「阅读时想看全屏」或做阅读器沉浸体验专项时。


## 目录折叠符号不与 TAB 联动（M12 T5，2026-10-22）
- 现状：目录面板每次 `show` 都按 `seshat-reader-current-doc-outline` 重建，行模型 `seshat-reader-outline--rows` 的 `collapsed` 集合恒传 `nil`，于是所有有子节点的行恒显示展开符号 `▾`。buffer 内的 `TAB` 折叠走 `outline-mode` 自身的不可见性（`outline-hide-subtree`），不改动行模型、也不重绘面板，因此用户 TAB 折叠后符号仍停在 `▾`。
- 影响：仅视觉误导——折叠功能本身正常（正文确实隐去），但符号不随状态变化，用户容易误以为折叠失败或符号只是装饰。不影响跳转、当前章高亮与页码对齐。
- 建议：二选一——① 把折叠态（行路径集合，与 `--rows` 的 `collapsed` 元素同构）持久化到 buffer-local 变量，在每次 `show` 重建时传给 `--rows`，重建后按集合恢复符号；② 不改行模型，改为渲染后用 `outline-invisible-p` 动态判定并就地更新折叠符号的显示属性（需要重建符号文本或用 overlay，注意别破坏 `outline-regexp` 的星号前缀）。推荐 ①，与「折叠态集合恒为 nil」的既有接口天然契合。
- 触发条件：用户反馈「TAB 折叠后 ▾ 不变」，或下次改目录面板折叠/刷新逻辑时。

## Emacs 端仍不显示手写笔迹（`ink:` 段）（M12 T10，2026-10-22）
- 现状：`seshat-reader-annotation--rects-from-location` 只解析 `rect:` 段，`ink:`（手写笔迹）段被显式忽略，页面高亮只覆盖批注矩形；服务端其余端已能返回 ink 形态的 location。
- 影响：在移动端用笔迹标注过的批注，桌面端仍看不到笔迹轮廓，只看到列表里的摘要文字；用户需要在两端来回切换才能理解标注指向的位置。
- 建议：C 层把 `ink:` 的折线点集转成 `fz_path`（polyline，`fz_stroke_path` 而非 fill），elisp 侧新增 `--ink-from-location` 解析并把点集按页喂入（与 `--add-highlight` 同形的新模块函数 `--add-ink`），共用 `--refresh-highlights` 的缓存失效路径。
- 触发条件：用户反馈「手机上手写的批注在桌面看不到」，或做批注跨端一致性专项时。

## 高亮颜色与透明度不可配置（M12 T10，2026-10-22）
- 现状：高亮颜色与透明度是 `render/render-core.c` 的编译期常量（`HIGHLIGHT_COLOR_R/G/B` = 1.0/0.85/0.0、`HIGHLIGHT_ALPHA` = 0.35），elisp 侧只暴露开关 `seshat-reader-annotation-highlight-enabled`，无法按主题调整颜色。
- 影响：暗色页（反色后）与彩色页面上的黄色半透明高亮可读性不同，用户无法按偏好调整；计划 D3 里提到的「颜色/透明度配置」本期未落地。
- 建议：新增 0 参以外形态的模块函数 `seshat-reader-dyn--set-highlight-style (r g b alpha)`（写入 `DocState` 并置 `highlights_dirty`），elisp 侧加 defcustom `seshat-reader-annotation-highlight-color`（`(R G B)` 浮点三元组）与 `-highlight-alpha`，在 `--apply-highlights` 的 refresh 前同步一次。
- 触发条件：用户反馈高亮看不清（尤其暗色模式），或做主题适配专项时。

## `is_reloading` 跨线程非原子读（M12 审查，2026-10-22）
- 现状：`render/render-core.h` 的 `bool is_reloading` 由主线程写（`emacs_load_doc` / `emacs_close_doc` 置 `true`），渲染线程 `draw_page_thread` 读，两边都没有原子操作或锁。C11 意义上属数据竞争（UB），x86-64 实践上可工作。同文件的 `highlights_dirty` 只在主线程读写（投喂与 refresh 都在主线程），不存在该问题。非 M12 引入。
- 影响：当前平台观察不到故障；换弱内存序架构或编译器做激进优化时，可能出现「渲染线程读到陈旧的 false，继续渲染即将被释放的文档」。
- 建议：改成 `atomic_bool`（`atomic_load` / `atomic_store`，与同文件 `doc_pages[i].refcount`、`active_jobs` 的既有风格一致），或至少在字段上注明「仅主线程写、渲染线程只读、依赖 x86-64 强序」。
- 触发条件：改动渲染线程生命周期、换目标架构，或做 C 层并发专项时。

## MuPDF 对超大矩形是否内部裁剪未确认（M12 审查，2026-10-22）
- 现状：`rect_to_page_space` 已加 ±1e6 点的绝对幅值上限（`HIGHLIGHT_MAX_ABS_COORD`），但 MuPDF 1.28.5 源码不在本机，无法代码级确认 draw device 对超大坐标（如 1e6 × 1e6 的填充）究竟是内部裁剪、还是按像素面积分配临时缓冲。
- 影响：当前靠上限兜底——1e6 点远超任何真实页面（A0 约 3400 点），经 `fz_transform_page` 的 ctm 缩放后仍在安全范围；但没有源码级证据说明「超上限区域会被 MuPDF 丢弃而非扩张」。
- 建议：升级 MuPDF 后复核 `fz_fill_path` / draw device 的 bbox 处理（`source/fitz/draw-device.c` 的 `fz_fill_path` → `fz_scan_convert`），确认超大路径的裁剪点；若发现按面积分配，则在 C 层把 rect 先与 `fz_bound_page` 求交再绘制。
- 触发条件：升级 MuPDF 版本，或出现与高亮相关的 OOM / 卡顿报告时。

## 目录行模型假定页号单调递增（M12 审查，2026-10-22）
- 现状：`seshat-reader-outline--current-path` 以「前序节点里页号 ≤ current 的最后一个」判定当前章，隐含假设 outline 页号单调不减。PDF 规范允许 outline 跳转乱序，MuPDF 也不排序，乱序目录下当前章标记可能指向错误节点。
- 影响：仅影响目录面板的当前章高亮（视觉误导），不影响跳转本身——`RET` 跳到的是各行自己的页号。
- 建议：在 `--current-path` 里做一次单调性检测（遍历行，出现 `page < 前一个 page` 即判非单调），非单调时降级为不标记当前章。补一条 ERT：乱序 outline 下 `--current-path` 返回 nil 而非错节点。
- 触发条件：遇到乱序目录的文档，或下次改目录当前章逻辑时。

## `submit_job` 的 malloc 未检查（M12 审查，2026-10-22）
- 现状：`render/render-threads.c` 的 `submit_job` 对 `malloc` 返回值未判空即解引用，内存耗尽时 NULL 解引用崩溃。M12 在 `submit_render_job` 内增加第二处 `malloc`（每页高亮快照），提高了触发概率（快照失败本身已优雅处理，返回 false）。
- 影响：低概率但后果严重（崩溃而非降级），且发生在渲染路径上，用户只会看到 Emacs 进程消失。
- 建议：`submit_job` 内对 `malloc` 判空，失败时返回 false，由调用方把该 CachedPage 置 `PAGE_STATUS_ERROR`（已有 `mark_cp_error` 可用），让渲染失败降级为错误页而不是崩溃。
- 触发条件：内存紧张环境，或下次改 job 提交路径时。

## 旋转页的 rect 采不准导致高亮可能错位（M12，2026-10-22）——已解决（P2-A，2026-10-27：`seshat-reader-select-posn->page` 出口按 `seshat-reader--multipage-rotate` 逆变换回未旋转页面空间）
- 现状（解决前）：`seshat-reader-select.el` 的选区取文**明确不支持旋转页**（`docs/api.md` §4.5 曾把「不支持已旋转页面」写进 `location` 约定）。M12 的高亮按 `rect` 在 C 层按页面 `ctm` 绘制——`ctm` 含 `rotate`/缩放，而 `rect` 本身是「未旋转页面坐标」，两者对同一个 `rect` 的解释在旋转页上不一致。
- 影响（解决前）：旋转页上的批注高亮位置可能偏移（数据本身已错，渲染忠实反映了错的数据）；不旋转的页无此问题。
- 建议（已采纳 ② 的 elisp 侧版本）：不新增 C 接口——`seshat-reader--multipage-rotate` 自 P1 起在 Lisp 侧可读（`defvar-local`，取值 ∈ {0,90,180,270}），坐标公式（0/90/180/270，90/270 交换宽高）经 C 侧 `fz_transform_page` 源码、同版本 MuPDF 实现与四象限灰度 PDF 像素实测三方核对；逆变换只在 `select-posn->page` 一处施加，避免多处换算叠加。残余项见本文件「`--page-space-size` 的 frame-scale 标定待真机」条（2026-10-28 已解决，仅剩 frame scale ≠ 1 的真机验收）。

## 高亮刷新与 strip 缓存的多窗口局限（M12，2026-10-22）
- 现状：① `--refresh-highlights` 只重建**当前窗口**的 ±5 页缓存（`wait_for_win_jobs` → `nullify_window_cache` → `build_cache_window` → `display_cached_page`，均以当前 `EmacsWinState` 为作用域），同文档的其它窗口在各自下次 redisplay 前仍显示旧位图；② 跨页 strip 用的上一页 image spec 缓存 `seshat-reader--page-image-specs` 是 **buffer 级** `defvar-local`（上限 5 条），而记录时页号取「当前选中窗口」显示的页——多窗口显示同一文档的不同页时，strip 取到的「上一页」可能与自身窗口的上一页不符。
- 影响：**仅多窗口场景**（同一 PDF 在两个窗口并排对照）。单窗口下两条局限都观察不到。
- 建议：①刷新时遍历同 buffer 的全部窗口（`get-buffer-window-list`）逐个失效并重建，或至少对其它窗口打「高亮已过期」标记，在其 redisplay 时强制重建；②把 spec 缓存改为按窗口维度（`window-parameter` 或 `(window . page)` 为键的 alist），而不是 buffer 级。

## 缩放/旋转后 strip 的上一页 spec 是旧尺寸（M12，2026-10-22）——已解决（2026-10-27 已随 P1 多页布局改造失效/解决：strip 机制已删除，spec 由 `--multipage-resize-spec` 逐页改写）
- 现状：`seshat-reader--page-image-specs` 缓存的是**页面已显示时**的 image spec（含当时的像素尺寸），缩放（`seshat-reader-increase-size` / `fit-to-width` / `fit-to-height`）或旋转后只重渲染当前页，**不清空该缓存**；strip 按缓存的旧图像尺寸裁取，再以 `:slice` 插到新尺寸的当前页之前。
- 影响：缩放后跨页 strip 的高度/内容与新页不匹配（旧尺寸的底部若干行被拉成固定像素高，比例与当前页不一致），旋转后同理；关掉 `seshat-reader-page-join-lines`（设 0）可规避。
- 建议：在缩放/旋转/重排尺寸的入口统一清空 `seshat-reader--page-image-specs`（或按新尺寸重新 `--remember-current-page-spec`），并保证下一次「上一页」可见时重建缓存；补一条 ERT 断言「缩放后缓存为空/尺寸已更新」。

## 跨页衔接（M12 strip）在 fit-to-height 下裁切页面（2026-10-22 真机反馈）——已解决（2026-10-27 已随 P1 多页布局改造失效/解决：机制已删除，跨页衔接由多页连续布局天然提供）
- 现象：`seshat-reader-page-join-lines` 取非 0（M12 默认值曾是 `1`）时，刚打开 PDF 页面不居中、整体挤向左侧，且只显示当前页的一小部分——`seshat-reader-fit-to-height` 下尤其明显。
- 根因：① 纵向——`seshat-reader--insert-join-strip` 在 `point-min` 插入 strip 行，破坏了页面 overlay 的几何假设：`seshat-reader--set-window-vscroll` 的上限与落点按「strip 高 + 图高」计算，而实际渲染的页面 image 并不包含 strip（strip 是另一行的独立 image），`fit-to-height` 把页高压到窗高之后任何正 vscroll 都会把页顶挤出窗口。② 横向——`seshat-reader--center-page` 把 `line-prefix` 从页面 overlay 移到 buffer 级 overlay 后，一旦 `when-let*` 链路短路就零兜底；叠加**既有缺陷**：`window-size-change-functions` 把 frame 当 window 传给 `--center-page`（参数类型不符，实际不生效），窗口尺寸变化后居中从不重算。
- 现状（止血，2026-10-22）：`seshat-reader-page-join-lines` 默认值改为 `0`（strip 默认关闭，代码路径完全不插 strip）；`window-size-change-functions` 改挂 `seshat-reader--window-size-change`（遍历 frame 的窗口，只处理显示当前 buffer 的窗口，单窗口出错不影响其它）；`--set-window-vscroll` 的 `image-height`、`--get-prefix-width` 的返回值补 nil 守卫（后者恒返回数字），`--center-page` 短路时清掉旧 `line-prefix` 并把水平滚动归零。
- 建议：彻底修法二选一——① 让页面 overlay 与 strip 行**彻底分离**（`move-overlay` 收回到当前页字符范围，页面几何只由页面 image 决定，strip 作为独立行处理，vscroll 上限不再叠加 strip 高）；② 改由 C 侧在渲染页面时**预留条带**（把上一页底部直接画进页面位图顶部），elisp 侧不再插行。任一方案落地并补真机验证后，再把默认值改回非 0。

## PDF 文本选区层与 `rect:` 采集未做（M10.3，2026-10-22）
- 现状：PDF **文本**批注在 Android 侧只记 `page:<n>`（`PdfReaderActivity` 长按菜单的「添加本页备注」走 `"page:${firstVisiblePage() + 1}"`，产 `kind=note`），没有选区层、也没有 `rect:` 坐标采集；`page:<n>;rect:...` 目前只有 Emacs 选区批注产生。本轮（M10.3）**明确不做**，原因：Android 侧 PDF 文本坐标需要 `PdfRenderer` 之外的文本布局信息（当前只有 `PDFTextStripper` 的纯文本，无字/行边界），属新能力而非文档同步。
- 影响：Android 端 PDF 高亮只有「页 + 选中原文」，无法在页面上画出高亮；跨端显示不对称——Emacs 建的 `rect:` 批注在 Android 上只能按页展示。`docs/api.md` §4.5 已把「PDF 文本批注本轮不产 `rect:`」写入契约。
- 建议：需要 PDF 高亮可视化时，先在 Android 引入文本行边界采集（`PDFTextStripper` 的 `TextPosition` 或换用带布局的抽取），再按 §4.5 的 `x0,y0,x1,y1` 换算；旋转页仍不支持（既有约束）。

## Android 无 instrumentation，EPUB 偏移采集与抽屉交互只靠纯函数单测 + 手工验收（M10.3，2026-10-22）
- 现状：`android/app/src/` 只有 `main` / `test` / `debug`，**没有 `androidTest`**（`./gradlew :app:testDebugUnitTest` 是唯一自动化入口）。M10.3 的新逻辑被刻意切成可 JVM 测试的纯函数（`LocationCodec` / `SelectionPayload` / `AnnotationGrouping` / `PendingDeletes` / `LocationScroll`），但**真正的 WebView 选区偏移采集**（注入脚本 + `Range` 前缀长度）与**抽屉的触摸/返回键交互**无法在 JVM 覆盖。
- 影响：偏移口径（`document.body` 文本流、UTF-16 code unit、跨块级空白规范化）与抽屉手势是否抢横向翻页，只能靠真机人工验收；这些路径处于零自动化保护状态。
- 建议：引入 `androidTest` + `Espresso`/`UiAutomator` 后优先补三条——① 真实 EPUB 上选中同一段文本两次，`chapter:<i>@<s>-<e>` 三段一致；② 抽屉打开时返回键只关抽屉；③ 抽屉开合不改变阅读区 padding。

## 一笔一条 annotation 的量级风险（M10.3，2026-10-22）
- 现状：`kind=ink` 的镜像批注**一笔一条**（协议见 `docs/api.md` §4.5.1），一页写 30 笔即 30 行；`GET /api/annotations?uid=` 按 uid **全量返回**（无分页、无 location 过滤），客户端 `pullAnnotations` 每次全量拉取并逐条合并。
- 影响：手写密集的书（讲义、习题）批注表可达数千行；打开书时的拉取/合并成本随笔数线性增长，服务端亦无按「页 / location 前缀」的查询入口（这也是 ink 汇总行无法批量删除的原因）。
- 建议：二选一——① 协议层加「按 location 前缀查询」或分页（`?page=` / `?prefix=page:12`）；② 客户端把 ink 合并为「按页一条」上传（`page:<n>;ink:` 后串联多笔），代价是单笔删除能力丧失。任一方案都要先量一次真实笔数分布（可用现有 `PdfInkStore` 数据统计）。

## T7 实现遗留：ink 聚合行不可单条删除、`chapter:` 条目不支持跳章（T7，2026-10-22）
- 现状 ①：Emacs 批注列表把同页 ink 合并为聚合条目（`seshat-reader-annotation--group-ink-items` / `--ink-aggregate-item`），该条目的 `:id` 与 `:uuid` 恒为 `nil`、只保留 `:ink-ids`（各笔服务端 id），因此 `d`（`seshat-reader-annotation-list-delete`）只弹一句提示、**删不掉**；要删只能回 Android 抽屉逐笔删或直接调 API。
- 现状 ②：`seshat-reader-annotation-list-goto` 的跳转只看行属性 `seshat-reader-annotation-page`（由 `--page-from-location` 解析 `page:<n>`），`chapter:<i>@<s>-<e>` 形态解析不出页码 → 只提示「当前行没有可跳转的页码」，**不支持跳章**；`--chapter-from-location` 目前只用于摘要文案（「章节 N」）。
- 影响：Emacs 侧对 EPUB 批注与 ink 批注只能「看」，不能「跳」或「删」，功能不对称。
- 建议：① 删除路径改为按 `:ink-ids` 逐条 `DELETE`（逐条成功再刷新，失败保持原样）；② 跳转增补 chapter 分支——`chapter:` 条目需先按 `spineIndex` 换到对应页（`seshat-reader` 的页 ↔ 章映射）再走 `seshat-reader-goto-page`，或复用 EPUB 端「跳章 + 偏移滚动」思路（Emacs 侧无 DOM，按字符偏移找位置成本更高）。

## Android 进度 409 未实现「重拉比较 + 带新时间戳重发」（M10.3/M10.4，2026-10-22）——已解决（2026-10-22 收尾轮：引擎 + UI 接线）
- 现状（历史）：`docs/sync-protocol.md` §7.2 要求进度冲突时「重拉 → 比较 `updated_at` → 以较新者为准 → 本地较新则带新 `updated_at` 重发一次」；Android 的 `pushProgress` 只是「带本地时间戳 `PUT`」，409 经 `ensureSuccess` 抛 `ApiException` 后由阅读器 `runCatching` 记为「推送失败（已忽略）」，**没有重拉与重发**。批注分支已实现（`UpdateAnnotationResult.Conflict` → `resolveConflict`）。
- 影响（历史）：两端同时阅读同一本书时，本地进度可能被服务端拒绝后丢失（下次 `onStop` 才再推，届时仍可能 409），用户可能看到「退出去再打开，进度跳回旧位置」。
- 解决（引擎）：`sync/SyncManager.kt` 新增可判别结果 `ProgressPushResult`（`Pushed` / `Merged` / `Rejected` / `Skipped`）与 `pushProgressDetailed(uid)`——409 → `getProgress` 重拉 → 本地较新则用「严格大于服务端 `updated_at`」的时间戳（`RETRY_TIMESTAMP_STEP_MILLIS` = 1000ms，服务端为秒精度）重发**一次** → 仍 409 返回 `Rejected`；服务端较新则写回本地并返回 `Merged`。`pushProgress` 降级为兼容包装（`Pushed`/`Merged` → `Progress`，其余 `null`，**公共 API 保留**），`syncDocument` 把该结局记入 `SyncSummary.progressRejected`。
- 解决（UI 接线）：`reader/EpubReaderActivity.kt`、`reader/PdfReaderActivity.kt` 的进度推送（`setupSync` 的打开时首推 + `enqueuePushProgress` 的 `onStop` 推）改调 `pushProgressDetailed` 并由私有 `handleProgressPush` 穷尽三态：`Pushed`/`Merged` 记 `lastPushedPosition`（防抖，`Merged` 静默因本地已被服务端值覆盖）→ 视为成功；`Rejected` 记 `Log.w`（含服务端 `updated_at`）+ 一次 Toast「进度同步冲突，已保留服务端版本」（`R.string.reader_progress_conflict`），由字段 `progressConflictNotified` 保证每个 Activity 生命周期只提示一次。
- 验证：`SyncManagerTest` 覆盖 `Merged` / 本地较新重发成功（`Pushed`）/ 重发仍 409（`Rejected`）三条分支；`./gradlew :app:testDebugUnitTest --rerun-tasks` 934 例 / 0 失败 / 1 跳过。
- 遗留：Activity 侧的三态 UI 分支无 JVM 单测覆盖（项目未引入 Robolectric，且 Toast 属设备级行为），只能真机/人工验收；「非 409 的异常」仍按原语义上抛给 `runCatching` 记 warn，不含用户提示（与批注分支一致）。

## M12 遗留：`emacs/seshat-reader` 的 `make all` 有 30 处 byte-compile warning（M12 基线，未修，2026-10-22）
- 现状：`emacs/seshat-reader` 执行 `make all` 产出约 30 处 byte-compile warning，集中在 `seshat-reader.el`（docstring 列宽、未使用参数、`free variable` 类告警）。这是**远程 M12 合并后的基线状态**，与 M10.3/M10.4 的改动无关（本轮未触碰 `seshat-reader.el`），为避免与 M12 归档内容冲突**未在本轮修**。
- 影响：warning 噪声掩盖新增告警（M12 与 M10.3 的改动都不易从输出里看出是否引入新问题）；`make all` 仍退出 0，不影响功能。
- 建议：单开一轮「seshat-reader 编译告警清零」——逐条分类（docstring 列宽可 `checkdoc` 自动修；`free variable` 需补 `defvar` 声明或改 `with-suppressed-warnings`），并把 `-Werror` 作为后续门禁的前提条件之一。

## `PUT`/`DELETE /api/annotations/{id}` 不校验 uid 归属（M7 既有行为，M10.3 复审，2026-10-22）
- 现状：`internal/api/server.go` 的 `handleUpdateAnnotation` / `handleDeleteAnnotation` 只把路径里的自增 `id` 交给 `storage.UpdateAnnotationAt` / `DeleteAnnotation`，**不比对记录实际的 `uid`**；任何持 Bearer token 的调用方用任意 id 即可改写/删除该批注（`uid` 创建后不可修改，但「谁能改哪一条」完全由自增 id 空间决定）。
- 影响：单用户部署下 Bearer token 是唯一的安全边界，行为等价（这也是它至今未被当作缺陷的原因）；一旦引入多用户或不同权限的令牌，即构成跨 uid 越权（IDOR，id 自增可穷举）。`GET /api/annotations?uid=` 有 uid 约束，读写两路鉴权口径因此不对称。
- 建议：二选一——① 端点接受可选 `uid`（query 或请求体）并与记录实际 `uid` 比对，不匹配返回 `404 not_found`（不泄露存在性）；② 改路径为 `/api/documents/{uid}/annotations/{id}`。两种都需 Emacs `seshat-rest.el` 与 Android `RestClient` 同步改动，故留待需要多用户时一并做。

## EPUB location 换代后 pull 的幂等键不同形（M10.3，2026-10-22）
- 现状：EPUB 批注 location 由旧形态 `chapter-<n>` 迁移到 `chapter:<spineIndex>@<startOffset>-<endOffset>`（`EpubSyncMapper.location()` 在 `BookAnnotation.location` 为空时仍回退 `chapter-<chapterIndex>`）；`SyncManager.pullAnnotations` 的「三路匹配」第 2 路按 `(kind, location, text)` 认领本地 `serverId == null` 的记录，两边形态一旦不同串就恒不相等 → 只能落到第 3 路「新增」。
- 影响：存量旧记录（本地无 location、服务端已是新形态）理论上会在 pull 时**重复显示**（一条本地旧条目 + 一条服务端新条目）；`AnnotationStore` 没有跨形态去重键，重复对用户可见且会各自被后续操作独立处理。
- 建议：① 认领键改为「归一化后比较」——用 `LocationCodec.parse` 解析出 `Chapter(spineIndex)` 即视为同章（需接受 `@start-end` 差异）；② 或一次性存量迁移（本地 `chapter-<n>` 补成 `chapter:<n>@0-0`，迁移须幂等）；③ 根治靠服务端稳定的客户端幂等键（另见「无服务端 client_uuid」）。

## `LocationCodec` 对 location 长度与 ink 点数无上限（M10.3，2026-10-22）
- 现状：`android/.../reader/LocationCodec.kt` 只用正则限制各段数字位数（`\d{1,9}`），对**整串长度**与 `ink:` 的**坐标点数**都没有上限（`grep -n "MAX_INK_POINTS\|MAX_OFFSET" LocationCodec.kt` 零命中）；`LocationScroll.MAX_OFFSET`（10_000_000）只夹紧「跳转脚本里注入的偏移量」，与 location 解析/存储无关。服务端 `annotations.location` 为 `location TEXT NOT NULL`（`internal/storage/db.go:58`，v8 只 ADD COLUMN，未动该列），除请求体 1 MiB 上限外无长度约束。
- 影响：脏数据或恶意客户端可提交接近 1 MiB 的单个 location（数万坐标点），随 `GET /api/annotations?uid=` 全量 pull 进两端内存并参与列表渲染；Emacs 侧有 `seshat-reader-annotation--location-max-length`（65536）兜底，**Android 侧解析与 `InkAnnotationMapper` 切分都没有对应上限**（`kind=ink` 一笔一条放大了行数，见「一笔一条 annotation 的量级风险」）。
- 建议：`LocationCodec` 增 `MAX_LOCATION_LENGTH`（建议 65536，与 Emacs 侧对齐）与 `MAX_INK_POINTS`（建议 4096；超出即拒绝或截断并计数），并补畸形输入单测（超长串、超大点数、`page:` 后跟 1e9 个逗号）。服务端如要根治需给 `location` 加长度校验并返回 `400 invalid_argument`，属协议变更，须与两端解析上限一并定稿。

## `PdfInkStore` 的写方法未加锁（M10.3 进度接线轮观察，2026-10-22）
- 现状：`reader/PdfInkStore.kt` 的 `appendStroke` / `undoLast` / `clearPage` 都是「读整份 `PdfInkDocument` JSON → 改内存 → 写回 SharedPreferences」的 read-modify-write，**未加 `@Synchronized`**。同目录的 `AnnotationStore` 因有「阅读器主线程（读者新增/删除）+ 同步线程（`pushAnnotations` 回填、`pullAnnotations` 合并、手写补登 `add`）」两条**并发写**路径，其写方法已全部 `@Synchronized`（见该类注释）。
- 判定（当前**不是**缺陷）：`PdfInkStore` 目前只在主线程写（落笔 / 撤销 / 清页），同步线程只**读**一次快照（`PdfReaderActivity.backfillInkAnnotations` → `inkStore.document(docId)`），读路径不做 read-modify-write，故不存在「读到旧快照再写回、覆盖掉并发笔画」的丢更新路径。
- 建议：若将来同步线程需要**写**笔迹（如把服务端下发的 `ink:` 落成本地笔迹、或按页批量删除），须先照 `AnnotationStore` 的做法给这三个写方法加 `@Synchronized`，并让 `document` 读也进同一把锁；否则会静默丢笔画。按「改前检查项」记录，当前无需改动。

## `seshat-reader--center-page` 以 `unconstrained` 设 hscroll，超宽页被两侧裁切（2026-10-22 观察，2026-10-23 已缓解）
- 现状：`seshat-reader--center-page` 用 `(seshat-reader--set-window-hscroll window scroll-offset t)` 写入水平偏移，第三个实参 `unconstrained = t` 绕过 `--right-most-window-hscroll` 的夹紧；当页面 image 宽于窗口（`doc-left-offset` 为负）时 `scroll-offset` 也是负值，页面整体左移、左右各裁掉约一半。放大到超宽（`+` / `W`）时同样命中。
- 缓解（2026-10-23）：`scroll-offset` 计算加 `(max 0 …)`，超宽时页面左对齐而不是两侧裁切；自动 fit（首次 + 尺寸变化后）改为 `seshat-reader--contain-scale`（`min(按高, 按宽)`），默认路径不再产生超宽页。仍未实现「横向滚动跟随翻页」（超宽页只能用 `scroll-left` / `scroll-right` 手动左右看），`unconstrained = t` 本身也未收紧。
- 建议：若要根治，给 `unconstrained` 路径补「页面至少留 N 列可见」的下界夹紧，并在翻页 / vscroll 变化时把水平偏移按阅读位置（左/中/右三段）跟随；须与 `seshat-reader-page-join-test.el` 的 5 个 vscroll 用例同步。

## `seshat-reader-default-fit` 在自动 fit 路径上已成 no-op（2026-10-23，D6 副作用）——已解决（重定义为新窗口初值，2026-10-23）
- 现状：自动 fit（`seshat-reader-mode` 首次 fit 与 `--refit-window` 的 fit 分支）改走 `seshat-reader--contain-scale`（`min(按高, 按宽)`）后，`seshat-reader-default-fit` 在整个仓库里只剩 defcustom 自身，没有任何调用点（`grep -n seshat-reader-default-fit emacs/seshat-reader/` 仅命中定义与一条 docstring 引用）。它不是缺陷的成因，但会让用户误以为可配置。
- 影响：设成 `seshat-reader-fit-to-width` 与 `seshat-reader-fit-to-height` 在自动 fit 下行为完全一样；任何「用该选项覆盖 contain」的实现都会让另一维溢出，因此**无法**在不溢出的前提下恢复区分度。
- 建议：二选一 —— ① 删除该 defcustom（破坏性变更，需在 CHANGELOG 记 BREAKING 并同步 `docs/configuration.md`）；② 重新定义为「手动 `H`/`W` 之外的默认命令」或彻底改语义（例如「是否允许放大到填满」）。在定稿前保留原样，并在 docstring 注明「自动 fit 不再使用本选项」。
- 已解决（2026-10-23）：该选项被重定义为「新窗口 / 新文档的初始适配模式」（`contain` / `width` / `height`，默认 `contain`），由 `--first-fit` 与 `--window-create-function` 读取；旧函数符号值经 `--normalize-default-fit` 兼容映射。见 `openspec/completed/2026-10-23-reader-default-fit-mode.md`。

## `seshat-reader--set-window-vscroll` 缺下界夹紧（2026-10-23）——已解决（2026-10-27 已随 P1 多页布局改造失效/解决：vscroll 族已删除，页内偏移由 `--multipage-page-max-offset` 夹紧）

- 现状：`seshat-reader.el:607-610` 的 `(max 0 …)` 只作用于**上限值**（`max-pixel-vscroll`），`corrected-pixel-vscroll` 只做 `(min pixel-vscroll max-pixel-vscroll)`，负值原样下发给 `set-window-vscroll`。本轮仅在尺寸变化路径用 `seshat-reader--clamp-window-vscroll` 绕行（先按 `--page-max-vscroll-pixels` 夹到 `[0, max]` 再下发），函数本身未修。
- 影响：其他调用点（翻页落点、书签恢复的 vscroll）若传入负值，页面仍可能被推出窗口顶部；`seshat-reader-page-join-test.el` 的 5 个 vscroll 用例锁定的是当前（含该缺口）行为，动函数会牵动这些断言。
- 建议：根治须同时补下界夹紧（`(max 0 (min pixel-vscroll max-pixel-vscroll))`）并更新上述 5 个用例，且与本计划（尺寸变化自适应）同批推进，避免两处夹紧口径不一致。

## 书签恢复不携带缩放来源（2026-10-23）

- 现状：`seshat-reader-bookmark.el:29` 只写 `(cons 'scale (seshat-reader-current-doc-scale-value))`，`:39` 读出后交给 `seshat-reader-doc-scale-page`（1 参调用，不带 source）。书签里没有「这个比例是手选的还是自动 fit 的」这层信息。
- 影响：跨会话恢复后 `scale-source` 为 nil（`seshat-reader--window-scale-source` 按 `fit` 处理），此后窗口尺寸一变就走 contain 重新贴合，把用户上次手选的比例重置。
- 建议：扩展书签存储格式（`'scale` 的值改为 `(scale . source)`，或新增独立键），并对旧标签兼容（缺 source 按 `fit`，与当前行为一致）。属存储格式演进，须与 `docs/` 中书签说明同步。

## 同一 buffer 重设窗口不触发 `window-buffer-change-functions`（2026-10-23）

- 现状：`(set-window-buffer win (current-buffer))` 同样会让 Emacs 归零该窗口的 hscroll（与换 buffer 同一机制），但 `window-buffer-change-functions` 只在**缓冲区发生变化**时运行，同 buffer 重设不触发；D8 在 `seshat-reader--handle-window-buffer-change` 里的 recentre 因此兜不住这一情形。
- 影响：用户或第三方包对同一个阅读窗口重复 `set-window-buffer` 后，页面可能贴右边缘，只能重开文档或触发一次尺寸变化自愈。
- 建议：覆盖需 advice `set-window-buffer`，会侵入所有调用方并可能与其他包的 advice 交互，暂不采用；若将来出现实际投诉再评估。

## `fit-to-height` / `fit-to-width` 仍裸读 image size（2026-10-23）

- 现状：`seshat-reader.el:397` 的 `(cdr (seshat-reader--get-current-doc-image-size))` 与 `:408` 的 `(car …)` 均未做 nil 守卫，页面尚未渲染时得到 nil 并直接进除法。
- 影响：只在显式 `H` / `W` 命令路径触发（首次打开走 contain，不会走到这里），D8 未覆盖；命中时报 `wrong-type-argument`。
- 建议：与 `--right-most-window-hscroll` 同口径加 `(numberp …)` / `(or … 0)` 守卫；注意 `(or … 0)` 会让未渲染时算出 0 缩放因子，须一并定「未渲染时直接 no-op」的语义，故本轮未随手改。

## `--contain-scale` 与 `--fit-scale` 的 contain 分支并存（2026-10-23）

- 现状：`--fit-scale` 的 `contain` 分支**直接转调** `--contain-scale`，两者语义等价——`--contain-scale` 是纯计算函数（取 `min(按高, 按宽)` 且刻意忽略 `seshat-reader-default-fit`），`--fit-scale` 在其外面包了一层「按 `fit-mode` 三值分支」。自适应改造**刻意未动** `--contain-scale` 本体（既有 16+ 例测试直接锁定它）。
- 影响：同一语义有两个入口，若将来改 contain 的算法（例如引入「允许放大到填满」或 strip 高度参与计算），必须同时确认两条路径；读代码时要多跳一次才知道 `contain` 的权威实现在 `--contain-scale`。
- 建议：保持现状即可（双入口换来零回归，收益大于整洁度）；若将来要合并，把 `--contain-scale` 收敛为 `--fit-scale` 的 `contain` 分支私有实现，并同时把锁定它的 16+ 例测试改指向 `--fit-scale`。

## `seshat-reader-default-fit` 仍是 no-op（2026-10-23，`fit-mode` 落地后复核）——已解决（2026-10-23）

- 现状：自动 fit 由 window parameter `fit-mode`（`contain` / `width` / `height`，未设置按 `contain`）决定，`seshat-reader-default-fit` 在整个仓库里仍只剩 defcustom 自身（`grep -n seshat-reader-default-fit emacs/seshat-reader/` 零调用点）——它既不参与首次打开、也不参与尺寸变化后的 refit，`W` / `H` 的语义已完全由 `fit-mode` 承载。
- 关联：既有条目「`seshat-reader-default-fit` 在自动 fit 路径上已成 no-op（2026-10-23，D6 副作用）」记录的是同一事实的成因（contain 化），本条只记录 `fit-mode` 落地后的现状，不重复其分析。
- 影响：设成 `fit-to-width` 与 `fit-to-height` 在自动路径下仍毫无差别；`fit-mode` 引入后该选项更易误导——用户想做的是「默认按宽度适配」，正确做法是打开文档后按 `W`（写入 `fit-mode`），而配置里改该选项没有任何效果。
- 建议：二选一 —— ① 删除该 defcustom（破坏性变更，需在 CHANGELOG 记 BREAKING 并同步 `docs/configuration.md`）；② 重新定义为「首次打开时写入的 `fit-mode` 初值」（`fit-to-width` → `width`、`fit-to-height` → `height`，其余 → `contain`），这样它重新有意义且不新增选项。②更贴合「默认适配维度」诉求，但需与「`fit-mode` 是否跨会话记忆」一并定稿（当前不记忆）。
- 已解决（2026-10-23）：同上条；`fit-mode` 与 defcustom 现已分工明确（前者管窗口、后者管起点），该选项重新具备可观察效果。

## `image-flush` 已从 `--apply-display-scale` 移除，「C 侧下次重渲染即清旧缓存」已观测：无线性泄漏（2026-10-23 真机 T4-3）

- 现状：`--apply-display-scale` 只改 image spec 的 `:width` / `:height`，实测（pure 实例）原地修改后无需 `image-flush` 即生效；早期版本在改写前调 `(ignore-errors (image-flush spec))` 主动丢弃旧缓存条目，但拖动分割线时每帧 flush 会强制 redisplay 重解码整页位图（真机实测拖一次卡 1–2 秒），**本轮已把 flush 整个移除**，改为依赖「C 侧下次重渲染替换 spec 时清掉旧缓存条目」。这条断言是读代码得出的推断，**该断言已于 2026-10-23 真机观测（T4-3），见下方「已观测」。**
- 影响：批量 ERT 全程在 batch 下跑（`image-property` / `image-flush` 可用，但**没有真实 GUI image cache**），因此「反复缩放数千次后的内存曲线」「不 flush 时旧位图是否真的被替换清掉」「image cache 峰值内存」这三件事只有真机能回答。若推断不成立，旧位图会滞留到 `image-cache-eviction-delay`（默认 300s，见下一条「image cache 条目累积」）。
- 建议：T6 真机验收（拖分割线）时顺带观测——拖拽期间与停手后各取一次 `memory-info`，并在同一文档上反复开合面板 20 次以上，若与 image cache 相关的计数持续上涨则按 H6 降级（改为「只在 idle 做 apply，接受一帧中间态」）；如需定量，可在 GUI 下用 `(image-cache-size)` 前后对比。若确认必须 flush，则只能加在「停手后的那次 refit」里（每帧加不起）。
- 已观测（2026-10-23 真机 T4-3，GUI Emacs 31.1 / pgtk）：同一文档开合目录 20 次，`(image-cache-size)` 59,985,948 → 61,860,828 B（+1,874,880 B ≈ +1.79 MB，≈90 KB/次），`(nth 1 (memory-info))` 22,090,868 → 22,010,188 kB。若无回收，20 次应至少涨一个数量级（整页位图约 2 MB/张），实测为常数级增量 → **「C 侧下次重渲染替换 spec 时旧缓存被回收」成立**，未见线性泄漏。剩余风险：长时间（数小时）曲线仍未观测，`image-cache-eviction-delay` 到期前的滞留量未定量。

## image cache 条目累积（原地改 spec 尺寸，2026-10-23）——已部分观测：拖拽期间零增长（真机 T4-4）

- 现状：image cache 以 spec 内容（含 `:width` / `:height`）为键。`--apply-display-scale` 原地改写这两个属性后，旧键条目不会立即消失，而会滞留到 `image-cache-eviction-delay`（默认 300s）。拖拽分割线时尺寸变化事件密集，数秒内即可造出几十个条目（A4 页面约 600×850 px，每条约 2 MB 量级），峰值内存随拖拽时长上涨。曾经用「改写前 `ignore-errors (image-flush spec)`」缓解，但逐帧 flush 会让拖动卡 1–2 秒，**本轮已把 flush 移除**——旧条目现在全靠 `image-cache-eviction-delay` 与 C 侧下次重渲染替换 spec 时回收，长时间真机内存曲线仍未观测，但 10 秒拖拽窗口已观测（T4-4），见下方「已观测」。
- 影响：长时间拖拽或频繁开关面板后，缓存里可能同时存在多份位图；`image-cache-eviction-delay` 到期前不会回收，属于「有界但不可控」的内存占用（上界与条目数、页面像素数成正比）。
- 附记：`--refit-window` 的清晰度闸（`render-scale` 与 `scale` 比较）写在 `unless manual` 守卫**之外**，理论上 manual 窗口在两者不相等时也会重渲染一次。正常路径下 manual 不改 `scale`（`+` / `-` / `0` 走 `doc-scale-page` 且写回同值），两者恒相等，故不触发；但若将来 manual 路径开始写不同值（例如引入「手动缩放下仍提升清晰度」），这行会成为一处隐性重渲染入口，改动时需一并审视。
- 建议：① 真机长观测（见上一条）；② 若确认峰值内存不可接受，改为「apply 只在几何变化超过阈值时执行」（合并连续小幅尺寸变化，减少键数量）或临时下调 `image-cache-eviction-delay`；③ 把清晰度闸移进 `unless manual` 分支（或显式加 `manual` 判据）以消除附记里的理论入口。
- 已观测（2026-10-23 真机 T4-4）：拖右侧分割线 10 秒，0.2 秒/次共 51 个采样点。拖拽期间 `(image-cache-size)` 的最大值 82,581,352 B **正是起始值**，末次采样 82,037,816 B（零增长、略降）；停手后一次采样 88,059,084 B（+6 MB ≈ 3 张位图，由 `image-cache-eviction-delay` 回收）；`(nth 1 (memory-info))` 21,864,632–21,892,992 kB，波动 <0.2%。结论：`seshat-reader--drag-threshold`（0.12 秒）**确认生效**，拖拽期间不产生新 cache 条目；条目累积风险由「密集增长」降级为「停手后一次性 +数张位图」。附记（清晰度闸写在 `unless manual` 守卫之外）仍然成立，未改。

## `page-join` strip 与 `before-string` 居中的交互未验证（2026-10-23）——已解决（2026-10-27 已随 P1 多页布局改造失效/解决：两套居中机制合并为逐页 `(space :align-to …)` 引导空格，strip 与 `--center-overlay` 全族已删除）

- 现状：居中改由页面 overlay 的 `before-string`（`:align-to`）承载后，页面行不再依赖 `line-prefix`；而跨页衔接 strip（`seshat-reader-page-join-lines` > 0）**依赖 center overlay 的 `line-prefix`** 才会跟着右移——fits 模式下 `--center-page` 现在会主动把 center overlay 的 `line-prefix` 清成 nil，strip 行因此只拿到页面 overlay 的 `before-string`（overlay 覆盖范围是页面行，strip 行是否在范围内取决于 `--ensure-center-overlay` / 页 overlay 的 `point-min`..`point-max` 覆盖）。
- 影响：`page-join-lines` 默认 `0`（关闭），故默认配置不受影响；一旦用户开启，strip 行可能比页面左移半个余量（或反之），表现为「上一页底部残影偏左」。批量 ERT 用 `overlay-get … 'before-string` / `'line-prefix` 断言几何，**不产生真实 redisplay**，无法发现视觉错位。
- 建议：真机验收时把 `seshat-reader-page-join-lines` 设为 `1` 单独过一遍（翻页后看 strip 与页面的左右边界是否对齐）；若错位，给 strip 行单独挂 `before-string`（与页面同一 `:align-to` 形态）或把 `before-string` 从页 overlay 移到 buffer 级 center overlay（两者权衡：后者要保证只在 fits 模式写、超宽模式清）。
- 更新（2026-10-23）：观测脚本已备（设置 `seshat-reader-page-join-lines` 为 1 后**用翻页**触发 `--update-join-strip`——调用点 seshat-reader.el:310/322/334/344/354——而不用 `revert-buffer`，后者会撞上本文件新增的「`revert-buffer` 后 buffer 保持 modified」条目），但按用户 2026-10-23 决定本轮不做，仍待真机目视。

## `--centered-p` 与 `--center-page` 的超宽判据分别用 `<` 与 `>=`（2026-10-23）

- 现状：`--center-page` 用 `(>= window-width doc-image-width)` 判定「页面放得下」并走 `before-string`；`--centered-p` 用 `(< window-width image-width)` 判定「页面比窗口宽」并检查 `line-prefix` 宽度。两者是同一判据的**互补写法**（`>=` 与 `<` 覆盖全部情形，恰好不重叠也不遗漏），但没有抽成同一个谓词。
- 影响：当前等价、行为正确（`=` 边界时 `--center-page` 走 fits 分支、`--centered-p` 走第二个分支——注意它在 `=` 时**不进**超宽分支，而进「能放下」分支做 spec 身份比较，与 `--center-page` 一致）。风险在于将来若有人只改一处（例如把「放得下」改成允许 N px 容差），两处会立刻给出不同答案，表现为「居中判定永远为假、每次 pre-redisplay 都重居中」——性能问题而非功能问题，很难凭现象定位。
- 建议：抽一个 `--page-fits-window-p (window)` 供两处共用；抽之前若必须改其中一处，务必同步另一处。

## `--first-fit` 无法区分 `--apply-display-scale` 返回 nil 的两种原因（2026-10-23）

- 现状：`--first-fit` 在 `(unless (--apply-display-scale …) (doc-scale-page …))` 里把 nil 一律当成「需要同步重渲染」。而 `--apply-display-scale` 在两种情况下返回 nil：① 拿不到页面 image spec（首次打开时页 overlay 的 `display` 还不是 image）；② spec 尺寸**已等于**目标尺寸（无需改动）。
- 影响：情形 ② 会多走一次同步 `doc-scale-page`（重渲染一次整页位图），功能正确但首次打开白做一次 C 侧渲染；只在「打开时窗口尺寸恰好等于文档默认渲染尺寸」这类边角出现，常规使用碰不到。
- 建议：让 `--apply-display-scale` 区分「已是最优」与「拿不到 spec」（例如返回 `'unchanged` / `nil` 两值），`--first-fit` 只在 `nil` 时才回退重渲染。改返回值会影响 resize 测试里对该函数的现有断言（多处按真/假判），需同批调整。

## batch 下 `window-body-width` 恒 80px（2026-10-23）

- 现状：ERT 在 batch 下没有真实 GUI frame，`(window-body-width)` 恒为默认 80 列、`window-body-height` 也是默认值，因此「页面放得下 / 放不下」这一分支的选择**完全由桩值决定**。本轮 resize 测试改成用桩 `window-body-width`（`cl-letf`）显式指定每例的窗口宽度，才能稳定命中 fits / 超宽两条分支。
- 影响：凡新增涉及「页面是否放得下」「居中走 before-string 还是 line-prefix」的用例，若忘了桩窗口宽度，就会跑到与意图相反的 branch，红灯与实现无关、容易误判成回归；同理，`--contain-scale` / `--fit-scale` 的断言依赖 `window-body-width` / `-height` 的桩值，数值一变结论就变。
- 建议：把「桩窗口几何」做成测试辅助宏（例如 `seshat-reader-test--with-window-geometry`），新增用例统一走它；已在 resize 测试内部用 `cl-letf` 实现，尚未提取为共享辅助函数。

## 阅读器尺寸自适应的两项 L3 验收：L3-6 已通过、L3-8 部分验证（2026-10-23 真机 T4-1 / T4-2）

- 现状：计划 `openspec/completed/2026-10-22-emacs-reader-resize-refit.md` 的 T4 列了 8 条真机验收（L3-1..L3-8）。归档时（2026-10-23）判定其中 6 条由后续计划 `openspec/completed/2026-10-23-emacs-reader-smooth-fit.md` 的真机 L3 验收覆盖，**L3-6（页面比窗口矮时滚到底 vscroll 不为负、图像不被下推）与 L3-8（`emacs --daemon` + `emacsclient -c` 下 idle timer 可靠触发）未单独复验**，按用户 2026-10-23 决定记为待观察，不阻塞归档。
- 影响：L3-6 直接关系到本条目前的「`seshat-reader--set-window-vscroll` 缺下界夹紧」——尺寸变化路径已有 `seshat-reader--clamp-window-vscroll` 绕行，但**翻页落点与书签恢复的 vscroll 路径仍无下界保护**，只有真机能确认短页 + `fit-to-width` 组合是否真的产生负 vscroll。L3-8 是 `openspec/decisions.md` 2026-10-23「尺寸变化重贴合用 idle timer」决策的降级判据：若 daemon 下 idle timer 不触发，按该决策第 3 级降级为「只 clamp + center、不 refit」，页面可能被裁切。
- 判据（下次真机批量验收照此执行）：L3-6 → 按 `W`（按宽适配）到短页后滚到底，`(window-vscroll nil t)` 应为 `0` 且页顶不被推出窗口；L3-8 → `emacs --daemon` + `emacsclient -c` 打开文档后开关目录（`o`），页面应在一次 redisplay 内归位（无「先偏一侧再居中」），并在停手后 0.15s 内清空 `seshat-reader--resize-refit-timer`。
- 建议：与「`image-flush` 已从 `--apply-display-scale` 移除、旧缓存未验证」「image cache 条目累积」两条合并为**一次真机批量观测**（同一次 GUI 会话可全部做完），观测后把结论写回本文件并删除或降级对应条目。（**2026-10-23 已执行**：T4-1 / T4-3 / T4-4 完成并回填，`image-flush` 与 image cache 两条已降级；仅 T4-5「strip 与 `before-string` 交互」未执行。）
- 复验结论（2026-10-23 真机）：
  - **L3-6 通过**：contain 模式下页面显示 608×771、窗口 1904×986（页面比窗口矮），`(seshat-reader--page-max-vscroll-pixels)` = 0，连按 `seshat-reader-scroll-down-screen` 到底后 `(window-vscroll nil t)` = 0（**非负**）、`--centered-p` = t，页顶未被推出窗口。附加数据：`W`（fit-mode = width）下页面 1904×2413、`page-max` = 1427、`vscroll` = 936 ∈ [0,1427]。
  - **L3-8 部分通过**：当前实例 `(daemonp)` = nil（直接启动的 pgtk GUI）。**观测方法教训**：`sit-for` 不能用来等 idle timer——按 `(elisp)Idle Timers`，Emacs 在「带超时等待输入」（`sit-for` 正是如此）时**不算 idle**，idle timer 不运行；必须真实空闲（手离开键盘鼠标）≥1 秒后再求值。改造后实测 `--resize-refit-timer` = nil、`--centered-p` = t，即 idle refit 正常执行并清空 timer。**daemon 场景（`emacs --daemon` + `emacsclient -c`）仍未验证**，该条降级保留。

## `revert-buffer` 后 buffer 保持 modified，与自动保存类包冲突（2026-10-23 真机观测发现，高优先）——已解决（2026-10-23）

- 现状：`set-buffer-modified-p nil` 只在 `seshat-reader-mode` 启用时执行一次（`seshat-reader.el:1751`）；`revert-buffer` 走的 `--non-queue-refresh-doc-buffer`（`:1507`）→ `--render-buffer`（`:1531`）会重写 buffer（`--update-join-strip` 等插入/删除内容），**之后没有再清 modified 标志**。
- 影响：① `g` / `M-x revert-buffer` 之后 modeline 显示 `**`，误导用户「文档有未保存改动」；② 与自动保存类包冲突——真机实测连续两条 `super-save-delete-trailing-whitespace-maybe: Buffer is read-only: #<buffer ….pdf>`（由 `super-save` 的 timer 在 modified buffer 上触发），并伴随 `Error running timer: (buffer-read-only …)`；③ **潜在数据损坏**：若用户解除只读（`C-x C-q`）后自动保存被触发，渲染占位内容会被写回原始 PDF 文件。
- 建议：在 `--render-buffer` 或 `--non-queue-refresh-doc-buffer` 的收尾处（`--update-join-strip` 之后）补 `(set-buffer-modified-p nil)`；同时复核 `auto-revert-mode 1`（`:1752`）与自定义 `revert-buffer-function` 的组合是否需要 `inhibit-read-only` 保护。须补一条 ERT（revert 后 `buffer-modified-p` 为 nil）并做一次真机复验（`g` 后 modeline 无 `**`、*Messages* 无 super-save 报错）。
- 已解决（2026-10-23）：`seshat-reader--render-buffer` 与 `seshat-reader--update-join-strip` 各自在改完 buffer 文本后补 `(set-buffer-modified-p nil)`——两处独立保证，不依赖调用顺序（真实链路上 `--render-buffer` 末尾会调 `--update-join-strip`，但用例里桩掉后者仍能判别前者，变异自检 A/B 分别打红对应用例）。新增 ERT 2 例（`seshat-reader-page-join-test.el` 24 → **26**；全仓 397 → **399**，0 unexpected / 0 skipped）；L1 `make all` EXIT=0、警告集 33 → 33 零新增。**残留**：`--insert-join-strip` / `--remove-join-strip` 自身仍可改文本（`inhibit-read-only t`），若将来新增调用方绕过 `--update-join-strip` 会重新标脏——这两处不宜单独加清除行（会在同一路径上重复清且掩盖调用链），保持现状并在此记录。

## WebDAV 后端的条件头仍不生效（M8-A，2026-10-24）

- 现状：`seshat-transport-backend` 可切到 `webdav`（`curl` + Basic），但服务端 `/dav` 通道（`x/net/webdav` v0.61.0）**静默忽略** `If-Match` / `If-None-Match`，行为退化为后写覆盖且无任何信号（`docs/api.md` 的 §8.2 已记录）。传输层只做契约归一，不修复此服务端限制。
- 影响：灰度期若走 WebDAV 后端，乐观锁等于没加，冲突只能靠事后 diff3 发现；同一文件在两处并发写会静默丢一次修改。
- 建议：灰度期只用于回滚兜底，不作长期通道；真正的冲突检测一律走 REST（`If-Match: "<blob>"`）。若要彻底消除，需服务端换支持条件请求的 WebDAV 实现。

## 状态库无并发保护（M8-A，2026-10-24）

- 现状：`seshat-state.el` 单文件原子写，但无文件锁；同一用户开两个 Emacs daemon 同时同步时，各自的 `save` 会互相覆盖（后写者胜），表现为 uid 映射或游标丢失。
- 影响：多 daemon 或「daemon + 独立 emacs」并行使用时可能丢状态；单进程使用无影响。
- 建议：若将来出现多实例需求，加 `lock-file` 或改用支持并发的后端；当前按「单 Emacs 进程假设」记录，不阻塞。

## `/api/versions` 的线缆参数名与形参名不一致（M8-A，2026-10-24）

- 现状：`seshat-rest-versions` 的形参叫 `blob`（与 `resources.blob` 语义对齐），但服务端读的查询参数名是 `hash`（`internal/api/server.go:566`）。实现里已做映射并在 docstring 注明，但两套命名并存。
- 影响：若后续调用方按形参名手写 `blob=` 查询，服务端会忽略并退化成「取当前版本」，表现为「历史内容与 head 相同」的静默错误。
- 建议：计划 B 接入 `seshat-conflict.el` 时统一口径（要么服务端支持 `blob` 别名，要么形参改名为 `hash`）。

## `seshat-state.el` 的单条目写入会全量重建 `:paths` 索引（M8-A 审查，2026-10-24）——已解决（M8-B T0，`seshat-state-batch`）

- 现状：`--put-entry` / `--update-entry` 每次条目变更都调用 `--rebuild-paths`（O(n)），而 `--paths-equal` 的比较是 O(n²)。单个 `set-base-blob` 调用即触发一次全量重建。
- 影响：计划 B 的批量同步（逐资源写 base blob、逐事件应用 changes）会退化为 O(n²)；书库规模上千后每次同步可能明显变慢。
- 建议：在计划 B 动工前提供批量入口（如 `seshat-state-batch` 宏或在 `let` 绑定下暂缓重建、退出时统一重建一次），或改为对单条目增量维护 `:paths`。当前单进程、小规模场景无感知。
- 已解决（2026-10-24，M8-B T0）：新增 `seshat-state-batch` 宏与 `--batch-depth` 守卫——批量期间跳过 `:paths` 重建、退出时统一重建一次（嵌套只在最外层重建）。**接口约束**：块内 `:paths` 陈旧，`uid-for-path` / `path-for-uid` 不保证命中本批新条目，且块内**不得** `state-save`（会写出与 `:uids` 不一致的索引）。新增 6 例用例锁定该语义。

## `--encode-path` 在 `seshat-rest.el` 与 `seshat-conflict.el` 各有一份（M8-A 审查，2026-10-24）

- 现状：`seshat-rest--encode-path`（`emacs/seshat-rest.el`）与 `seshat-conflict--encode-path`（`emacs/seshat-conflict.el:52`）逐字重复——逐段 URL 编码并保留 `/`。计划 A 刻意不抽公共库（避免把 conflict 的依赖方向倒置）。
- 影响：两处口径若将来出现漂移（例如一方开始处理 `%` 或前导斜杠），会出现「同一条路径生成不同 URL」的静默不一致。
- 建议：计划 B 接入 `seshat-conflict.el` 到 REST 条件写时，一并把两处收敛到 `seshat-rest--encode-path`（conflict 已经有对 `seshat-rest` 的依赖，方向合法）。

## `seshat-reader.el` 的 `with-demoted-errors` 缺少 FORMAT 参数（M8-A 收尾发现，2026-10-24）——已修复（2026-10-27，见本文件「…缺 FORMAT 参数（Emacs 30+ 旧式用法，2026-10-27 发现）」一条）

- 现状：`emacs/seshat-reader/seshat-reader.el:82-83` 的 `(with-demoted-errors (require 'seshat-render-core))` 未传 FORMAT 首参。`with-demoted-errors` 的首个参数是格式串，缺省时会用宏的默认消息，但字节编译/log 每轮都报 `Warning: Missing format argument in 'with-demoted-errors'`（14 个测试文件加载 reader 时各报一次）。
- 影响：功能无影响（该 `require` 失败仍被静默降级），但会污染编译输出、掩盖真正的新警告；且该 `require` 失败后，后续 `seshat-render-core-*` 调用会以 `void-function` 在运行期才暴露，定位成本高。
- 建议：改为 `(with-demoted-errors "seshat-reader: %S" (require 'seshat-render-core))`，与仓库其它 `with-demoted-errors` 用法对齐；属一行修复，可随下次阅读器改动顺带处理。
- 已解决（2026-10-27）：实为 `"seshat-render-core: %S"` + `(require 'seshat-render-core)`（与本文件较新一条记录、即 2026-10-27 发现条同一处、同一修法），验证数字（warning 24 → 20 / ERT 1266 例）见该条。

## rename 判据 `size + mtime` 的两个盲区（M8-B，2026-10-24）

- 现状：`seshat-sync-detect-renames` 用「同根下 `size` 与 `mtime` 都相同的消失 + 新增」配对判定 rename，不读内容 hash。
- 影响：① **rename 后立即编辑**（size/mtime 随之变化）会被判为「删 + 建」，uid 因此不稳定；② 同尺寸且同 mtime 的两个不同文件会被误判为一对 rename（概率低，但移动后服务端与本地会指向错误内容）。
- 建议：精化判据时改用 `blob`（服务端 `resources.blob` 与本地内容 hash 比对），代价是每次候选配对都要读文件；可对候选集先按 size 过滤再算 hash，成本可控。

## 无 inotify：本地改动最坏延迟一个同步周期（M8-B，2026-10-24）

- 现状：本地编辑靠 `seshat-sync-detect-renames` 的 `size`/`mtime` 快照比对发现，只在 `seshat-sync-now`（含定时器，默认间隔 300 秒）时触发。
- 影响：用户保存后要等下一次同步才会推送到服务端；跨端协作时另一端的可见延迟因此有 5 分钟量级的上限。
- 建议：若需要近实时，可加 `after-save-hook`（仅对根目录内的文件）直接标脏并触发一次 debounce 同步；当前未做以避免与大量第三方包的文件保存钩子抢时序。

## 被跳过的事件静默丢失，用户不可见（M8-B，2026-10-24）

- 现状：`seshat-sync--apply-event` 因「未知 op / 根未配置 / 路径越界 / 下载失败」跳过事件时只发 warning，同时游标照常前进（否则会无限重放同一批）。统计里的 `cool < events` 就是这个差集，但**没有任何用户可见的呈现**。
- 影响：服务端有变更、本地没落地时，用户只能从 `*Messages*` 的 warning 里翻找；长期运行后可能积累不一致。
- 建议：在 `seshat-sync-status` 或 `seshat-sync-now` 的摘要里输出「本轮跳过 N 个事件（含原因分布）」，并在跳过数连续非零时提示 `M-x seshat-sync-reset-roots` 或检查根配置。

## 先运行 `seshat-sync-status` 会得到「未登记」误报（M8-B，2026-10-24）

- 现状：`seshat-sync-status` 的 uid 解析依赖 `seshat-state-roots`，而根映射只在 `seshat-sync-pull`（即 `seshat-sync-now` 的第一步）里初始化。从未同步过就直接看状态，会逐文件报「未登记，先运行 `seshat-sync-now`」。
- 影响：首次使用的用户容易误以为配置错了；实际只需先跑一次同步。
- 建议：在 `seshat-sync-cmd--root-relative` 的调用处判断 `(null (seshat-state-roots))` 时只读地提示「尚未初始化根映射」，而不是逐文件刷同一句话（属 `seshat-sync-cmd.el` 的小改动）。

## 全仓 ERT 的 `-L` 清单未固化进仓库（M8-B，2026-10-24）

- 现状：跑全仓 ERT 需要 3 个仓库目录（`emacs`、`emacs/seshat-reader`、`emacs/tests`）+ straight `build-31.1` 下的包目录，其中 **`etaf` 的包文件在 `build-31.1/etaf/lisp/`**（只加 `build-31.1/etaf` 不够）。该清单只存在于计划与 `docs/emacs-reader.md` 的示例里，没有可执行脚本。
- 影响：每轮开发都要重新推导命令；漏一个目录就出现 `annotation-v8` 2 例 `etaf-ui` 缺失、`translate` 整文件加载失败、`etaf` 用例 skipped 等**假失败**，容易被误判为回归。
- 建议：固化 `scripts/test-emacs.sh`（或 Makefile 的 `test-emacs` 目标），用通配拼 `EMACSLOADPATH`，并在 CI/文档里统一引用。

## 首同步的落盘次数与状态库规模（M8-B，2026-10-24）

- 现状：`seshat-state-save` 是整体序列化（O(n)），而首同步每页索引、每批 changes 都落盘一次。大书库首同步的写盘成本因此呈 O(n²) 级（页数 × 状态大小）。
- 影响：书库上千后首次同步可能明显变慢；日常增量不受影响（批数与状态大小都小）。
- 建议：若要优化，可改为「每 N 页/批落盘一次 + 退出时强制落盘」，或换增量落盘格式；当前优先保证崩溃恢复语义（每页落盘意味着中断损失最小）。

## 库外文档不支持批注，且无「入库后迁移」（2026-10-24 阅读模式，2026-10-24）

- 现状：`seshat-reader-annotation--uid`（`seshat-reader-annotation.el:178-181`）对不在任何 `seshat-reader-annotation-roots` 根下的文件抛 `user-error`，`annotation-create` 无条件调用它。本计划只让降级警告静音（`--doc-id` 的可选 QUIET 参数），**没有**实现「库外本地批注」。
- 影响：把 reader 当通用阅读器用时，批注命令会明确报错（这是正确的用户提示，但用户可能期望「至少能本地记一笔」）。
- 建议：若要支持，需要设计本地批注的存储（`.eld` 侧车？）与「入库时把 `local:` 批注迁移到 uid」的语义；迁移还要处理幂等键（`(uid, kind, location, text)`）与冲突。属独立计划。

## 入库后原件与副本双份，且原件不含库身份（2026-10-24 阅读模式，2026-10-24）

- 现状：`seshat-library-add` 按用户决定「复制上传、保留原件」，因此本地同时存在原件（库外，显示 `[库外]`）与副本（库内，显示 `[库]`）。入库后调用的 `seshat-reading--apply-identity-for` 只把**调用方 buffer** 的身份更新为副本；若用户之后再 `find-file` 原件，仍显示 `[库外]`。
- 影响：同一本书有两份本地文件，用户需自行管理原件（删除或移走），否则容易在原件上继续批注/修改而不同步。
- 建议：可考虑入库后提示原件的处置（或在 `seshat-library-add` 末尾询问是否打开副本 / 删除原件）；若要「移动」语义，需另加选项。当前按用户 2026-10-24 的决定（复制）保持。

## 阅读模式的身份标识无法关闭，且每个文档都会显示（2026-10-24 阅读模式审查）

- 现状：`seshat-reading-mode` 接管 `auto-mode-alist` 后，每个打开的 PDF/EPUB 都会在 mode-line 显示 `[库]` / `[未入库]` / `[库外]` / `[状态异常]` 之一，且没有 `defcustom` 可关闭。
- 影响：把 Emacs 当纯通用阅读器用、从不使用 Seshat 库的用户，也会在每个文档的 mode-line 上多看到一段与己无关的标识。
- 建议：加一个 `seshat-reading-mode-line-indicator`（默认 t），关闭后不安装 `mode-line-misc-info` 条目；身份解析仍可保留（供 `seshat-reading-refresh` / `seshat-library-add` 使用）。

## 状态库的 `.bak` 备份从不清除（2026-10-24 阅读模式审查）

- 现状：`seshat-state--backup-corrupt` 在状态文件损坏时把它改名为 `<FILE>.bak`，此后从不删除（下一次损坏会覆盖同名 `.bak`，最多保留一份）。`broken` 判定已改为读「本次加载是否命中损坏」标记，不再依赖 `.bak` 是否存在。
- 影响：磁盘上会长期留一份可能含旧游标/uid 映射的 `.bak`（自身是合法 `.eld`，不含敏感信息）；用户看到它可能困惑。
- 建议：在状态库成功保存后提示一次「旧的损坏备份仍在 <路径>，可手动删除」，或加一个 `seshat-state-clean-backup` 命令；不要在加载时自动删除（备份是最后的恢复手段）。

## 「相对根路径」的安全校验有三份实现（2026-10-24 阅读模式审查）

- 现状：`seshat-sync--local-path`（`emacs/seshat-sync.el`）、`seshat-sync-cmd--safe-local-path`（`emacs/seshat-sync-cmd.el`）、`seshat-reading--target-path`（`emacs/seshat-reading.el`）各有一份「把服务端/用户给的相对路径拼到根目录并校验不越界」的实现。三者细节不同：reading 侧内联了 `file-truename` 复核、拒绝已存在的目录、并规范化 REL（末尾斜杠/单点/连续斜杠）；sync 侧没有 REL 规范化；cmd 侧是纯字符串规范化。
- 影响：口径漂移会导致「同一条路径在三处得到不同结论」，其中任何一处松懈都是路径逃逸的入口（安全隐患）。三份 docstring 已互相引用说明，但依赖人工同步。
- 建议：抽一个共享函数（如 `seshat-path-safe-join`，放在 `seshat-state` 或新模块 `seshat-path.el`），三处统一调用；抽之前若必须改其中一处，务必同步另两处并各补一条软链用例。

## C 侧渲染像素路径无自动化回归（2026-10-24）

- 现象：高亮矩形的绘制（`draw_page_thread` 的 `fz_fill_path`）完全在 C 层，ERT 只对 elisp 层的 `--add-highlight` 做 mock / 间接断言，全仓 682 例全绿也**不能**证明高亮落点正确。
- 影响：2026-10-24 修复的「双重变换导致高亮按 scale² 放大」若无用户目视反馈不会被任何测试发现。
- 待办：① 已做——`fz_catch` 里的高亮异常改为 `fz_warn` 且在每进程只告警一次，同类变换错误会留下日志；② 仍未做——为渲染路径补一条最小回归（headless 下渲染固定页面 + 在已知 rect 画高亮，导出 PNM 后断言该区域像素被着色）。

## HiDPI 下渲染分辨率未含 frame scale（2026-10-24，假设?）

- 现象：`emacs_doc_scale_page` 的 `resolution = scale × 72` 不含 `frame_scale`，而 `local_imgw = fz_pixmap_width / frame_scale` 交给 Emacs 作 `:width`；elisp 侧 `posn->page` 又乘一次 `frame_scale`。本机 `frame-scale-factor` 恒为 1.0（三个 frame 实测）时三者自洽，但 `> 1` 时位图分辨率相对显示尺寸偏低（画面被放大、偏糊），且乘/除方向不对称。
- 状态：本机无法复现，未修改。
- 待办：在 `frame-scale-factor > 1` 的环境（或临时构造该参数）下复测，再决定是否把 `frame_scale` 纳入 `resolution` 并同步调整 elisp 侧换算。

## 存量 `note` 无法迁移为 `highlight`（2026-10-25 术语与 kind 语义修正）

- 现状：`kind` 收敛为单维类型后，正确的模型是「选中原文 → `highlight`；纯页级备注 → `note`」。但存量数据无法判定归属：Emacs 旧记录由服务端兜底为 `kind=note` **且带 `rect:`**（有几何但类型是 note），Android 旧 `note` 则完全没有几何（`location=page:<n>`）。两种情况都可能是「用户当时想标的是一段原文」。
- 影响：存量批注在 Android 分组里继续进「便签」组、在 Emacs 列表里继续当 `note` 显示，与新建的 `highlight` 条目并列；同一段原文可能同时存在一条旧 `note` 与一条新 `highlight`（幂等键 `(uid, kind, location, text)` 带 `kind`，两条独立记录，`text` 也通常不同）。
- 解除条件：不存在「安全」的自动迁移——按「有 `rect:` 就改 `highlight`」会改写 Emacs 用户的真实便签，按「无几何就保留」又会漏掉 Android 侧；且改写用户已有批注不可逆。只有引入「显式迁移命令 + 用户逐条确认」或等新的专用字段（如 `origin` 记录创建端与创建时版本）才可能处理，本期**不做**。

## Android 无 AVD / 设备，UI 改动仅人工验收（2026-10-25 术语纠正批次）

- 现状：本机无 Android SDK 模拟器镜像与实体设备，`./gradlew test` 只覆盖 JVM 纯逻辑（分组、location 编码、提示可见性等），**不覆盖**真实渲染与交互。
- 影响：本批次改的可见文案与布局只能靠代码走查确认，以下各点需真机/模拟器人工确认：① PDF 长按菜单第二项显示「添加本页备注」且点击仍走 `PdfReaderActivity.addAnnotation`（`kind=note` + `page:<n>`）；② PDF 目录抽屉底部状态行为「第 N/M 页 · K 个书签」两段拼接、分隔符不重复；③ EPUB 目录抽屉的书签 Tab 空态只显示「尚无书签」，**没有**「点顶栏书签图标可添加」的错误指引；④ EPUB 批注抽屉看不到「添加本页备注」入口（选中即 `highlight`），编辑备注保存后该行仍在「高亮」组而非「便签」组；⑤ 批注抽屉「⋮」菜单显示「编辑便签 / 删除」。
- 解除条件：接入 AVD 或真机后把上述 5 点转为 instrumentation / 手工验收清单并记录结果；在那之前本批次 UI 结论一律标注「待真机」。

## `underline` / `strikeout` 已定语义但尚未实现（2026-10-25）

- 现状：术语定案把 `underline`（下划线）/ `strikeout`（删除线）列为批注子类型，服务端**不做枚举校验**因而无需改服务端；但三端都还没有产生这两个值的入口——Android 无对应菜单项，Emacs 只有 `highlight` / `note` 两条路径，且两者都没有「画下划线 / 删除线」的渲染通道。
- 影响：若外部客户端（或手写 JSON）提交这两个 `kind`，Android 会归入「其它」组（行内保留原始 `kind`，可跳转可删除），Emacs 按 `note` 兜底进入列表——数据不丢，但显示语义降级。文档已声明「已定语义、尚未实现」，避免读者误以为可用。
- 解除条件：实现渲染通道（Emacs 侧需在 `draw_page_thread` 增加描边/删除线绘制，见装饰通道计划 `openspec/active/2026-10-25-reader-decoration-and-text-highlight.md`）与 Android 菜单项后，同步更新 `docs/api.md` §4 的填充矩阵与 `docs/android.md` §6.8 的分组映射。

## Emacs 的 `seshat-rest-set-progress` 仍无调用点（2026-10-25 观察）

- 现状：`seshat-rest.el` 已封装 `PUT /api/progress`（`seshat-rest-set-progress`），但仓库内**没有任何生产调用点**——唯二的两次 grep 命中是它自己的 `defun` 与文件头注释里的用法示例。阅读进度目前只由 Android 写入（`ReadingProgressStore` / `PdfProgressStore` → 进度端点），Emacs 侧只读取（`seshat-sync-status` 展示）。
- 影响：Emacs 读完某页不会回报进度，跨端「继续阅读」在 Emacs 一侧永远停在 Android/初始值；该封装函数与 `GET` 版并列存在，容易被误读成「已支持双向」。
- 解除条件：Emacs 侧接入进度上报（触发点建议沿用 reader 翻页命令 + idle 去抖，避免逐页打网络），或明确声明「进度单向（Android → 服务端）」，并把无调用点的封装标 `;;; TODO` 或下沉到测试辅助。

## `TocDrawer.show` 旧签名已无调用者（2026-10-25，dead code 待清理）

- 现状：`TocDrawer.show(allRows, currentTarget)` 这个两参重载现在没有任何生产代码或测试调用（两阅读器都改调带 `statusLine` / `bookmarks` / `bookmarksSupported` 的完整版本）。
- 影响：多一条「看起来可用但永远拿不到状态行与书签」的入口，改动 `show` 语义时容易漏改；Kotlin 不会对未使用的 public 方法报警，测试也覆盖不到。
- 解除条件：删除该重载（`TocDrawer` 是内部组件、`show` 非跨模块 API），或若确需保留则补一条用例锁定其默认值行为。

## 装饰层未做内存检查（2026-10-25）

- 现象：本轮 C 装饰表（rect + stroke，深拷贝快照）只靠「所有权规则写进 `Decoration` 结构体注释 + 唯一释放函数 `free_decoration_table` + 压力循环不崩溃」保证，**未做 valgrind / ASan 验证**——batch Emacs 无法构造 docstate + window，attach 运行中 daemon 不可行。
- 影响：`pts` 的深拷贝与释放路径（`free_draw_thread_args` 的 7 条退出路径、`free_doc_state`、`free_decoration_table`）若存在漏 free 或双 free，现有 ERT 与人工压力循环都不会暴露，只会在长时间阅读 + 反复刷新装饰后表现为内存增长或崩溃。
- 解除条件：补一次 valgrind 启动 daemon，或 ASan 构建下跑「加载文档 → 加 stroke → 刷新 → 关闭文档」循环并通过。

## verify 实例无 GUI frame 导致 `image-flush` 抛错（2026-10-25）

- 现象：`display_img_to_overlay` 在终端 frame 上必然抛「Window system frame should be used」，因 `overlay-put` 在其之前执行，像素仍可取，但**任何依赖 `display_cached_page` 返回值的断言在 verify 实例里不可信**。
- 影响：隔离实例（`elisp-test`，无 GUI frame）上跑 ERT 时，凡断言「刷新后页面已重绘 / 返回 t」的用例都会失真（走 error 分支或断言到未定义值），结论不可作为回归依据。
- 解除条件：改用 GUI frame 跑该类断言，或调整 flush 的顺序 / 条件（`image-flush` 移到 `overlay-put` 之前，或按 frame 能力跳过）。

## `emacs_add_stroke` 点列表遍历未提前截断（2026-10-25）

- **已修复**（2026-10-25，Phase 4 审查修复）：循环顶部先判 `pt_count >= DECORATION_MAX_POINTS`，达到即置 `truncated` 并 `break`（break 前仍做 `listp` 断言，不对非列表调 `car`/`cdr`），不再把超限输入的剩余部分逐点走完。取「达到上限即停」而非原「超过 2 倍上限再停」，是因为超过上限的点本就会被丢弃，多走一个都是纯浪费。上限值 1024 **未放宽**，「截断而非拒绝」语义不变；代价是上限之后的畸形数据不再被校验（历史正文保留如下）。
- 现象：`DECORATION_MAX_POINTS`（1024）只是「存不下就不存」——一个百万点的 elisp 列表仍会被**完整遍历**（约 40 万次 module funcall），循环内没有提前退出。
- 影响：异常或超大输入（不可信调用方、超长笔迹）会长时间占住 Emacs 主线程，表现为卡顿；该上限只保护了内存，没有保护 CPU。
- 解除条件（已满足，见上）：循环内加「读到的点数超过 `2 × DECORATION_MAX_POINTS` 即 break」的提前退出（保留现有「截断而非拒绝」语义）。实际实现取更严的「达到 `DECORATION_MAX_POINTS` 即 break」。

## `fz_stroke_state` 栈副本依赖 `dash_len == 0`（2026-10-25）

- 现象：`draw_page_thread` 的 stroke 绘制用 `fz_default_stroke_state` 的**栈副本**，其 `dash_len = 0` 保证柔性数组 `dash_list[]` 永不被读；这是本轮「结构体放栈上」写法的唯一前提。
- 影响：将来若支持虚线，`dash_list[]` 会被实际访问，而栈副本只含零长度的柔性数组尾部 → 越界读取（UB），且不会在编译期报错。
- 解除条件：支持虚线时改用 `fz_new_stroke_state_with_dash_len(ctx, len)` 并在用后 `fz_drop_stroke_state`，同时补一条虚线渲染的像素回归。









## `character` 粒度撞 500 段锚上限（2026-10-25 装饰表与字级高亮批次）

- 现象：`seshat-reader-select-highlight-granularity` 设为 `character` 时，一行十几字就是十几段矩形，一页选区轻松过千段；`seshat-reader-annotation--anchor` 的写入端上限是 500 段（`--anchor-max-segments`），超出部分**被丢弃**——只写前 500 段并提示一次，页面下部因此**没有高亮**，而批注本身仍成功创建。
- 影响：`character` 粒度的用户在大段选区上看到「高亮只覆盖上半页」，提示只说「只写入前 500 段」，看不出是被截断成半页。选 `line`（默认）时每页通常几十段，不受影响。
- 解除条件：改为「先按行合并再写入」（`character` 只影响选择与闪现，落库时统一按行），或提高写入端上限并重新评估 64 KB `location` 长度上限与解析端 2000 段的余量关系。

## `elisp_check_parens` 对大型测试文件假阳性（2026-10-25 装饰表与字级高亮批次）

- 现象：`elisp_check_parens` 对 `emacs/tests/seshat-reader-annotation-test.el`（实测 948 行规模）报括号不平衡，而同一实例内对该 buffer 直接跑 `check-parens` 与命令行 batch 加载该文件均**通过**。
- 影响：若把该工具当作 L1 门禁的唯一判据，会在大型测试文件上误判并诱导去「修」并不存在的括号错误；本批次改用「`make -C emacs/seshat-reader clean all` + batch ERT 加载」作为 L1 判据。
- 解除条件：定位该工具与 `check-parens` 的差异（疑似只检查可见区或未 `revert` 磁盘新内容）后修工具；在那之前，L1 门禁不单独依赖 `elisp_check_parens`。

## verify（headless）实例的 `--refresh-highlights` 恒返回 nil 且首帧尺寸不同（2026-10-25 装饰表与字级高亮批次）

- 现象：隔离实例里 `seshat-reader-dyn--refresh-highlights` 恒返回 nil（无 GUI frame，重绘路径提前返回），且同一文档首帧与后续帧的 `image :data` 尺寸不同（实测 1454127 B vs 90897 B）。
- 影响：**不能**把该实例里的像素结论当作绝对判据——只能在**同一会话内做相对比较**（如「加装饰前后同页 PNM 是否逐字节一致」），不能跨会话或跨首帧/后续帧比较尺寸与哈希。
- 解除条件：为无 frame 场景提供「渲染到 PNM 但不经窗口」的判据入口（渲染确定性导出），或改用带 GUI 的实例做像素验收。

## `--add-stroke` 已实现但 Lisp 侧尚未使用（2026-10-25 装饰表与字级高亮批次）

- 现状：C 侧 `--add-stroke(page r g b alpha width points)`（7 参，扁平点列表，每笔 ≤1024 点，点列由 C 侧 `malloc` 自持）与装饰表的 stroke 类型都已落地，但 Lisp 侧没有任何调用点——`ink:` location 段仍不解析、不渲染。
- 影响：手写笔迹在 Emacs 端只显示为「第 N 页手写（M 笔）」的聚合行，看不到轨迹；同时该入口没有真实调用方，等于未经端到端验证的 API（只有 ERT 桩级覆盖）。
- 解除条件：ink 轨迹渲染与手写存储按计划 `openspec/active/2026-10-25-reader-search-and-ink.md` 落地后接入，并补一条「解析 `ink:` → 投 stroke → 像素出现」的回归。

## `--anchor-segments` 对坏 rect 静默丢段（2026-10-25 装饰表与字级高亮批次）

- 现象：`seshat-reader-annotation--anchor-segments` 对「不是前四元素都是数字」的坏元素直接跳过（`dolist` 里的 `when` 过滤），既不计入段数、也不提示；而**段数超限**时却会提示一次（`--warn-anchor-truncated`）。
- 影响：两种数据丢失的处理**不对称**——超限提示、坏段静默。若上游给出畸形矩形（如坐标为字符串），用户只会看到「高亮少几段」而无任何线索，排查时容易误判为渲染问题。
- 解除条件：对跳过的坏段做与截断同级的「一次性提示」（计数 + 样本），或把握手级别的 `numberp` 校验上移到产出方（`--rects-in-rect` / 合并函数）使其不可能产出坏段。

## `--refresh-highlights` 存在「一步错位」（2026-10-25 搜索与 ink 批次）

- 现象：单次 `--refresh-highlights` 之后立即取页面 overlay 的 image 数据（PNM），拿到的是**上一状态**的位图：重绘经渲染线程异步完成，`--refresh-highlights` 返回时新帧尚未挂到 overlay 上。
- 影响：跨批次做像素断言时，一次 refresh + 立即取图会得出「装饰没生效」的错误结论（实测表现为「加了装饰但 PNM 与之前逐字节相同」）。
- 可靠做法：`refresh → sleep（等渲染线程落地）→ refresh` 再取图；跨批次像素断言必须用此法，且只在同一会话内做相对比较（见上一条 headless 限制）。
- 解除条件：让 `--refresh-highlights` 同步等待本页渲染完成（或提供「渲染完成」回调/返回值），使调用方无需靠 sleep 猜测。

## `--highlight-module-available-p` 探针合并导致中间态 `.so` 连 rect 装饰也不画（2026-10-25 搜索与 ink 批次）

- 现象：Lisp 侧把「模块是否支持装饰」的探测合并成**一个**函数 `--highlight-module-available-p`（同时检查 rect 与 stroke 入口），于是「有 rect 入口但无 stroke 入口」的中间态 `.so`（升级过程中的构建产物、或未重新编译的旧 `.so`）被整体判定为「装饰不可用」。
- 影响：这种中间态下连**矩形高亮**（批注 rect）也不再绘制——用户看到「批注高亮全没了」，而实际能力只缺 stroke 一项；排查时容易误判为高亮投喂逻辑回归。
- 解除条件：拆成 rect / stroke 两个独立探针（`--rects-available-p` / `--strokes-available-p`），按能力分别降级：缺 stroke 时仅跳过 ink，rect 装饰照常投喂。

## `--add-*` 与 `--search-page` 的 page 基数曾不一致（2026-10-25 搜索与 ink 批次）

- 现象：`--add-highlight` / `--add-decoration` / `--add-stroke` 经 `resolve_page_arg` 取 **1-based** 页号，而 `--search-page` 初版直接 `extract_integer` 取 **0-based** 页号——同一模块内两类按页索引的入口语义相反，跨页搜索的命中会整体错一页（Lisp 侧靠 `(1- page)` 掩盖，任一侧改动即失效）。
- 现状：已在本次统一为 **1-based**（`--search-page` 改走 `resolve_page_arg`，Lisp 侧去掉 `(1- page)`，测试桩与断言同步；`--text-in-rect` / `--rects-in-rect` 保持 0-based，因为它们服务于已在页索引空间工作的选区代码）。
- 解除条件/预防：后续新增任何按页索引的 C 入口必须**显式声明基数**并在函数注释首段标注（当前四个入口的基数已在注释中逐个写明）；`--text-in-rect` / `--rects-in-rect` 的 0-based 约定属于历史遗留，若将来统一，需同步 `seshat-reader-select.el` 与相关 ERT 桩断言。

## 导出副本落在书库目录，会作为「新书」出现在书架上（2026-10-25 搜索与 ink 批次）

- 现状：`PdfInkExporter` 把副本写在**源文件同目录**（`<base>.seshat.pdf`），去重靠 `-1` / `-2` 后缀。若该目录在书架扫描范围（`filesDir/books/`）内，导出结果下一轮扫描就会作为一本**独立新书**出现——同一本书在书架上出现两份，且副本自身也带批注/进度键差异。
- 影响：用户可见的重复条目；副本再导出会产生 `a.seshat-1.pdf` 等递增文件，书架条目随导出次数线性增长，需手动清理。
- 建议（**待产品决策**）：① 导出到「下载」目录（`Environment.DIRECTORY_DOWNLOADS`）或 SAF 目录选择器，与书库解耦；或 ② 落在原目录但写入书架忽略名单（需书架扫描支持排除规则）。当前实现保持「同目录」是因为它最符合「就地生成可见副本」的直觉，且不引入 storage 权限与路径管理。

## 导出不支持 `content://` 源（2026-10-25 搜索与 ink 批次）

- 现状：`PdfReaderActivity.exportInkCopy` 只接受 `file://` 源；SAF 等 `content://` 来源拿不到可写的同目录路径，直接提示「仅本地文件可导出副本」。
- 影响：从系统文件选择器打开的 PDF **无法导出手写副本**（书库内的书走 `file://`，不受影响）。这是有意的拒绝而不是静默降级——把副本写到别处会让用户找不到文件，也会与书库扫描结果不一致。
- 建议：接 SAF 后要额外解决「目标 URI 授予」与「同目录判定」，或改用 `ACTION_CREATE_DOCUMENT` 让用户指定副本位置；在此之前保持拒绝并给出明确提示。

## 旋转页（`/Rotate` ≠ 0）导出时被跳过（2026-10-25 搜索与 ink 批次）

- 现状：`PdfInkStore` 的归一化坐标相对**渲染后（已应用旋转）**的显示矩形，而 PDF 用户空间不含该旋转，两者差 90°；`PdfInkExporter.export` 因此跳过 `page.rotation % 360 != 0` 的页，被跳过页数在结果里回报（提示「已导出 X（N 页未导出）」）；若全部页被跳过则不产出空副本并报错。
- 影响：旋转页上的手写与高亮**不会出现在导出副本里**（侧车数据本身完好，Emacs 端渲染时受同一旋转限制，见「旋转页的 rect 采不准导致高亮可能错位」）。
- 解除条件：在导出侧按 `page.rotation` 做一次逆变换（把渲染后坐标转回未旋转用户空间），需要与屏幕渲染共用同一份旋转矩阵实现并补单测，属独立一轮。

## `--text-in-rect` / `--rects-in-rect` 与装饰入口的页号基数不同（0-based vs 1-based，2026-10-25 起为显式约定）

- 现状：装饰与搜索入口（`--add-highlight` / `--add-decoration` / `--add-stroke` / `--search-page`）一律 **1-based**，而选区几何入口（`--text-in-rect` / `--rects-in-rect`）保持 **0-based**（服务于已在页索引空间工作的 `seshat-reader-select.el`）。两套基数在同一模块内并存，判定只能看函数注释（四个 1-based 入口的注释首段已逐个写明）。历史成因与修正过程见「`--add-*` 与 `--search-page` 的 page 基数曾不一致」。
- 影响：新增按页入口时若照抄了错的那一组，会出现整体错一页的静默 bug（Lisp 侧很容易用 `(1- page)` 把它掩盖掉，任一侧改动即失效）。
- 约定/预防：**新增按页入参的 C 入口必须显式声明基数**（函数注释首段），默认跟 1-based；测试桩必须按各自基数断言（搜索用 1-based、选区用 0-based），任一侧被改都会有用例失败。统一两套基数的代价是同步改 `seshat-reader-select.el` 与 4 个测试文件的桩，本轮不做。

## 真双栏正文页未验证（整行吸附，2026-10-25 F23 批次）

- 现状：`seshat-reader-dyn--lines-in-rect` 的「双栏不互相污染」只做过**结构等价**验证——用 `d2l-zh-pytorch.pdf` 页脚的「同 y 两互斥行」当作双栏的替身（框住其中一行时另一行不被带出）。手头没有一份**真双栏正文** PDF：`d2l-zh-pytorch.pdf` 无真双栏正文；`Kademlia` PDF 的 stext 行被切成碎片，同一 y 上的片段是**同一视觉行的碎片**而非左右两栏，用它做双栏断言会把「同一行被切碎」误读成「两栏」。
- 影响：若某份 PDF 的 stext 把左右两栏并进同一 line，「该行被碰到即整行输出」就会把对侧栏一起高亮——这是 stext 树的性质，elisp 侧无法在行内再判断栏界。
- 解除条件：用一份**真双栏** PDF（左右栏各自成 line）验证：框住左栏一行时右栏同行不被输出，且左栏行条 x 范围不越过栏间距。验证后把结论与文档名写进 `docs/architecture.md` 的框选闪现一节。

## 整行高亮的像素级确认只能在图形 frame 补做（隔离实例无 image，2026-10-25 F23 批次）

- 现状：整行吸附的几何（每行 x0/x1、行数、双栏互斥）已在隔离实例（`elisp-test`，tty frame）里用模块函数返回值与 ERT 断言验证，但**像素级**确认（高亮实际画在哪几个像素、有无越界出页）需要把页面 image 真正渲染出来；隔离实例是 tty frame，`create-image` 无法创建图像，页面 overlay 的 `display` 落不成位图，故像素级对照只能留待图形帧。
- 影响：算法级结论（返回值）可靠，视觉结论（是否看起来是整行）仍只在托管用户的主实例里由肉眼确认过，未做自动化像素断言。
- 解除条件：在图形 frame 环境（或主实例显式授权）里跑同一框选，导出页面 PNM 做逐像素/边界断言。

## gt 流式 hook 守卫依赖 gt 内部变量名与 hook 时机（2026-10-25 面板承载批次）

- 现象：流式增量的归属判定（`seshat-reader-translate--stream-sync`）只能事后比对中转 buffer 的 buffer-local `gt-buffer-render-translator` 与本次登记的 translator 是否 `eq`——`gt-buffer-render-output-hook` 不带任何参数，没有别的可用标识。这是绕过 gt 内部约定的 HACK。
- 影响：gt 升级若把该变量改名、写到别的 buffer-local 上、或改变 hook 的触发时机，守卫会**永久失配且不报错**：面板静默退回「完成时整体渲染」，用户只感觉「这次没有边生成边显示」。排查入口是 header-line 在生成期间是否变化。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`
- 解除条件：gt 提供带 translator 参数（或 stream id）的输出 hook 后改走正式接口；或本包侧对「守卫连续失配」计数并告警一次（当前无告警是刻意的保守取舍——流式与否属体验差异，不是功能错误）。

## `"Loading..."` 占位符按字面量匹配（2026-10-25 面板承载批次）

- 现象：`seshat-reader-translate--extract-result` 的 `SKIP-LOADING` 分支用 `string=` 把片段文本与常量 `seshat-reader-translate--loading-text`（字面 `"Loading..."`）比较，以丢弃 gt 尚未产出结果的占位片段。
- 影响：gt 若改文案（大小写、省略号形态、本地化），占位符不再被识别，会**短暂作为译文**写进面板与 `seshat-reader-translate-last-result`；流式下表现为答案开头多一行 `Loading…`，完成后被正文替换，只在生成期间可见——容易被当成「gt 自己的小毛病」而无人排查。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`
- 解除条件：改为结构判据（该片段不含 `gt-result` 文本属性即视为占位），或在启动时按 gt 实际写入的占位文本动态取常量。

## 追问与首轮流式并发时 `--current-translator` 是单例（2026-10-25 面板承载批次）

- 现象：`seshat-reader-translate--current-translator` 只有一个槽，登记的是**最近一次**装配的 translator。首轮译文尚未完成时发起追问（`C-c C-q`）会把它改写成追问的 translator。
- 影响：首轮的迟到增量此时不再满足 `eq` 守卫，因此**不会**写进追问答案区（守卫已缓解）；但守卫只保证「不匹配就不写」，一旦 gt 在同一 buffer-local 上的写入次序与预期相反、或将来放宽守卫，首轮增量仍可能落进追问的答案区，表现为答案里混入译文片段。**已缓解、未根治**。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`
- 解除条件：改为 **per-request 令牌**——每次请求生成唯一 id 并随请求携带，增量按 id 归属，而不是按「最近一次」归属。

## 多 child frame 面板按固定 margin 纵向堆叠，无底部避让（2026-10-25 面板承载批次）

- 现象：`seshat-reader-sidebar--cf-position` 只按 `TOP = margin + Σ(已存在面板高 + margin)` 往下排，**不检查父 frame 高度**（docstring 明确只把非数值/非正项跳过，不做上界夹紧）。
- 影响：目录 + 译文两个面板同时显示时，若父 frame 过矮（矮屏、缩小后的 frame、或两面板高度比例之和逼近 1），后一个面板会**溢出父 frame 底部**：面板自身有内部滚动条，但 frame 本身位于父 frame 之外，用户看不到也滚不到。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`
- 解除条件：`--cf-position` 增加底部夹紧（`TOP` 上界取「父高 − 面板高 − margin」），空间不足时降级为「只显示最近一个面板」，或按可用高度动态压缩 `seshat-reader-panel-height`。

## `make all` 产物的忽略规则只由 vendored `.gitignore` 承担（2026-10-25 面板承载批次，原假设已修正）

- 现象：`*.elc` 与 `seshat-reader-autoloads.el` 实际由 **`emacs/seshat-reader/.gitignore`** 排除（实测 `git check-ignore -v` 分别命中其 `*.elc` 与 `seshat-reader-autoloads.el` 两行）；仓库根 `.gitignore` 的「构建产物」段只列 `/bin/`、`/dist/`、`*.exe`、`/server`，**不含**这两个模式。故构建后 `git status` 并**不会**变脏（本批次实测：`make -C emacs/seshat-reader all` 之后工作区只有本次待提交改动，无 `.elc` 条目）。
- 影响：该 `.gitignore` 属 vendored 目录内文件（本仓库已无逐文件对照上游的能力，见 `VENDORED.md`「同步策略」），**从上游重拷整个目录时会被覆盖**；若覆盖后的版本不再含 `seshat-reader-autoloads.el` 行，构建产物就落回未跟踪状态，`git status` 每次验证后变脏，且容易被 `git add -A` 误提交。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`（原计划记为「未被 `.gitignore` 覆盖、每次须手工清理」，实测后该前提被推翻）
- 解除条件：在仓库根 `.gitignore` 补 `*.elc` 与 `emacs/seshat-reader/seshat-reader-autoloads.el` 作兜底；重拷后核对子目录 `.gitignore` 是否仍含这两条。

## `elisp_check_parens` 对 `.el` 假阳性的成因待定位（跨仓库，2026-10-25 面板承载批次）

- 现象：该工具（thomas-emacs 的 `site-lisp/thomas-mcp-tools.el`）在**临时 buffer** 里读文件后直接 `check-parens`，未先把 buffer 切到 `emacs-lisp-mode`，因此用的不是 elisp 的语法表；此外工具经跨行 shell 命令取内容时，命令自身的括号也可能带偏扫描起点。**本批次对 `seshat-reader-sidebar.el` / `seshat-reader-translate.el` 实测均返回 `status: ok`（未复现误报）**，故成因属**未完全定位**，候选解释为 ① 语法表不是 elisp 的（`standard-syntax-table` 里 `(`/`)` 是标点，`check-parens` 语义随之漂移）、② 跨行命令把无关括号带进扫描范围。
- 影响：该工具不能单独作为本仓库 L1 门禁（本批次用「`elisp_check_parens` + `make -C emacs/seshat-reader all`」双判据）。与既有条目「`elisp_check_parens` 对大型测试文件假阳性」同源但成因未归并，两条暂并存。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`；修复归属 **thomas-emacs 仓库**（临时 buffer 内先 `(emacs-lisp-mode)` 或 `(set-syntax-table emacs-lisp-mode-syntax-table)` 再 `check-parens`）。
- 解除条件：thomas-emacs 侧修好工具后回本仓库复验（对注释中含单侧括号的 `.el` 应报 `status: ok`），并把成因结论并回既有条目。

## 面板 `q` 的 kind 推断依赖 buffer 名（2026-10-25 面板承载批次，既有契约未改）

- 现象：`seshat-reader-sidebar-quit` 用 `seshat-reader-sidebar-buffer-p` + `--kind-for-buffer-name` 按 **buffer 名**推断 kind（目录面板 `*Outline of <源 buffer 名>*`、译文面板 `*Seshat Sidebar*`），再据此调 `--toggle-kind`。
- 影响：极端情形下可能误判——源 buffer 名本身形如 `*Seshat Sidebar*`、或含 `*Outline of ` 文本时，推断可能命中错的 kind，`q` 关掉的是另一个面板（或退回 `seshat-reader-sidebar-toggle` 把面板全关）。实际触发需要用户把文件 buffer 命名成面板名，概率极低；两个判据函数是既有契约，本批次**未改**。
- 来源：`openspec/active/2026-10-24-emacs-reader-panel-childframe-and-ux.md`
- 解除条件：kind 改由 buffer-local 变量（或面板自身的 `seshat-reader-panel-kind` frame/window parameter——后者已是 childframe 的唯一判据）承载，`q` 直接读它，不再解析名字。

## 跨计划协调：gt 预设查表有两处，迁移预设必须同步修改

- 现象：`seshat-reader-translate--translator` 与
  `seshat-reader-translate--preset-chatgpt-engine` 各自执行
  `(alist-get preset (gt-ensure-plain gt-preset-translators))`。若按
  `openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`
  把 `reader` / `reader-explain` 移出全局 `gt-preset-translators`、改存自定义变量，只改
  `--translator` 会让追问（`C-c C-q`）取不到 ChatGPT 引擎，直接 `user-error`。
- 影响：多轮追问功能立刻失效（且错误信息只提示"预设引擎不支持多轮"）。
- 来源：本计划 T5 实现与上述并行计划的 T1 冲突面（2026-10-25 代码审查发现）。
- 解除条件：两处查表统一为一个辅助函数（如 `--preset-translator`），或迁移时同时改两处并补一条 ERT 断言「预设迁出后 `--preset-chatgpt-engine` 仍能取到引擎」。（**2026-10-25 已解除**：`--translator` 与 `--preset-chatgpt-engine` 现共用 `seshat-reader-translate--preset-translator`，并有「自有表优先 / 回落全局表 / thunk」三条 ERT。）

## `eieio clone` vs `gt-single` 实例缓存未验证（2026-10-25 预设隔离与解释质量批次）

- 现象：gt 的 engine / parser / render 均继承 `gt-single`，其 `make-instance` 以「槽参数的 sha1」为键做 **class 级实例缓存**（`gt-core.el`）。`describe-function clone` 只说它是 generic 且带 PARAMS，**不保证**不经 `make-instance`，因此「`(clone engine)` 后 `oset` 改槽」是否真的产出独立副本**至今无测试支撑**。目前该路径被两处依赖：`seshat-reader-translate--enable-stream`（`oset copy stream t`）与 `--follow-up-translator`（`oset engine-copy prompt`，commit `8d43480` 引入）。
- 影响：若 `clone` 命中缓存，改的就是**全局共享的引擎实例**——流式开关会污染其它 gt 用法，追问的 messages 函数会顶替用户预设里原本的 prompt（表现为「某次追问之后，普通翻译也开始输出问答格式」），且**不报错**、只能靠行为异常发现。本批次因此**不克隆引擎**（解释 prompt 全走 taker text，见 `openspec/decisions.md` 2026-10-25 D2 条）。
- 来源：`openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`（F3 / D2）；`seshat-reader-translate.el` 的 `--enable-stream` / `--follow-up-translator`。
- 解除条件：写一个 spike——对同一预设连续 `(clone engine)` 两次，断言两次的 `eq` 为 nil（不同对象）、`oset` 其中一个的槽后另一个与原预设的该槽不变（`eql` 相等），并覆盖「槽参数完全相同」（最易命中缓存）与「参数不同」两种情形。结论若为「clone 不绕缓存」，则流式 / 追问必须改为「在 taker text / messages 层实现」或「显式 `make-instance` 新引擎」，并把该 spike 固化为 ERT。

## `--page-text` / `--text-in-rect` 的软换行粘连（解释上下文受其影响）

- 现象：C 侧两个取文入口把 stext 的 run 拼成一整串，**行与行之间不插 `\n`**（PDF 文本层本无换行概念），实测同一段落跨行处的中英文会直接粘成 `…the modelisto…` / `…模型的输入是…`。上游 `thomas-emacs` 的 `gt-source-text-transformer`（`+thomas/normalize-soft-wraps`）在**段落内**能把排版硬换行合并成空格，但它依赖文本里**存在**换行，无法还原从未写入的分隔。
- 影响：解释的上下文文本（`--context-text` 走 `--text-in-rect` 或降级 `--page-text`）会出现单词/词块粘连，语种混杂处的粘接可能让模型误读术语边界；同时上游的「保护行」（列表 / 标题 / 代码围栏）识别也会因为缺少换行而失效——全部内容被视为一个超长段落。
- 来源：`openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`（D3 上下文链）；依赖 active 计划 `2026-10-25-pdf-text-line-separators.md`（C 层按行边界补分隔符）。
- 解除条件：该 C 层计划落地后，`--text-in-rect` / `--page-text` 的返回按行边界插入 `\n`（需同时核对既有 ERT 对取文结果的逐字断言与 `seshat-reader-select` 的选区文本语义），本批次无需改 elisp；解除前不建议调大 `seshat-reader-translate-context-lines`（粘连会随行数放大）。

## 流式增量路径不经过 `--strip-chatter`

- 现象：输出净化（`seshat-reader-translate-strip-chatter`）挂在 `--record-result` 之前，而流式增量由 `gt-buffer-render-output-hook` 直接写入面板正文区、**不经过** `--record-result`——因此 `seshat-reader-translate-stream` 为 `t`（默认）时，面板上仍会先出现「好的，以下是……：」这一行，只有收尾文本（`last-result` / 存为批注 / 后续追问引用的文本）是净化后的。
- 影响：观感不一致——同一次解释，面板首行是寒暄、存成批注却没有；关闭流式（`(setq seshat-reader-translate-stream nil)`）时两者一致。功能无碍，属显示层瑕疵。
- 来源：`openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`（D5 明示「流式增量过程不经过」）。
- 解除条件：在增量同步的**首次**替换时对已到达文本做一次前缀净化（需处理「首行尚未接收完」的边界：冒号可能落在第二个增量里），或流式期间只在骨架里留占位、完成时统一净化重写正文（代价是失去增量观感）。改前先确认 `gt-buffer-render-translate-translator` 身份守卫仍成立。

## `with-eval-after-load` 重载 `init-tools.el` 会重复 push 预设

- 现象：`thomas-emacs/lisp/init-tools.el` 用 `(with-eval-after-load 'seshat-reader-translate (push … seshat-reader-translate-presets) …)` 注册两个预设。`with-eval-after-load` 的钩子在**每次** feature 加载时执行一次；正常启动只加载一次，但用户在运行中 `M-x load-file init-tools.el`（或重新 `require 'seshat-reader-translate` 前后重放）会把 `(reader . …)` / `(reader-explain . …)` 再 `push` 一遍。
- 影响：`seshat-reader-translate-presets` 出现同名重复项。**行为无害**——`--preset-translator` 用 `alist-get` 取**首个**命中，新 push 的项在表头、取到的仍是同一个预设；唯一可见后果是变量内容变长（每重载一次 +2 项）。
- 来源：`openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`（T5 配置迁移）。
- 解除条件：配置侧改成幂等的 `(setf (alist-get 'reader seshat-reader-translate-presets) …)`（或 push 前先 `assq-delete-all`），或把两个预设包进 `(unless (assq 'reader seshat-reader-translate-presets) …)`。改后需在 `test/init-smoke-test.el` 补一条「重载两次后表内无重复键」的断言。**2026-10-25 已解决**：`init-tools.el` 的两个 push 已加 `(unless (assq …))`，连续重载 3 次表长度恒为 2。

## 解释上下文超上限时只保留前缀，下方块可能被整块截掉（minor，2026-10-25 T6b-3）

- 现象：`--context-text` 的矩形路径把「选区上方块 + 下方块」拼成一个**不含选区**的串后交给 `--context-window`；该函数在其中定位不到选区（字符串里本就没有选区），于是走「取前 MAX-CHARS 个字符」分支。当上方块本身较长、两块合计超过 `seshat-reader-translate-context-max-chars`（默认 1200）时，**下方块会被整体截掉**，模型只看得到选区之前的正文。真实 PDF 实测（`d2l-zh-pytorch.pdf` 第 21 页，矩形 `(0.0 150.0 400.0 250.0)`）两块合计仅 179 字符，未触发；触发条件是「选区上方还有长段正文」。
- 影响：解释质量而非正确性——上下文偏向选区之前、缺少后文承接；不报错，长度上限仍被守住。
- 来源：`openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`（T6b-3：上下文改为取选区上下块）。
- 解除条件：矩形路径改为「按块分配预算」（各占 `max-chars / 2`，任一块不足时把余量让给另一块），或在拼接前对各块分别截断；改动需补一条 ERT（「上方块超长时下方块仍保留部分」）并同步 `docs/configuration.md` 的 `-context-max-chars` 说明。

## `--strip-chatter` 可能误删以「下面 / 这段」开头的正文首行（minor，2026-10-25 审查残余）

- 现象：`seshat-reader-translate--chatter-regexp` 只要求「首行以寒暄词开头 + 该行以冒号结尾」，因此正文本身以「下面 / 这段」开头且以冒号收尾时（如「下面这段代码做了什么：」作为正文首行）会被当成寒暄整行删掉。
- 影响：输出内容被削掉一行；强特征（行尾冒号）+ 可关开关（`seshat-reader-translate-strip-chatter` 设 `nil`）使风险可控，不报错。
- 来源：`openspec/active/2026-10-25-reader-translate-preset-isolation-and-explain-quality.md`（D5 输出净化的审查 minor）。
- 解除条件：收紧词表（只保留「好的 / 以下是」这类纯寒暄词），或要求更长的寒暄短语（如「好的，以下是」整串匹配）以降低对正文首行的命中率。

## gt 异步渲染路径把分段 text 列表当字符串（2026-10-25 加固，gt 侧仍存隐患）

- 现象：gt 的 translator `text' 槽永远是**分段列表**（一个选区 = `("文本")`）。gt 的异步渲染路径（`gt-word-p` / `gt-buffer-insert-source-text` / overlay 与 insert 两类渲染）在部分预设下会把整表当字符串交给 `string-trim` 一类函数，报 `Wrong type argument: stringp, ("…")`；用户在主实例实测命中（`[unhandled error] Wrong type argument: stringp, ("Kademlia: …")`）。触发条件多为 `word` / overlay 类预设或旧版 gt 代码路径。
- 本包已做的加固（`seshat-reader-translate.el`）：新增 `seshat-reader-translate--as-string`（字符串原样 / nil → 空串 / 纯字符串列表换行拼接 / 其它 `format'），在三处边界接线——`--explain-escape-value`（避免 `string-replace' 崩）、`--apply-template`（避免把 `("…")` 的 prin1 形态静默写进面板）、`--record-result`（避免把 list 写进 `last-result`，否则后续 `--save-as-annotation' 的 `string-trim' 在同源第二现场崩溃）。
- 剩余隐患：**gt 侧未改**（本仓库不 vendored gt，也不得改 thomas-emacs）。因此 `word`/overlay 类预设、以及上游 gt 升级后新出现的字符串假设，仍可能在渲染阶段抛 `stringp` 错误——本包的规范化只保证「错误不落在 seshat 自己的边界函数上」。
- 来源：2026-10-25 逐函数探针（HEAD 上 `--explain-escape-value` 收到单元素 list 必抛错；`--apply-template` / `--record-result` 静默污染）。
- 解除条件：gt 上游在渲染路径入口统一 `(mapconcat #'identity text ""/ "\n")`；或本包改用自建渲染器（放弃 gt 的 overlay/word 渲染）。在此之前不建议把 `seshat-reader-translate-preset' 切到 `word`/overlay 预设。

## 流式开启时 gt 的 `:then` 回调不触发（`--stream` 与 sidebar 组合）——已定位并规避（2026-10-25）

- 现象：`seshat-reader-translate-stream` 为 `t`（默认）时，`gt-finalize` 的 stream 分支不调 `gt-update`，因此渲染器的 `:then` 回调**不触发**——纯流式下侧栏面板的内容依赖 `gt-buffer-render-output-hook` 的增量；而 `gt-posframe-*` 类渲染会在局部改写该 hook（`gt-posframe-pop-render-output-hook` / `gt-posframe-pin-render-output-hook`），流式 + sidebar 组合下增量与收尾可能同时失效（面板停在骨架或停在最后一段增量）。
- 影响：显示层，不报错；`last-result` 与面板内容可能不一致（面板缺收尾更新）。
- 临时规避：`(setq seshat-reader-translate-stream nil)`——退回「完成时一次性渲染」，`:then` 路径恢复。
- 来源：2026-10-25 主实例诊断（`gt-finalize' 的 stream 分支与 `gt-update' 调用链）；与上方「流式增量路径不经过 `--strip-chatter`」同属流式分支的 gt 契约缺口。
- 实测根因（2026-10-25 verify 实例真实 DeepSeek 流式请求 + 逐函数探针，比上面的推测更靠前，且更正「增量可用」这一判断）：
  ① `gt-finalize' 的 stream 分支只调 `(gt-output render task)'，**不调** `gt-update'，translator `state' 停在 2，`:then' 永不触发（实测 `(oref translator state)` = 2）；
  ② task 级 `gt-output' 走 `gt-insert-text-at-marker'，**不调**渲染器的 output 函数，因此 `gt-buffer-render-output' 根本不执行、`gt-buffer-render-output-hook' 不会 run——`--stream-sync' 挂在该 hook 上，**从未被调用**（探针无输出，而 hook 列表里确实有它，`gt-buffer-render-translator' 也与本次 translator `eq`，即不是守卫失败）；
  ③ 结果是面板的两条创建路径（`:then' 与非流式渲染）全部失效，而增量只写进 `(display-buffer-no-window)' 隐藏的中转 buffer ` *Seshat gt*`（实测其中确有完整增量文本）——面板既不出现也不报错。
- 修复（同 commit）：新增 `seshat-reader-translate--stream-wanted-p'——面板路径（`sidebar' + 侧栏启用）恒返回 nil，`--translator' 据此不再给引擎开流式，退回「完成时一次性渲染」，面板必现；posframe 路径维持原行为。`gt-buffer-render-output-hook' 的安装保留（当前不触发，为 gt 未来补回调预留）。
- 遗留：sidebar 下「边生成边显示」能力因此暂时不可用（`--stream-sync' / `--stream-init' / `--stream-render' 与追问流式渲染成为无调用路径的实现），需 gt 提供流式完成或增量回调后重新接线。
- 复验：verify 实例真实请求下 `stream=t' 与 `stream=nil' 两种设置面板均出现（49 / 48 行，`last-result' 343 / 438 字符）。
- 解除条件：gt 在 stream 收尾路径补调 `gt-update'（或提供独立的「流式完成」回调）、且流式增量也走渲染器的 output 函数；届时把 `--stream-wanted-p' 的面板分支改回允许流式并删除本规避。

## gt 在引擎 `stream` 为 t 时跳过 `delimit` 的 join（2026-10-25 修复，gt 侧组合仍不安全）

- 现象：gt 的 `gt-execute`（`gt-core.el`）只在 `(and delimiter (not (oref engine stream)))` 时把 translator `text` 槽的分段列表 `string-join` 成字符串。引擎 `stream` 为 `t` 时**跳过 join**，依赖字符串的引擎（google / youdao / 多数非 LLM 引擎，`delimit` 默认 `t`）随即在内部字符串函数上报 `Wrong type argument: stringp, ("…")`（每个引擎一次，两个引擎即 `[2 times]`）。chatgpt 引擎因为走 `gt-dolist-concurrency` 逐项处理所以不受影响。
- 本包已做的规避（`seshat-reader-translate.el`）：`--enable-stream` 的开流判据加上 `(null (oref engine delimit))`——只有 `delimit` 为 nil 的引擎（LLM 类）才克隆并 `oset stream t`；`delimit` 非 nil 的引擎保持原对象（不 clone、不改槽），翻译一次性返回。判据用引擎自身的槽，与 gt 的 join 决策同源，不硬编码引擎类名。
- 剩余隐患：**gt 侧组合本身仍不安全**——「流式 + `delimit` 非 nil」在 gt 内部依旧会崩。托管配置的其它路径（或用户自定义预设）若手动 `oset stream t` 给这类引擎，同样会踩中。
- 来源：2026-10-25 主实例实测（`--enable-stream` 给全部带 `stream` 槽的引擎开流式，youdao/google 各报一次 `stringp` 错误）。
- 解除条件：gt 修复该组合（stream 为 t 时仍按 `delimit` join，或给出能力探测/声明式约束），本包即可去掉 `delimit` 判据；在此之前**勿在配置侧手动**给 `delimit` 非 nil 的引擎 `oset stream t`。

## `C-u N G` 跳指定页能力收窄（2026-10-26）

- 现状：阅读器关闭 evil 后，包内 `vim` preset 的 `G` **只跳末页**（`seshat-reader-last-page`）；原 `thomas-emacs/lisp/init-evil.el` 里带前缀参数的 `+seshat-reader-goto-page` helper（`C-u 5 G` 跳第 5 页）随该文件的 seshat 段（103 行）一并删除，包内没有等价实现。
- 影响：习惯「`C-u N G` 跳页」的用户少一条路径；**跳指定页仍可用** `M-g g`（`M-g M-g` / `<remap> goto-line` 同绑），功能不缺失，只是键位形态变了。
- 建议：如需恢复 vim 风格，可在 `vim` preset 里把 `G` 绑到一个 wrapper——`(if current-prefix-arg (seshat-reader-goto-page) (seshat-reader-last-page))`，并保证 `seshat-reader-goto-page` 在无前缀时能取到默认页号（现为交互式读 `read-number`）。注意 `G` 目前在 `--key-bindings-vim-only` 表内，改动同时要更新 `seshat-reader-evil-keymap-test.el` 的键位断言与帮助页键位表。

## evil 在 buffer 显示路径上会重新 enable（2026-10-26）

- 现象：`seshat-reader--disable-evil` 在 mode body 里调用之后，buffer 一旦被 `pop-to-buffer` / `display-buffer` 显示，`evil-local-mode` 会**重新变回 `t`**（2026-10-26 verify 实例实测），因此「在 mode body 里关一次即可」的假设不成立。
- 现状：帮助页 `seshat-reader-help` 在 `special-mode` 就位时关一次、`pop-to-buffer` **之后**再关一次；面板由 `seshat-reader-sidebar--display`（window / childframe 两条承载路径）在显示前关一次，`show` 的 `pop-to-buffer` 回退分支另关一次；另有 ERT 断言「re-enable 后重关」。阅读 buffer 本身路径稳定，未见回弹。
- 风险：任何**新增的显示路径**（新的面板承载、新的 `display-buffer` 调用、第三方接管显示）都可能漏掉第二次关闭，症状是「evil 键位在某些 buffer 里突然回来」，且 `(key-binding …)` 查得到正确命令、真实按键却落到 evil（与 M11.2c 的 keymap 装载问题同形）。
- 建议：长期改为不依赖「关两次」的形态——给 help / panel buffer 派生专用 major mode 并在其中以 buffer-local 方式维持 `evil-local-mode` 为 nil（例如挂 `change-major-mode` 或在 `window-buffer-change-functions` 里补关），或向 evil 请求「此 buffer 恒 emacs state」的声明式入口。在此之前，新增显示路径必须复用 `--display` 漏斗或显式补一次 `seshat-reader--disable-evil`，并加对应 ERT。

## 帮助页键位表与实际绑定无一致性断言（2026-10-26）

- 现状：`seshat-reader-help--navigation-keys` / `--feature-keys` / `--panel-keys` / `--search-panel-keys` 是「命令符号 → 说明」的静态表，帮助页渲染时用 `substitute-command-keys` 从**运行时** keymap 解析键位，取不到绑定就显示「（未加载）」。若某命令改名或删除而未同步改表，帮助页会**静默**把该行显示成「（未加载）」，既不报错也不失败测试——本轮改键位时就依赖人工核对。
- 影响：文档与代码漂移只表现为帮助页多出一行「（未加载）」，容易被忽略；比编造键位好，但仍不是不变量。
- 建议：加一条 ERT 遍历四张表的 `car` 并断言 `(fboundp cmd)`（模块未加载时用 `require` 或 `declare-function` 桩），把「表里的命令必须存在」编码成可机械检查的不变量；`make -C emacs/seshat-reader all` 的 checkdoc 不覆盖这类语义，只能靠测试。

## 两套根配置待统一（M8-C，2026-10-26）

- 现象：Emacs 端存在两套互相独立、形态不同的根配置——`seshat-state-roots`（同步用，元素 `(TAG DIR MODE)`）与 `seshat-reader-annotation-roots`（批注 / 引用用，元素 `(TAG . DIR)`）。`seshat:` 的 uid 解析链路是「按后者得 `(tag . rel)` → 软依赖 `seshat-state-uid-for-path` 查 uid」，因此**两套 tag 必须一致**才能解析出 uid。本计划（M8-C）按取舍 A4 明确**不统一**。
- 影响：① 同一目录可能被配两次（用户要在两处各写一遍，且两处形态不同、无法复制粘贴）；② 两套 tag 不一致时不报错、只表现为「链接回落成 `doc-id` 形态」（失去改名稳定性），定位成本高；③ 新增入口每接一次就要重复一遍「这套配置给谁用」的判断。
- 建议：将来把 `seshat-reader-annotation-roots` 改为**从** `seshat-state-roots` 派生（保留只读覆盖语义），或提供一条把后者同步成前者的命令；改动需同步批注 / 翻译 / 离线队列三处推导点，并补「两套配置不一致时给出显式提示」的断言。

## `ondemand` 副本过期无可检测信号（M8-C，2026-10-26）

- 现象：`ondemand` 根的资源 `blob` **恒为空串**，`changes` 事件也不带 `size` / `mtime`（`docs/api.md` / `docs/sync-protocol.md` 均已写明）。因此服务端替换书库文件后，客户端的 `need-download` 判定恒为 nil，**本地副本永不自动刷新**；本计划只能提供显式刷新（书架 `u` 键 / `seshat-library-fetch` 传 `force`）。
- 影响：用户不按 `u` 就继续读旧副本，且没有任何提示能告诉他「你手上的副本已经过期」。属已知取舍，不属缺陷——协议层没有可比较的信号。
- 建议：服务端先为 `ondemand` 根补 `blob`（或让 `changes` 事件带 `size` / `mtime`），客户端再做自动比对（比对放书架打开路径还是后台定时器需另行决策：前者多一轮请求，后者引入后台写状态库的并发面）。在此之前**不要**用「每次打开书架都拉全清单比对」来绕过——实测收益仅为省一次按键。

## 书架清单一次性拉全根（M8-C，2026-10-26）

- 现象：`M-x seshat-library` 首次打开会分页拉取全部 `ondemand` 根的清单（每页 2000 条，直到 `has-more` 为 nil），全程同步 HTTP、跑在主线程上。另因 `/api/resources` **没有 offset 分页**，客户端只能用 `:since-mtime` 前进；「同秒记录多于一页」时 `seshat-sync--next-since-mtime` 会强制 `(1+ mtime)`，该秒剩余记录被**跳过**（只在真正同秒超页时提示一次，不重试、不补救）。
- 影响：大书库下打开书架会阻塞 Emacs（无进度、不可中断）；同秒超页会静默少几行（提示只在消息区闪一次，缓冲区分页后更难察觉）。`g`（重拉清单）同样一次性拉全根，且 `d` / `u` 刻意不走它（见 decisions「按需取书用原子落位 + 显式刷新」）。
- 建议：服务端为 `/api/resources` 加**分页游标**（稳定排序键而非 `mtime`），客户端改为按页异步拉取（`url-retrieve` 回调 + 增量 `tabulated-list` 插入），并把「清单可能不完整」升级为 buffer 内的可见横幅而不是一次性 `message`。
- 状态更新（2026-10-26 安全加固）：现已加 `seshat-library--max-pages` **500 页上限**（100 万条），恶意 / 异常服务端不再能造成无限循环——达上限 `display-warning` 并返回已收集部分；清单仍是一次性拉全根，阻塞主线程的体验问题与上条建议不变。

## reader 包对 `save-place-to-alist` 的 advice 是既有侵入（M8-C，2026-10-26）

- 现象：`emacs/seshat-reader/seshat-reader-saveplace.el:66` 用 `(advice-add 'save-place-to-alist :around (lambda …))` 把 reader buffer 的 saveplace 记录改存成 vector——属 **vendored 既有行为**（集成 saveplace 所需），非 M8-C 引入，已纳入透明性白名单 `{save-place-to-alist, pcase--mutually-exclusive-p}`。**另有一处重复**：`emacs/seshat-reader/seshat-reader-autoloads.el:204` 有**功能完全相同**的一条 `advice-add`，与 `.el` 里的 `;;;###autoload` 重复。
- 影响：① advice 链会出现**两跳**（两个匿名 lambda 串联），调试时 `advice--p` 只说明「被 advice 过」、看不出层数，排查 saveplace 行为异常时容易漏看；② 只要 `.el` 与 `autoloads` 两份中任一份被编辑而另一份未同步，两者行为就会静默分叉（其中一份带 `;;;###autoload`、另一份是生成物，改动时机不同）。白名单是**精确函数名集合**（不是计数或前缀过滤），因此任何**新增** advice 都必须先更新白名单——白名单变更即侵入评审点。
- 建议：清理 `seshat-reader-autoloads.el` 里的重复条目，源头收敛到 `.el`（并确认 `make all` 的 autoload 生成不会把它再写回来）；或补一条 ERT 断言「同一函数上 seshat 系 advice 条数 ≤ 1」，把「不留双跳」编码成可机械检查的不变量。附注：`pcase--mutually-exclusive-p` 是 stock `cl-macs.el` 自带 advice（装不装 seshat 都在），纳入白名单是基线而非侵入。

## 透明性断言的两处已知边界（M8-C，2026-10-26）

- 现象：`emacs/tests/seshat-transparency-test.el` 的六项反向断言有两处覆盖不到——① **hook 内部**：`after-save-hook` / `after-change-major-mode-hook` 的断言只检查 hook 列表里**顶层函数符号**是否以 `seshat-` 开头，若某 seshat 行为被包进 `(lambda …)` 再挂上 hook，名字里没有 `seshat-` 就查不到；② **keymap 范围**：keymap 断言只覆盖 `dired-mode-map`（递归前缀子 keymap 含 `remap`，不跟随父链与 `global-map`），`global-map` / `tabulated-list-mode-map` 等未被覆盖。
- 影响：这两条侵入路径在断言下是**静默通过**的假绿面——hook 里塞 lambda、或在 `global-map` 上绑 `C-c` 前缀 seshat 命令，测试都不会失败。要求「不跟随 `keymap-parent` / 不看 `global-map`」是刻意的：按命令反查按键的查询函数会连带搜索父链与 `global-map`，无法限定「只查自身」，会让断言在无关绑定上误报。
- 建议：① keymap 断言参数化——把「要检查的 keymap 列表」提成变量（追加 `tabulated-list-mode-map`，`global-map` 若纳入需先评估噪声：第三方包在 `global-map` 上绑键很常见，只筛 `seshat-` 前缀命令应可接受）；② hook 项改用「函数**源文件位置**是否在 seshat 目录内」过滤——`(symbol-file fn)` 对具名函数有效、对 lambda 无效，故只能作为补充而非替代，且易误报（用户配置里的包装函数），需先评估误报率再落。两项改动都要同时补充**变异自检**（注入假侵入必须让断言失败），否则改了等于没改。

## `Content-Length` 缺失时下载上限不生效（M8-C 安全加固，2026-10-26）

- 现状：`seshat-library-max-download-bytes` 的超限判定依据是服务端响应的 `Content-Length`，在写盘**之前**预判（这样不会先把磁盘写满才发现超限）。但分块传输（`Transfer-Encoding: chunked`）或网关压缩时，该头可能**不存在**、或数值与实际字节数不符；此时预判被跳过，上限形同不设。`url.el` 一侧没有流式读入字节数的限制能力（`url-retrieve-synchronously` 只能整体取回），curl 后端虽有 `--max-filesize`，但当前 `:binary` 路径主要走 url 后端。
- 影响：面对**恶意**服务端（故意不给 `Content-Length` 却持续发送大响应）时，单次取书仍可能把 Emacs 拖入长时间等待与大内存占用；超时闸（`seshat-library-download-timeout`）能兜住「无限阻塞」，但兜不住「在 30 秒内塞满几百 MB」。
- 建议：将来在传输层按**实际读入字节数**硬限（回调计数达上限即中止并丢弃 buffer），或把 `:binary` 路径统一切到 curl 后端并启用 `--max-filesize`。在此之前，上限只对「规矩的服务端」有效，残余风险由服务端可信度承担。另有一条低成本加固：写盘前可用 `(string-bytes (plist-get response :body))' 对**已取回的响应体**再做第二道判定，能防「磁盘写满」（内存占用仍需传输层流式限制，故它只是减轻而不是替代）。

## `force` + 非交互路径会阻塞在确认（M8-C 安全加固，2026-10-26）

- 现状：`seshat-library-fetch` 在 `force` 非 nil 且本地已有副本时 `yes-or-no-p` 询问是否覆盖。当前只有书架 `u` 键会带 `force`（交互场景，确认合理），但函数契约本身不区分「有人按键」与「程序调用」。
- 影响：将来若加「批量全部刷新」「定时刷新」这类入口，`yes-or-no-p` 会阻塞在批处理 / 定时器上下文（无 `y-or-n-p` 输入来源，轻则卡住流程、重则在 `--batch` 下直接报错），而调用方多半不会预期一个「刷新」动作会弹确认。
- 建议：届时改为显式传入「已确认」标志（如 `:confirmed t` 形参），或把确认改用可 `noerror` 的 `y-or-n-p` 并把「拒绝」交给调用方决定重试策略；改签名时须同步书架 `u`、`:follow` 按需下载两条既有调用路径与对应 ERT。


## uid 正则在 4 处 + 2 处测试内联重复（M8-C 安全复核，2026-10-26）

- 现象：uid 的权威字符集（26 位 Crockford Base32，排除 I / L / O / U）在多处以**字面量正则**重复出现：`internal/registry/uid.go:29`（`^[0-9A-HJKMNP-TV-Z]{26}$`）、`emacs/seshat-library.el:71`（`seshat-library--uid-regexp`）、`emacs/seshat-reader/seshat-reader-reference.el:154`（`--uid-regexp`）、`seshat-reader-reference.el:214`（同字符集的 `+` 变体，用于「整串都是 Crockford 字符」的判定），另有两处测试内联：`emacs/tests/seshat-library-test.el:1055` 与 `internal/registry/uid_test.go:89`。
- 影响：改字符集（例如服务端换编码）时要同步改 **6 处**，漏一处就出现「服务端认为合法、客户端拒绝」（或更糟：客户端放行一个服务端会拼进 URL 的更宽字符集，安全性由**较宽**的那份决定）。重复本身由依赖方向决定、**不可简单去重**：`emacs/seshat-reader/**` 不得依赖项目层（`seshat-library`），`seshat-library` 也不得依赖 reader 包，Go 侧更不可能共享 Elisp 常量——任何「提取公共定义」的方案都要先打破分层约束。
- 建议：不做代码去重，改为在文档里固定一句「uid 字符集唯一权威 = `internal/registry/uid.go`（`^[0-9A-HJKMNP-TV-Z]{26}$`）」，并在 `docs/`（architecture 或 api 的 uid 节）显式列出其余 5 处副本；改动字符集时**必须** `grep -rn '0-9A-HJKMNP-TV-Z'` 复核全部副本，同时更新 `seshat-library-test.el` 的 fixture 校验用例。若将来要机械化，可考虑一条跨语言的一致性测试（Go 侧生成期望值、Elisp 测试读同一份 JSON fixture），但那要求仓库内置一份 fixture 文件而不是再抄一遍正则。

## `mirror` 根下载仍无 timeout / max-bytes（M8-C 安全复核，2026-10-26）

- 现状：本轮（M8-C 安全加固）只给 `seshat-library` 路径收口了下载边界——`seshat-library-fetch' 显式传 `seshat-library-download-timeout` / `seshat-library-max-download-bytes` 给 `seshat-rest-download-file'。其余调用方**一个关键字都没传**：`emacs/seshat-sync.el`（两处，`need-download` 与首同步取内容）、`emacs/seshat-conflict.el'（三方合并前拉远端版本）、`emacs/seshat-reading.el'（阅读器按需取原文件）。
- 影响：同一条「一台挂住的慢服务 / 一个超大响应拖死主线程」的风险面在笔记同步路径**依旧完全敞开**——同步是后台定时器触发的，用户看不到任何进度，卡住的表现是「Emacs 莫名不动」。`seshat-rest-download-file' 的 `timeout` / `max-bytes` 默认都是 nil（不限），因此「不传」等于「无闸」。
- 建议：把两个限制提升为 `seshat-rest' 层的默认策略——或给 `seshat-rest-download-file' 内部兜底读取全局 defcustom（如 `seshat-rest-download-timeout` / `seshat-rest-max-download-bytes`，供所有调用方继承），或在 `seshat-rest' 层给 `:timeout` / `:max-bytes' 一个非 nil 默认值。注意 `mirror` 根的正常文件可能比书库大（附件类笔记），设默认值前先确认「超限」在同步路径的降级行为（当前是 `:too-large' → 不写盘，需要调用方各自处理，否则会被静默当成「已下载失败」重试）。

## 书架「根」列与实际操作目标可能分叉（M8-C 安全复核，2026-10-26）

- 现状：`seshat-library--collect' 只保证「响应 `:root' == 请求的 tag」，**不保证**它等于「本地状态库为该 uid 登记的 root」。两者在配置迁移（`ondemand` → `mirror`，或服务端换根而客户端状态库未跟上）后会分叉：行仍然显示在 books 根下、状态列显示「已下载」（`--local-state' 用的是状态库里的 root + path），但 `RET' / `u' / `d' 会先按**状态库登记的 root** 过 mode 门，于是被 `user-error' 拒绝（提示「不是书库（ondemand）根」）。
- 影响：失败方向是安全的（**拒绝**，不写不删），但体验误导——用户看到一列「已下载」的书，按 `RET' 却被告知「该根不是书库」，且提示里的根 tag 与「根」列显示的 tag **不一致**，很难自己定位到「状态库没跟上」。
- 建议：让 `seshat-library--local-state'（或 `--entry'）顺带比对「状态库登记的 `(car location)'」与「清单 item 的 root」，不一致时把状态列显示为「未登记」（或新增一个「根已变」文案），并在 `seshat-library-fetch' 的 mode 门拒绝消息里带上两边 tag（「清单根 X，登记根 Y」）。改动需补一条 ERT：构造「item root = books、状态库登记 root = notes」的不一致态，断言状态列不显示「已下载」。

## 面板宽表格溢出被裁切（valign 绝对像素对齐，2026-10-26）

- 现状：译文/解释面板的 Markdown 表格由 `valign-mode`（`seshat-reader-translate-valign`，默认 `t`）对齐，它用 `:align-to` 做**绝对像素**对齐——每个单元格的显示宽度按表格自身最宽内容分配，与面板窗口宽度无关。列总宽超过面板可用宽时，**最右侧几列直接落到面板右缘之外**：不可见、不能折行，也不能横向滚动（面板正文折行模式才是 vfcm/valign 生效的条件，而不折行模式又会跳过 valign）。
- 影响：面板常态宽度 `seshat-reader-sidebar-width` 为 `0.25`（约 1/4 屏宽），4 列以上且含长中文单元格的表格极易命中。且**没有任何截断提示**——右侧内容凭空消失，读者容易误判为「模型少输出了几列」，属于误导性呈现。本轮（2026-10-26 面板宽度跟随 + valign）**不解决**该问题，只保证**不加剧**：valign 是新引入的能力，此前表格根本不对齐、也不存在「对齐后被裁切」这一具体失败形态。
- 建议（三级，按代价递增）：
  1. **零代码缓解**（当前可用）：按 `w`（`C-c w`）把面板扩到 `seshat-reader-sidebar-expanded-width`（0.75）让表格放得下；或 `(setq seshat-reader-translate-valign nil)` 退回不依赖像素对齐的 Markdown 渲染（列不齐但内容完整）。
  2. **表格宽度感知**：渲染前测最宽行（按 `window-text-pixel-size` 或字符宽度估算），超过面板可用宽时**临时不启用** valign，只对该份内容退回非对齐渲染。代价是同一面板内对齐策略不一致（有的表格对齐、有的不对齐），需要用户裁定「对齐 vs 完整可见」谁优先——这是产品取舍，不宜由实现单方面决定。
  3. **渲染侧重排**：对超宽表格做单元格换行（多行单元格），使表格永不溢出。属**渲染语义变更**（Markdown 表格从「一行一记录」变成可能多行），会影响复制/搜索/`valign` 自身行为，需单独立项评估。
- 约束：**任何方案都不得改 `seshat-reader-panel-truncate-lines` 的默认值**——该默认值（`nil` = 折行）是 2026-10-25 按用户真实阅读习惯定的，为了迁就表格而改回不折行会让长段落阅读体验整体倒退。

## 多页连续布局（路线 3）落地前必须处理（P0 后，2026-10-26）

- 现状：P0 已交付「渲染任意页返回 image spec」的纯查询接口（C `seshat-reader-dyn--page-image-spec` + elisp `seshat-reader--page-spec`，见 `openspec/completed/2026-10-26-reader-multipage-p0-page-spec-api.md`），但**没有任何显示路径使用它**，既有的 per-window 缓存 / 刷新范围 / hscroll / 多窗口页号语义全部原样未动。下列 7 项在多页 buffer 连续布局（P1 起）落地前必须逐条处理：
  1. **per-window 11 槽缓存无法表达多页**：`PAGE_CACHE_SIZE`（`render/render-core.h`）的键是「窗口 + 当前 scale/rotate」，**不含页号维度**，且 `resolution` / `rotate` 一变整窗失效。要在一个窗口同时持有 N 页，必须先把键扩成 `(page, resolution, rotate, decoration-version)` 并处理 `decoration-version` 变化时的批量失效。
  2. **`--refresh-highlights` 只重建当前窗口 ±5 页**：多页布局下视口可跨更多页，装饰（批注 / 框选闪现 / 搜索命中 / ink）刷新范围必须按视口实际页数重算，否则刚滚入视口的页会显示旧装饰。
  3. **hscroll 是窗口级**：整页横向滚动会让整栏（含相邻页）一起移动，宽页（如 A0 图纸）在多页布局下会把邻页推出视野。需改为按页对齐或按页单独横向偏移。
  4. **多窗口「各看不同页」的能力将丢失**：路线 3 的决策是「页号由视口顶页派生」，不再用 window 参数 `page` 作真相来源；同一文档在两个窗口停在不同位置后，依赖 `page` 参数同步的功能（书签恢复、`--centered-p`、侧栏跳转回写）都要改成按窗口各自派生。
  5. **整页位图内存与驻留策略（P2-5）——部分缓解（2026-10-28 canvas 后端）**：**已消除** ① Lisp 堆上的 PNM 字符串副本（旧口径 72 dpi 1.42 MB/页、150 dpi 6.16 MB/页）；② C 侧 `CachedPage.img_data`（`CachedPage` 已随 legacy 渲染路径删除）。**仍存在** ① Emacs image cache 内的 canvas 缓冲（每页 `w*h*4`，612×792 ≈ **1.9 MB**，比旧 ≈3.4 MB 降 **43%**）；② 渲染期临时内存——MuPDF pixmap（3 分量 + alpha）与 BGRA 中间缓冲，渲染函数返回前释放、不进缓存。**旧结论已被推翻**：「一张位图在内存里至少两份」不再成立，现状是「Emacs 侧一份常驻 + 渲染期最多两份临时」。**口径更新**：驻留估算改 `data-width × data-height × 4`（不再读 `:data` 长度）；上限仍由 `seshat-reader--page-spec-cache-limit`（8）与多页驻留集（视口 ± `seshat-reader--multipage-preload`）共同约束。**未做**：pin 引用而非复制（已无复制对象）。**已解决（2026-10-29）**：异步渲染与 idle 预取由 P2-B 交付（`openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md`），本项内存模型未变——异步只改「何时渲染」，驻留集与缓存上限未动。
  6. **`snapshot_page_decorations` 与 `submit_render_job` 渲染路径重复未合并**：P0 新增的静态 `snapshot_page_decorations`（`render/render-core.c`）与 `render/render-threads.c` 的 `submit_render_job` 内联的装饰快照逻辑**语义等价但是两份代码**（deep copy 规则、`pts` 逐条拷贝、失败降级策略），任一处修改都会让「屏幕上的位图」与「`--page-spec` 返回的位图」装饰不一致。合并时必须保证 `free_draw_thread_args` 仍是 worker 路径的唯一释放漏斗。
  7. **batch 下第二次渲染撞 `image-flush`**：`emacs --batch` 里连续多次渲染/写 overlay `display` 时 C 侧 `image-flush` 抛 `Window system frame should be used`，因此 P0 的 ERT 夹具必须 `(fset 'image-flush #'ignore)`。**GUI 侧未验证**是否有图像库警告或缓存行为差异——若 GUI 下 `image-flush` 被反复调用（例如每页替换 spec），可能有性能影响，需在 P1 的 GUI 冒烟里观察。
- 影响：①②③ 是布局**正确性**前置（不处理会画错位置 / 显示旧装饰 / 邻页被推出视野）；④ 是**能力回退**（用户当前依赖的多窗口各看不同页会消失）；⑤ 是**内存上限**，处理不当会让打开大文档直接吃满内存；⑥⑦ 是**一致性与可测试性**债，短期不致命但会让「两条渲染路径取到不同位图」这类 bug 极难定位。
- 建议：按 ①→⑦ 顺序处理；①③ 与 P1 的布局改造同一批（它们都在渲染/滚动的几何层），②④ 在 P1 收尾时统一改（都涉及「页号真相来源」），⑤ 在 P1 设计视口时先定量（用 P0 的实测口径复测目标缩放档），⑥ 作为独立的纯重构提交（用 PNM sha256 守门），⑦ 随 P1 的 GUI 冒烟一并验证。
- 约束：**不得靠「提高 `--page-spec` 缓存上限」掩盖 ⑤**（上限 8 是双份内存的折中，16 是硬上限）；**不得为多页布局再引入第二套渲染路径**（⑥ 的合并方向是「一份快照逻辑」，不是「两套各修各的」）；跨页选区仍按 2026-10-26 决策禁掉，不在本轮技术债里提前解禁。

## `TestRescanSerializesConcurrentRequests` 的并发断言先天宽松（服务端技术债 A 批二次验证，2026-10-26）

- 现状：该用例起 8 个并发 `POST /api/resources/rescan`，只断言「每个响应状态 ∈ {200, 409}」「至少有一个 200」「收尾请求成功」。**没有**断言「恰好 1×200 + 7×409」——理论上 8 个全返回 200 也能通过，而 `rescanRunning` 的 CAS 互斥正是本用例唯一要守的不变量。
- 影响：若将来有人把 CAS 抢占改坏（例如误改成 `Store(true)` 或用读-判断-写），该用例仍会绿，并发互斥的不变量失去回归保护。
- 建议：在原断言基础上补 `ok == 1 && busy == 7`（在 `rescanMinInterval = 0` 的 fixture 下这是确定性结果，不是概率断言）；同时注意 `t.Cleanup` 恢复包级 var 的顺序，避免与其他 rescan 用例互相污染。属测试加固，不与已归档的 A 批混改。
## 暗色 tint 把彩色内容压成单色调（阅读器暗色配色预设，2026-10-27）

- 现状：`seshat-reader-dyn--doc-tint` 的下发路径把**每像素亮度**线性映射到 BG–FG 两端（C 侧 `fz_tint_pixmap`），Chrominance 信息整体丢弃。因此暗色模式下彩色插图、彩色封面、彩色标注图一律变成单色（实测 p775 彩色插图 + 透明 mask 页：整页最大亮度分量恰等于 FG，即全图被压到调色板末端的同一个色值）。`graphite` 预设走旧 `fz_invert_pixmap_luminance` 路径，保留色度，是唯一例外。
- 影响：**可读性**上无问题（文字页与线稿更好读），但**信息丢失**——书里的彩色示意图、图表配色、封面无法辨认原色，读图类文档（教材、图鉴、幻灯片型 PDF）实际不可用暗色模式。
- 建议：做内容分流——「文字走 tint、图片保色」需要 C 层按区域判定（例如用 `fz_stext` 的 image block 或页面 display list 的 image device 划出图片区域，只对非图片区域做 tint），代价是每页多一次区域分析，且与既有「像素变换 → 装饰 wash → PNM」的次序耦合；短期替代方案是保留 `graphite` 作为读图时的切换档，或在阅读器提供「本页临时关闭 tint」的一次性命令。

## `sepia`（亮底）下既有黄色高亮装饰几乎不可见（阅读器暗色配色预设，2026-10-27）

- 现状：装饰配色是独立于暗色调色板的固定值——批注 `highlight` 恒为黄 `1.0/0.85/0.0` α `0.35`（`--add-highlight` 的历史配色，未改），`sepia` 预设的页面底色是亮米黄 `#xe8dfc8`。黄色半透明块叠在米黄底上几乎不产生可见差异，用户会以为高亮没画出来。
- 影响：`sepia` 档下所有批注高亮 / 框选闪现（同为暖黄系）可见性接近 0；`midnight` / `charcoal` / `night-sepia` 三档是暗底，黄块对比充足，不受影响。属**装饰配色未随预设自适应**，不是渲染缺陷。
- 建议：让装饰默认色随当前 tint 档位取反相 / 高对比色（例如亮底走深蓝、暗底保留黄），需要把「当前预设」暴露给 `seshat-reader-annotation--redraw-highlights` 一侧（C 侧已有 `theme_tint_bg`，可由 elisp 读一份镜像值）；或最小改法——检测到亮底预设时把默认高亮色改为深色系（`0.1/0.3/0.9`）。两条路径都要保证 `--add-highlight` 的历史配色在默认（`charcoal` / `graphite`）下逐像素不变。


## 2026-10-27 阅读器多页布局（P1）遗留

- **多页布局的内存上限**：同时驻留 spec ≤ 6 页（K=2），按 150 dpi ≈6.2 MB/页 × 2（Lisp 堆 + C 侧）≈ 75 MB 为告警线（`seshat-reader-multipage-memory-warning-mb`）；P1 不做异步预取与内存回收策略，长期滚动仍依赖视口淘汰。
- **跨页选区未实现**：首期 `user-error`（决策 D7）；需「按阅读顺序拼接两页文本 + 跨页矩形集合（带页号）」。——**已解决（P2-A，2026-10-27）**：页区间由 `--posn-page-extent` / `--selection-page-rects` 求出、逐页调 C 侧单页接口取文取几何，文本按阅读顺序拼接（页间一个换行），几何存 `:page-rects`（`(PAGE X0 Y0 X1 Y1)`），location 写 `pages:<a>-<b>;rect@<p>:…`（单页仍写旧形态、逐字节不变）。落点：`openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`（批次 1–3）+ `docs/api.md` §4.5.3 + `openspec/decisions.md` 2026-10-27「跨页选区的 location 形态与引用链接降级」；残余降级见本文件「跨页选区的四类残余降级」条。
- **横向滚动整栏平移**：`height` 模式与手动放大下，宽页横向滚动会让整栏（含邻页）一起移动（窗口级 hscroll）。
- **宽页按宽裁剪的取舍**：基准页取「打开文档那一页」，异常宽页被缩到刚好不溢窗；若改用「全文档最大页」需新增 C 侧批量查页尺寸接口。
- **异步渲染未做**：P1 全同步（0.7–11 ms/页），滚动到新页会阻塞；P2 再做异步 + idle 预取。——**已解决（P2-B，2026-10-29）**：两阶段渲染落地（同步只查页尺寸 4.5–10.3 µs、像素由 idle 首轮 + `run-at-time` 周期 timer 补上），三层兜底 + 运行时回滚开关 `seshat-reader-render-async`。落点：`openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md`；用户视角见 `docs/emacs-reader.md` §7「两阶段异步渲染」；剩余缺口（`fit-width` 单页成本、连按缩放无去抖、双窗口独立滚动等）见本文件「阅读器两阶段异步渲染（P2-B）遗留（2026-10-29）」。
- **C 侧单页 overlay 机制仅剩兼容外壳**：`init_overlay` / `init_win_state_ptr` / `get_win_state_ptr` / `--refresh-highlights` / `--window-close` 仍存在但 elisp 侧除 `--window-close`（释放 EmacsWinState）外已无调用；`elisp-helpers.c:279-287` 的 `overlay-put` 无 nil 守卫（`overlayp, nil` 的潜在来源）。——**已解决（P2-A 真机修复，2026-10-27）**：`overlayp nil` 不再有任何真实路径可达——① `check_current_overlay` / `get_current_doc_overlay` 的 nil 判定由 `emacs_value` 指针相等改为 `env->eq`（句柄相等不可靠，nil 真到达时原写法漏判，把 nil 喂进 `overlay-buffer` 即崩溃）；② `prepare_rect_query`（三个 rect 入口的唯一前半段）不再走 `get_reader_current_state`，改为只读 buffer-local 的 `seshat-reader-current-doc-state-ptr`（`get_doc_state_ptr`），overlay / `EmacsWinState` 与 `win_state->closing` 检查一并退出该路径。剩余外壳（`init_overlay` 等）**保留**：`--window-close` 仍需释放 `EmacsWinState`，且旧翻页/显示族 C 函数仍按自己的路径调用 `get_reader_current_state`；`elisp-helpers.c` 的 `overlay-put` 处未加 nil 守卫（无 elisp 调用者，加守卫等于给死代码加分支）。回归：`emacs/tests/seshat-reader-rect-query-overlay-test.el` 6 例（真实 `.so` + 真实 PDF，窗口 overlay 置 nil / 置外来 overlay / 置本 buffer 普通 overlay 三态对比），旧构建下 5/6 失败并复现 `(wrong-type-argument overlayp nil)`。
- **`posn-*` 访问器在字节编译后被内联**：测试若要桩替必须加载同源 `.el`（已在 `emacs/tests/README.md` 记录）。

## 阅读器跨页落点无法用 ERT 覆盖 redisplay 交互（2026-10-27）

- 现状：滚动族用例把 `window-start` / `set-window-vscroll` / `redisplay` / `--multipage-sync` 全部桩掉，能证明的只有「命令内的调用顺序与数值」（例如 `set-window-vscroll(0) → set-window-start → sync → redisplay → set-window-vscroll(offset)`），**不能**证明偏移能否跨 redisplay 存活。
- 影响：「与新设 `window-start` 同帧的像素偏移会被 Emacs 丢弃」这类行为只靠 ERT 永远测不出来——本次缺陷（`k` 跨页跳回上一页顶部）就这样逃过了当时全量 1224 例。任何声称「跨页落点已验证」的结论，若只有 ERT 支撑都不算通过。
- 建议：保持「命令内顺序/数值靠 ERT、跨 redisplay 行为必须真机」的分工；真机探针读数（四条，含 `3090 → 0` / 先落帧后保留 `3090`）已记入 `openspec/completed/2026-10-27-reader-cross-page-scroll-fix.md` 的「真机诊断记录」。将来改这一段滚动逻辑，先跑同样的探针再下结论。

## 阅读器 `pagecount` 未就绪期间末页上限不生效（2026-10-27）

- 现状：`seshat-reader--multipage-page-max-offset` 用 `seshat-reader--multipage-pagecount` 判断「是否末页」；该值在文档加载初期与 `revert-buffer` 之后为 `nil`，此时一律按**非末页**公式（`span − 1`）处理。单页文档在这一瞬间会退化为旧公式，可被滚出页面底部。
- 影响：瞬态（pagecount 就绪即自愈），但用户若恰在此窗口内快速下滑，仍可能看到一次空白「假页」。
- 建议：接受现状（保守回退，行为与修复前一致），不做「按已驻留页数猜末页」的推断——那会在多页文档里把中间页误判为末页。若要消除，需在 C 侧保证 doc load 完成前不暴露滚动路径，属跨层改动。

## 阅读器落点阈值用 `frame-char-height` 近似光标高（2026-10-27）

- 现状：`seshat-reader--multipage--place-point` 用「`vscroll` 是否大于一个文本行高（`frame-char-height`）」判断顶页行首的光标是否已被切出视口，而不是精确比较光标（glyph）高度。
- 影响：行高与光标实际可见高度的差异会造成阈值边界处的保守/激进判断——阈值偏大时可能少移动一次 point（光标仍部分可见，Emacs 不会回滚偏移，安全）；阈值偏小时多移动一次（落到邻居页行首，同样安全）。当前两种误差都不影响正确性，只是落点可能与「光标刚好露出 1px」的边界不同。
- 建议：若将来出现边界场景的观感问题，改用光标的实际度量（`(window-text-pixel-size)` 或 `window-cursor-pixel-height` 一类接口）后再校核；改动需真机复验。

## 书签的页内偏移恢复疑似持续失效（2026-10-27，code-reviewer major）——已修复并验证（2026-10-27，批次 A）

- 现状：`emacs/seshat-reader/seshat-reader-bookmark.el:117-118` 先调 `seshat-reader--multipage-goto`（内部执行 `set-window-start`）再直接 `set-window-vscroll offset`，两步之间**没有落帧**。
- 影响：与本轮确证的「同帧丢弃偏移」同根——若真机确认，则「存书签 → 跳回」的页内偏移会被清零（每次都落回页首），而 ERT 因为桩掉了 `set-window-vscroll` 看不出来。属**未验证的疑似缺陷**，本轮未改（计划明确不碰 bookmark）。
- 建议：修复方式与本轮跨页序列一致——在 `set-window-start` 与写偏移之间补一次 `(redisplay t)`，或直接复用跨页序列；修复后必须真机验「设页内偏移 → 存书签 → 跳回 → 偏移仍在」，并同步补一条 tech-debt 之外的回归说明。
- 已解决（2026-10-27）：按上面的「建议」落地——新增 `seshat-reader--multipage--apply-offset`（先 `(redisplay t)` 落帧再 `set-window-vscroll`；nil 窗口按 selected window 解析；非正数 offset 既不动作也不落帧），`seshat-reader-bookmark-jump` 第 ③ 步改调它，saveplace 经同一 handler 一并受益。**ERT 断言了落帧顺序**（事件序中 `redisplay` 早于 `set-window-vscroll`，实参 `(list (selected-window) 120 t)`），全量 **1266** 例 0 unexpected / 0 skipped。**T5 真机（书签跳回同页同偏移 / 关掉 Emacs 重开 PDF 验证 saveplace / 宽页 `hscroll`）待用户确认**——ERT 只能证明落帧发生在写偏移之前，不能证明偏移跨 redisplay 存活，故本条**暂留**于此，真机三项通过后再删。
- 已完成（2026-10-27）：用户真机确认 ① 书签跳回同页同偏移、② saveplace 重开 PDF 自动回原位 均通过。③ 宽页 hscroll 未验证，另立条目跟踪。

## 阅读器跨页存在一帧「新页顶部」中间态（2026-10-27）

- 现状：两帧方案里 `(redisplay t)` 落帧时像素偏移尚未写入，那一帧显示的是「新页 + 偏移 0」；紧接着才写最终偏移并落 point。
- 影响：快速连滚时理论上可见一帧跳动（每跨页一次）；实测未观察到用户可感的中间帧，正常翻页速度下不可见。
- 建议：若要消除，必须同时重估 Emacs 的「同帧丢弃偏移」行为（例如寻找不需要两次设置偏移的写法，或让跨页与偏移在同一次窗口状态变更里完成），属需要真机探针先行的高风险改动；不要在不重新探针的前提下「优化掉这次 redisplay」——那会直接回退成 `k` 跳页首。

## 窗口解析仍有多处旧写法 `(if (window-live-p window) window (selected-window))`（阅读器 fit 修复后观察，2026-10-27）

- 现状：D1 只把 fit 计算的三处（`--multipage-target-scale` / `--multipage-fit-scale` / `--multipage-current-fit-mode`）改为 `seshat-reader--multipage--display-window`。计划点名的四处仍是旧写法——`--multipage-base-fit-scale`、`--apply-display-scale`、`--multipage-resize-spec`、`--multipage-refresh-decorations`（最后一个是 `(or window (selected-window))` 变体）。实测 `grep -n "window-live-p window) window (selected-window)"` 共命中 14 处（13 处代码 + 1 处 docstring 引用），涉及的函数除前三个外还有 `--fit-scale`、`--multipage-page-should-center-p`、`--multipage-prefetch`、`--multipage-page-max-offset`、`--multipage--apply-offset`、`--multipage-scroll`、`--centered-p`、`--center-page`、`--scroll-step-pixels`、`--scroll-screen-pixels`。
- 影响：这些函数若在 minibuffer 激活期间被调用，仍会把 mini window 当几何来源。当前靠两层兜底不发病——上游调用点显式传的是「显示当前 buffer 的窗口」，且 `--multipage-target-scale` 内部自己再解析一次窗口，所以即便下游拿到 mini window，spec 尺寸仍由正确窗口算出。风险在**将来新增调用点**、或在 minibuffer 上下文里直接调用这些函数时以同样形式复现。
- 建议：不做批量替换（十余处逐一改造的收益低于回归风险，且多数函数在 minibuffer 上下文里本来就不该被调用）。新增调用方一律走 `--multipage--display-window`；某一处出现真机症状时再按单点替换并补 ERT。

## 冻结期间 `--multipage-sync` 仍可能按压缩后的可见范围回收页（2026-10-27，待真机确认）

- 现状：`seshat-reader-freeze-layout-during-minibuffer` 冻结的是几何（`--refit-window` / `--schedule-refit` / `--recenter-window` 的 `--apply-display-scale` 步骤），**不冻结** `--multipage-sync`。同步按当前视口算驻留集，而 minibuffer 展开时视口变矮、页面仍按旧尺寸显示（被窗口裁切），算出的可见页范围随之缩小（range 缩小），可能把「已被裁掉、但仍属于版面」的页移出驻留集。
- 影响：若被回收的页仍被页行引用，表现可能是**页面消失**（行还在、位图没了）而不是「底部被裁切」。理论上位置正确（重新渲染即可恢复），但观感是「展开提示符后底下几页空了」。ERT 覆盖不到（需真实 minibuffer + 真实 redisplay），本轮未真机复现。
- 建议：按计划 L3 第 1 步真机确认——`M-x` 展开期间看页面底部是「被窗口裁切」还是「页行变空」。若出现后者，把 `seshat-reader--layout-frozen-p` 也接进 `--multipage-sync`（或让同步的视口计算沿用冻结时的窗口高度），并在 `--after-minibuffer-exit` 的 refit 里顺带重建驻留集。

## seshat-reader.el 的 with-demoted-errors 缺 FORMAT 参数（Emacs 30+ 旧式用法，2026-10-27 发现）——已修复（2026-10-27）

- 现状：`emacs/seshat-reader/seshat-reader.el:87` 写作 `(with-demoted-errors (require 'seshat-render-core))`。`with-demoted-errors` 的签名是 `(with-demoted-errors FORMAT &rest BODY)`，此处第一个实参 `(require 'seshat-render-core)` 被填进 FORMAT、BODY 为空——属**旧式（无 FORMAT）调用**。本机 Emacs 31.1 实测：该宏内保留了**兼容垫片**（非字符串 FORMAT 会被 push 回 BODY），故该 `require` **仍会执行**；但宏展开时必定发出 `Warning: Missing format argument in ‘with-demoted-errors’`（`macroexpand-1` 与 `batch-byte-compile` 两条路径均命中）。
- 原拟结论（本次记录时的初判）：「该 `require` 实际不执行」——**已被实测证伪**。实测方式：`emacs --batch -Q -L <dir> --eval '(with-demoted-errors (require (quote fake-mod)))'`，随后 `fake-mod-loaded` = `t`，说明 BODY 确实执行。只有当宏定义退回到 Emacs ≤29 的旧实现（`(macroexp-progn body)` 直接展开、body 为空）时，该 `require` 才会被静默跳过。
- 影响：当前**无功能故障**（实测 `(featurep 'seshat-render-core)` = t，模块另由其他路径加载）。实际风险有三：① 每次加载 / 编译都多一条 warning（当前 `make all` 的 warning 基线中属固定项）；② 上游宏内注释明确「这类剩余用法将来会被移除」，一旦移除，该 `require` 才会**真的不执行**，届时干净环境下首次加载就会缺 render-core；③ 加载错误被 demote 成 `*Messages*` 里的一行 `Error: ...`，容易被忽略，掩盖真正的加载失败原因。
- 建议：改为 `(with-demoted-errors "seshat-render-core: %S" (require 'seshat-render-core))`，语义不变且消除该告警；修完跑 L1 + L2 复核 warning 数（计划记 24 → 23，以当日实测为准）。
- 备注：非本次修复引入，属既有问题；发现时机与上下文——L3 加载源码版时 `*Messages*` 里出现该 warning，随后追到 `seshat-reader.el:87`。复现命令：`emacs --batch -Q --eval '(prin1 (macroexpand-1 (quote (with-demoted-errors (require (quote seshat-render-core))))))'`。
- 已解决（2026-10-27）：改为 `(with-demoted-errors "seshat-render-core: %S" (require 'seshat-render-core))`，`require` 语义不变（失败仍被 demote 成 `*Messages*` 一行），并补注释说明「必须给出 FORMAT」。**该 warning 在 `make all` 里出现 4 次**（`seshat-reader.el` 被编译 1 次 + 作为依赖被其余 3 个编译进程加载），故实测基线由 **24 → 20**（不是计划预估的 24 → 23，计划按 1 次计数估算）。验证：`make -C emacs/seshat-reader clean all` EXIT 0、warning **20**（改动前同命令实测 24，逐条 diff 只少这 4 条、零新增）、`make -C emacs/seshat-reader checkdoc` 0 报错、`check-parens` 通过、`make -C emacs/tests ert` **33** 文件 **1266** 例（0 unexpected / 0 skipped）、`make -C emacs/tests check-criteria` PASS。

## 宽页水平滚动（hscroll）在书签恢复时是否保留未验证（2026-10-27）——已验证通过（2026-10-27）

- 现状：`seshat-reader-bookmark-jump` 第 ④ 步用 `(set-window-hscroll nil hscroll)` 恢复横向位置，但尚未真机验证；书签偏移批次计划 `openspec/completed/2026-10-27-reader-bookmark-offset-restore.md` 注意事项 5 明确「若 L3 发现它也不恢复，登记 tech-debt 另议」。
- 影响：宽页（页面宽于窗口）横向滚动到中段后存书签，跳回时可能回到最左侧，属体验缺陷，不影响垂直偏移的正确性。
- 建议：下次阅读宽页文档时顺手验证；若不恢复，另开小计划（可能同样需要「落帧后再设 hscroll」的次序）。
- 已验证（2026-10-27，用户真机）：用户确认书签跳回后位置正确（含横向位置），宽页 `hscroll` 在书签恢复时被保留，本条可关闭。

## 阅读器页间分隔区的渲染高度与名义像素的偏差（2026-10-27；2026-10-29 修正为「约 1 个字符行高/页」并已修 span 计算，保留记录）

- 现状（**2026-10-29 实测修正**）：本条目原记「偏差 ±1–2px」，**实测口径错了**。真实偏差是**约 1 个字符行高/页**：分隔区的规则行是 `(space :align-to (- right 0))` 的 **stretch space**，行高恒为一个 `frame-char-height`、**不吃 face 的 `:height` 相对高度**（上/下空白行是普通文本行，`:height 0.2` 精确生效、实测 4 px 无误差）。因此实际高度恒为「`frame-char-height` + 上下留白」，比名义多 `frame-char-height − thickness`——char-h 20 → **+18 px/页**，char-h 25/35/17 → +25/+33/+15；关掉 `seshat-reader-page-separator` 后偏差归零（0/0，对照组实测）。
- 影响（**已缓解/已修**）：`--multipage-page-span` 是 `--multipage-scroll` 跨页累减距离的唯一依据，修前每跨一页少走一个字符行高、**5 页累计 90 px**（跨页落点累积偏移）。2026-10-29 起 `--multipage-page-gap-pixels` 返回**实测值**（gap 行 + 名义分隔区 + 新增纯函数 `seshat-reader--multipage-separator-extra-pixels` 的补偿），span / `--multipage-page-max-offset` / 跨页累减距离全部按实际布局；独立 GUI 实测 span vs 实测 row→row **0 px**、全文范围 vs Σspan **0 px**、页高三态 0 px。**视觉未变**（分隔行构造与 face 逐字未改，页间距仍是原来那个高度）。
- 建议（**保留记录，勿重复排查**）：① 不要再把本条目当成「±1px 观感问题」重新立项——偏差的量级与来源已确证，且已被 span 修复吸收；② 依赖「名义分隔区高度」的新消费方必须改用 `--multipage-separator-pixels`（名义）而不是 `--multipage-page-gap-pixels`（实测）；③ 残余：`--multipage-page-span` 仍未透传 window（多 frame 且字体不同时取 `selected-window` 的 `frame-char-height`），见本文件「滚动侧 span 未透传窗口」条——那是 ±1–2 px 级残余，与本条的 +18 px 不是同一件事。

（来源计划：`openspec/completed/2026-10-27-reader-page-separator.md` 的「T0 实测结论」与 T1–T3 实测偏差段；修正依据：`openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` 的「T9 分隔区 span 修复（2026-10-29）」）

## 阅读器分隔区选项改动需重排才生效（2026-10-27）

- 现状：`seshat-reader-page-separator` / `-separator-height` / `-separator-thickness` / `-separator-face` 与既有的 `seshat-reader-page-gap-lines` 一样，在**页行插入时**被读取（`seshat-reader--multipage-insert-page` 调用 `seshat-reader--multipage-separator-rows`）。已存在于 buffer 的页行与分隔行不会被重写，本轮**未实现** defcustom `:set` 自动重排。
- 影响：`setq` / `customize-set-variable` 之后当前 buffer 观感不变，需重开文档或触发一次 `seshat-reader--multipage-relayout` 才生效；用户容易误判为「选项无效」。属与 `page-gap-lines` 一致的既有语义，不算回归，已在 docstring 与 `docs/emacs-reader.md` §7 写明。
- 建议：若要消除，给这 5 个选项加 `:set` 回调，在「存在活的阅读 buffer」时调一次 `seshat-reader--multipage-relayout`；但必须先解决两个问题——① customize 逐项 set 会触发多次整本重排（需合并为一次 idle 重排，参照 `--schedule-refit` 的做法）；② 重排过程中不得递归触发自身。属独立任务，不要在修其它问题时顺手加。

（来源计划：`openspec/completed/2026-10-27-reader-page-separator.md` 的「注意事项 4」与 D5。）

## 滚动侧 span 未透传窗口（2026-10-27）

- 现状：`seshat-reader--multipage-page-span` 只有 `(page)`，内部 `--multipage-page-gap-pixels` 不传 window，落到 `selected-window` 的 frame 取 `frame-char-height`；而**渲染侧**已改为按 `--multipage--display-window` 的 frame 烘焙分隔行 `:height`（本轮 code-reviewer 修复 1）。
- 影响：多 frame 且字体不同时，渲染高度与滚动几何可能差 ±1–2px（单 frame 无影响）；属「像素与 buffer 分叉」的最后一条残余路径。
- 建议：给 `--multipage-page-span` 加 `&optional window`，并在 `--multipage-page-max-offset` 与 `--multipage-scroll` 的跨页循环里一路透传；改动面小，但需同步更新测试对 span 的调用。
- 来源：`openspec/completed/2026-10-27-reader-page-separator.md`（归档后路径）。

## 跨页选区的四类残余降级（P2-A，2026-10-27）

- 现状：跨页选区（P2-A）已落地——拖选跨页不再 `user-error`，逐页取文取几何、location 写 `pages:<a>-<b>;rect@<p>:…`。以下四处是**本轮有意保留**的降级，不是缺陷，但也确实不是完整实现：
  1. **跨页选区的 `seshat:` 引用链接降级为纯页锚** `page:<起点页>`（`--current-location` 与 org `:store` 两处写端共用 `--selection-cross-page-p` 判定），并 `message` 提示「跨页选区引用已降级为起点页锚点（第 N 页）」；
  2. **跨页 explain / 翻译的上下文只覆盖起点页**：`translate.el` 的上下文扩展用 `:rect` 单 bbox，而 `:rect` 按 D1 恒为**起点页**的选区 bbox；翻译对象本身仍是 `:text` 全量；
  3. **选区确认时的高亮闪现只落在起点页**：`--flash-selection` 仍只吃 `:rects`（起点页多段）；
  4. **Android 不渲染 `pages:` 形态**（见下一条）。
- 影响：①②③ 只在「跨页选区」这一新场景下可见——单页选区的行为与改造前完全一致；②会让跨页解释的模型输入缺少第二页上下文（用户可能以为模型看得到整段）；③会让用户确认选区时只看到首页闪一下（第二页无反馈，容易以为没选中）。
- 建议：①引用链接若要保真，需先让读端 `--goto-location` / `--description` 支持 `pages:` 并定义「跳到哪一页」（当前哲学是「引用只需可复现落点」，改动前先确认需求）；②给 `translate.el` 的上下文装配加一条「跨页时按 `:page-rects` 逐页扩行」的路径，注意它会放大送模型的字符数（`seshat-reader-translate-context-max-chars` 需同步评估）；③要闪多页，得先让 `--normalize-flash-rects` / `--rect-valid-p` 接受 5 元组（目前只认 4 元组与 `(PAGE X0 Y0 X1 Y1)` 之外的形态各自归一），属批次 3 之后的独立改动。
- 来源：`openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md`（批次 1–4 的「偏差与遗留」小节）、`docs/emacs-reader.md` §5「跨页选区」与 §12 第 9 条。

## Android 不解析 `pages:` 跨页形态（P2-A，2026-10-27）

- 现状：`android/app/src/main/java/com/seshat/app/reader/LocationCodec.kt` 的 `parsePage` 在 `text.split(';').size > 2` 时直接返回 `Parsed.Unknown(location)`（多段 `rect:` 今日同样落这里），`pages:` 前缀也不在 `parse` 的分派表里。Android 端因此对跨页批注**不画高亮**，但**不抛异常、不崩溃**，批注本体（`text`）照常可读。
- 影响：Emacs 产出的跨页批注在 Android 上没有页面高亮（列表里仍能看到该条批注与其正文）；用户若只在 Android 阅读，会觉得「这条批注怎么没有框」。属跨端能力差异，不是数据损坏——服务端按不透明串保存，原样回传给能解析的端。
- 建议：需要时改 `LocationCodec.parsePage`——先按 `pages:` 前缀分派，解析 `a-b` 跨度与逐段 `rect@<page>:`，返回新的 `Parsed.PageRects`（多页矩形）；注意 `Parsed` 是封闭 union（`Unknown` / `Page` / `PageRect` / `Chapter` / `Ink`），新增分支要同时覆盖 `PdfReaderActivity` 与 EPUB 侧的所有 `when` 分支，并补单测（现有 Android 测试对多段 `rect:` 已断言「落 Unknown」，改语义会打红，属预期）。按 2026-10-27 用户确认，本轮（批次 A）**不改 Android**。
- 来源：`docs/api.md` §4.5.3 的兼容表；`LocationCodec.kt:97`、`:107-119`。

## `--page-space-size` 的 frame-scale 标定待真机（P2-A，2026-10-27）——已解决（2026-10-28）

- 现状（修复前）：`seshat-reader-select--page-space-size` 对「页面坐标单位」的假设是 `native × frame-scale`（与 `posn->page` 的 `image_px × frame_scale / page_scale` 对齐，`native` = 已旋转位图尺寸 ÷ 渲染 scale）。为不把单位误差带进几何，`--selection-page-rects` **不直接采信绝对值**，而用**起点页**的 `extent / native` 实测比例做标定（起点页结论与批次 1 逐值一致，其余页按同比例缩放），标定不可用时才退回绝对值。
- 影响（修复前）：真机上 `frame_scale ≠ 1` 或 `page_scale ≠ 渲染 scale` 时，中间页的 `y1`（非末页取该页自身高度）可能偏一个比例因子——表现为跨页高亮在第二页上下略有偏移。默认缩放下比例因子为 1，无影响。
- 处置：**比例标定整段删除**。上面那条公式里的 `page_scale` 被明确为**该页实际显示 scale**——新增纯函数 `seshat-reader-select--display-scale`（该页 spec `:width` ÷ 该页 native 宽；两者同向，spec 与 native 都是按当前 rotate 渲染的位图口径，直接相除、不交换宽高，交换只属于出口为未旋转页面坐标的 `--page-space-size` / `--posn-page-extent` 经 `--unrotate-size` 的那一侧），`posn->page` / `--posn-page-extent` 均按 posn 所在页取分母；`--selection-page-rects` 改为每页直接用自身 `--page-space-size`，不再做「起点页 `extent / native`」标定——分母口径统一后该比例恒为 1，标定已无意义。
- 残余：**`frame_scale ≠ 1` 的端到端真机验收仍未做**，本条降级为 L3 待办（见 `docs/emacs-reader.md` §12 第 1 条 2026-10-28 补充）。单位假设 `native × frame-scale` 本身未改，根治方式（C 侧批量暴露每页未旋转 pt 尺寸）未实施。
- 回归：`seshat-reader-select-cross-page-test--posn->page-divides-by-displayed-scale` / `--cross-page-rects-use-displayed-scale` / `--display-scale-is-measured-on-same-orientation` / `--display-scale-nil-when-spec-sizes-unusable` / `--page-scale-falls-back-when-undisplayable`。
- 来源：`openspec/completed/2026-10-27-reader-multipage-p2a-cross-page-selection.md` 批次 2「偏差 ②（单位口径靠标定）」；`CHANGELOG.md`「修复 → 矩形选区取文被截断（换算分母用错 scale）」；落点 `emacs/seshat-reader/seshat-reader-select.el` 的 `seshat-reader-select--display-scale`（`:790`）、`--page-scale`（`:833`）、`--selection-page-rects`（`:1109`）。

## 矩形查询必须在阅读 buffer 内调用（`prepare_rect_query` 只看 buffer-local 文档指针，P2-A，2026-10-27）

- 现状：`overlayp nil` 真机修复把 `prepare_rect_query`（`--text-in-rect` / `--rects-in-rect` / `--lines-in-rect` 三个入口共用的前半段）改为只依赖 buffer-local 的 `seshat-reader-current-doc-state-ptr`（`get_doc_state_ptr`），不再取窗口 overlay / `EmacsWinState`。
- 影响：**任何在非阅读 buffer 里调用这三个入口的路径都会静默返回 nil**——早退刻意不 `message`（调用方可能在 redisplay 中），所以既不报错也不提示。写新测试或将来新增调用点时若忘了切到阅读 buffer，症状是「一个字符也取不到」而不是异常，比崩溃更难定位（改造前同类错误会以 `overlayp nil` 崩溃暴露，虽也不好但至少可见）。
- 建议：新代码一律在阅读 buffer 上下文调用（`with-current-buffer` 到阅读 buffer，或沿用 `seshat-reader-select-drag` 的「在被拖窗口的 buffer 里执行整段手势」写法）；测试需要负向覆盖时，用显式「无文档指针 → 静默 nil」断言（见回归文件里的 `--no-doc-state-returns-nil`），不要指望它报错。
- 来源：`CHANGELOG.md`「修复 → 拖选抛 `overlayp nil`」；`emacs/seshat-reader/render/render-core.c` 的 `prepare_rect_query`；`emacs/tests/seshat-reader-rect-query-overlay-test.el`。

## `emacs/tests/Makefile` 无 `load-prefer-newer`，改 `.el` 不重编译 `.elc` 会静默跑旧代码（2026-10-27）

- 现状：`emacs/seshat-reader/` 下存在 `seshat-reader.elc`、`seshat-reader-annotation.elc` 等构建产物（`.gitignore` 排除、不入库），而 `emacs/tests/Makefile` 的 ERT 入口只传 `-L`、没有 `(setq load-prefer-newer t)`，`.elc` 可用时即优先加载。于是只改 `.el` 而没重编译 `.elc` 时，ERT 断言的是旧代码——**静默假绿**，构建系统不报任何错。
- 影响：任何改动 `emacs/seshat-reader/*.el` 的批次都必须记得 `make -C emacs/seshat-reader <file>.elc`，否则回归结论不可信。2026-10-27 的 `undo-outer-limit` 修复批次实测踩到：不重编译时新增用例仍失败（加载的是旧 `.elc`），重编译后才转绿。
- 建议：二选一——① 在 `ert` 目标里加 `--eval "(setq load-prefer-newer t)"`（改一处，语义为「源码较新则用源码」）；② 给 `ert` 目标加 `.elc` 依赖（`%.elc: %.el`），由 make 保证同步。①更贴近「测试跑当前源码」的意图，②更接近真实加载路径，两者可并存，建议先做①。
- 来源：`emacs/tests/Makefile`（`TEST_FILES := $(sort $(wildcard …))` 已能自动收集新增测试文件，问题只在 `.elc` 优先级）；本轮修复的执行记录。

## `Makefile` 缺头文件依赖，换 `.h` 后复用旧 `.o`（canvas 迁移 T1 发现）——已解决（2026-10-28）

- 现状（修复前）：`emacs/seshat-reader/Makefile` 只有 `%.o: %.c` 规则，未生成/引用头文件依赖；`render/render-core.h`、`render/emacs-module.h` 等改动后，只要 `.c` 时间戳没变就**不会重编**——表现是「头文件升级已生效、行为却没变」或反向的诡异编译错误。
- 处置：`CFLAGS` 增 `-MMD -MP`、Makefile 末尾 `-include $(OBJS:.o=.d)`、`clean` 一并删 `.d`。实测 `touch render/render-core.h` 后 4 个 `.o` 全部重编（gcc 命令可见），内容不变再跑则「已是最新」。
- 来源：`openspec/completed/2026-10-28-reader-canvas-backend-migration.md`「验证记录 → 批次 T8a」第 ③ 项。

## `emacs/tests/Makefile` 的 `BUILD_ROOT` 硬编码 `build-31.1`——已解决（2026-10-28）

- 现状（修复前）：ERT 夹具把 straight 包目录写死为 `.../straight/build-31.1`，Emacs 升到 32 后所有第三方 `-L` 全部落空，相关用例静默 skip 或加载失败。
- 处置：改为按 `emacs-major-version` / `emacs-minor-version` 推导 `build-<major>.<minor>`，并加「同前缀唯一目录」回退；推导不出唯一目录时直接 `$(error)`，**不静默降级成空 `-L`**（空 `-L` 会让测试跑但结论不可信）。本机解析为 `~/.local/straight/build-32.0.50`，8 个包的 `-L` 全部命中。
- 来源：同上，「验证记录 → 批次 T8a」第 ④ 项。

## `--page-text` 的 0 参路径引入 C→elisp 反向依赖（canvas 迁移 T6/T7，2026-10-28）

- 现状：legacy 渲染路径删除后，C 侧不再持有窗口状态（`EmacsWinState` 已删），而 `seshat-reader-dyn--page-text` 允许省略 `PAGE` 参数。省略时由 C 侧 `current_page_from_elisp` 调用 elisp 函数 `seshat-reader-current-doc-pagenumber`（`env->intern` + `fboundp` 守卫 + `funcall`），把返回的 1-based 页号转成 C 侧 0-based 索引；函数不存在（如 `emacs -Q --batch` 里只 `module-load`）或返回非整数时，回退到 `--load-doc` 记录的页号。
- 影响：① 模块不再「自包含」——C 代码调用了 elisp 层的函数名，改名或改语义会静默降级成「用 load-doc 的页号」而不是报错；② 该回退让「当前页」在无 elisp 环境时与真实视口不一致（batch 场景下可接受，交互场景下 elisp 总是存在）。**不得**在 C 侧缓存该调用的结果（页号随滚动变化）。
- 建议：新增依赖 elisp 符号的 C 路径时，一律走「`fboundp` 守卫 + DocState 兜底」这一既有模式，并在函数注释里写清依赖的符号名；若将来要彻底消除反向依赖，可把 `PAGE` 参数改成必填、由 elisp 侧负责取页号（`--text-in-rect` 一族已有先例：0 参路径不存在，页号总是显式传）。
- 来源：`emacs/seshat-reader/render/render-core.c` 的 `current_page_from_elisp`；迁移计划的 T6/T7 批次记录。

## `.so` 未用 `-fvisibility=hidden`，内部符号仍对外导出（2026-10-28）

- 现状：`seshat-render-core.so` 的编译选项没有 `-fvisibility=hidden`，也没有 `-Wl,--version-script` 或 `-Wl,-Bsymbolic` 之类的收口，实测 `nm -D --defined-only seshat-render-core.so | grep -c ' T \| D \| B '` = **48**，其中只有 **14** 个是 elisp 入口（`seshat-reader-dyn--*` 与 `emacs_module_init`），其余 30 余个是内部 helper 与全局变量。legacy 退役后仍如此（删除的是入口，不是可见性）。
- 影响：① 内部符号进入动态符号表，同名符号在进程内可能与其它动态模块互相干扰（`emacs_module_init` 之外的重名风险）；② 无法靠符号表判断「哪些是本模块的公开 API」，review 时容易误以为内部函数可被 elisp 调用。当前**未观测到**实际冲突。
- 建议：加 `-fvisibility=hidden` 并对 14 个入口显式 `__attribute__((visibility("default")))`（或维护一份 version script）。改动小但需要全量重编 + 重启 Emacs 后跑一遍 L2 与 14 入口冒烟；本轮不做，避免与迁移批次耦合。
- 来源：canvas 迁移收尾盘点（`nm -D` 实测，2026-10-28）。

## `transform-smoothing` 默认未开，放大是最近邻硬边（2026-10-28）

- 现状：本包**不设置** canvas spec 的 `:transform-smoothing` 属性，取 Emacs 默认 `nil` → 放大/缩小都用最近邻。实测（整块像素统计）：放大 2 倍只有 2 色、格子周期 16px 硬边；缩小 0.5x 同样 2 色、四角内容齐全（**不是裁剪**）；显式设 `t` 后放大 6–10 色、缩小 18 色（平滑）。
- 影响：放大阅读（`+` / `W` / 手动缩放）时笔画边缘是阶梯状；这既是「与旧 pbm 后端逐字节一致」的原因，也是部分用户会觉得「不如 PDF 阅读器柔和」的原因。`t` 的代价是每帧重采样（滚动/拖拽时 CPU 上升）。
- 建议：保持 `nil` 为默认（性能优先，且不改变既有观感）；若有用户明确诉求，再做成 defcustom（例如 `seshat-reader-transform-smoothing`）在写 spec 时下发。**不要**按缩放比例自动切换——那会让同一份文档在不同缩放级别下观感不一致。
- 来源：spike「补充验证」第 1 项（像素统计）；`docs/emacs-reader.md`「渲染后端、观感与性能 → 观感开关」。

## 单页渲染比旧后端慢 0.6~1.0 ms（结构性往返，2026-10-28）

- 现状：`--page-image-spec` 中位耗时 **0.589 → 1.22 ms**（scale 1.0）、**1.732 → 2.77 ms**（1.5）、**0.742 → 1.16 ms**（rotate 90），即 **+0.6~1.0 ms/页**。已排除的因素：`-O2`（已加，`-O3` 仅 1.08/2.76/1.07，无实质收益）、逐像素写法（`memset` + 3 字节写 1.51/2.80/1.15、64 位块写 1.22/2.85/1.15）。剩余成本在「3 分量 pixmap → BGRA 中间缓冲 → 逐行 memcpy 进 canvas 缓冲」这条链的**结构性往返**。
- 影响：翻页/首屏渲染各多约 1 ms（相对一次 redisplay 可忽略）；批量预渲染（如一次性 `--page-image-spec` 扫全本）会累积成秒级差距。
- 建议：**本轮明示取舍不做**。若将来要回补，只有一条路——让 MuPDF 直接产出 4 分量（`FZ_DEVICERGB` + alpha / 自建 device）或让 canvas 接受 3 分量缓冲（Emacs 侧不可能），即「渲染端直出 4 分量」；那需要重做 `render_page_to_buffer` 的输出契约与装饰 wash 的通道处理，属独立计划，不应搭在文档批里。
- 来源：迁移计划「验证记录」批次 T2+T3 / T2b / T2c 的耗时对比。

## batch ERT 无法断言 canvas 缓冲内容（2026-10-28，代码审查 minor 7）

- 现状：canvas 后端的像素由 C 侧经 `env->canvas_data` 直写进 Emacs 持有的缓冲，elisp 侧的 spec `:data` 恒为 `nil`，也没有任何 Lisp 层访问器能读出缓冲像素。因此 ERT 里只能断言**形状**（`:type` 为 `canvas`、`:data` 为 nil、`:data-width` / `:data-height` / `:width` / `:height` 为正整数、清缓存后第二次渲染仍 `imagep` 且是新对象、`canvas-refresh` 后 `:type` 稳定），**无法断言缓冲是否真被填充**——模块漏写像素时 spec 形状完全正常，只有画面全黑。`seshat-reader-page-spec-test.el` 的新用例 `--canvas-buffer-fill-regression` 因此明确把「缓冲已填充」留给外部手段，而不是伪造断言。
- 影响的缺口：单测层面抓不到「渲染成功但像素没写进去」这类回归（历史上 T2/T3 阶段是靠 `/tmp/canvas-baseline` 的临时 dump 模块 + 与 PNM 基线逐字节比对发现的）。目前该覆盖只存在于一次性回归脚本里，脚本不在仓库内（`dumpmod.c` 刻意不进仓库，因为要用未导出的 `canvas_data`）。
- 建议：若要把它变成常规回归，需要一条**仓库内**的像素出口，二选一——① 给模块加一个仅在测试构建启用的入口（如 `--debug-canvas-hash`，返回缓冲的 FNV/sha 摘要，不返回整块像素，避免把几 MB 塞进 elisp）；② 让测试在临时目录编译一个小 dump 模块（与 `dumpmod.c` 同构）。①更可控，代价是多一个半公开 API，需在 docstring 里标明「仅测试/诊断用，不保证语义稳定」。本轮不做，因为改动会扩张模块入口面（当前 14 个入口刚在 canvas 迁移中收敛）。
- 来源：`emacs/tests/seshat-reader-page-spec-test.el`（`--canvas-buffer-fill-regression` 的 docstring）、`render/elisp-helpers.c` 的 `data2elisp_canvas`；代码审查 minor 7。

## 阅读器两阶段异步渲染（P2-B）遗留（2026-10-29）

> 来源：`openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md`（T9 真机验收 ①–⑤ 通过、⑥ 双窗口不通过；D8 的两处出口已修）。本节的条目**都不是**本项引入的回归，而是本项暴露或未覆盖的缺口。

### 1. 双窗口独立滚动不成立（P1 L3-⑪ 违反，主缺口）——**已解决（2026-10-29）**

> **状态**：已由 P1 follow-up 落地并归档，见 [`openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`](completed/2026-10-29-reader-multiwindow-independent-scroll.md)（驻留集并集化 + 每窗口同步区间 + 重锚换锚点；真机 6 项全部通过）。下列内容保留为**历史根因记录**，行号已按 2026-10-29 改后实测更新——**优先按函数名 grep**，行号仍会漂移。

- **现象**（用户 2026-10-29 真机回报）：同一文档开两个窗口，滚 A 时 B 跟着动、**且位置看起来「随机」**；B 的页还会变成**背景色**（占位态无像素）且不再恢复。
- **证据**（T9 客观测量量化）：两窗口视口相隔 11 页时，B 的 `window-start` 从 p12 **塌到 p6**，2 条 `--multipage-sync` 只恢复到 p7，需 1 次显式 `goto-page` 才回位。P2-B 修掉的 D8 违规只解释「不恢复」这一半（态 C 整队清空丢掉另一窗口的 pending），**位置塌陷与「随机」感**属布局模型。
- **根因**（2026-10-29 改后实测行号，按函数名 grep 定位）：① `seshat-reader--pages` 是**单 buffer** 的驻留行表（`seshat-reader.el:462`）；② 回收循环遍历整个 buffer、只保留**本窗口**区间（`--multipage-sync-blocking` 回收判据 `:3259`、`--multipage-sync-async` 回收判据 `:3416`，修前是 `(or (< page first) (> page last))`）；③ 回收删行让另一窗口的 `window-start` 随 marker 前移（`--multipage-remove-page` 的 `delete-region` `:2049`）；④ `--ensure-window-layout` 对**非当前窗口**显式 `set-window-start` 并钉到最小驻留页（`:4059`，`set-window-start` 在 `:4102`；旧锚点来源是 `--multipage-window-start-page` `:3954` 的 `first` 兜底）；⑤ 同步区间的早退记账是 **buffer 一份**（修前 `--multipage-last-range`，现已删除，改为 window-parameter `seshat-reader--range-parameter` `:2225` + `--multipage-last-range-for` `:2253` / `--multipage-clear-last-ranges` `:2282`）⇒ 「区间未变即早退」在多窗口下永远错、结果依赖命令顺序 ⇒ 「随机」感；⑥ 居中/贴左决策按**单窗口**宽度写入 buffer 全局文本属性（`--multipage-set-page-centered` `:1760` / `--multipage-page-should-center-p` `:1808`）⇒ 横向症状。
- **影响**：P1 L3-⑪（「双窗口各自滚动正常」）修前**不成立**，用户实际只能单窗口阅读，或接受另一窗口被拖走。**修后**：纵向已达标（同 frame 上下分窗 + 跨 frame 各一轮真机验收通过，30 页交替滚动不塌不跳）；横向（⑥）与预取方向仍是已知限制，见本节 §7、§8。
- **建议方向**：已落地，落点 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md`（T1–T6，含 D1–D6 决策与逐条变异测试）。**不要**在修其它问题时顺手回退这三处（驻留集回收判据 / 窗口级区间记账 / 重锚锚点）——涉及驻留集语义、内存上限与全部几何断言；横向 ⑥ 与预取方向另见 §7 / §8。

### 2. `--multipage-async-overdue-p` 用单一 buffer 时间戳（多窗口粗粒度近似）

- **现象**：超时判据 `--multipage-async-pending-since` 是 **buffer-local 单值**，而队列是「所有窗口的并集」⇒ A 窗口把队列撑久后，B 窗口的下一条命令也会被判「超时」并强制同步。
- **证据**：`seshat-reader.el` 的 `--multipage-async-overdue-p`（`(> (- (float-time) since) timeout)`）+ `--multipage-note-pending-since` 的「队非空且无时间戳才补」语义；T9 D8 批次已把「幸存队项重启计时」做进 `--multipage-clear-synced-pending`，但**起点仍是单值**。
- **影响**：多窗口下强制同步的触发频率高于必要（**性能退化，不会渲染错**）；单窗口无影响。
- **建议方向**：队项级时间戳（`(PAGE . SINCE)`）或按窗口分别记账；若采用前者，`--multipage-pending-remove` / `--multipage-prune-pending` 的队项结构要一并改（当前队项是页号整数），回归面比看起来大。**先做 §1 再谈本项**——两者都动队列结构。

### 3. 并集队列在「窗口长期不可见」时可能长期非空

- **现象**：若某个显示本 buffer 的窗口长期不可见（被 bury 到不可见 frame、或被其它窗口完全遮挡），它的页仍在并集口径里 ⇒ `--multipage-prune-pending` 不会裁掉它 ⇒ 队列长期非空。
- **证据**：T9 D8 修复批次的「发现但未处理的风险」段（计划内明写「本批按任务书要求不自行加新机制」）；`--multipage-all-visible-pages` 只看「哪些窗口显示本 buffer」与它们的 `--multipage-visible-range`，不看窗口/frame 可见性。
- **影响**：每条命令都可能因「超时」走强制同步（**性能退化，不会渲染错**）；单窗口、窗口都可见时无影响。
- **建议方向**：二选一——① 并集口径纳入窗口/frame 可见性（`window-visible-p` + `frame-visible-p`）；② 给队项加登记时间戳、按龄淘汰（与 §2 的队项结构改动可合并）。

### 4. `fit-width` 单页渲染成本高 + 连按缩放无去抖

- **现象**（用户 2026-10-29 真机回报）：`fit-width` 模式卡顿较长（虽已比改造前好）；连按 `+` / `-` 缩放卡顿明显。
- **证据**：T9 主观项 ②（fit-width 卡顿）与 ④（连按缩放卡顿）；缩放路径每次 `clear-cache` + 同步渲染 point 页与相邻页，无 debounce；单页渲染成本随显示面积增长（canvas 后端实测 0.589 → 1.22 ms 只是 scale 1.0 的口径）。
- **影响**：观感问题，不影响正确性；`render-idle-batch` 默认 `2` 是「大页场景单轮 ~100 ms」的取舍点，用户可自行降到 `1`。
- **建议方向**：① 缩放加去抖（参照既有 `--schedule-refit` 的 `--drag-threshold` 范式：连续缩放只保留最后一次，中间帧只做显示层缩放、不重渲染）；② 或给 `fit-width` 单独降 batch。两者都要真机验「缩放后首屏清晰度」不变。

### 5. 跨 frame 双窗口场景无真机覆盖

- **现象**：`--multipage-all-visible-pages` 已改为遍历 `frame-list`（代码审查 ① major 的修复），但只有 **batch 桩用例**（`--all-visible-pages-walks-every-frame`，桩 `frame-list` / `frame-live-p` / `window-list`）证明它遍历每个 frame，**没有真机**两 frame 场景的验收。
- **证据**：该用例的变异测试（改回无参 `window-list` ⇒ 用例转红）证明断言非空，但 batch 无真实 redisplay 与真实多 frame；T9 真机项 ⑥ 只覆盖同 frame 双窗口。
- **影响**：跨 frame 时并集口径的正确性只有代码与单测支撑；若 `frame-list` 在某路径上返回非预期（如 minibuffer-only frame、已死 frame 竞态），队项可能被误裁 ⇒ 另一 frame 的占位页不恢复。
- **建议方向**：GUI 两 frame 真机验收一次（开第二 frame 显示同一 buffer，两 frame 各滚不同页，观察两边的占位页都能补上像素）；后续若做 §1，本项应与 §1 一并验。

### 6. `seshat-reader-sidebar.el:489` 的 `--windows` 与已修 major 同类（docstring 称「全体」实际只答选中 frame）

- **现象**：`seshat-reader-sidebar--windows` 的 docstring 写「返回本包当前的**全体**信息面板窗口」，实现是 `(dolist (win (window-list nil 'nomini)) …)`——无参 `window-list` **只答选中 frame** 的窗口（`seshat-reader-sidebar.el:489`）。
- **证据**：与 P2-B 代码审查 ① major 完全同类（`--multipage-all-visible-pages` 修前也这么写，docstring 却称「walks every frame」）；该 major 的修法是 `frame-list` → `frame-live-p` 过滤 → `window-list FRAME`。
- **影响**：面板窗口在另一个 frame 时，`--windows` 看不到它 ⇒ 依赖它的路径（`--window-for-kind` 判「同 kind 是否已显示」、`seshat-reader-sidebar-toggle-width` 取「最近的」面板、kind 全关）在跨 frame 时会误判：可能重复开面板，或 `C-c w` 找不到面板只提示。**不涉及阅读器渲染正确性**。
- **建议方向**：把实现改成与 `--multipage-all-visible-pages` 同构（`frame-list` → `frame-live-p` → `window-list FRAME`，保持 docstring 的「全体」语义），并补一条桩用例（桩 `frame-list` / `window-list` 按 frame 作答、断言无参调用零次）。**同一轮里检查其它 docstring 写「全体」但实现用无参 `window-list` 的函数**——这类不一致会反复被写出来。

### 7. 横向：居中/贴左按**单窗口**宽度决策，却写进 buffer 全局几何（左右分窗 / 跨 frame 不同宽时一个窗口位置错）

- **现象**：上下分窗（同宽）时两个窗口的页面位置一致；**左右分窗、或两个 frame 宽度不同**时，两个窗口里同一个页面的水平位置/宽度必有一个是错的——看起来像「有一边的页面没对齐 / 宽度不对」，且换窗口重绘也修不好（错的那份是共享的）。
- **证据**：居中决策是 `--multipage-page-should-center-p`（`seshat-reader.el:1808`，按**某个窗口**的宽度算「页面能否完整放下」），结果由 `--multipage-set-page-centered`（`:1760`）写成**每页行的 `display` 文本属性**（`align-to` + spec）——行是 buffer 文本，所有窗口共享；贴左路径同理改的是窗口 hscroll + `line-prefix`。写几何的 5 处入口：`--multipage-sync` 的 refit（`:558` / `:741`）、`--multipage-rerender-page`（`:2369` / `:2389`）、异步补位的 `:3008`、`--refit-window`（`:4436`，`--multipage-refit-page` 调用在 `:4468`）、`--redisplay-all-windows`（`:5484`）。修前 P2-B 的 D8 只统一了**队列**口径，没有触及这族「窗口宽度 → buffer 文本属性」的写入。
- **影响**：**横向**布局正确性（纵向已由 `openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md` 解决）。上下分窗同宽不受影响，因此不影响日常单窗口与上下对照阅读；左右对照（宽页、`width` 模式）时会看到一个窗口的页面宽度/位置不对。
- **建议方向**：把「居中/贴左」从 buffer 级文本属性改为**窗口级**表达——`display` 属性只表达「页宽」（与窗口无关的那部分），水平偏移交给窗口级手段（`window-hscroll` 的 per-page 口径，或 `:align-to` 用窗口相对的表达式而非常量像素）。改造面覆盖 refit / rerender / 异步补位 / `--redisplay-all-windows` 四处，且要与「页间空行、相邻页整栏平移」的既有语义（见 §P2-3 横向滚动整栏平移）一并重估，属独立立项范畴，不建议顺手改。

### 8. 预取方向按窗口（`--multipage-scroll-direction` 仍是 buffer 级）

- **现象**：双窗口交替向相反方向滚动时，预取可能预热**另一侧**的一页——被最后滚动的窗口覆盖方向后，另一个窗口的「下一页」没有被预热，而「上一页」被预热了。
- **证据**：`seshat-reader--multipage-scroll-direction` 是 `defvar-local`（buffer 一份），由 `--multipage-scroll` 每次滚动写回；`--multipage-prefetch`（`:3055`）的边界计算读它。驻留集并集化与「预取边界改用调用窗口 range」（`openspec/completed/2026-10-29-reader-multiwindow-independent-scroll.md` 的 T5）只解决了**边界**，没有解决**方向**。
- **影响**：**不影响正确性**，只影响预取命中率：另一侧一页多渲染一次（canvas 实测 1.16–2.77 ms/页），且被并集回收 + spec 缓存上限双重兜住，内存不会越线。单窗口无影响。
- **建议方向**：方向也改窗口参数（与 `seshat-reader--range-parameter` 同一范式，值同样带 `BUFFER` 校验），`--multipage-prefetch` 的 `WINDOW` 形参已经就位（T5 保留了它）。改造要动像素滚动路径（`--multipage-scroll` 写回点）与全部滚动用例，回归面比看起来大——先量化「预热错侧的实测代价」，再决定是否值得做。

## 书架封面依赖外部命令（Emacs 离线书架，2026-10-29）

- **现象**：`seshat-covers` 的 L1（EPUB 封面）依赖 `unzip`、L2（PDF 首页）依赖 `mutool`。两者都缺失时只能退化到 L3「书名首字占位」——封面区永远只有字，且**没有任何界面提示「装好工具就能有封面」**。
- **影响**：① 环境缺依赖时功能静默降级（这是刻意设计：不报错、不阻塞书架）；② 更麻烦的是**负缓存**：失败时写入 `<uid>.none`，装好 `unzip` / `mutool` 之后这些条目**仍不会重试**，用户会误判「工具装了没用」。唯一出路是 `M-x seshat-covers-clear-cache`（清缓存 + 负缓存）或手动删 `~/.cache/seshat/covers/`。
- **建议方向**：① 书架或 `*Seshat Status*` 里对「封面缺失且 L1/L2 探针不可用」给一行说明（一次性、不刷 echo）；② 负缓存条目记录失败原因（`tool-missing` / `too-big` / `decode-failed`），`seshat-covers-extract` 在 `tool-missing` 且当前探针已可用时自动重试一次——只对「依赖缺失」这一类放宽，其它失败仍按永久负缓存。

## 书架批注数离线不可得（Emacs 离线书架，2026-10-29）

- **现象**：书架「待同步」列只显示本地批注队列里待上传的条数（`seshat-reader-annotation-queue-count` 按 uid 过滤），**不显示服务端该书的批注总数**。
- **影响**：用户看到的「批注」列语义是「还没传上去的」而不是「这本书有多少批注」——与 Android 端的「批注总数」口径不同，容易误读。要显示总数需**逐书**拉取（N 本书 = N 次往返），且离线时无数据源，正是本项刻意不做的事（D5「诚实降级」）。
- **建议方向**：若将来服务端提供**批量**批注计数端点（一次请求返回全库 uid → count），可在 `g` 刷新远端清单时顺带落盘到 `library-cache.eld` 并显示两列（总数 / 待同步）；在此之前保持只显示「待同步 N」，并在文档与列头文案上写明口径。

## 启动汇总的服务端可达性用「上次运行结论」（Emacs 离线书架，2026-10-29）

- **现象**：`seshat-status-summary` 里的「上次同步 2h 前 · 失败」取自状态库 `:runtime` 键（上次同步的时间与结果），**启动时不发任何探测请求**。
- **影响**：「服务端**此刻**是否可达」在启动汇总里不可知——上次同步成功但服务端刚挂，汇总仍显示「成功」；反之刚恢复也仍显示「失败」，直到下一次同步刷新 `:runtime`。这是「启动路径零网络、不拖慢启动」的直接代价（D7）。
- **建议方向**：保持零网络口径，但在文案上明确「上次」二字（已如此）；若确需即时可达性，只在用户**显式**打开 `*Seshat Status*` 详情 buffer 时做一次带超时的轻量探测（`seshat-status` 是交互命令，不属启动路径），并把结果标注为「刚才探测」而非混进启动汇总。

## 封面负缓存永久累积（Emacs 离线书架，2026-10-29）

- **现象**：失败标记 `~/.cache/seshat/covers/<uid>.none` **没有任何自动清理路径**——`seshat-covers-clear-cache` 需手动调用，书架与启动汇总都不会清理它。
- **影响**：书库很大时该目录会持续增长（每本失败一次留一个空文件，几千本 = 几千个 inode）；已删除的书留下的 `<uid>.png` / `<uid>.none` 也不会随书消失。单文件很小，问题在**条目数与陈旧度**，不在体积。
- **建议方向**：将来加一条低成本清理——① 启动汇总或 `g` 刷新后按「当前状态库 uid 集合」求差删除孤儿缓存（O(n) 字符串比较，零网络）；② 或给缓存文件加 atime/mtime 语义做 LRU 上限（如 `seshat-covers-cache-max-entries`，超限删最旧）。②需要读目录 mtime，成本略高，建议先做 ①。

## 书架分页渲染牺牲连续滚动观感（Emacs 离线书架，2026-10-29）

- **现象**：书架一次只显示一页（`seshat-library-page-size` 默认 **30** 条），**没有连续滚动**——浏览大书库要靠 `n` / `p` / `M-<` / `M->` 翻页。
- **影响**：翻页会整屏换内容，跨页比较（「刚才那本在哪」）不方便；过滤 / 排序后页码归零也会跳回第一页。这是 I-OOM（驻留 image ≤ 一页条目数）的**直接代价**：连续滚动意味着同时驻留更多封面 image。
- **建议方向**：`seshat-library-page-size` 可调大（如 200+ 近似「一屏到底」），但内存**线性增长**（每页封面 ≈ 数十 KB 级，实际取决于封面尺寸），且 I-OOM 的上界随之放宽——调整时应在文档里明示这条权衡。真正的连续滚动需要「可视区按需构造 + 离屏立即 flush」的虚拟化机制，属另立项范畴，不建议顺手改。



