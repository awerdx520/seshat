# 安全说明

本文件描述 seshat 服务的安全模型：加密、认证、密钥管理与传输安全。
相关文档：[配置说明](configuration.md)、[架构设计](architecture.md)、
[技术债](../openspec/tech-debt.md)。

## 1. 加密模型

采用**静态加密**（服务端可读明文以支持全文索引），分层实施：

| 层 | 机制 | 状态 |
|---|---|---|
| 磁盘层 | LUKS 全盘/分区加密（云 VPS 数据盘） | 部署时启用 |
| 数据库层 | SQLCipher（`internal/storage`，DB 文件级加密） | `-tags "sqlcipher sqlite_fts5"` 启用（见下） |
| 传输层 | TLS（见第 5 节） | 部署时启用 |

### 1.1 磁盘层（LUKS）

云 VPS 上承载 `data/`（数据库、笔记目录、附件对象库）与 git 版本库的数据盘
使用 LUKS 加密。这是当前**兜底的静态加密手段**：即使 DB 层加密未启用，
磁盘离线数据也不可读。解密密钥在实例启动时解锁，不落盘于实例内部。

### 1.2 数据库层（SQLCipher）

SQLite 数据库文件加密由 `github.com/mutecomm/go-sqlcipher/v4` 提供，
`storage.Open(path, key)` 的 `key` 参数即 `SESHAT_DB_KEY`。该库**自带 SQLCipher
amalgamation**（包内 `sqlite3.c` + tomcrypt 源码），编译只需 CGO + gcc，
**无需系统安装 `libsqlcipher-dev`**。存储层按 build tag 选择驱动：

- **启用加密**：以 `-tags "sqlcipher sqlite_fts5"` 构建（`sqlite_fts5` 为迁移 v4
  创建 FTS5 虚表所需；go-sqlcipher 默认未编入 FTS5，缺该 tag 会在运行期报
  `no such module: fts5`），此时 `key` 经 DSN `_pragma_key` → `PRAGMA key`
  对 DB 文件启用加密。
- **无该 tag**：默认构建使用纯 Go 驱动 `modernc.org/sqlite`（明文），非空 key
  被忽略并告警，作为可部署回退。

- 现状：见 [`openspec/tech-debt.md`](../openspec/tech-debt.md)「SQLCipher 降级（已解决）」。
- 加密构建命令：`CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" ./cmd/...`（需 gcc）。
- 影响：未启用加密构建（或构建环境缺 gcc）时，数据库文件为明文，机密性依赖磁盘
  LUKS 兜底。

### 1.3 边界与限制

- 无端到端加密（E2EE）：服务端持有明文以做索引、同步与 LLM 处理。
- 已解密的数据在服务进程内存中可见；威胁模型为「防止磁盘/备份介质离线泄露」，
  而非「防御已攻陷的服务进程」。
- 附件二进制同样落在加密数据盘；对象库按 SHA256 内容寻址，不含额外加密层。

## 2. 认证

单用户模型：客户端身份由**主令牌**统一承担，本地 LLM 处理节点可选使用独立的
**节点令牌**，两类令牌经 `internal/auth` 的 `NodeMiddleware` 相互隔离。

- **主令牌**（`SESHAT_AUTH_TOKEN`）：面向客户端与通用接口。
  - **REST API**：HTTP `Authorization: Bearer <SESHAT_AUTH_TOKEN>`。
  - **WebDAV**：HTTP Basic 认证，用户名任意，**密码为同一个 `SESHAT_AUTH_TOKEN`**
    （对外标准出口与内部同步通道共用该令牌）。
- **节点令牌**（`SESHAT_NODE_TOKEN`，可选）：本地 LLM 处理节点专用，仅保护节点端点
  （注册 / 轮询 / 回传，最小权限）。`auth.NodeMiddleware` 使两类令牌互不越权——
  主令牌访问节点端点返回 `401`，节点令牌访问普通端点也返回 `401`。
  **未配置节点令牌时，节点端点回退接受主令牌**（向后兼容既有单令牌部署；
  此时隔离失效，生产环境建议显式配置节点令牌）。
- 令牌由环境变量注入（见第 3 节），不落盘、不进 git。
- 缺失或错误的令牌返回 `unauthorized`（见 `internal/logging` 错误码），
  不区分「缺失」与「错误」以免泄露信息。

由于是单用户系统，不存在用户注册/吊销流程；轮换令牌即等于更换唯一凭据
（见第 4 节的密钥生命周期）。

## 3. 密钥管理

### 3.1 密钥清单

| 变量 | 用途 | 生成方式 | 来源 |
|---|---|---|---|
| `SESHAT_DB_KEY` | 存储层数据库密钥（32 字节 hex） | `scripts/gen-secrets.sh` | 脚本生成 |
| `SESHAT_AUTH_TOKEN` | REST Bearer + WebDAV Basic 令牌 | `scripts/gen-secrets.sh` | 脚本生成 |
| `SESHAT_NODE_TOKEN` | 本地 LLM 节点专用令牌（节点端点，最小权限） | `scripts/gen-secrets.sh` | 脚本生成 |
| `SESHAT_LLM_API_KEY` | 云端 LLM API key | 脚本不生成 | LLM 服务商 |

四者均为敏感值，对应结构体字段标记为 `yaml:"-"`，只能通过环境变量注入
（详见 [配置说明](configuration.md)）。

### 3.2 生成

```bash
# 生成到默认路径 ./data/secrets.env（权限 600）
scripts/gen-secrets.sh

# 或指定路径
scripts/gen-secrets.sh /etc/seshat/secrets.env
```

脚本使用 `openssl rand -hex 32` / `openssl rand -base64 32` 生成强随机值，
**不向 stdout 回显任何密钥值**；目标文件已存在时默认拒绝覆盖（`FORCE=1` 可强制），
避免误覆盖导致静态加密数据永久不可恢复。

### 3.3 注入方式

生产环境经 systemd `EnvironmentFile` 注入：

- 单元模板：[`deploy/seshat.service.example`](../deploy/seshat.service.example)
  （`EnvironmentFile=/etc/seshat/secrets.env`，`ExecStart=/usr/local/bin/seshat-server`）。
- 变量模板：[`deploy/seshat.env.example`](../deploy/seshat.env.example)（值为占位符）。
- 部署步骤：`cp deploy/seshat.env.example /etc/seshat/secrets.env` → 填入真实值
  → `chmod 600 && chown root:seshat` → 重启服务。

替代方式：systemd `LoadCredential=`/`credentials` 目录，或在 orchestrator 中挂载
密钥卷；无论哪种方式，密钥值都不得写入单元文件或配置文件。

### 3.4 权限与存放

- 密钥文件权限必须为 `600`，属主为运行服务的专用用户（如 `root:seshat`）。
- 存放位置限定在受保护路径（如 `/etc/seshat/`），不得置于 WebDAV 根目录、
  附件对象库或任何可被 HTTP 读到的目录内。
- 仓库中的 `.gitignore` 排除 `.env`、`.env.*`、`*.env`、`*.key`、`*.pem`、`secrets/`、
  `*.keystore`、`*.jks`、`*.p12`、`*.pfx`；仅 `.example` 后缀的模板可提交，且值必须为占位符。

### 3.5 禁止事项

- 禁止将密钥写入 `config.yaml` 或任何配置文件（同名 YAML 键被忽略）。
- 禁止将密钥文件提交到 git（含临时文件的误提交）。
- 禁止在命令行内联、日志、错误信息或调试输出中回显密钥值。
- 禁止在脚本中用 `${VAR:-default}` 形式探测密钥变量（会把值带进输出）。

上述禁止事项与第 6 节的提交前自动检查相互补充——钩子在本机提交前做兜底拦截，
但受 §6.4 的边界限制，不能替代本节的人工约束。

## 4. 备份与恢复演练

**核心前提**：静态加密下，**丢失密钥 = 数据永久丢失**。数据盘与备份介质即使
完好，缺少 `SESHAT_DB_KEY`（DB 层加密启用后）与磁盘 LUKS 口令也无法解密。

### 4.1 备份对象

1. 密钥文件（`/etc/seshat/secrets.env`）——必须单独、离线备份。
2. 磁盘 LUKS 口令/头部信息——离线保管，建议多份异地。
3. 数据盘备份（数据库、笔记目录、附件对象库、git 版本库）。

密钥备份与数据备份应**分离存放**：仅拿到其中一份都不可用，降低单点泄露风险。

### 4.2 恢复演练步骤

1. **备份**：将 `secrets.env` 复制到离线介质（加密 U 盘/密码管理器），
   记录备份时间与校验和（`sha256sum`，只记录校验和，不记录值）。
2. **模拟丢失**：在测试实例上删除 `/etc/seshat/secrets.env` 与磁盘挂载，
   确认服务无法启动 / 数据不可读（验证加密确实生效）。
3. **恢复**：从离线介质还原 `secrets.env` 到 `/etc/seshat/`，`chmod 600`；
   解锁磁盘、挂载数据盘、启动服务。
4. **验证**：`systemctl start seshat`，确认服务正常启动、可读取既有笔记与数据库
   （若 DB 层加密已启用，错误 key 应打开失败，正确 key 应成功）。
5. **记录**：在 `openspec/completed/` 或运维日志中记录演练日期、结果与改进项。

建议频率：部署时执行一次完整演练；此后每季度或每次密钥/数据盘变更后复演。

### 4.3 密钥轮换

轮换 `SESHAT_AUTH_TOKEN`：生成新令牌 → 更新 `secrets.env` → 重启服务 →
同步更新各客户端。轮换 `SESHAT_DB_KEY`（DB 层加密启用后）需先解密再以新 key
重加密数据库，属于高风险操作，须在备份完成后执行并立即复演恢复流程。

## 5. 传输安全

- 全链路 TLS：对外 WebDAV、REST API、LLM 云端调用均走 HTTPS/TLS 1.2+；
  VPS 前置于反向代理（如 Nginx/Caddy）终止 TLS，证书用 Let's Encrypt 自动续期。
- 服务进程仅在环回地址监听，由反向代理对外，禁止明文端口直接暴露公网。
- 本地 LLM 处理节点：经 VPN 或仅凭节点令牌 + TLS 访问服务端，不暴露明文端口。
- 客户端侧：桌面 Emacs/Android 均校验服务端证书；Basic/Bearer 凭据只在 TLS
  通道内传输，禁止明文 HTTP。
- **基础安全响应头由服务端自己下发**（`internal/api/security.go` 的 `securityHeaders`
  中间件，套在 `handler()` 返回的整棵 mux 外层）：`/api/`（含 200 JSON、401/4xx/5xx
  错误响应）、Web UI 首页、`/static/`、以及 mux 产生的 404/405 **全部**带
  `X-Content-Type-Options: nosniff`、`X-Frame-Options: DENY`、
  `Referrer-Policy: no-referrer`。**CSP 仍只由 Web UI 的 `setWebUISecurityHeaders`
  设置**（取值 `default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'`，
  见 §8.8）——中间件刻意不设 CSP，否则会覆盖含 `script-src 'self'` 的那份、把
  `app.js` 拦掉。`/dav/` 与 `/public/` 由 `internal/webdav` 自己的 server 提供，
  由 §8.8 的 `SandboxContent` 单独加 `nosniff` + `Content-Security-Policy: sandbox`。
- **HSTS 仍由反向代理下发**：TLS 在反代终止，服务端看不到真实 scheme，无法判断该不该
  发 HSTS（内部回环请求明明是明文）。nginx / Caddy 的配置行与「`always` 让 4xx/5xx 也
  带上」的说明见 [部署说明 §7](deploy.md#7-反向代理-https)；部署检查清单第 11 节有对应
  核对项。

## 6. 提交前自动检查

仓库通过 [pre-commit](https://pre-commit.com/) 钩子在本地提交前扫描密钥，
钩子配置见根目录 [`.pre-commit-config.yaml`](../.pre-commit-config.yaml)。

### 6.1 安装（每个克隆执行一次）

**前置依赖**：使用前需已安装 `pre-commit` 与 `gitleaks`。钩子以
`language: system` 调用本机 `gitleaks`；缺失时钩子会 fail-closed 直接阻断提交
（不会静默放行）。

**平台前提**：钩子脚本基于 bash，适用于 Linux / macOS / WSL；Windows 原生
cmd / PowerShell 需通过 Git Bash 或 WSL 运行。

```bash
pre-commit install
```

该命令把钩子写入 `.git/hooks/pre-commit`。`.git/hooks/` 属于本地 git 目录、
**不随仓库分发**，因此每次新克隆后都必须重新执行一次 `pre-commit install`，
否则后续提交不会触发检查。

### 6.2 两道检查

| 钩子 id | 职责 |
|---|---|
| `gitleaks` | 扫描暂存区内容，识别 API key、私钥、令牌等凭证，命中即阻断提交（输出经 `--redact` 打码） |
| `no-secret-files` | 文件名黑名单（keystore / env / 私钥类文件），专门拦截被 `.gitignore` 覆盖、却被 `git add -f` 强制添加的文件 |

### 6.3 手动检查

提交前钩子只作用于**暂存区**：`gitleaks` 钩子的 entry 固定为
`gitleaks git --staged --redact --no-banner`，故 `pre-commit run --all-files`
**不会**对全仓库内容做密钥扫描（该次 `Passed` 仅等价于「暂存区为空」）；它真正
提供的是让 `no-secret-files` 按 **git 已跟踪的全部文件**做文件名检查。
`pre-commit run --all-files` 只作用于已跟踪文件；未跟踪 / 被忽略的文件
（如本机 `android/keystore.properties`）不在其列，这正是该项退出码 0 的原因。

需要内容级检查时，用 gitleaks 独立命令：

```bash
# 全 git 历史：判定「仓库是否曾经泄漏」的权威命令
gitleaks git --log-opts="--all" --redact --no-banner

# 当前工作区全部文件（含未跟踪 / 被 .gitignore 忽略的本地文件）
gitleaks dir . --redact --no-banner
```

实测边界：`gitleaks dir .` 会扫描**未跟踪的本地文件**（例如本机
`android/keystore.properties`，含真实口令、被 `.gitignore` 忽略、从未提交），
其非 0 退出属「本地文件命中」而非 git 泄漏；判定仓库是否泄漏以全历史命令为准。

### 6.4 边界与绕过（如实声明）

- 钩子只覆盖**本机提交**；`git commit --no-verify` 可绕过（见 §6.5，不作为常规手段）。
- 其他克隆者、已安装钩子之前提交的内容、以及历史遗留内容，均不在覆盖范围。
- 远端 CI 兜底**尚未部署**；因此 §3.5 的禁止事项仍是第一责任。

### 6.5 误报处理

- 临时跳过单个钩子：`SKIP=<hook-id> git commit ...`（如 `SKIP=gitleaks git commit -m ...`）。
- 长期放行应调整 `.pre-commit-config.yaml` 中对应钩子的 `exclude`（在本节记录理由与日期）。
- 明确禁止把 `--no-verify` 作为常规手段。
- 已知正则宽化：`no-secret-files` 的 `.env(\..*)?$` 按「路径以 `.env.<后缀>` 结尾」
  判定，比 `.gitignore` 的 `.env.*` 更宽，会连带拦下 `config.env.js` 一类命名。本项目为
  Go / Elisp / Android，无此类命名；未来若引入，需评估调整正则或为其加 `exclude`。

## 7. Android 端令牌存储策略（M9.1）

Android 客户端的访问令牌（等同服务端 `SESHAT_AUTH_TOKEN`）按以下策略处理：

| 项 | 策略 | 理由 |
|---|---|---|
| 落盘 | 只经 `EncryptedSharedPreferences`（MasterKey AES256_GCM，键 AES256_SIV、值 AES256_GCM） | 令牌等同账号口令，不能明文落盘 |
| 加密不可用时 | `SecurePrefs.putSecret()` **拒绝写入并返回 false**；设置页禁用保存、显示常驻告警、提供「重置本地配置」 | 宁可功能不可用，也不能把令牌写成明文 |
| 读取异常（KEK 失效 / 备份恢复 / 密钥损坏） | `getString()` 捕获异常、返回默认值、回调 UI 提示，不崩溃 | 用户必须还能进设置页重置配置 |
| 备份 | `res/xml/backup_rules.xml` 与 `data_extraction_rules.xml` 排除 `seshat_sync_secure.xml` 与 `seshat_sync.xml` | 避免明文令牌随 Auto Backup 上云；避免密文换机后无法解密 |
| 服务端地址 | 仅接受 `https`；拒绝 userinfo、查询参数、锚点；长度上限 2048 | 防止凭据被发往伪装主机或明文传输 |
| UI 暴露 | 令牌**不回填明文**，只显示「已配置 / 未配置」；输入框 `importantForAutofill="no"` + `saveEnabled="false"`；设置页 `FLAG_SECURE`；离开页面清空输入框 | 缩小截屏、Autofill、saved state、View 驻留等旁路 |
| 撤销 | 设置页提供「清除访问令牌」（`SettingsStore.clearAuthToken()`） | 设备外借/丢失时需能回到无凭据状态 |
| 连通性测试（M9.2） | 令牌**只**经 `Authorization` 头发往经 `SettingsValidator` 校验的 https origin（仅 https、拒 userinfo/查询参数/锚点）；结果只回传状态码或固定文案（`令牌包含非法字符` / `仅支持 https 地址`），不把令牌写入日志、Toast 或界面；OkHttp 对敏感头打码，跨 origin 重定向时剥离 `Authorization` | 让用户在保存前自证「地址 + 令牌」可用，同时不扩大令牌的信任边界 |

### 7.1 非机密偏好与备份范围（M9.2）

- 远程目录、主题、正文字号、翻页模式存于独立的 `seshat_app_prefs.xml`（**普通** SharedPreferences）：不含凭据，**不加密**，**参与**系统备份与设备迁移。
- 与之相对，`seshat_sync_secure.xml` / `seshat_sync.xml` 被 `res/xml/backup_rules.xml` 与 `data_extraction_rules.xml` 排除出备份（见上一节）。
- 其余本地数据（`reader_annotations` / `reading_progress` / `pdf_reader`）会随云备份上传：它们**不含凭据**，但包含批注文本、阅读书目与进度，属用户内容隐私。该取舍为「用户自己的 Google 账号内可接受」，若未来需要更严格隔离，应把这些 prefs 一并加入备份排除规则。

## 8. M7 引入的安全边界（2026-10-18）

本节把 M7 修复轮固化的边界集中记录，便于审计与回归时对照（判据以代码为准，此处只做归纳）。
原有章节的编号未变动，本节追加在末尾。

### 8.1 路径边界

**规范化规则**（顺序即实现顺序，任一不通过即拒绝）：

1. 拒绝含 NUL 字节的路径（REST 侧单独检查，避免 `open(2)` 层才报错）；
2. 按 `/` 切段，任一段恰为 `..` → 拒绝（先拒 `..` 再做 `path.Clean`，避免折叠把越界
   段吃掉）；
3. `path.Clean` 折叠（去前导斜杠、合并重复斜杠、消 `.`）；折叠后为空或 `.` → 拒绝
   （文件端点不允许指向根本身）；
4. 逐段拒绝 `.git`（大小写不敏感，兼顾大小写不敏感卷）与任何以 `.` 开头的段
   （隐藏文件/目录）。

**五个入口同口径，规则本体唯一（A 批，2026-10-26）**：规则实现在 `internal/pathguard`
（`CleanRel` / `IsDotName` / `HasDotSegment` + `Options`），下面五个入口都是薄包装——
REST（`internal/api/files.go` 的 `cleanRelPath`）、WebDAV 出口（`internal/webdav/policy.go`
的 `hasDotSegment`，`/dav/` 与 `/public/` 共用同一策略包装）、登记层
（`internal/registry/service.go` 的 `normalizeResourcePath`）、扫描层
（`internal/registry/bootstrap.go` 的 `isDotName` + `SkipDir`）、版本层
（`internal/gitver/version.go` 的 `resolve` / `resolveAny`）。`Options` 的**零值即最严格**
（拒空、拒 `..` 段、拒点段），三个开关只能放宽；WebDAV 出口与 `gitver` 是两处「折叠 `..`
而非拒绝」的显式例外（`AllowParentSegments: true`），语义与历史实现逐字等价（抽取时用 12
个输入逐条比对，输出逐字节一致）。登记可接受集与出口可访问集因此一致——不会出现「磁盘有、
登记表没有」或「API 能写、登记拒绝」的死角。细节见 [架构设计 · 路径安全](architecture.md) 的「路径安全：`internal/pathguard` 单一真源」节。

**根选择**：`?root=` 只能在 `SetRoots` 登记的 tag 中精确匹配（大小写敏感，缺省首根），
未知 tag → `400 invalid_argument`；客户端无法用 tag 或路径拼出配置之外的物理目录。

**写路径双重校验**：`mirrorRepo` 除取根外，还校验 `filepath.Abs(root.Path)` 与
`repo.Root()` 一致——配置漂移时拒绝写入（`500`），避免「写入落到别的根」。错误信息只
带根 tag，不回绝对路径（物理路径属部署细节）。

**`SetRoots` 拒绝空 `Path`**：空 Path 会让 `filepath.Join("", rel)` 退化为进程 CWD，
使「登记根」静默变成「当前工作目录」并越界扫描部署目录。

### 8.2 符号链接策略

| 环节 | 策略 |
|---|---|
| 登记 / 重扫 | 只登记普通文件（`d.Type().IsRegular()`），符号链接、设备、管道一律跳过；`filepath.WalkDir` 本身不跟随目录软链 |
| REST 读（`GET`） | 目标自身是符号链接 → `404 not_found`（读侧不区分「不存在」与「是链接」，避免用状态码差异探测根外文件是否存在） |
| REST 写（`PUT`/`DELETE`） | 目标自身是符号链接 → `400 invalid_argument`（明示非法请求，不写穿链接） |
| 父目录逃逸 | 父目录链解析真实路径后必须仍在根的真实路径内（前缀 + 分隔符校验）→ 否则 `400 invalid_argument` |
| 比较基准 | 根自身先 `EvalSymlinks`（部署侧挂载根常是软链），否则合法路径会被误判为逃逸 |
| 父目录尚不存在 | `realPathLoosely` 逐级向上找最深存在祖先做 `EvalSymlinks`，再拼回未存在的尾段（尾段不含 `..`，不会引入新逃逸） |

### 8.3 条件写

- **原子性**：`gitver.WriteAndCommitIf` 把「读当前 ETag → 比较 → 写文件 → git commit」
  收进同一持锁临界区。条件不成立返回 `ErrBlobMismatch` → `412 etag_mismatch`，且
  **不落盘、不产生提交**；并发两个相同 `If-Match` 的写恰好一个成功。
- **`If-None-Match: *`** 的「已存在」判据是「登记表有存活行 **或** 磁盘文件存在」——两种
  不一致状态（登记有行/磁盘无文件、磁盘有文件/登记无行）都不会被当成可创建。
- **空 ETag 永不匹配**：`If-Match: ""` 不会被当成「当前内容为空」或「无条件写」，而是
  直接 `412`；这堵住了「空 ETag → 下层按空期望值比较 → 退化为无条件覆盖」的降级路径。
- **两个条件头都校验**：`If-Match` 与 `If-None-Match` 同时出现时**不是二选一**——任一前提
  不成立即 `412`。`If-Match` 匹配必然意味着资源存在，故与 `If-None-Match: *` 的组合恒为
  `412`，这正是「两个前提不可同时成立」的正确表达。

### 8.4 资源上限

| 边界 | 取值 | 目的 / 位置 |
|---|---|---|
| PUT 请求体 | 32 MiB（`maxFileBytes`） | 防止单请求把整库内存打满 |
| GET 响应体 | 流式（`http.ServeContent`），ETag 逐块 sha1 | 内存 O(1)，大书文件不整体读入 |
| 单文档引用条数 | 2000（`maxRefsPerDocument`） | 超出按首次出现顺序截断并记日志（写操作仍成功），避免单请求阻塞 DB |
| 目录删除列举上限 | 100000（`deleteListLimit`，包级 `var` 仅供测试覆写） | 一次尽量取全登记行，否则会漏写墓碑；**撞到上限时记 `slog.Warn`**（含 `root` / `prefix` / `limit`），超出部分仍不写墓碑，分批删除待实现（见 §8.7 第 8 条） |
| 清单 / 变更流 `limit` | 夹紧到 `[1, 2000]` | 防止一次拉取无界 |
| 启动登记 `bootstrapTimeout` | 2 分钟 | 超大目录树不至于让进程无限卡在启动 |
| `rescan` 执行时长 | 请求上下文（客户端断开即取消） | 断开的长扫描不会继续跑完 |

### 8.5 错误信息边界

- 响应只含稳定错误码 + 固定中文文案，**不含**底层错误串、SQL、绝对路径与文件内容；
  底层细节只进服务端日志。
- `merge-base` 的 `409` 文案固定为「两个版本无共同祖先」，原始 git 错误仅以 `slog.Warn`
  记录（修复前会把 git 的错误文本透出）。
- `416` 由标准内容服务产生，响应体是 Go 标准库的纯文本（不是本服务的错误 JSON）；它同样
  不携带任何服务端内部信息。
- 根 tag 是唯一允许出现在错误信息里的「配置相关」字段，物理路径始终不出现。
- **已知不一致**（记 `openspec/tech-debt.md`「错误 message 反射客户端可控 path」）：部分端点的
  message 会回显**客户端自己传入的** `path`（如「文件 %s 在版本 %s 中不存在」）。它不泄漏
  服务端信息（回显的是输入而非物理路径），但与「固定中文文案」的措辞不完全一致，且把一个
  可控字符串带进了响应体（换行/控制字符需转义）。

### 8.6 维护端点与令牌模型

- `POST /api/resources/rescan` 挂在 `/api/` 之下，与其它端点共用**主令牌**认证；节点令牌
  不覆盖 `/api/`。它有两层成本护栏：**并发互斥**（`rescanRunning` CAS，抢不到立即 `409
  rescan_in_progress`，不排队）与**频率限制**（距上一次重扫**结束**不足 60 秒 → `429
  rate_limited` + `Retry-After: <秒>`，向上取整且 ≥1）。两者语义刻意分开：`409` 是「另一次
  重扫正在进行中」，`429` 是「上一次已结束但还没过最小间隔」——客户端对前者退避重发、对后者
  按 `Retry-After` 等待。
  - 最小间隔是包级 `var rescanMinInterval = 60 * time.Second`（**不是配置项**，仅测试可临时
    覆写）；`rescanLastAt` 记「上一次重扫**结束**的时刻」，因此并发到达的多个请求看到的是旧
    值 → 只有 1 个抢到 CAS、其余 `409`（正在进行中 ≠ 被限流）。
  - `429` 分支**不抢占互斥锁、不写 `lastAt`**，故重试既不会延长禁用窗口、也无后端成本
    （只有一次时间比较）；失败的重扫同样写 `lastAt`，防止用注定失败的请求刷频。
  - 进程内限流在**单实例部署**下等价于全局限流——`deploy/` 的单元模板与 compose 文件都按
    单实例定位，不做多副本共享限流状态。
- 这意味着**令牌即全权限**：持有主令牌者可以反复触发全量扫描（成本随文件数 × 内容哈希
  增长，现被 60 秒间隔压到每分钟至多一次），也可以读写任何 `mirror` 根、删除目录、发起
  revert。主令牌应按「管理员口令」对待（仅存于服务端与受信客户端、只经 TLS 传输、泄露即
  轮换，见 §3.4、§4.3），不要下发给多用户客户端。

### 8.7 已知残余（明确未解决）

1. ~~**安全响应头只覆盖两个入口**~~ —— **已解决（A 批，2026-10-26）**：安全响应头改为
   套住**全部路由**的统一中间件（`internal/api/security.go` 的 `securityHeaders`，见 §5），
   `/api/` 的 JSON 端点与 401/4xx/5xx 错误响应、mux 的 404/405、Web UI 首页与 `/static/`
   一律带 `nosniff` + `X-Frame-Options: DENY` + `Referrer-Policy: no-referrer`；CSP 仍只
   由 Web UI 的 `setWebUISecurityHeaders` 设置（中间件不设，避免覆盖 `script-src 'self'`）。
   `/dav/` 与 `/public/` 由 `internal/webdav` 的 `SandboxContent` 加 `nosniff` + `CSP:
   sandbox`（§8.8）。**唯一仍留给反代的是 `Strict-Transport-Security`**（理由见 §5：TLS 在
   反代终止）。
2. **Emacs 端 uid 缓存不随服务端重建失效**：服务端重建登记表（DB 重来、切 base-url）后
   uid 变化，客户端缓存的旧 uid 会持续 `404 unknown_uid`，需手动清缓存或等同步失败后重解析。
3. **`registry.Apply` 的读-改-写非原子**：`GetResourceByUID` 在事务之外执行，「查现状 → 写
   登记」之间存在 TOCTOU 窗口（并发写同一路径时可能重复处理或漏写事件）。
4. ~~**`rescan` 可反复触发**~~ —— **已解决（A 批，2026-10-26）**：加 60 秒最小间隔 + `429
   rate_limited` + `Retry-After`（见 §8.6）。**未做**的是审计记录（谁在何时触发了多少次）
   ——仍只有常规 `slog` 日志。
5. ~~**WebDAV 出口未做独立的软链拒绝**~~ —— **已解决（S1，2026-10-18）**：新增
   `internal/webdav/symlink.go` 的 `symlinkGuardFS`，接入 `/dav/` 与 `/public/` 两个出口
   （包装顺序 `webdav.Dir → extWhitelistFS → readOnlyFS → symlinkGuardFS → dotPathFS →
   versionedFS`）。请求路径的父链或目标自身含软链一律拒绝（错误包裹 `os.ErrPermission`，
   故 PROPFIND 遍历时该项被静默跳过，响应仍是 207）。口径比 REST 更严：**不看软链指向根内
   还是根外**，任何软链中间段都拒。裸 `webdav.NewHandler` 入口仍不含守卫，但装配链路
   （`cmd/server/main.go`）不使用它。
6. **符号链接策略的覆盖面**：`DELETE` 目录的子树收敛作用于登记表（不含软链），但「目录内
   存在软链」与「软链指向根外」的组合未被专门测试覆盖。
7. **`/api/files/` 的内联响应没有 `CSP: sandbox`**（A 批记录，**评估后决定不加**）：白名单
   内的 PDF/EPUB/图片按声明类型内联返回，浏览器会以原生解析器渲染**攻击者可控的二进制**
   （一个 PUT 上来的 PDF/EPUB 即可），主风险是解析器漏洞而非同源脚本执行。加
   `CSP: sandbox` 会让 PDF 预览失效（Chrome/Firefox 的内置 PDF 阅读器在 `sandbox` 指令下
   被禁），代价大于收益；缓解手段是「只有白名单扩展名才内联」+ `nosniff`。WebDAV 出口
   相反——那里 Content-Type 由客户端解释、必须内联，故套 `CSP: sandbox`（§8.8）。
8. **目录删除的截断只有服务端日志可见**：撞到 `deleteListLimit`（100000）时记 `slog.Warn`
   （含 `root` / `prefix` / `limit`），但响应体没有「已截断」字段，客户端无法自助发现；
   漏写墓碑的那部分资源会一直保留在客户端本地，直到下一次 `rescan` 把它们按「磁盘上已不
   存在」写墓碑。分批删除留 B 批。

### 8.8 WebDAV 出口的差异（M7 安全复审，2026-10-18）

两个 WebDAV 出口（`/dav/`、`/public/`）与 REST 文件端点**并非等价**。下表逐项如实记录
（判据为 2026-10-18 的代码事实，不以计划代替实现）：

| 能力 | REST `GET/PUT/DELETE /api/files/{path...}` | WebDAV `/dav/`、`/public/` |
|---|---|---|
| 点路径（`.git`、任一 `.` 开头的段） | 拒绝 → `400 invalid_argument` | 拒绝 → `403 Forbidden`（`dotPathFS`）——**已落地** |
| 符号链接（目标自身或中间段） | 目标自身：读 `404` / 写 `400`；中间段：`400`（`physicalPathChecked` + `rejectSymlinkAncestors`，见 §8.2） | 拒绝 → `403 Forbidden`（`symlinkGuardFS`）；**口径更严**：不看软链指向根内还是根外，任何软链中间段都拒；PROPFIND 中该项被静默跳过 ——**已落地** |
| 条件写 `If-Match` / `If-None-Match` | 支持，两者同时出现时**都校验**，且比较与写入在同一临界区（§8.3） | **不支持**：`x/net/webdav` v0.61.0 的 `handlePut` 不解析这两个头，客户端条件写被**静默忽略**（退化为无条件覆盖） |
| 危险扩展名（`.html`/`.svg` 等主动内容） | **白名单内联**（A 批，2026-10-26）：只有 17 项被测为「被动」的扩展名按固定 `Content-Type` 内联（见下），**名单外一律** `application/octet-stream` + `Content-Disposition: attachment`，所有下载加 `nosniff` | 本出口**不做强制下载**（强制 `attachment` 会破坏 Calibre / Obsidian 等按 `Content-Type` 处理文件的客户端），改为给全部响应加 `X-Content-Type-Options: nosniff` + `Content-Security-Policy: sandbox`（`internal/webdav/security.go` 的 `SandboxContent`）：文档进入不透明源、脚本与同源 DOM 访问被禁，`Content-Type` 与字节不变 |
| 写与提交的临界区 | 落盘 + commit + 登记全在 `repo` 锁内 | 库自行落盘，钩子只保护「暂存 + 提交」——锁不对称 |

对应技术债见 `openspec/tech-debt.md`：`WebDAV 出口不支持条件写`、
`WebDAV 写与 REST 写的锁不对称`、`根内软链的部署假设`。

**给客户端实现的结论**：点路径与符号链接守卫在**两个出口都生效**（软链口径 WebDAV 更严），
这部分无需按出口做差异处理。但**需要乐观锁的写入必须走 REST** `PUT /api/files/{path...}`，
或改用 `ETag` + `GET /api/merge-base` 自行检测冲突；WebDAV 出口只适合「最后写入即算数」的
场景（例如把整棵目录当普通网盘挂载）。

**危险扩展名策略：已反转为白名单内联（A 批，2026-10-26）**。`GET /api/files` 的
Content-Type 判定不再用「枚举主动内容黑名单」，而是「**静态白名单内联**」
（`internal/api/files.go` 的 `inlineContentTypes`，17 项，键为小写含点扩展名）：

| 扩展名 | Content-Type | 扩展名 | Content-Type |
|---|---|---|---|
| `.txt` | `text/plain; charset=utf-8` | `.pdf` | `application/pdf` |
| `.md` / `.markdown` | `text/markdown; charset=utf-8` | `.epub` | `application/epub+zip` |
| `.org` | `text/plain; charset=utf-8` | `.png` | `image/png` |
| `.csv` | `text/csv; charset=utf-8` | `.jpg` / `.jpeg` | `image/jpeg` |
| `.json` | `application/json` | `.gif` | `image/gif` |
| `.webp` | `image/webp` | `.bmp` | `image/bmp` |
| `.ico` | `image/vnd.microsoft.icon` | `.tif` / `.tiff` | `image/tiff` |

命中名单 → 按上表的固定值内联（**不查宿主 MIME 数据库**）；**名单外一律**
`Content-Type: application/octet-stream` + `Content-Disposition: attachment;
filename="..."`（文件名取最后一段，引号/反斜杠/控制字符替换为 `_` 以防头注入），并且
**所有**文件下载响应都带 `X-Content-Type-Options: nosniff`。

反转的三个理由：① **默认安全**——新增/未知扩展名（`.shtml`、`.xhtmlz`、`.htc`、任何厂商
扩展名）自动落到强制下载，不再需要「想起来把它加进黑名单」，漏项不再形成 XSS 缝隙；
② **不依赖宿主环境**——静态表使「哪些类型可内联」在任何机器上都是同一答案（旧的
`mime.TypeByExtension` 会读 `/usr/share/mime/globs2` / `/etc/mime.types`，同一文件在不同
MIME 数据库版本下得到不同 `Content-Type`）；③ 安全属性可判定——表里只列「确定被动」的类型。

**行为变更（唯一一项）**：`.org` 的 `Content-Type` 由 `text/org; charset=utf-8`（来自本机
MIME 数据库）改为 `text/plain; charset=utf-8`（静态表）。其余 16 项的取值与客户端既有行为
一致——Emacs 与 Android 的下载/阅读路径都不依赖 `Content-Type`。

**WebDAV 出口不做白名单，而是套 `CSP: sandbox`**（`internal/webdav/security.go` 的
`SandboxContent`，`/dav/` 与 `/public/` 均包装）。原因：该出口的 `Content-Type` 仍由
`x/net/webdav` 按扩展名推断并内联返回，强制 `attachment` 会让 Calibre / Obsidian 等按
`Content-Type` 处理文件的第三方客户端失效；`CSP: sandbox` 只让文档进入**不透明源**并禁掉
脚本与同源 DOM 访问（因此读不到 Web UI 存在 `localStorage` 里的令牌），而 `Content-Type`
与字节内容都不变。**这不是白名单**：能内联的类型仍是「任何扩展名」，只是内联后无法执行
脚本（记入 `openspec/tech-debt.md`）。这关闭了「`PUT` 一个 `.html` 再诱导浏览器导航过去」的
同源脚本执行通道。

Web UI 的首页与 `/static/` 另由 `setWebUISecurityHeaders` 加 `nosniff` +
`X-Frame-Options: DENY` + CSP（`default-src 'self'; script-src 'self'; object-src 'none';
base-uri 'none'`，`internal/api/embed.go`）；`/api/` 的其余响应（JSON 端点与错误响应）自
A 批起也由统一中间件加基础安全头，详见 §5 与 §8.7 第 1 条。

## 9. 客户端防御上限（M12，2026-10-22）

M12 把批注页面高亮下沉到 C 渲染层（`render/render-core.c` 的 `draw_page_thread`）——
高亮不再是 elisp 侧的文本属性，而是在页面位图上绘制的**半透明高亮**矩形——并把服务端
返回的 `location` 直接喂进渲染路径。这条链路的两端都不可信——PDF 文件可来自任何来源，
批注 `location` 则是服务端返回的字符串——因此补了一组**显式上限**，判据以代码为准，
此处只做归纳。

### 9.1 渲染层上限

| 边界 | 取值 | 位置 / 行为 |
|---|---|---|
| 单文档高亮条数 | 100 000（`HIGHLIGHT_MAX_COUNT`） | `--add-highlight` 达上限时静默返回 nil，**不覆盖**已有条目 |
| 单条 `rect` 坐标绝对幅值 | ±1 000 000 点（`HIGHLIGHT_MAX_ABS_COORD`） | `rect_to_page_space` 在 `isfinite` 之后校验四角，超限返回 false、不进高亮表（`--text-in-rect` 与选区取文共用该换算点，同受此限） |
| outline 标题字节数 | 8 192 字节（`OUTLINE_TITLE_MAX`，`render/elisp-helpers.c`） | `outline2plist` 取 `strlen` 后**截断**再构造 Lisp 字符串；按字节截断可能切断多字节序列，`decode-coding-string` 会把不完整序列保留为 raw byte 而非报错 |

### 9.2 客户端解析上限（elisp 侧）

| 边界 | 取值 | 行为 |
|---|---|---|
| `location` 字符串总长 | 64 KB（`seshat-reader-annotation--location-max-length`） | 超长先**截断**再解析（不整条丢弃），避免对不可信响应做无界解析 |
| 单条 `location` 的 `rect:` 段数 | 2 000（`seshat-reader-annotation--rect-max-segments`） | 只解析前 2 000 段，其余忽略（已解析的保留） |

两处上限的目的都是「单条不可信字符串不得把解析/渲染成本放大到无界」：一条
`location` 若含数万段 `rect:`，未设限时会在 elisp 解析与 C 侧逐段 `fz_fill_path`
上同时放大。

### 9.3 已修的真实泄漏（M12，code-reviewer minor-2）

`render/mupdf-helpers.c` 的 `free_doc_pages` 此前**零调用点**——换文档
（`emacs_load_doc`）与关文档（`emacs_close_doc`）都走 `free_doc_state`，而它没有
拆 `DocPage` 数组，于是每次切换文档都**泄漏整份 `DocPage` 数组与每页 mutex**
（连同其已缓存的 display list）。M12 在 `free_doc_state` 开头接入
`free_doc_pages(state)`，位置在 drop MuPDF 对象之前，覆盖 `free_doc_state` 的三个
调用点（换文档、加载失败清理、关文档）。这与本节的「上限」不同——它是**无上限的线性泄漏**，
只是恰好也在 M12 的高亮/render 加固轮里被发现并修掉。

### 9.4 威胁模型（一句话）

上述上限针对**不可信 PDF**（恶意 outline 标题、超大/极其密集的批注矩形）与
**不可信服务端响应**（超长 `location` 字符串），目的是防止 UI 冻结与内存膨胀；
它们不提供任何机密性保证，也不试图防御已经攻陷的服务进程（见 §1.3）。
