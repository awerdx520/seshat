# 技术债

记录已知技术债与待办。

## SQLCipher 降级（M0.4，2026-10-11）
- 现象：系统未安装 libsqlcipher（pkg-config 探测 NOT found），无法使用 CGO 绑定 github.com/mutecomm/go-sqlcipher。
- 现状：DB 层暂用纯 Go 驱动 modernc.org/sqlite（无加密），Open 的 key 参数保留但被忽略并打降级告警。
- 兜底：静态加密依赖磁盘 LUKS；DB 层加密待部署阶段启用。
- 待办：部署时安装 libsqlcipher-dev → 切换 go-sqlcipher → 补「错误 key 打开失败」加密测试。

## LLM 双后端未打通（M6，code-reviewer major #2）
- 现象：internal/llm/local.go 的 LocalNodeClient 直连 Ollama（localhost:11434），与 cmd/llmnode + storage/llmtask 的任务队列轮询是两套互不相干的机制。
- 现状：Router.RouteLocal 走直连，route='local' 的任务只能被 cmd/llmnode 领走，但能力函数未接入队逻辑。
- 待办：明确二选一或打通——同步 Chat 走直连、长任务走队列（需定义「异步取结果」的客户端契约）。

## REST 状态同步缺时间戳冲突检测（M1.4，minor #6）
- 现象：storage/state.go 的 SetProgress/UpdateAnnotation 是纯 UPSERT 后写覆盖，未比较客户端 updated_at 与已存值。
- 现状：计划同步协议声称「后写覆盖 + 时间戳冲突检测」，实现只有后写覆盖。
- 待办：补充乐观冲突检测（比较 updated_at，冲突返回 409）或修正文档。

## 单令牌无角色区分（minor #8）
- 现象：LLM 节点复用同一个 NOTES_AUTH_TOKEN，poll/result 端点无节点身份绑定，任何持令牌方可领取任务并读取 payload（可能含发往 LLM 的敏感笔记片段）。
- 现状：单用户模型下可接受。
- 待办：引入独立节点令牌或角色校验（最小权限）。

## Android 令牌明文存 SharedPreferences（minor #9）
- 现象：gtd/GtdActivity.kt 把 auth_token 存普通 MODE_PRIVATE 文件。
- 待办：改用 Keystore 支持的 EncryptedSharedPreferences。

## elisp 令牌经 curl 命令行传递（minor #10）
- 现象：emacs/notes-sync.el 用 `-u "user:token"` 传递令牌，令牌短暂暴露于进程列表；notes-sync-token/notes-rest-token 以 defcustom 明文存 Emacs 配置。
- 现状：单用户桌面可接受。
- 待办：用 curl --netrc-file 或 --config 传递凭据。

## 部署即明文风险（code-reviewer 安全专项）
- 现象：SQLCipher 降级下，若运维未启用 LUKS，数据库与笔记明文落盘，威胁模型失效。
- 待办：部署文档强制要求 LUKS 启用检查（已部分在 docs/security.md，需在部署清单中设为硬性步骤）。
