# 服务端（Go）技术债 A 批：路径规则单一真源 · 出口安全策略 · rescan 限流

## 当前状态
- 阶段：**Phase 4 完成（已归档）**
- 已确认：方案 ✅（用户 2026-10-26 确认：T1–T4 四项，HSTS 与 WebDAV 出口不在本批）· 计划 ✅（plan-reviewer 复审通过 + 用户确认）
- 审查：**代码审查通过** —— code-reviewer 通过；security-reviewer **有条件通过** → 其 M1（`handleRevert` 路径校验）与 L5 已修；随后 F1–F5 五项审查驱动的修复完成
- 执行状态：**T1–T5 全部完成**（六个 checkbox 均已勾选）
- 文档沉淀：**完成**（`docs/security.md` / `docs/errors.md` / `docs/api.md` / `docs/architecture.md` / `docs/deploy.md` / `CHANGELOG.md` / `openspec/tech-debt.md` / `openspec/decisions.md`）
- 归档：**已归档** → `openspec/completed/2026-10-26-server-techdebt-batch-a.md`

## 目标

把服务端四处「同一不变量多份实现 / 枚举式黑名单 / 只有并发互斥没有频率上限」的边界缺陷收敛为单一真源与统一策略，且不改变任何对外错误码与中文文案。

## 根本问题（第一性原理）

| # | 根本问题 | 事实依据（已读源码核实） |
|---|---|---|
| R1 | 路径安全不变量有五份实现，靠注释「两处必须同步修改」维系 | `internal/api/files.go:570` `cleanRelPath`、`internal/webdav/policy.go:177` `hasDotSegment`、`internal/registry/service.go:427` `normalizeResourcePath`、`internal/registry/bootstrap.go:145` `isDotName`、`internal/gitver/version.go:415/433` `resolve`/`resolveAny` |
| R2 | 出口安全策略是「枚举坏东西」且分散：主动内容用 14 项枚举黑名单（`files.go:805` `activeContentExts`）；安全响应头只覆盖 Web UI 与 `/static/`（`embed.go:56`），`/api/` 全部 JSON 与错误响应零安全头 | 同上两处源码 |
| R3 | 成本型端点只有并发互斥没有频率上限（`rescan.go:61` 仅 `rescanRunning.CompareAndSwap`）；`deleteListLimit=100000`（`files.go:56`）超出即静默截断 | 同上 |

## 假设清单

| # | 假设 | 来源 | 验证方式 |
|---|---|---|---|
| A1 | 新增 `internal/pathguard` 只依赖 stdlib，不造成包循环 | 事实✓（仅需 strings/path/filepath；`gitver` 当前不依赖 `registry`/`api`） | T1 步骤 1 跑 `go list -deps ./internal/gitver` 并肉眼确认无 `seshat/internal/{api,registry,webdav}` |
| A2 | 五处语义差异可用「零值即最严格」的选项参数完整表达 | 事实✓（WebDAV 允许空/挂载根，且其 `hasDotSegment` 用 `path.Clean` **折叠** `..`（`a/../b` → `b` 放行）；gitver 同样折叠 `..` 且额外拒「指向仓库根」） | T1 矩阵用例逐条锁定差异（含「折叠 vs 拒绝」两条分支） |
| A3 | 表驱动不变量测试只能锁到「是否拒绝」这一层，不能锁错误文案 | 假设?（五处错误形态不同：AppError / os.ErrPermission / fmt.Errorf） | T1 用 bool 拒绝矩阵断言，不对错误文本做跨入口比较 |
| A4 | 统一安全头中间件不会打红既有 `server_test.go` / `files_test.go` | 假设?（未逐条核对现有响应头断言） | T2 步骤 1 先跑基线 `go test ./internal/api`，改后逐条比对 |
| A5 | 主动内容反转白名单不影响客户端：白名单内联、名单外强制下载 | 事实✓（Emacs 按需下载与 Android 下载均不依赖 Content-Type；PDF/EPUB/图片/纯文本仍内联） | T3 矩阵用例 |
| A6 | rescan 限流不破坏既有用例（需适配） | 事实✓（已核实 `rescan_test.go` 存在 4 处连续多次 POST 的用例：`TestRescanCreatesThenReportsUnchanged` / `TestRescanTombstonesVanishedFile` / `TestRescanRevivesTombstoneWithSameUID` / `TestRescanSerializesConcurrentRequests`（收尾那次请求）） | T4a 统一在 fixture 内置 `rescanMinInterval = 0` 并 `t.Cleanup` 恢复 |
| A7 | 本批不需运行中的服务即可验收 | 事实✓（全部可用 httptest + 单测；curl 冒烟仅作补充） | L2 全绿即达标 |

## 设计

### D1 `internal/pathguard` 单一真源（T1）

新增包，三个导出符号，**零值选项 = 最严格行为**：

```go
// Options 的零值表示最严格口径：拒绝空路径、拒绝 ".." 段、拒绝点段。
type Options struct {
    AllowEmpty           bool // 允许规范化结果为空（WebDAV 挂载根本身、gitver 的仓库根）
    AllowParentSegments  bool // 允许 ".." 段（仅 gitver：Clean 后折叠到根内，不拒绝）
    AllowDotSegments     bool // 允许 .git 与以 '.' 开头的段（仅 gitver）
}

func CleanRel(rel string, opts Options) (string, error)
func IsDotName(name string) bool          // 单段名字判定（bootstrap WalkDir 用）
func HasDotSegment(rel string) bool       // 整路径判定；内部 CleanRel(Options{AllowEmpty: true, AllowParentSegments: true})——只判点段、".." 折叠到根内（与现状 webdav/policy.go 逐字等价）
```

规则（与现状逐条对齐）：
1. 含 NUL 字节 → 拒绝；
2. 不做 TrimSpace（TrimSpace 由各调用方按现有语义自行处理——**api/registry 侧现在 TrimSpace，gitver 侧不 TrimSpace**，这个差异必须保留）；
3. 反斜杠统一转 `/`（`filepath.ToSlash`）；
4. 若 `!AllowParentSegments`：在**原始分段**上出现任一段 `..` 即拒绝（注意是原始分段，不是 Clean 之后——`a/../b` Clean 后是 `b`，仍须拒绝）。**本条是 `CleanRel` 的默认口径**：`gitver` 与 `HasDotSegment` 显式传 `AllowParentSegments: true`（走折叠），API / 登记层 / bootstrap 用零值（走拒绝）；
5. `clean := strings.TrimPrefix(path.Clean("/"+slashed), "/")`；
6. `clean == "" || clean == "."`：`AllowEmpty` 为真时返回 `""` + nil，否则报错；
7. 若 `!AllowDotSegments`：Clean 后的任一段 `EqualFold(".git")` 或以 `.` 开头 → 拒绝；
8. 返回 clean。

**两条「折叠而非拒绝」的特例必须显式表达，不能靠零值**：① `HasDotSegment` 只判点段，对 `..` 走折叠（`AllowParentSegments: true`），与现状 `webdav/policy.go:hasDotSegment` 的 `path.Clean` 行为逐字等价——**收紧成拒绝会是 WebDAV 出口的行为变更**，本批不做；② `gitver.resolve` 同样折叠（`AllowParentSegments: true`），`../x` → `x`，改签名不改语义。

**五处替换映射**（错误包装留在调用方，文案与错误码一字不改）：

| 位置 | 替换为 |
|---|---|
| `internal/api/files.go` `cleanRelPath` | 保留函数名与签名作为薄包装：`TrimSpace` 后调 `pathguard.CleanRel(v, pathguard.Options{})`，把 pathguard 的 error 按**原文案**包成 `logging.NewAppError(logging.ErrInvalidArgument, ...)`。NUL / `..` / `.git` / 点段四种文案保持现有中文 |
| `internal/registry/service.go` `normalizeResourcePath` | 同上（作为薄包装，保留函数名与签名） |
| `internal/webdav/policy.go` `hasDotSegment` | 函数体改为 `return pathguard.HasDotSegment(name)`；签名不变 |
| `internal/registry/bootstrap.go` `isDotName` | 函数体改为 `return pathguard.IsDotName(name)`；签名不变 |
| `internal/gitver/version.go` `resolve` | 改调 `pathguard.CleanRel(name, pathguard.Options{AllowEmpty: true, AllowParentSegments: true, AllowDotSegments: true})`，随后 `filepath.Join(root, FromSlash(clean))` + 原越界 `filepath.Rel` 兜底。`resolveAny` 的「指向仓库根即拒绝」逻辑原样保留 |

> 保留薄包装而非直接内联调用：调用点与测试大量按这些名字断言/构造，改签名会扩大爆炸半径。薄包装只做「TrimSpace + 错误码包装」，规则本体归 pathguard。

### D2 安全响应头统一中间件（T2）

新增 `internal/api/security.go`：

```go
// securityHeaders 给全部路由补基础安全头。
// 刻意不设 Content-Security-Policy：Web UI 的 CSP 含 script-src 'self'，
// 若由中间件统一设置会覆盖它，导致 Web UI 的脚本被拦。
func securityHeaders(next http.Handler) http.Handler
```

设置：`X-Content-Type-Options: nosniff`、`X-Frame-Options: DENY`、`Referrer-Policy: no-referrer`。
套在 `internal/api/server.go` 的 `handler()` 返回值外层（`return securityHeaders(root)`），使 `/api/`、Web UI、`/static/` 全部覆盖；`/dav/` `/public/` 由 `internal/webdav` 自己的 server 提供，**不在本批范围**。
`embed.go` 的 `setWebUISecurityHeaders` 保留不动（它负责 CSP，中间件不设 CSP，两者不打架；重复设置 nosniff / X-Frame-Options 无害）。
**HSTS 不下发**：当前 TLS 由反向代理终止，服务端看不到真实 scheme，HSTS 交给反代（与既有 `docs/security.md` §5 口径一致）。

### D3 主动内容策略反转为白名单（T3）

`internal/api/files.go`：
- 删除 `activeContentExts` 与 `isActiveContent`；
- 新增 `inlineContentTypes`（白名单，小写含点；类型由 `map[string]struct{}` 变为 `map[string]string`，值为 Content-Type）：`.txt .md .markdown .org .csv .json .pdf .epub .png .jpg .jpeg .gif .webp .bmp .ico .tif .tiff`；
- 新增 `inlineContentType(rel string) (string, bool)`（实现名；原计划写作 `canInline(rel) bool`）；
- `handleGetFile` 判定改为：`inlineContentType` 为假 → `application/octet-stream` + `Content-Disposition: attachment`（沿用现有 `contentDispositionFor`）；为真 → 用静态映射表命中的 Content-Type。
- `contentTypeFor` **已删除**：其职责并入静态表查表；不再调用 `mime.TypeByExtension`，`internal/api/files.go` 的 `mime` import 已移除。

> 实现期修订（2026-10-26）：白名单由「扩展名集合」升级为「扩展名 → Content-Type 静态映射表」，以消除对宿主 MIME 数据库（`/usr/share/mime/globs2`、`/etc/mime.types`）的依赖；代价是 `.org` 的 Content-Type 由 `text/org; charset=utf-8` 收敛为 `text/plain; charset=utf-8`。

WebDAV 出口**不动**（已知缺口，记 tech-debt）：第三方客户端（calibre / Obsidian）按 Content-Type 处理文件，强制 `octet-stream` 会破坏其行为。

### D4 rescan 限流 + 截断可见（T4）

`internal/api`：
- `Server` 增 `rescanLastAt atomic.Int64`（UnixNano，0 = 从未跑）；
- 新增包级 `var rescanMinInterval = 60 * time.Second`（**var 而非常量**：测试可临时覆写）；
- `handleRescan` 顺序：① 校验 registry → ② 读 `now - rescanLastAt < rescanMinInterval` 则返回 `429` + `Retry-After: <向上取整秒数>`（**不抢占 CAS、不写 lastAt**）→ ③ CAS 抢占，失败仍 `409` → ④ 原重扫逻辑 → ⑤ 在 `defer` 中、`rescanRunning.Store(false)` 之前执行 `rescanLastAt.Store(endTime)`。
- **写入时机是本设计的关键**：`rescanLastAt` 记「上一次重扫**结束**的时刻」而非开始时刻。由此：并发多请求到达时 lastAt 仍是旧值 → 全部通过间隔检查 → 1 个抢到 CAS、其余 `409`（语义正确：**正在进行中 ≠ 被限流**）；串行第二次在第一次结束后才看到新 lastAt → `429`。失败路径同样写 lastAt（防止用失败请求刷频）。
- 若 `internal/logging` 无 429 对应错误码，新增 `ErrRateLimited` 并映射到 `http.StatusTooManyRequests`（先 grep `internal/logging/errors.go` 的错误码表与 `internal/api` 的状态码映射，按现有模式加）。
- `internal/api/files.go`：`const deleteListLimit = 100000` → `var deleteListLimit = 100000`（注释写明「仅测试覆写」）；在目录删除的 `List` 返回条数 `== deleteListLimit` 时记一条 `slog.Warn`（含 root、prefix、limit），**分批删除留 B 批**。

### D5 不做什么（本批边界）

- 不做 HSTS 下发，不做 `/dav/` 与 `/public/` 的响应头与 Content-Type 统一；
- 不做 `registry.Apply` 事务化、MOVE 墓碑复活、`deleteListLimit` 分批删除（B 批）；
- 不做 WebDAV `bufferedFS` 统一写路径（C 批，单独立项）；
- 不改任何对外错误码语义与中文文案（429 是**新增**，其余不动）。

## 任务

- [x] T1 新增 `internal/pathguard`（`CleanRel` / `IsDotName` / `HasDotSegment` + `Options`），五处改为调用（薄包装保留原名与签名），新增 `pathguard_test.go` 表驱动拒绝矩阵 ≥20 例。矩阵必须覆盖：`""`、`"/"`、`"."`、`"./"`、`"//a.org"`、`"/a.org"`、`"a//b"`、`"a/../b"`、`".."`、`"../x"`、`"a/b/.."`、`".git/x"`、`"A.GIT/x"`、`".hidden"`、`"a/.git/b"`、`"a\b.org"`（反斜杠）、含 NUL、`"a.org "`（尾空格，验证 gitver 不 TrimSpace 与 api/registry TrimSpace 的差异由调用方承担）、`"a/./b"`、以及 `Options` 三开关的 2×2×2 组合中与差异相关的 4 组。验收：`go test ./internal/pathguard ./internal/api ./internal/registry ./internal/webdav ./internal/gitver` 全绿，且 `grep -rn "hasDotSegment\|isDotName\|cleanRelPath\|normalizeResourcePath" internal/` 显示各自只剩「定义 + 调用」，无第二份规则实现。（依赖：无）
- [x] T2 新增 `internal/api/security.go` 中间件并在 `handler()` 外层套用；新增 `internal/api/security_test.go`：Web UI 首页含 nosniff + X-Frame-Options + 原 CSP；`/static/` 同；`GET /api/roots`（200）含 nosniff + X-Frame-Options；一个 4xx 错误响应（如缺认证的 `/api/roots`）同样含这两个头；断言 `/api/` 响应**不含** CSP（避免与 Web UI 的 CSP 混淆）。验收：`go test ./internal/api` 全绿。（依赖：无）
- [x] T3 `files.go` 删除 `activeContentExts`/`isActiveContent`，新增 `inlineContentTypes`/`inlineContentType`，改 `handleGetFile` 判定；新增用例矩阵（放 `files_test.go` 或新文件）：`.html .htm .xhtml .shtml .ehtml .xht .svg .svgz .xml .xsl .js .mjs .mht .rdf` 全部 `application/octet-stream` + `attachment`（含大小写变体 `.HTML`、`.Svg`）；无扩展名文件同样；`.org .md .txt .pdf .png .jpg` 内联且 Content-Type 正确（`text/plain; charset=utf-8` 等，按静态映射表实际输出断言）。验收：`go test ./internal/api` 全绿。（依赖：无）（实现期将扩展名集合升级为 ext→Content-Type 静态映射表，详见 D3 的修订说明）
- [x] T4a 限流实现：`Server.rescanLastAt atomic.Int64` + 包级 `var rescanMinInterval = 60 * time.Second` + `logging.ErrRateLimited`（429）与 `Retry-After` 头；按 D4 的「结束时写 lastAt」时机实现。**必做三小步**：① 若 `internal/logging/errors.go` 与 `statusForCode` 无 429 映射则按现有模式新增（错误码字面量 `rate_limited`）；② **适配既有用例**——在 `rescan_test.go` 的公共 fixture（`newRescanFixture` 或各用例入口）里置 `rescanMinInterval = 0` 并 `t.Cleanup` 恢复原值，使 `TestRescanCreatesThenReportsUnchanged` / `TestRescanTombstonesVanishedFile` / `TestRescanRevivesTombstoneWithSameUID` / `TestRescanSerializesConcurrentRequests`（8 并发 + 收尾请求）四处连续 POST 不打红；③ **限流行为用独立用例覆盖**（单独 fixture，显式把 `rescanMinInterval` 设为 60s）：首次 200、窗口内第二次 429 且 `Retry-After` ≥ 1、把间隔改 0 后再 200；**并发用例不做断言改写**（8 并发仍应为 1×200 + 7×409，因为 lastAt 只在结束时写）。验收：`go test ./internal/api` 全绿且并发用例断言未被弱化。（依赖：无）
- [x] T4b `deleteListLimit` 由 `const` 改 `var`（注释写「仅测试覆写，生产恒 100000」）+ **抽出纯函数** `truncationReached(returned, limit int) bool` 并在 `handleDeleteFile` 的 `List` 返回处据此打 `slog.Warn`（含 root、prefix、limit；**不改日志基础设施**——`slog` 为包级调用，无可注入点，故只对纯函数断言）。用例必须放在**新文件 `internal/api/files_internal_test.go`（`package api`）**——`files_test.go` 是 `package api_test`，访问不到未导出的 `deleteListLimit`：① 纯函数表驱动（`(0,1)→false`、`(1,1)→true`、`(2,1)→true`、`(100000,100000)→true`）；② 端到端：临时把 `deleteListLimit` 设为 1，删除含 2 个登记行的目录，**只断言仍返回 200 且目录已删（行为不变）**——截断的可观测性由 ① 的纯函数断言承担，端到端不重复断言日志（包级 `slog` 无可注入点，捕获 stderr 会让用例脆弱）。验收：`go test ./internal/api` 全绿。（依赖：T4a）
- [x] T5 文档沉淀与归档：按「## 文档清单」逐项更新；勾销/降级 tech-debt 对应条目；decisions.md 补两条决策（白名单反转、HSTS 不下发）；计划自身勾选完成后移入 `openspec/completed/`。（依赖：T1–T4）

## 文档清单

| 文档 | 需同步内容 |
|---|---|
| `docs/security.md` | ① 安全头覆盖范围改写（不再只有 Web UI：`nosniff` + `X-Frame-Options` + `Referrer-Policy` 覆盖全部路由；CSP 仍只 Web UI；HSTS 仍由反代负责）；② 主动内容策略由「枚举黑名单」改为「白名单内联」，列出白名单扩展名与「名单外一律强制下载」；③ rescan 限流（60s、429、`Retry-After`）；④ 目录删除列举上限的截断后果（仅告警，不自动分批） |
| `docs/api.md` | ① `POST /api/resources/rescan` 新增 429 响应与 `Retry-After` 头；② `GET /api/files/{path...}` 的 Content-Type 判定改为白名单语义（列出白名单）；③ 错误码表加入 `rate_limited`（若新增） |
| `docs/errors.md` | ① 错误码表新增 `rate_limited` → 429（按该文件自述的三步流程：`internal/logging` 常量 → 本文件映射与场景 → `statusForCode`）；② `POST /api/resources/rescan` 的端点错误码清单补 `rate_limited` 与触发条件（距上次重扫结束不足 60s）；③ 客户端动作表补「429 按 `Retry-After` 退避重试，不得立即重发」 |
| `docs/architecture.md` | 新增一节「路径安全单一真源 `internal/pathguard`」：五个入口 → 一个包、`Options` 零值最严格、薄包装保留错误文案 |
| `docs/configuration.md` | 本期**无新增配置项**（`rescanMinInterval` 为内部 var）。若最终决定暴露为配置项，须在此补条目并同步 `config.example.yaml` |
| `CHANGELOG.md` | `### 变更`（主动内容白名单、rescan 限流）+ `### 安全`（安全头覆盖全部路由、主动内容策略反转） |
| `openspec/tech-debt.md` | 勾销/降级 5 条：「路径规范化逻辑在四处重复（实为五处）」→ 已解决；「安全响应头覆盖不全」→ 已解决（除 HSTS）；「`rescan` 无频率限制」→ 已解决；「`deleteListLimit = 100000` 截断」→ 降级为「仅告警，分批删除留 B 批」；「主动内容内联黑名单为枚举式」→ REST 侧已解决、WebDAV 侧仍缺（保留新条目） |
| `openspec/decisions.md` | ① 主动内容策略选「白名单内联」而非「黑名单强制下载」的理由（默认安全、新增 MIME 映射不再形成缝隙）；② HSTS 不下发的理由（TLS 由反代终止） |
| `openspec/active/roadmap.md` | 无里程碑归属，**不改**（本批为技术债，不属 M7–M12） |

## 验证标准

- **L1**：`go build ./...`、`go vet ./...` 均 EXIT 0；`gofmt -l .` 输出为空（含新文件：`internal/pathguard/{pathguard.go,pathguard_test.go}`、`internal/api/{security.go,security_test.go,files_internal_test.go}`、`internal/webdav/{security.go,security_test.go}`）。
- **L2**：`go test ./...` **14 个包全 PASS、0 SKIP**——基线为 13 包 466 例，T1 新增 `internal/pathguard` 后为 14 包；总例数应为 466 + 本批新增例数。逐包核对新增用例确实执行（不能只看 `ok`），并确认 `internal/pathguard` 作为**新包**出现在测试输出中。
- **L3（补充，不阻塞）**：本地启动服务端后 curl 三项——① `curl -i http://127.0.0.1:<port>/api/roots -H "Authorization: Bearer <token>"` 响应含 `X-Content-Type-Options: nosniff`；② `GET /api/files/<某 .html>` 返回 `application/octet-stream` + `attachment`；③ 连续两次 `POST /api/resources/rescan`，第二次 429 且带 `Retry-After`。注意本机 `http_proxy` 已设而 `no_proxy` 未设，curl 必须加 `--noproxy '*'`。
- **任务类型**：本批为 Go 项目，不涉及 elisp MCP 实例；如验证过程需要读取 Emacs 侧内容（本批不需要），才走 `elisp_mcp_set_task`。

## 注意事项

1. **错误文案与错误码一字不改**（429 为新增，属例外）。既有测试大量断言中文文案与 `logging` 错误码，改文案会牵连无关用例。
2. **`gitver.resolve` 的 `..` 语义必须保留「折叠」**：`AllowParentSegments: true`。它现在把 `../x` 折叠成 `x`（注释明写「与 webdav.Dir 相同」），改成拒绝是**行为变更**，会打红 `gitver` 既有用例。
3. **TrimSpace 差异必须留在调用方**：`cleanRelPath` / `normalizeResourcePath` 现在 TrimSpace，`gitver.resolve` 不 TrimSpace。pathguard 不做 TrimSpace，否则两端语义被强行统一。
4. **CSP 不能由中间件设**：Web UI 的 CSP 含 `script-src 'self'`，中间件统一设置会覆盖它并拦掉 `app.js`，Web UI 直接白屏。
5. **安全头用例必须覆盖错误响应路径**：`writeError` 走的是另一条写响应分支，最容易漏（tech-debt 原文就点了「错误响应可被 MIME 嗅探」）。
6. **`deleteListLimit` 改 var 的注释要写清「仅测试覆写，生产恒 100000」**，否则下一个人会以为是配置项。
7. **`activeContentExts` 删除后全仓 grep 必须零残留**（含测试文件里的引用）。
8. **不要动 WebDAV 出口**（`internal/webdav`）：`hasDotSegment` 只做「改为调用 pathguard」的等价替换，不改其 v FS 包装、不加 Content-Type 处理。
9. **注意 `inSubtree` 与 `List` 的关系**：T4b 的截断判定要基于 `List` 返回条数（未按子树收敛前），不是收敛后的 `entries` 长度——收敛会丢条数，永远判不出截断。
10. **不加新依赖**：pathguard 只用 stdlib；`go.mod` 不应变化。
11. **`HasDotSegment` 不得收紧 `..` 语义**：现状 WebDAV 侧用 `path.Clean` 折叠 `..`（`a/../b` 放行），本批只做「换实现入口」的等价替换；若发现自己在写「拒绝 `..`」，说明选项传错了（应为 `AllowParentSegments: true`）。
12. **`rescanLastAt` 在重扫结束时写、不在开始时写**：写在开始时会让并发请求全部变成 429，破坏「正在进行中返回 409」的既有语义，并打红 `TestRescanSerializesConcurrentRequests`。
13. **`package api` 与 `package api_test` 不能混用**：需要访问未导出标识符（`deleteListLimit` / `rescanMinInterval` / `rescanLastAt`）的新用例一律放 `package api` 的内部测试文件；`package api_test` 的用例只能走 HTTP 黑盒。

## 与已确认方案的偏差（请用户留意）

- 方案里 T2 原写「HSTS 由新配置项开关（默认关闭）」，本计划收窄为**不做 HSTS 配置项、HSTS 一律留给反代**。理由：TLS 在反代终止，服务端无论如何都判断不了 scheme，加一个永远「默认关闭」的开关只会增加配置面与文档面。若你要求可配，请在此点上驳回。
- [`docs/deploy.md`](../../docs/deploy.md) §7 新增 nginx / Caddy 的 HSTS 配置行作为兜底（本批文档沉淀的产出，非代码改动）。

## 执行记录（2026-10-26）

### 批次划分

| 批次 | 内容 | 说明 |
|---|---|---|
| 1 | **T1 + T2 并行** | 两者互不依赖（pathguard 是纯新包；安全头中间件只碰 `server.go` 的装配点），并行可把「等编译」的时间叠起来 |
| 2 | **T3 + T4a + T4b** | T4a/T4b 同属 `internal/api` 且 T4b 依赖 T4a 的 fixture 约定，串行做；T3 只碰 `files.go` 的白名单区域，与前两者文件区域不重叠 |
| 3 | **F1–F5** | 双路审查（code-reviewer / security-reviewer）驱动的修复批次 |

### L1 / L2 / L3 实际结果

| 级别 | 命令 | 结果 |
|---|---|---|
| L1 | `go build ./...` / `go vet ./...` / `gofmt -l .` | 前两者 **EXIT 0**；`gofmt -l .` 输出**为空**（含 7 个新文件：`internal/pathguard/{pathguard.go,pathguard_test.go}`、`internal/api/{security.go,security_test.go,files_internal_test.go}`、`internal/webdav/{security.go,security_test.go}`） |
| L2 | `go test ./...` | **14 个包全 PASS**、顶层 **497** 例、含子测试 **698** 例、**0 FAIL / 0 SKIP**；`internal/pathguard` 作为第 14 个包出现在测试输出中（基线 13 包 / 466 例） |
| L3 | 手工冒烟（服务端 + `curl --noproxy '*'`） | ① `/api/roots` 响应含 `X-Content-Type-Options: nosniff`；② `GET /api/files/<某 .html>` 返回 `application/octet-stream` + `attachment`；③ 连续两次 `POST /api/resources/rescan`，第二次 `429` + `Retry-After` |

`go.mod` 未变化（pathguard 只用 stdlib），新增依赖 **0**。

### 两处计划文本错误（执行中核实后被推翻）

1. **`A.GIT/x` 实为放行**：计划 T1 的覆盖矩阵把它当「`.git` 的大小写变体」列在应拒绝一侧，实测**放行**——`A.GIT` 少了前导点，既不是 `.git` 的大小写变体（`EqualFold("A.GIT", ".git")` 为 false），也不以 `.` 开头。用例最终固定为「放行」并写注释说明理由；`.GIT/x`（有前导点）才是大小写变体、判拒绝。
2. **`a/../b` 改动前就已拒绝**：计划把它当作「折叠 vs 拒绝」的分歧样本，但 REST 与登记层侧（`Options` 零值口径）改动**前**就已在**原始分段**上拒 `..`；折叠只发生在 WebDAV 出口与 `gitver`（两者显式传 `AllowParentSegments: true`）。等价性比对因此按「每个入口各自的前后输出」做，而不是按「全局应拒绝」做。

### security-reviewer 的一处误判（核实后被推翻）

- **L2「宿主 MIME 表未读」误判**：审查意见认为「白名单不读宿主 MIME 表」的说法不成立（暗示 `mime.TypeByExtension` 只读内置表）。核实后推翻：Go 的 `mime.TypeByExtension` **优先读** `/usr/share/mime/globs2`（其次 `/etc/mime.types`，最后才回落内置表），因此「不查宿主 MIME 数据库」的说法成立——`.org` 在本机得到 `text/org` 正是宿主库给的，静态表把它固定为 `text/plain` 才有意义。该误判已在本记录与 `docs/security.md` §8.8 中说明。

### 审查驱动的范围扩大

双路审查把范围从「计划内的四项」扩到「含 F1–F5」。**范围扩大本身是审查的价值**：计划里被显式排除的两处（D5 的「不做 WebDAV 出口」「不做 HSTS」）在审查中被判定为「同一风险的最后一个出口」，理由如下：

1. **WebDAV 出口加固（`internal/webdav/security.go` 的 `SandboxContent`）**：计划 D5 原写「不做 `/dav/` 与 `/public/` 的响应头与 Content-Type 统一」。审查指出：REST 侧白名单修好后，「`PUT` 一个 `.html` 再诱导浏览器导航」的同源脚本执行通道**只剩 WebDAV 出口**——两个出口挂同一个服务端 origin，漏一个等于没修。且 `CSP: sandbox` 是零客户端影响的方案（不强制 `attachment`），代价可控，故纳入本批。
2. **`handleRevert` 路径校验**（security-reviewer M1）：`POST /api/revert` 此前只判 `path` 非空，隐藏文件可经 revert 落盘——而「隐藏文件一律不可写」是本仓库的既有硬约束（§8.1），该端点是同一不变量的缺口，属必须修。
3. **`deleteListLimit` 截断的可观测性**（原 T4b 的一部分）：审查把它从「改 `var` 便于测试」推进到「撞上限必须有 warning 日志 + 纯函数判定」，否则「静默截断」这条技术债只改了可见性的一半却看不出来。
4. **`.org` 的 `Content-Type` 变更单独成条**：白名单反转必然改变 `.org` 的取值（`text/org` → `text/plain`），审查要求把它写成显式的行为变更条目而不是埋在「其余不变」里——否则客户端排查「类型怎么变了」时无从下手。

> F1–F5 的具体编号由审查批次给出；上表按**实现事实**归纳为四项范围扩大，若与审查记录编号不一致以审查记录为准。

### 四项残余（完整 11 条见 `openspec/tech-debt.md`）

1. **`/api/files/` 的内联响应（PDF/EPUB/图片）无 `CSP: sandbox`**——评估后**决定不加**（会禁掉浏览器内置 PDF 阅读器，代价大于收益）；主风险是解析器漏洞而非同源脚本执行。
2. **WebDAV 出口加固的装配点无集成断言**——`SandboxContent` 只有中间件单测，`cmd/server/main.go` 的包装链在 `package main` 无可测入口；新增第三个出口不会有测试提醒漏包装。
3. **三处纯折叠未收敛**：`internal/gitver/merge.go:cleanTreePath`、`internal/webdav/symlink.go:cleanRel`、`internal/webdav/versioned.go:blobPath` 仍是 `path.Clean` 折叠，未调 pathguard。
4. **`deleteListLimit` 截断仅服务端日志可见**——响应体无 `Truncated` 字段，客户端无法自助发现；分批删除留 B 批。

另记两条运维相关（同见 tech-debt）：`/api/` 响应无 `Cache-Control`（反代若开 `proxy_cache` 会共享缓存私密内容）；`rescanLastAt` 用墙上时钟（NTP 回拨会延长限流窗口，非漏洞）。

### 收尾

- 文档沉淀 8 处：`docs/security.md`、`docs/errors.md`、`docs/api.md`、`docs/architecture.md`、`docs/deploy.md`、`CHANGELOG.md`、`openspec/tech-debt.md`（勾销/降级 5 条 + 新增 11 条）、`openspec/decisions.md`（3 条决策）。
- 归档：本文件移至 `openspec/completed/2026-10-26-server-techdebt-batch-a.md`。
- 与已确认方案的偏差：HSTS **不做**服务端配置项（见上节）；WebDAV 出口加固**超出原方案**（见「审查驱动的范围扩大」第 1 条）。

### 归档后核对（2026-10-26）

独立二次验证复跑：`gofmt -l .` 空、`go build ./...` / `go vet ./...` EXIT 0、`go test ./...` 14 包顶层 497 / 含子测试 698 例、0 FAIL / 0 SKIP、`go.mod` / `go.sum` 零改动 —— 与前序报告逐字吻合。

据该验证修正三处记录失真：① D3/T3 的符号名（`inlineContentExts`/`canInline`/`contentTypeFor` → `inlineContentTypes`/`inlineContentType`，`contentTypeFor` 已删除）；② 新增 Go 文件数为 7 而非 5；③ 记入 tech-debt：`TestRescanSerializesConcurrentRequests` 的并发断言先天宽松（只断言「∈{200,409} + 至少一个 200」，未断言恰好 1×200 + 7×409）。
