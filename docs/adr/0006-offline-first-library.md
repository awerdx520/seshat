# ADR-006：书架清单主源改为本地状态库（离线优先）+ 自建 buffer 分页渲染

## 状态
已接受（2026-10-29）

## 背景
Emacs 书架（`M-x seshat-library`）的清单**只来自远端 REST**：打开书架即发清单请求，断网 / 服务端不可达时书架是**空表**——不是「加载失败」，而是「看起来书库空了」。而本地 `seshat-state` 的 `:uids` 索引里其实已登记全部 uid（含未下载项），足以支撑「有哪些书」的渲染，只是从未被书架当作数据源使用。

同时，用户可见输出的规模已经失控：项目层 el 文件共约 **210 处**输出点（`(message` 155 处 + `(display-warning` 55 处，2026-10-29 实测），其中 `seshat-sync.el` 一个文件就有 103 行含 message/warning（43 处 `display-warning`）。这些输出由**两个后台定时器**（同步定时器与批注队列同步定时器）持续触发，表现为 echo area 长期刷屏、真正需要用户注意的信息被冲掉。

富展示（封面、进度、批注数）在离线语境下必须先回答「数据从哪来」：封面可以从本地文件生成（EPUB zip 内嵌图 / PDF 首页栅格化），进度只能本地记录（服务端 progress 只读且格式不透明），批注总数离线**不可得**（逐书拉取 = N 次往返）。而「书架里给每本书配封面」这件事本身有 OOM 风险：一次为全库创建 image 对象，在测试期已多次把 Emacs 拖进 OOM。

## 决策
1. **书架清单主源改为本地状态库，远端降级为可选增强 + 落盘缓存**：主源是 `seshat-state-entries`（新增公开枚举，读 `:uids`，零网络），增强源是 `~/.local/share/seshat/library-cache.eld`（只在显式 `g` 刷新时原子写），本地事实（是否已下载）由 `file-exists-p` + `file-attributes` 判定。合并策略以状态库为准，缓存项仅在 uid 不在状态库时以「未登记」状态出现；远端刷新失败静默进日志，书架永不因网络失败而空表。
2. **书架 UI 自建 buffer + 显式分页，同时驻留 image ≤ 一页**：`special-mode` 派生的自建 buffer（**不用 ETAF、不用 `tabulated-list-mode`**），每条目一行 = 行内封面 image（`display` 属性 + 固定像素高）+ 书名 + 根 + 大小 + 进度 + 待同步 + 状态徽章；`seshat-library-page-size`（默认 30）控制每页条目数，只为当前页创建 image，翻页 / `q` 时对离开页调 `image-flush`。**不变量 I-OOM**：任一时刻驻留 image 对象数 ≤ `seshat-library-page-size`，对非当前页条目的封面文件/文档解析次数为 0。
3. **封面三级回退，零网络、惰性、限速**：L1 EPUB 用 `unzip` 取 OPF 声明的 cover-image 原始字节；L2 PDF 用 `mutool draw -r 24 … 1` 栅格化首页；L3 书名首字 + face 占位（零依赖，永远可用）。命中缓存即用，失败写**负缓存** `<uid>.none` 不再重试；生成走串行 idle 队列（每次 1 本）+ `seshat-covers-timeout`（默认 3s）+ `seshat-covers-max-bytes`（4 MiB）双重上限，另加**连续失败 5 次熔断 60 秒**（内部 `defconst`，成功一次即清零）；生成完成只重绘该书所在行。
4. **日志收口为 `seshat-log` + 启动一次汇总**：新增 `emacs/seshat-log.el`（`seshat-log-level` / `seshat-log-quiet` / ring 上限 2000 行的 `*Seshat Log*`），`seshat-sync` / `seshat-sync-cmd` / `seshat-library` / `seshat-reading` / `seshat-reader-annotation-queue` 的**自动路径**全部改走 `seshat-log`；显式交互命令（`M-x seshat-sync-now`、`u`、`d`、`x`）保留单行 echo 反馈。新增 `emacs/seshat-status.el` 在 `emacs-startup-hook` 延迟 2s 做**一次**汇总（书库本数与已下载数、待同步笔记/批注、上次同步时间与结果、状态库是否损坏、从未同步提示），服务端可达性用状态库新增的 `:runtime` 键（上次运行结论），**不在启动时探测网络**。
5. **本地进度侧车 + 批注列降级**：新增 `seshat-reads-file`（`~/.local/share/seshat/reads.eld`，`uid → (:page :total :updated)`，原子写），在阅读器换页（debounce 2s）与 `kill-buffer-hook` 写入，零网络；批注列只显示「待同步 N」（本地队列可数），N 为 0 显示 `-`，**不显示服务端批注总数**。

## 理由
- **「断网空表」是数据源选错，不是网络问题**：本地状态库本就持有 uid 全集，把它当主源后，「有哪些书」这一最基本的问题不再依赖网络。远端清单的剩余价值是「服务端全集里本地未登记的项」与远端 size——这正是**增强**的定义，可以缓存、可以缺失、失败不影响主功能。
- **OOM 只能由结构约束**：`tabulated-list` 无法承载行内封面（列格式化不能按条目控制行高与 `display` 属性），ETAF 在测试期已多次 OOM。自建 buffer 把「行 = 一条目、行内一个 image」写成结构，再用**分页**把「同时存在的 image 数」钉在 `page-size` 上——这是唯一能不依赖 GC 时机保证的内存上限。代价是排序/过滤/翻页必须自己实现，但它们同时变成**可测纯函数**（这也是不选 ETAF 的隐性收益）。
- **封面必须可降级**：`unzip` / `mutool` 是外部命令，缺依赖不能报错——三级回退让「有图用图、没图用字」，且负缓存避免每次渲染都重试失败项；限速与超时保证单本坏文件不会拖住整个书架。
- **静默是「收口」而非「闭嘴」**：用户不反对信息存在，反对的是**自动路径**在 echo area 刷屏。自动路径写日志、启动时汇总一次、显式命令保留回显——三条规则同时成立，故障仍然可见（`*Seshat Log*` / `M-x seshat-status`），且「上次同步失败了」不会再被下一次刷屏冲掉。
- **诚实边界**：批注总数、远端清单、翻译/解释在离线时确实不可得，方案选择「不显示 / 显示上次结论 / 静默失败」，而不是缓存伪造或用 N 次往返硬撑。

## 替代方案
- **继续以远端清单为主源 + 本地缓存兜底**：否决。缓存是「上次刷新的快照」，一旦过期或从未刷新就退化为空表；而状态库是**权威的本地事实**，断网时也完整。主源与兜底的关系不能靠「哪个更新」动态判定，那会让「书架显示什么」随网络状态漂移。
- **用 `tabulated-list-mode` + `display` 属性放封面**：否决。列宽按字符计、行高按字符行计，行内 image 会撑破列对齐；且 `tabulated-list` 每次重排重建整表，与「只为当前页创建 image」的节流目标冲突。
- **用 ETAF 承载书架**：否决（用户实测结论）。ETAF 的表格抽象在测试期常 OOM；且它为「大数据量表格」设计，其内部缓存与重绘策略无法表达「驻留 image ≤ 一页」这一硬上限。
- **一次性为全库生成封面 + 内存缓存**：否决。直接违反 I-OOM；全库 image 常驻在数百本规模下不可控。
- **启动时探测服务端可达性**：否决。启动路径加网络请求会让「启动变慢 / 卡住」成为新的投诉面，且离线时必然超时；用上次运行结论（`:runtime`）表达「上次同步失败了」已足够，用户要看实时状态可以显式 `g`。
- **离线展示服务端批注总数（逐书拉取或缓存）**：否决。逐书拉取是 N 次往返且离线必然失败；缓存批注需要新增一套本地批注存储与失效逻辑，收益（一个数字）远小于成本。

## 后果
- **正向**：断网可用——书架能列出全部已登记书，能打开已下载书、能看进度、能删本地副本；OOM 有界（image 驻留数由 `seshat-library-page-size` 硬约束，测试与 tty 环境完全跳过 image）；echo area 干净（自动路径零输出，启动一行汇总）；故障可追（`*Seshat Log*` ring + `M-x seshat-status` 详情）；进度本地可见且零网络。
- **负向**：① **首次使用前必须先同步过一次**（状态库与缓存都为空时书架显式提示 `M-x seshat-sync-now`，不假装书库是空的）；② 封面依赖外部命令（`unzip` / `mutool`），缺依赖时退化为首字占位；③ 批注总数离线不可得（列上只有「待同步 N」）；④ 分页牺牲连续滚动观感，翻页有明确边界，条目多时需要多次 `n`；⑤ 静默化会让「不看日志就不知道出过问题」成为新的默认，需靠启动汇总兜住。
- **风险**：状态库若被损坏（文件读不出），书架与汇总都必须降级为「提示 + 空表」而不是抛错（`seshat-state` 加载路径已有坏文件降级惯例，汇总需显式区分「损坏」与「从未同步」两种空态）；封面缓存目录长期累积负缓存文件，需要 `seshat-log-clear` 之外的清理路径（本轮不做，登记 tech-debt）。
- **回退路径**：删 `library-cache.eld` 回到「只用状态库」；`seshat-log-quiet` 设 nil 恢复 echo；`seshat-covers-max-bytes` 设 0 使封面全走占位；`seshat-library-page-size` 调大可近似「一屏到底」（代价是 I-OOM 上限随之放宽）。

## 实现要点
- 依赖方向（新增模块必须在图内）：`seshat-log` 零依赖；`seshat-reads` / `seshat-covers` 纯本地文件系统，**禁止 require `seshat-rest`**；`seshat-library` 依赖 state/reads/covers/log，软依赖 `seshat-reading`；`seshat-status` 依赖 state/reads/queue/log，**禁止 require `seshat-rest`**。`seshat-reader/**` 仍不得反向 require 上述项目层模块。
- 继承既有不变量：`ondemand` 根只读（书架不发写请求）、所有落盘路径过 `seshat-sync--local-path`、`mirror` 根拒绝删/覆盖（`seshat-library--ondemand-root-p` 门）。
- 两条机械不变量必须在 ERT 里可判定：I-NONET（把 `seshat-rest--request` 绑成抛错函数后跑书架全路径）与 I-OOM（`cl-letf` 包裹 `create-image` 计数，翻页 10 次后断言峰值 ≤ `page-size`）。
- 计划与任务拆分见 [openspec/completed/2026-10-29-emacs-offline-library.md](../../openspec/completed/2026-10-29-emacs-offline-library.md)（T1–T9、D1–D9、事实基线与假设清单）。
