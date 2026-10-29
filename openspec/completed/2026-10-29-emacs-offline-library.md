# Emacs 端离线优先书架（离线清单 + 分页封面列表 + 静默日志）

## 当前状态
- 阶段：Phase 4（Review & Document）· **已完成**
- 已确认：方案 ✅（用户 2026-10-29 确认：范围 C / 提醒口径 A / 封面视图乙 / 不使用 ETAF）；计划 ✅（三轮审查通过后用户确认）
- 执行：6 批次 10 任务全部完成（T1–T4 / T5a / T5b / T6–T9，计划内 checkbox 共 10 项全 `[x]`）；L1 全绿（check-parens + 字节编译 0 warning）；L2 `make -C emacs/tests ert` → **FILES=47 TOTAL=1568 UNEXPECTED=0**；L3 待人工（断网真机）
- 归档：本文件已移至 `openspec/completed/2026-10-29-emacs-offline-library.md`

## 目标
1. **书架零网络可用**：清单主源改为本地状态库（`seshat-state` 的 `:uids` 索引），远端清单降级为可选增强并落盘缓存。
2. **本地管理能力**：行内封面列表、按根分组、关键词过滤、状态过滤、多列排序、进度列、待同步批注列、批量删本地副本、dired 定位。
3. **富展示按离线可获取性分级**：封面三级回退（零网络、惰性、限速）、阅读进度本地侧车、批注只显示待同步条数（不编造总数）。
4. **OOM 有界**：书架分页渲染，同时驻留 image 对象数 ≤ 一页条目数；全库封面/文档解析次数为 0（只解析当前页）。
5. **日志收口**：自动路径（定时器、书架渲染、阅读器打开、批注队列同步）全部静默进 `*Seshat Log*`；启动时一次性汇总提醒。

## 非目标（明确不做）

| 不做 | 理由 |
|---|---|
| 服务端任何改动（清单接口、进度接口、批注总数接口） | 本项是纯客户端离线化；服务端 `position` / `location` 契约不动，避免跨端连带改动 |
| 本地批注缓存（离线展示批注总数） | 逐书拉取是 N 次往返，且离线时无数据源；本轮只显示「待同步条数」（本地队列可数），不编造总数 |
| 全文离线搜索 / 本地索引 | 与书架清单正交，涉及索引格式与增量更新，规模独立 |
| 改造 `seshat-reader-etaf.el`（改用自建 buffer） | 用户明确「不使用 ETAF」是针对**书架视图**；阅读器侧的 ETAF 现状保持不动，避免把 OOM 风险引入阅读路径 |
| 书架用 `tabulated-list-mode` | 行内封面需要按条目控制行高与 `display` 属性，`tabulated-list` 的列格式化无法承载 image 行；代价是排序/过滤必须自写纯函数（可测，见 T5a） |
| 预取非当前页封面 / 后台批量生成全库封面 | 直接违反 I-OOM 与「全库解析次数为 0」；封面只随当前页惰性生成 |

## 事实基线（2026-10-29 实测）

| # | 事实 | 依据（命令 / 读数） |
|---|---|---|
| F1 | 项目层 el 文件共 **155** 处 `(message` + **55** 处 `(display-warning` ≈ 210 处用户可见输出点 | `grep -ro '(message' emacs/*.el emacs/seshat-reader/*.el \| wc -l` → 155；同法 `(display-warning` → 55 |
| F2 | 待改造文件的输出点规模：`seshat-sync.el` **103** 行含 message/warning（其中 43 处 `display-warning`）；`seshat-library.el` **33** 行（5 处 `message` + 8 处 `display-warning`）；`seshat-reading.el` **17** 行（8 处 `message` + 1 处 `display-warning`）；`seshat-sync-cmd.el` **20** 处 `(message`；`seshat-reader/seshat-reader-annotation-queue.el` **8** 处 `(message` | `grep -c 'message\|warning' <file>` 与 `grep -o '(message' <file> \| wc -l` |
| F3 | 仓库**无顶层 Makefile**，也**无 `emacs/Makefile`**；`checkdoc` 目标只存在于 `emacs/seshat-reader/Makefile:186`，并由 `all`（:171）串联 | `grep -n '^[a-zA-Z_.-]*:' emacs/seshat-reader/Makefile` |
| F4 | ERT 入口是 `emacs/tests/Makefile`（`all: ert check-criteria`，:69；逐文件 `emacs --batch -Q … -f ert-run-tests-batch-and-exit`，汇总 `FILES=/TOTAL=/UNEXPECTED=`）；现有测试文件 **42** 个 | `sed -n '65,110p' emacs/tests/Makefile`；`ls emacs/tests/*.el \| wc -l` → 42 |
| F5 | 现有 L2 基线：**42 文件 / 1403 例 / 0 unexpected / 0 skipped**（2026-10-29 实跑） | 同级计划 `openspec/completed/2026-10-28-reader-multipage-p2b-async-render.md` 的「L2 基线」 |
| F6 | 项目层模块现成：`seshat-state.el` / `seshat-library.el` / `seshat-reading.el` / `seshat-sync.el` / `seshat-sync-cmd.el` / `seshat-rest.el` / `seshat-transport.el` / `seshat-conflict.el` / `seshat-merge.el`；批注队列在 vendored 包内 `emacs/seshat-reader/seshat-reader-annotation-queue.el` | `ls emacs/`、`ls emacs/seshat-reader/ \| grep annotation` |
| F7 | `docs/adr/` 现有编号只有 `0005-reader-panel-carrier.md` ⇒ 本计划新增 ADR 取 **0006** | `ls docs/adr/` |

## 假设清单（FP-1）

| # | 假设 | 来源 | 验证方式（何时） |
|---|---|---|---|
| A1 | `seshat-state` 的 `:uids` 索引已覆盖全部已登记 uid（含未下载项），可作为书架主源 | 假设? | T2 枚举后与缓存清单条数对拍；缺项则 D1 合并策略退化为「缓存为主源」并回写计划 |
| A2 | 书架当前清单**只**来自远端 REST（断网即空表），本地状态库未被用于渲染 | 假设? | T5a 动手前读 `seshat-library.el` 数据层确认取数入口；若已有本地路径则收窄 T5a 范围 |
| A3 | 封面 L1/L2 依赖的 `unzip` / `mutool` 在本机可用 | 事实?（未实测） | T4 实现前 `(executable-find "unzip")` / `(executable-find "mutool")` 探针，结果写进「验证记录」 |
| A4 | `create-image` 在 `emacs --batch -Q` 下可安全调用（不依赖图形环境）；只有「把 image 放进 buffer 显示」才需要图形环境 | 事实✓ | T8 用 `cl-letf` 桩 `display-graphic-p` 为恒 t + 对 `seshat-library--make-cover-image` 计数验证 I-OOM；T4/T5b 另测「非图形环境不显示但仍可构造」 |
| A5 | 既有「断言 message」的用例集中在 `seshat-library-test.el` / `seshat-sync-cmd-test.el` | 假设? | T8 改造前 `grep -n 'message' emacs/tests/*.el` 列出全部受影响用例并纳入同一批次 |
| A6 | 阅读器换页有唯一可挂钩的入口（页号变化点），可在其上做 debounce 写侧车 | 假设? | T3 动手前定位 `seshat-reading.el` 换页函数；若存在多个入口则收口到一个内部写入函数 |
| A7 | `seshat-covers` / `seshat-reads` 仅依赖文件系统即可实现，无需 `seshat-rest` | 事实✓（D8 依赖图设计约束） | T4/T3 完成后 `grep -n 'require' emacs/seshat-covers.el emacs/seshat-reads.el` 断言不含 `seshat-rest` |

## 设计

### D1 数据源分层（离线优先）
| 层 | 来源 | 网络 | 提供字段 |
|---|---|---|---|
| 主源 | `seshat-state-entries`（新增公开枚举，读 `:uids`） | 零 | uid / root / path / size / mtime |
| 增强源 | 远端清单缓存 `~/.local/share/seshat/library-cache.eld`（原子写） | 仅显式 `g` 刷新时写 | 远端 size、服务端全集（含本地未登记项） |
| 本地事实 | `file-exists-p` + `file-attributes` | 零 | 已下载 / 未下载 |

- **合并策略**：以状态库为准；缓存项仅在 uid 不在状态库时以「未登记」状态出现（可展示、可删缓存行）。缓存过期不做时间判定——它只是「上次刷新看到的远端」。
- **远端刷新失败**：静默（写日志），继续用缓存；书架永不因网络失败而空表。
- **首次使用前从未同步过**（状态库为空且缓存缺失）：书架**显式提示**「请先运行 `M-x seshat-sync-now` 建立索引」，不显示空表假装书库是空的。

### D2 分页渲染（OOM 有界，核心不变量）
- `seshat-library-page-size`（defcustom，默认 30）：每页条目数。
- 键位：`n` / `p` 翻页、`M-<` / `M->` 首末页、`g` 重算并回第一页。
- **只为当前页条目创建 image**；翻页或 `q` 关闭时对离开页的封面调 `image-flush` 释放。
- **不变量 I-OOM**：任一时刻驻留的 image 对象数 ≤ `seshat-library-page-size`；书架任何操作对「非当前页条目」的封面文件/文档解析次数为 0。
- **构造与显示分层**（关键，否则 OOM 断言无法测）：`seshat-library--make-cover-image` 是**唯一**的 image 构造点（内部才调 `create-image`），它**不受** `display-graphic-p` 约束；`display-graphic-p` 只守卫「把 image 放进 buffer 显示」这一步。非图形环境（含 ERT 批处理）因此表现为「描述了 image 但不显示」，构造计数仍可测——`create-image` 在 `emacs --batch -Q` 下是安全的。

### D3 封面三级回退（零网络、惰性、限速）
- 缓存：`seshat-covers-dir`（默认 `~/.cache/seshat/covers/`），命中文件即用；**负缓存** `<uid>.none` 表示「已尝试且失败」，不再重试。
- L1 EPUB：探针 `(executable-find "unzip")`，从 zip 取 OPF 声明的 cover-image 原始字节落盘。
- L2 PDF：探针 `(executable-find "mutool")`，`mutool draw -r 24 -o <tmp>.png <file> 1` 栅格化首页。
- L3 占位：书名首字 + face（零依赖，永远可用）。
- 生成**串行 + 限速**：idle 队列每次只处理 1 本，单次超时 `seshat-covers-timeout`（计划期默认 10s；**实施期调整为 3s**，理由见 `docs/configuration.md`「书架离线层」）；源图大于 `seshat-covers-max-bytes`（默认 4 MiB）跳过并写负缓存。
- 生成完成只重绘「该书所在行」，不整页重渲染。

### D4 本地阅读进度（离线侧车）
- 新文件 `seshat-reads-file`（默认 `~/.local/share/seshat/reads.eld`），结构 `uid → (:page N :total M :updated TIME)`，原子写（同目录临时文件 + `rename-file`，与 `seshat-state-save` 同惯例）。
- 写入点：`seshat-reading-mode` 的换页（页号变化 debounce 2s）与 `kill-buffer-hook`；**零网络**。
- 显示：`page/total (NN%)`；total 未知时显示 `p.N`；从未读过显示 `-`。
- 服务端 progress 只读展示、**不自动推**（不假设服务端 `position` 字符串格式）。

### D5 批注列降级（诚实）
- 只显示「待同步 N」（`seshat-reader-annotation-queue-count` 按 uid 过滤），N 为 0 显示 `-`。
- **不显示服务端批注总数**：离线无本地批注缓存，逐书发请求会 N 次往返；不编造数据。

### D6 日志收口
- 新增 `emacs/seshat-log.el`：`seshat-log-level`（默认 `info`）、`seshat-log-quiet`（默认 `t`）、`seshat-log`（写 `*Seshat Log*`，ring 上限 2000 行）、`seshat-show-log`、`seshat-log-clear`。
- 改造：`seshat-sync.el`（103 处）、`seshat-sync-cmd.el`、`seshat-library.el`（实测 33 行）、`seshat-reading.el`（实测 17 行）、`seshat-reader-annotation-queue.el` 的**自动路径**全部改走 `seshat-log`。
  - **计数口径**：以 F2 实测为准，动手前复测。
- 保留反馈：**显式交互命令**（`M-x seshat-sync-now`、`u`、`d`、`x`）保留单行 echo 反馈（用户主动操作需要结果）；定时器/打开文档/渲染等自动路径零 echo 输出。

### D7 启动汇总（一次提醒）
- 新增 `emacs/seshat-status.el`：`seshat-status-startup-notify`（默认 `t`）、`seshat-status-startup-delay`（默认 2s，挂 `emacs-startup-hook`）、`seshat-status-summary`（纯函数）、`seshat-status-notify`（一行 message）、`seshat-status`（`*Seshat Status*` 详情 buffer）。
- 汇总内容：书库 N 本（本地已下载 M）、待同步 笔记 X / 批注 Y、上次同步时间与结果、状态库是否损坏、从未同步提示。
- **零网络**：服务端可达性用「上次运行结论」（状态库新增 `:runtime` 键：上次同步时间/结果），不在启动时探测。
- 示例行：`Seshat: 书库 128 本（本地 37）· 待同步 笔记 2 / 批注 5 · 上次同步 2h 前失败 · M-x seshat-show-log 查看`

### D8 依赖方向与不变量
```
seshat-log（零依赖）
seshat-state ← seshat-rest ← seshat-transport ← seshat-sync ← seshat-conflict
seshat-reads / seshat-covers（纯本地文件系统，禁止 require seshat-rest）
seshat-library（书架 UI：依赖 state / reads / covers / log / **rest / sync**，软依赖 seshat-reading）
seshat-status（启动汇总：依赖 state/reads/queue/log，禁止 require seshat-rest）
```
- `seshat-reader/**` 仍**不得**反向 require 上述任何项目层模块（vendored 包边界不变）。
- `seshat-library` 对 `rest` / `sync` 的依赖只用于三处：`RET` 取书、`u` 强制重下、`g` 远端刷新；以及落盘路径校验 `seshat-sync--local-path`。**翻页 / 过滤 / 排序 / 删本地副本 / 批量删 / 打开已下载书**这些纯本地路径不得触碰 `rest` / `sync`（I-NONET 只约束这些路径，不是「整个模块零 require」）。
- 继承既有不变量：`ondemand` 根只读（书架不发写请求）、所有落盘路径过 `seshat-sync--local-path`、`mirror` 根拒绝删/覆盖（`seshat-library--ondemand-root-p` 门）。

### D9 离线不可用清单（诚实边界）
翻译/解释（LLM 云端）、远端清单刷新、`seshat-library-add` 入库上传、`seshat-reading-refresh`、批注列表拉取。这些保持原行为，失败静默进日志，不阻塞任何本地功能。

## 风险与回退

| # | 风险 | 缓解 | 回退开关 |
|---|---|---|---|
| R1 | 状态库与远端清单不一致（本地缺项）⇒ 书架「少书」 | D1 合并策略让缓存项以「未登记」出现；`g` 可显式刷新 | `seshat-library-source` 式开关不引入；直接删 `library-cache.eld` 即回到「只用状态库」 |
| R2 | 封面生成把外部命令卡住（大 PDF） | 串行 idle 队列 + `seshat-covers-timeout` + `seshat-covers-max-bytes` 双重上限 | 删 `seshat-covers-dir` 目录 + 写负缓存；`seshat-covers-max-bytes` 设 0 即全占位 |
| R3 | 静默化让故障不可见 | 启动汇总（D7）+ `*Seshat Log*` + `M-x seshat-show-log`；显式命令仍回显 | `seshat-log-quiet` 设 nil 恢复 echo |
| R4 | 分页牺牲连续滚动观感 | `seshat-library-page-size` 可调大（内存线性增长，明示代价） | 调到 200+ 近似「一屏到底」，但 I-OOM 上限随之放宽 |
| R5 | 既有测试断言 message 被静默化打破 | 同一批次改断言（T8），不是回归 | — |
| R6 | 封面负缓存（`<uid>.none`）永久累积，换封面后仍不重试 | 负缓存只在「明确失败」时写；`seshat-log-clear` 之外提供 `M-x seshat-covers-clear-cache` | 手动删 `~/.cache/seshat/covers/` |
| R7 | `image-flush` 影响同 image 的其它窗口（多 frame 同开书架） | 书架 buffer 名唯一（`*Seshat Library*`），同一时刻只有一个实例；关闭时统一 flush | `q` 关闭后重开即重建 |
| R8 | 状态库与缓存**双空**（首次使用 / 状态库损坏） | D1 已定：显式提示「先运行 `M-x seshat-sync-now`」；D7 汇总区分「从未同步」与「状态库损坏」两个分支 | 跑一次同步即恢复 |
| R9 | 重写 `seshat-library.el` 对既有 `seshat-library-test.el` 的回归面比「断言 message」更广（数据结构、键位、渲染路径全变） | T8 把该测试文件按新结构整体重写而非逐条修补，并在计划「验证记录」记录旧用例的去留 | 保留旧文件为 `seshat-library-legacy-test.el.bak` 不纳入编译，供对照 |

## 执行批次

| 批次 | 任务 | 说明 |
|---|---|---|
| 1 | T1、T2 | 地基（日志层 + 状态库枚举），互不依赖，可并行 |
| 2 | T3、T4 | 本地数据源（进度侧车 + 封面），互不依赖，可并行 |
| 3 | T5a | 书架数据层与纯函数（依赖批次 1） |
| 4 | T5b | 书架视图与交互（依赖批次 3 与批次 2） |
| 5 | T6、T7 | 启动汇总 + 静默化（互不依赖，T7 依赖 T1/T2） |
| 6 | T8、T9 | 测试收口 + 文档沉淀 |

## 任务

- [x] T1 日志收口层（`emacs/seshat-log.el`）
  - 新增 defcustom `seshat-log-level` / `seshat-log-quiet` / `seshat-log-max-lines`；函数 `seshat-log`（LEVEL FORMAT ARGS）、`seshat-show-log`、`seshat-log-clear`。
  - 验收：单测 ≥8 例——quiet 为 t 时不进 echo area 但进 buffer；level 为 warn 时仍 message；buffer 行数上限裁剪；buffer 未创建时可调用；`seshat-show-log` 幂等复用 buffer。（依赖：无）

- [x] T2 状态库公开枚举 + 上次运行记录（`emacs/seshat-state.el`）
  - 新增 `seshat-state-entries`（返回 `(uid . entry)`，可选参数决定是否含墓碑/孤儿）、`seshat-state-runtime` / `seshat-state-set-runtime`（`:runtime` 键，写同步时间与结果）。
  - `seshat-state--normalize` 需兼容旧文件（无 `:runtime` 时补 nil），不得破坏既有格式。
  - **前置验证 A1**（动手第一步）：用 `seshat-state-entries` 枚举条数与 `library-cache.eld` 中的远端条数对拍；若状态库缺项（例如从未同步过、或 ondemand 根未登记），把结论写入计划「验证记录」并据此调整 D1 合并策略（缓存升为主源或追加提示）。**未做这一步不算完成 T2**。
  - 验收：单测——枚举顺序与 `:uids` 一致、墓碑/孤儿过滤、旧文件加载后 `:runtime` 为 nil、runtime 往返、`seshat-state-version` 不变。（依赖：无）

- [x] T3 本地阅读进度侧车（`emacs/seshat-reads.el`）
  - `seshat-reads-file` / `seshat-reads-get` / `seshat-reads-record` / `seshat-reads-percent`（纯函数）/ `seshat-reads-clear`；原子写；坏文件降级为空（不抛错）。
  - 接入 `emacs/seshat-reading.el`：页号变化 debounce 2s 与 `kill-buffer-hook` 写入，零网络。
  - **前置验证 A6**：定位 `seshat-reading.el` 中所有会改变当前页号的入口；若存在多个入口，收口到单一内部写入函数（建议名 `seshat-reads--note-current-page`），所有入口只调它。把入口清单写入「验证记录」。
  - 验收：单测 ≥10 例——记录/读回、百分比边界（total 为 nil / 0 / page>total）、原子写不残留临时文件、坏文件降级、重复记录幂等。（依赖：T1）

- [x] T4 封面三级回退（`emacs/seshat-covers.el`）
  - `seshat-covers-dir` / `seshat-covers-timeout` / `seshat-covers-max-bytes` / `seshat-covers-path`（uid → 缓存路径）/ `seshat-covers-extract`（三级回退）/ 负缓存 `<uid>.none` / 串行 idle 队列（每次 1 本）。
  - 验收：单测 ≥12 例——路径派生、命中缓存不发子进程、负缓存不重试、unzip 缺失降级到 mutool、mutool 缺失降级到占位、源图超限跳过并写负缓存、子进程失败不抛错、`display-graphic-p` 为 nil 时**不显示** image（降级占位）但仍可构造描述符（构造计数可测，见 A4）。（依赖：T1）
  - **测试隔离外部命令**（必做）：所有用例内用 `cl-letf` 桩掉 `executable-find`（按用例返回路径或 nil）与子进程调用（`process-file` / `call-process`），**不得**依赖本机是否安装 `unzip` / `mutool`；「L1 缺失 → 降级 L2」「L2 缺失 → 降级 L3」「两者都缺失 → 占位 + 负缓存」三条分支各须至少一例真实触发。

- [x] T5a 书架数据层与纯函数（`emacs/seshat-library.el` 数据层部分）
  - **前置验证 A2**：先确认现有 `seshat-library.el` 的数据层取数入口（`--collect` / `--remote-entries`）是否已存在任何本地渲染路径；若已存在则收窄 T5a 范围并回写计划，**不得**凭假设重写。
  - 实现：`--entries-local`（`seshat-state-entries` 枚举，零网络）、`--entries-cached`（读 `library-cache.eld`，坏文件降级为空）、`--entries-merge`（D1 合并策略）、`--entries-refresh-remote`（显式刷新，写缓存，失败静默走 `seshat-log`）、过滤纯函数 `--filter-items`、排序纯函数 `--sort-items`（书名/根/大小/进度/最近）、分页计算纯函数 `--page-count` / `--page-slice`。
  - 验收 ≥14 例：条目构造（uid/root/path/size/进度/待同步/状态六字段）、合并策略（缓存项仅在状态库缺失时出现、同 uid 以状态库为准）、过滤（关键词大小写不敏感、状态过滤三态、过滤后页码重置）、排序（四键稳定排序、nil 值排尾）、分页边界（首页/末页/空结果/页码越界夹紧）、缓存坏文件降级、**零网络断言**（见 T8）。（依赖：T1、T2）

- [x] T5b 书架视图与交互（`emacs/seshat-library.el` 视图层）
  - 实现：自建 buffer（`special-mode` 派生，**非** tabulated-list、**非** ETAF）：每条目一行 = 封面 image（经 `seshat-library--make-cover-image` 构造，`display` 属性显示，固定像素高）+ 书名 + 根 + 大小 + 进度 + 待同步 + 状态徽章；分页渲染（D2）；行首文本属性承载 uid 供命令定位；**15 个键位**（`RET` 打开 / `u` 刷新本地副本 / `d` 删本地 / `x` 批量删 / `m` 标记 / `D` dired 定位 / `n` 下一页 / `p` 上一页 / `M-<` 首页 / `M->` 末页 / `g` 刷新远端 / `/` 关键词过滤 / `F` 状态过滤（三态循环）/ `s` 排序循环 / `q` 关闭）。`/` 与 `F` 是**两个不同维度**的过滤（关键词 vs 下载状态），语义不重叠，可叠加生效。
  - 封面惰性联动：当前页渲染时对「本地有文件且缓存不存在且无负缓存」的条目入队，idle 每轮 1 本，完成后只重绘该书所在行。
  - 不变量：`d`/`x`/翻页/过滤/排序**零网络**；翻页释放离开页 image（D2 I-OOM）；所有落盘路径过 `seshat-sync--local-path`；`ondemand` 根只读。
  - 验收 ≥16 例：行文本属性可反查 uid、**15 个键位**各自可调用（逐个 `keymap-lookup` 断言非 nil 且 `commandp` 为 t）、翻页释放离开页、`d`/`x` 只删已下载且只删 ondemand 根、`x` 无标记时提示、`D` 在 dired 定位、过滤/排序后页码归零、非图形环境降级占位不报错、**I-OOM 断言**（见 T8）。（依赖：T1、T2、T3、T4、T5a）

- [x] T6 启动汇总（`emacs/seshat-status.el`）
  - `seshat-status-startup-notify` / `seshat-status-startup-delay` / `seshat-status-summary`（纯函数，入参为各数据源快照）/ `seshat-status-notify` / `seshat-status`（详情 buffer）/ 挂 `emacs-startup-hook`（延迟执行、可关）。
  - 待同步 批注 Y 的来源是 `seshat-reader-annotation-queue-count`（按 uid 过滤，软依赖，缺失显示 `-`）。
  - 验收：单测 ≥10 例——summary 各分支（从未同步 / 状态库损坏 / 正常 / 待同步非零）、notify 关闭时不 message、延迟钩子不阻塞启动、零网络断言。（依赖：T2、T3）

- [x] T7 静默化改造
  - `seshat-sync.el` / `seshat-sync-cmd.el` / `seshat-reading.el` / `seshat-reader-annotation-queue.el`：自动路径改走 `seshat-log`；显式命令保留单行反馈；`seshat-sync-now` 收尾写 `:runtime`。
  - **vendored 边界**：`seshat-reader-annotation-queue.el` 位于 vendored 包内，**不得**硬 `require` 项目层模块。对 `seshat-log` 一律**软依赖**：`(fboundp 'seshat-log)` 探测，命中则 `funcall`，未命中则降级为原 `message`（行为与改造前一致）。同样规则适用于 `seshat-reader/**` 内任何需要写日志的位置。
  - 验收：单测——定时器路径不产生 echo 输出（`cl-letf` 捕获 `message`）、交互路径仍有反馈、`:runtime` 在成功/失败两条路径都写入；`grep -rn "require 'seshat-log" emacs/seshat-reader/` 必须**为空**（软依赖断言）。（依赖：T1、T2）

- [x] T8 测试与两条机械不变量
  - 新增 `emacs/tests/seshat-log-test.el` / `seshat-reads-test.el` / `seshat-covers-test.el` / `seshat-status-test.el`；扩展 `seshat-library-test.el` / `seshat-state-test.el`。
  - **零网络断言**：把 `seshat-rest--request` 绑成 `(lambda (&rest _) (error "网络调用"))`，跑「打开书架 / 翻页 / 过滤 / 排序 / 删本地 / 批量删 / 启动汇总 / 打开已下载书」全部通过。
  - **OOM 有界断言（去假绿）**：测试内 `cl-letf` 把 `display-graphic-p` 桩成恒 `t`，并分别包裹 `seshat-library--make-cover-image` 与 `image-flush` 做计数。**必须先有一条正断言**，否则下面的守恒式在「构造恒 0」时全部假绿：
    - **正断言（P）**：首屏渲染完成后，`seshat-library--make-cover-image` 的调用次数 **> 0**，且**等于当前页「有封面可用」的条目数**（占位条目不计）。这条断言是整个 OOM 用例的靶点。
    - **守恒式①（上界）**：任一页渲染完成后，当前驻留（已构造未 flush）数 ≤ `seshat-library-page-size`。
    - **守恒式②（收支）**：`flush` 次数 == **构造总次数 − 当前驻留数**。**不得**用「当前页条目数」作被减数——占位条目不经构造，末页也常不足 `page-size`。
    - **守恒式③（无泄漏）**：关闭 buffer 后 `flush` 次数 == 构造总次数。
  - **必须覆盖的三个场景**（每个场景都跑 P + ①②③）：
    (a) 正常页：全部条目都有封面；
    (b) **当前页含占位条目**（构造数 < 页条目数，专测②的收支口径）；
    (c) **末页不满**（条目数 < `page-size`）。
  - **反假绿自检**：把 `display-graphic-p` 的桩**去掉**（回到批处理真实值 nil）后重跑同一用例，**正断言 P 必须失败**（构造次数为 0）。把这次变异自检的结论写进「## 验证记录」的对应行。若去桩后用例仍全绿，说明 P 写错了，必须修 P 而不是删自检。
  - 验收：`make -C emacs/tests ert` 全绿、0 unexpected、0 skipped。（依赖：T1–T7）

- [x] T9 文档沉淀
  - `docs/emacs-reader.md` 书架章节重写（离线语义 / 新键位 / 分页 / 封面三级回退 / 进度与批注列口径）。
  - `docs/architecture.md`：**重写**「书架与按需取书（M8-C）」节——保留三条不变量（`d` 零网络、落盘必过 `seshat-sync--local-path`、`ondemand` 根只读），把 UI 层描述从 `tabulated-list-mode` 四列五键改为「自建 buffer + 显式分页 + 15 键位」，数据层补「本地状态库为主源」；并**新增**「书架离线层」小节（数据源分层、依赖方向、I-OOM）。
  - `docs/configuration.md` 新增 defcustom 表（log / reads / covers / library / status）。
  - `CHANGELOG.md`、`openspec/decisions.md`（3 条决策）、`openspec/tech-debt.md`（外部命令依赖、批注数离线不完整、启动可达性用上次结论、分页渲染的观感代价、封面负缓存（`<uid>.none`）无清理路径，长期累积）。
  - 验收：文档中出现的每个 defcustom 与函数名都能在源码 grep 到；`make validate`（若有）通过。（依赖：T8）

## 文档清单
| 文档 | 变更域 | 动作 |
|---|---|---|
| docs/emacs-reader.md | 对外行为变更（书架键位/列/离线语义） | 重写书架章节 |
| docs/architecture.md | 架构决策（数据源分层、依赖方向） | 新增小节 |
| docs/configuration.md | 新增配置参数 | 新增 defcustom 表 |
| CHANGELOG.md | 用户可感知变更 | 新增条目 |
| openspec/decisions.md | 架构决策 | 追加 3 条 |
| openspec/tech-debt.md | 技术债 | 新增 5 条 |
| README.md | 模块目录（若新增顶层模块） | **必须更新**（新增 4 个顶层模块：`seshat-log` / `seshat-reads` / `seshat-covers` / `seshat-status`） |

## 验证标准
- **L1**：`make -C emacs/seshat-reader all`（含 `checkdoc` 目标，见 F3）与顶层 `emacs/*.el` 字节编译 0 warning；`emacs/*.el` 的 checkdoc 走 batch 等效命令（仓库无顶层 Makefile / 无 `checkdoc` 聚合目标，实测见 F3）；`elisp_check_parens` 全绿。
- **L2**：`make -C emacs/tests ert` 全绿（新增 ≥60 例；基线 42 文件 / 1403 例见 F5），含 T8 的两条机械不变量。
- **L3**（人工，需断网）：拔掉网络后 `M-x seshat-library` 能列出全部已登记书、封面三级回退、`RET` 打开已下载书、进度显示、`d`/`x` 删本地、`n`/`p` 翻页、启动提醒一行、`*Seshat Log*` 有记录且 echo area 无刷屏。
- **机械不变量**：I-OOM（驻留 image ≤ page-size）、I-NONET（书架全路径零网络）、I-READONLY（ondemand 根不发写请求）。

## 注意事项
- **不使用 ETAF**：实测测试期常 OOM，书架 UI 一律自建 buffer + 原生 image；`seshat-reader-etaf.el` 保持现状不动。
- **不用 tabulated-list**：行内封面与行高控制需要自建 buffer；排序/过滤因此要自己实现纯函数（可测）。
- 测试环境无图形显示：`display-graphic-p` 只守卫「把 image 放进 buffer 显示」，**不**守卫 `seshat-library--make-cover-image` 的构造（见 A4 / D2「构造与显示分层」）；否则 ERT 批处理下构造计数恒 0，I-OOM 断言退化为空断言。
- 封面依赖外部命令（`unzip` / `mutool`）：必须探针 + 自动降级，缺依赖时功能退化而非报错。
- 既有测试大量断言 message（`seshat-library-test.el` / `seshat-sync-cmd-test.el`），静默化必然要同步改这些断言——这是预期改动，不是回归。
- **输出点计数口径**：D6 的改造量以 F2 实测为准（`seshat-library.el` 33 行、`seshat-reading.el` 17 行），改造前用同一命令复测并写进「验证记录」，避免按旧口径漏改。

## 验证记录

> 实施期逐条回填（前置验证结论、变异自检结论、实测数字）。

| 项 | 结论 | 日期 |
|---|---|---|
| A1 状态库覆盖对拍 | 本机无真实状态库（`~/.local/share/seshat/` 不存在，实测 `STATE_DIR=absent`）→ 改用**构造数据**对拍：`seshat-state-entries` 3 条 + `--entries-cached` 3 条（其中 1 条 uid 不在状态库），经 `--entries-merge` 合并后 **4 条**（`:source` 为 `local local local cache`，缓存独有项状态 `unregistered`），符合 D1「以状态库为准、缓存独有项以未登记出现」的合并策略 | 2026-10-29 |
| A2 现有书架取数入口 | 改造前唯一取数路径是远端 REST（`--collect` → `--remote-entries`），无本地渲染路径；A2 假设成立 | 2026-10-29 |
| A3 `unzip` / `mutool` 探针 | 均可用：`(executable-find "unzip")` → `/usr/sbin/unzip`；`(executable-find "mutool")` → `/usr/sbin/mutool`（封面 L1/L2 不降级） | 2026-10-29 |
| A6 换页入口清单 | 命令层全部经 `seshat-reader--multipage-goto`；视口层（滚轮 / 滚动条 / `set-window-start`）不经翻页函数 → 接入点选 buffer-local `post-command-hook` + 页号比对去抖 | 2026-10-29 |
| T8 OOM 三场景（正常页 / 当前页含占位条目 / 末页不满）的 P + ①②③ | 三例全绿：`seshat-library-i-oom-scenario-a-normal-page` / `-b-placeholders-on-page` / `-c-last-page-partial`，每例都跑正断言 P + 守恒式 ①②③；`make -C emacs/tests ert` 47 文件 / 1568 例 / 0 unexpected | 2026-10-29 |
| T8 反假绿变异自检（去桩后 P 必须失败） | 去桩后正断言 P 失败：`(should (> created 0)) :form (> 0 0) :value nil`（T5b-2 已固化，`seshat-library-i-oom-positive-assertion-fails-without-graphic-stub` 通过） | 2026-10-29 |
| L2 ERT 基线（文件数 / 例数） | 42 文件 / 1403 例 → **46 文件 / 1555 例**（T1–T7 新增 4 个测试文件）→ 本次 T8 后 **47 文件 / 1568 例**（新增跨模块不变量文件 13 例），0 unexpected / 0 skipped | 2026-10-29 |
| T8 跨模块不变量 | I-NONET 10 场景全通过；I-OOM 跨模块复核通过；两条反向自检均证明桩有效 | 2026-10-29 |
