# M8-B：增量同步引擎（pull · push · move 检测 · 冲突整合）

## 当前状态

- 阶段：Phase 2（Plan）· **独立审查意见已落实，待用户确认计划**
- 已确认：M8 整体方案 ✅（用户 2026-10-24）；计划 A（地基）已完成并归档 ✅（`openspec/completed/2026-10-24-m8a-emacs-sync-foundation.md`）；本计划 4 个决策 ✅（用户 2026-10-24：`/api/resources` 建索引 + changes 追平 / rename 双向 / 直接替换旧引擎 / 冲突整合并入本计划）
- 审查记录：首轮 plan-reviewer 判「不通过」（2 blocking：`resources` 分页 `since+1` 会丢同秒记录且兜底方向颠倒；push 缺「本地内容修改 → mark-dirty」的发现机制），已全部修订；另落实 3 major + 9 minor，并新增 D8「计划 A 的实际 API」表与 T1 四段拆分；第二轮复审指出 T1b/T1c 边界潜在循环、T3 验收缺「同路径内容修改 → mark-dirty」、编排重接线无任务归属——已重排 T1b/T1c/T1d 为「事件应用 → 首同步追平 → 增量循环」、补 T3 用例、把编排并入 T4。
- 下一步：用户确认计划 → Phase 3（T0 → T1a → T1b → T1c → T1d，之后 T2，T2 完成后 T3 与 T4 并行）

## 目标

把 Emacs 端同步从「全量遍历 + 路径身份 + WebDAV 弱乐观锁」切到「增量游标 + uid 身份 + REST 条件写」，并补齐 M8.3 的 rename/move 检测。

**完成后**：对同一批文件做一次同步，网络代价与**变更数**成正比，而非与书库规模成正比；冲突检测真正生效；改名不再破坏 uid 稳定性。

## 根本问题

| # | 现状 | 冲突（证据） |
|---|---|---|
| 1 | **pull 是全量**：每次 `PROPFIND` 全目录再逐文件 GET | `/api/changes` 的 `seq` 游标让代价与变更数成正比，全量遍历随书库增长线性劣化（`seshat-sync-cmd.el:129-165`） |
| 2 | **push 无真正乐观锁**：`seshat-sync-put-if-match`（`seshat-conflict.el:129`）走 WebDAV，而 `/dav` 静默忽略 `If-Match` | 冲突检测形同虚设；只有 REST 的 `If-Match: "<blob>"` 生效（`docs/api.md` §8.2）。且 head 是全局单值，无法按文件比对（`seshat-conflict.el:42,87-94`） |
| 3 | **身份仍是路径**：`seshat-sync-status` 把相对路径当 uid 传给 `/api/progress/{uid}` | 现状必然拿不到进度（`seshat-sync-cmd.el:200-201`）；rename 只能表现为「删一个 + 建一个」 |

## 事实清单

| # | 事实 | 来源 |
|---|---|---|
| F1 | 全局单游标 `seq`，跨根共享；空批次 `next_cursor` 回传 `since`（不倒退） | `docs/adr/0004`、`docs/api.md` §9 |
| F2 | **无「查最新游标」端点**；不带 `since` 等价 `since=0`（返回最早批次，不是最新） | `docs/api.md` §15 第 5 条 |
| F3 | `changes` 事件 9 字段，**无 `size`/`mtime`**；`ondemand` 根 `blob` 恒为空串 | `internal/api/resources.go:68-76`、`docs/api.md` §15 第 3 条 |
| F4 | `ondemand` 根任何写 → `403 root_read_only`，**不重试** | `docs/sync-protocol.md` §9 要点 |
| F5 | 墓碑占 `UNIQUE(root,path)`：move 到墓碑路径 → `409` **但物理移动已完成** → 不可立即重试，需 `rescan` | `docs/api.md` §15 第 1 条 |
| F6 | 条件写只有 `If-Match: "<blob>"`；空 ETag 永不匹配；`If-None-Match: *` 仅创建；两条件头并存恒 `412` | `docs/api.md` §8.2 |
| F7 | `/api/resources` **无 offset 分页**，只有 `limit` + `has_more`；其 `since` 语义是 **`mtime >= since`**（非 `>`）。用「本页最后一项 mtime」翻页时，同秒内超过 `limit` 条的剩余记录会被跳过（`since+1` 才能前进、否则死循环），因此**索引可能不完整** | `docs/api.md` §1.5、`docs/sync-protocol.md` §9.1（Android 已明确「不保证单次全量」）、`docs/android.md:320` |
| F8 | 状态上传（进度/批注）失败**不阻塞**内容同步 | `docs/sync-protocol.md` §9 要点 |
| F9 | 状态库单条目写入会全量重建 `:paths`（O(n)），比较为 O(n²) | 计划 A 审查，`openspec/tech-debt.md` |
| F10 | `seshat-conflict.el` 的 `diff3` + smerge 可复用，但「取远端内容」走 WebDAV GET（`:181`）、「取祖先」走 `/api/versions`（`:187`，path 索引） | `seshat-conflict.el:162-213` |
| F11 | 计划 A 已提供全部能力：`seshat-rest-changes/list-resources/download-file/upload-file/move-resource/delete-file/versions` + `seshat-state-*`（cursor / base-blob / dirty / 墓碑 / remap / roots / 双索引） | `openspec/completed/2026-10-24-m8a-emacs-sync-foundation.md` |
| F12 | `seshat-rest-download-file` 内部已硬编码 `:binary t`（不接受该形参）；`seshat-transport-request` 的直接调用方需自行传 `:binary t` 才能拿到原始字节 | `emacs/seshat-rest.el`、`emacs/seshat-transport.el` 的 `:binary` 分支 |

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| H1 | 首同步两阶段，但**职责分开**：`changes?since=0` 追平是**权威全集**（`seq` 单调、按游标分页无损、幂等 upsert 可安全重放）；`/api/resources` 分页建索引只是**尽力而为的预建**（可能丢同秒记录），用于在 `changes` 事件因钩子失败而缺失时提供线索。**兜底方向是「索引缺 → changes 补」，不是「changes 缺 → 索引补」** | 事实✓（`api.md` §1.5、§4.5 的 rescan 兜底、`sync-protocol` §9.1） |
| H2 | rename 必须**双向**：服务端 `op=rename` 事件 → 本地改名；本地快照比对 → `POST /api/resources/{uid}/move` 上报。单侧不够 | 假设?（T3 实现后验证） |
| H3 | push 只遍历 `dirty-uids`，不做全量扫描 | 事实✓（状态库能力） |
| H4 | 状态上传失败不阻塞内容同步 | 事实✓（F8） |
| H5 | 冲突合并复用 `diff3` + smerge，只换远端/祖先取法 | 事实✓（F10） |
| H6 | 用户可见命令名与键位不变（`seshat-sync-now` / `-pull-all` / `-push-all` / `-status` / 定时器） | 约定（M8.6 透明性） |
| H7 | 必须先有 state 批量写入，否则逐 uid 写 base blob 退化为 O(n²) | 事实✓（F9） |

## 设计

### D1 引擎分层

```
seshat-sync-cmd.el   命令 / 定时器（名字不变；`seshat-sync-now` 的三阶段编排仍在
                     本文件，内部改调 seshat-sync-pull / -detect-renames / -push）
        ↓
seshat-sync.el       引擎：seshat-sync-pull / -push / -detect-renames / -now
        ├──→ seshat-state.el   cursor / base-blob / dirty / 墓碑 / remap（批量写入）
        ├──→ seshat-rest.el    计划 A 的 9 个端点封装
        └──→ seshat-conflict.el  diff3 + smerge（远端/祖先改走 REST）
```

**旧 WebDAV 函数的去留**：`seshat-sync.el` 的 `seshat-sync-profind` / `-get` / `-put` / `-delete` / `-etag` **保留不动**（`webdav` 传输后端在灰度期仍可能需要，且删除会造成 `seshat-conflict.el` 的编译期依赖断裂）；本计划不改它们的实现，只让 `seshat-sync-pull-all` / `-push-all` 改为调用新引擎函数（保持命令名与签名为兼容入口）。

### D2 `seshat-state` 批量写入（T0）

新增 `seshat-state-batch` 宏（或等价的 `let` 约定）：

- 进入时 `(setq seshat-state--batch-depth (1+ seshat-state--batch-depth))`；
- `--put-entry` / `--update-entry` 在 `batch-depth > 0` 时**跳过** `--rebuild-paths`；
- 退出时（`unwind-protect`）递减，减到 0 时统一 `--rebuild-paths` 一次。
- 语义保证：批量结束后的状态与逐条写入**完全一致**（用同一组操作做对照断言）。

### D3 pull（T1a / T1b / T1c / T1d）

`seshat-sync-pull`：

1. **首同步**（`state` 的 `cursor` 为 0 且 `:uids` 为空）：
   - a. **预建索引（尽力而为，不作全集依据）**：`seshat-rest-list-resources` 分页，每页 `limit=2000`，用当前页最后一项的 `mtime` 作为下一页的 `since-mtime`；若 `:has-more` 为真且 mtime 未前进（同秒），则 `since-mtime = mtime + 1` 强制前进——**这会跳过同秒的剩余记录，是已知代价**（F7）。**必须按根分别发起**（`seshat-rest-list-resources` 的请求粒度为单根，`403` 也是按根返回；四根一次调用会把只读根的 `403` 变成整批丢弃）：写入 `state` 的 uid↔path（不含 base-blob）。**每页写完 `state-save` 一次**，中断后可从未落盘点继续。
   - b. **权威全集：changes 追平**：`seshat-rest-changes :since-seq 0 :limit 2000` 循环到 `:has-more` 为 nil，逐事件**幂等 upsert**（事件优先于索引）。每批 apply 完成后 `(seshat-state-set-cursor (plist-get resp :next-cursor))` 并 `state-save`。**索引缺失的条目由这一步补齐；全集保证在这一步，不在 a 步。**
2. **增量**：`changes?since=cursor` 循环：`apply` 全部事件 → `state-set-cursor next_cursor` → `:has-more` 时立即再拉（不 sleep）。
3. **事件应用**：
   - `create` / `update`：mirror 根按 `blob` 与 `state` 的 `:base-blob` 比较，不同则用 `seshat-rest-download-file`（**内部已硬编码 `:binary t`，不接受 `:binary` 形参**）落盘，随后 `(seshat-state-set-base-blob uid blob size mtime)`——`blob` 取事件的 `:blob`，`size` / `mtime` 取落盘后本地 `file-attributes`（D5 的基线依赖它）；`ondemand` 根**只在本地缺文件时**下载。
   - `rename`：`rename-file` 本地文件 + `state-remap`（`old_path` → `path`）。
   - `delete`：本地文件删除或标记，`state-mark-deleted`（保留 base-blob，供后续判断）。
4. **`403 root_read_only`**：跳过该根，不重试、不报错刷屏。

### D4 push（T2）

`seshat-sync-push`：

1. 遍历 `seshat-state-dirty-uids`（H3）。
2. 对每个 uid：
   - 无 `:base-blob` → `upload-file` 带 `if-none-match "*"`（仅创建）；
   - 有 `:base-blob` → 带 `if-match base-blob`（条件覆盖）。
3. 状态码分支：
   - `2xx` → `(seshat-state-set-base-blob uid (plist-get resp :etag) size mtime)`——**blob 取响应里的 `:etag`**（服务端 `etag` 与 `blob` 同值，可直接用作后续 `If-Match` 的取值）；`:rev` 是提交 hash，**不得**用作条件写。`size` / `mtime` 取本地 `file-attributes`；
   - `412`（`etag-mismatch`）→ 取远端（`seshat-rest-download-file`）+ 祖先（`seshat-rest-versions` 位置参数传当前 base-blob）→ `diff3 -m` 三方合并：
     - **无冲突标记** → 写回本地、带**新的** base 重发**一次**（仍 `412` 则放弃）；
     - **有冲突标记** → **不进入 `smerge` 交互**（本流程可能由定时器触发，交互会阻塞）→ 保留本地合并结果、**保留 `dirty`**、`message` 提示人工处理；

   **与 D6/T4 的关系**：本步（自动、可能由定时器触发）用 `diff3 -m` 的输出 + 正则扫 `^<<<<<<<` / `^>>>>>>>` 判定冲突，**永不进入交互**；D6/T4 的 `seshat-conflict-resolve-and-put` 是**手动**入口（用户在编辑器里主动触发），仍用 smerge。两条路径底层判据相同（diff3 冲突标记），只是检测与呈现方式不同；push-all 改为调用新引擎后，`resolve-and-put` 只保留为手动入口。

   - `409`（`state-conflict`）→ 不重试；按 `:from`/`:to` 或重拉 `changes` 对齐；
   - `403`（`read-only-root`）→ 标记该根只读，跳过其余同根条目。
   - **放弃重发后 `dirty` 一律保留**（否则下次不再重试）；用户可通过 `seshat-sync-status` 看到 dirty 数量。
4. **状态上传**（进度/批注）在内容同步之后，**失败不阻塞**（F8），只记 warning。

### D5 move 检测（T3）

`seshat-sync-detect-renames`（在 push 之前执行）：

1. **本地快照**：遍历 `state-roots` 里 `mode = mirror` 的根，收集 `path → (size mtime)`。
2. **本地内容修改检测（必须先于 rename 判定执行）**：遍历 `state` 里已登记、未墓碑的 uid；若本地文件存在且其 `(size, mtime)` 与 `state` 基线不同 → `seshat-state-mark-dirty uid`。**这一步是 push 的输入来源**——没有它，`dirty-uids` 只会在 rename/新增时被填充，用户对已有文件的编辑永远不会被推送。与第 3 步的作用域互斥：本步只处理「本地文件存在且未改名」的已登记 uid；路径消失或新出现的判定归第 3 步（路径消失后无法 `stat`，不会同时命中）。
3. **与 state 比对**：
   - state 有该 uid 但本地文件消失 → 候选「本地删除」；
   - 本地出现 state 未登记的路径 → 候选「新建 / 改名目标」；
   - 若「消失的旧路径」与「新出现的路径」的 **size + mtime 相同**（且旧路径未被外部修改）→ 判定 rename，调 `seshat-rest-move-resource (uid to)`（**两个位置参数**，非 cons）。
4. `move-resource` 返回 `409`（墓碑占用）→ **不重试**，记 warning 并建议 `rescan`（F5：物理移动已完成）。
5. **服务端 rename 事件**（pull 阶段）→ 本地 `rename-file` + `state-remap`（D3 第 3 步）。

### D6 冲突整合 + status 修复（T4）

1. `seshat-conflict.el`：
   - `seshat-conflict--remote-head`（`:77`）改用 `seshat-rest-versions`（拿 `head`）；
   - `seshat-conflict--merge-three-way`（`:162`）的「取远端内容」改用 `download-file`，「取祖先」改用 `versions` 带 `hash`；
   - `--record-head` / `--read-head` 的全局单文件 head 改为读写 `state` 的 per-uid `:base-blob`；`seshat-conflict-local-head-file` 保留为**废弃别名**（defcustom 加 obsolete 标记，不移除，避免用户配置报错）。
2. `seshat-sync-status`（`seshat-sync-cmd.el:186`）改用 uid（`state` 的 `uid-for-path`），不再把相对路径当 uid。

### D7 边界（硬约束）

- 命令名、键位、`seshat-sync-interval` 定时器语义**不变**（H6）。
- 不引入外部依赖（`cl-lib` / `url` / `json` / `subprocess` 之外一律不用）。
- `ondemand` 根**绝不主动写**（F4）。
- 所有下载统一走 `seshat-rest-download-file`（内部已硬编码 `:binary t`，字节保真由计划 A 保证）；**不要**手动给该函数传 `:binary` 关键字（它不接受，会 `wrong-number-of-arguments`）。
- **只读根的 `403` 处理必须共用同一处**：T1a（预建索引）、T1b（事件应用）、T2（push）三处都会遇到 `403 root_read_only`，实现时抽一个 `seshat-sync--read-only-root-p` 判定 + 根级缓存，三处共用；不得各写一套判断（否则会出现「某根被 push 跳过但 pull 仍尝试写入」的不一致）。

### D8 计划 A 的实际 API（执行时按此调用，勿凭记忆）

| 调用 | 实际签名 | 注意 |
|---|---|---|
| `seshat-rest-changes` | `(&key since-seq limit)` → `(:status :changes :next-cursor :has-more)` | 返回键是 `:next-cursor` |
| `seshat-rest-list-resources` | `(&key root prefix since-mtime include-deleted limit)` → `(:status :items :has-more)` | 形参是 `since-mtime`（mtime 秒） |
| `seshat-rest-get-resource` | `(uid)` | `404` → `:not-found` |
| `seshat-rest-download-file` | `(path target &key root if-none-match)` | **无 `:binary` 形参**（内部硬编码） |
| `seshat-rest-upload-file` | `(path content &key root if-match if-none-match)` → `(:status :uid :etag :rev)` | `:etag` 可作 `If-Match` |
| `seshat-rest-delete-file` | `(path &key root)` | |
| `seshat-rest-move-resource` | `(uid to)` — **两个位置参数** | 不是 cons |
| `seshat-rest-versions` | `(path &optional blob)` | 线缆参数名是 `hash` |
| `seshat-rest-roots` | `()` → `(:status :roots)` | 每项 `(:tag :mode :default)` |
| `seshat-state-set-base-blob` | `(uid blob size mtime)` — **四参** | |
| `seshat-state-remap` | `(uid root new-path)` — **三参** | 返回 `(:old-uid :old-path)` |
| `seshat-state-uid-for-path` | `(root path)` | |
| `seshat-state-path-for-uid` | `(uid)` → `(root . path)` | 墓碑/orphan 返回 nil |
| `seshat-state-dirty-uids` / `-deleted-uids` | `()` | |
| `seshat-state-mark-deleted` / `-mark-dirty` / `-mark-clean` | `(uid)` | |
| `seshat-state-cursor` / `-set-cursor` | `()` / `(seq)` | |
| `seshat-state-roots` | `()` → `((TAG DIR MODE) ...)` | mode 是第三位 |

**状态条目 schema（重要）**：`seshat-state` 的条目固定为**八个字段**（`:root` `:path` `:base-blob` `:size` `:mtime` `:dirty` `:deleted-at` `:orphan`），`--normalize-entry` 与 `save` 都会把条目重建成这八个字段——**任何第九个字段（例如 `:mode`）会被静默丢弃**。因此：

- 根级属性 `mode`（`mirror` / `ondemand`）由 `seshat-state-roots` 的第三位承载，**不进条目**；
- 写条目时必须 **merge 而非整体覆盖**（用 `seshat-state--update-entry`），否则会清掉 `:base-blob`，导致下轮 push 把服务端已有的文件误判为新建并撞 `412`；
- 若将来确实需要 per-entry 的新字段，必须同时改 `--normalize-entry` 并升 `seshat-state-version`，属独立任务。

## 已知取舍

1. **rename 判据用 `size + mtime`**：不读内容 hash（避免全量读盘）；代价是「同尺寸同 mtime 的不同文件」会被误判为 rename。接受，因为误判会被服务端 `move` 的 `409`/成功语义暴露，且可在计划 C 用 blob 精化。另：**rename 后立即编辑**（size/mtime 随之变化）会被判为「删 + 建」而非 rename，uid 因此不稳定——这是该判据的已知盲区，精化（改用 blob 比对）留给计划 C。
2. **首同步仍要遍历一次全库**（建索引）：这是不可避免的一次性成本；之后才是指数改善。
3. **不做后台增量监听**（inotify）：本地改动靠定时器 + 快照比对发现，最坏延迟一个 `seshat-sync-interval`（默认 300s）。
4. **状态上传失败只记 warning**：与 F8 一致，但用户可能不知进度没同步；在 `seshat-sync-status` 输出里体现「上次状态同步失败」。

## 任务

### [ ] T0 `seshat-state` 批量写入

- 动作：按 D2 实现 `seshat-state-batch`；把 `--rebuild-paths` 的触发改为受 `--batch-depth` 控制。
- 依赖：无
- 验收：新增 ERT ≥5 例——批量 N 次写入后 `--rebuild-paths` **只被调用 1 次**（桩计数）；批量结果与逐条写入**完全一致**（同组操作对照）；批内异常（`unwind-protect`）仍重建一次且状态可用；嵌套批量（depth 2）只重建一次；批量期间 `:paths` **不更新**，`uid-for-path` / `path-for-uid` **不保证**命中本批新写入的条目；批量结束后状态（含 `:paths`）与逐条写入完全一致
- **内部可拆 2 步**：先加 `--batch-depth` 与守卫，再补测试。

### [ ] T1a 首同步：预建索引

- 动作：按 D3 第 1.a 步实现 `seshat-rest-list-resources` 分页建索引（每页 `state-save`）。
- 依赖：T0
- 验收：新增 ERT ≥6 例——分页按 `:has-more` 循环至结束；`since-mtime` 取本页最后一项 mtime；同秒时不前进会死循环、`+1` 后能前进（用例显式断言「同秒超过 `limit` 时索引可能不完整，这是已知代价，由 T1c 补齐」）；每页结束调用一次 `state-save`（桩计数）；`403` 根跳过不报错；零网络（全桩 transport）；且必须断言**按根分别发起**（每根**至少发起一次**，根之间互不干扰：某个根返回 `403` 时其余根仍继续；单页场景下总请求次数 = 根数，需要翻页时按 `:has-more` 递增）

### [ ] T1b 事件应用（四类事件的唯一实现）

- 动作：实现 `seshat-sync--apply-event`（单事件 → 更新 `state` + 落盘），供首同步与增量循环**共用一个实现**：
  - `create` / `update`：mirror 根按 `blob` 与 `state` 的 `:base-blob` 比较，不同则 `seshat-rest-download-file`（内部硬编码 `:binary t`）落盘，随后 `(seshat-state-set-base-blob uid blob size mtime)`；`ondemand` 根只在本地缺文件时下载；
  - `rename`：本地 `rename-file` + `seshat-state-remap`（三参：uid、事件 `:root`、新 `:path`）；
  - `delete`：本地文件删除 + `seshat-state-mark-deleted`（保留 base-blob）；
  - `403 root_read_only`：跳过该根，不重试、不刷屏。
- 依赖：T1a
- 验收：新增 ERT ≥8 例——四类事件各 1 例（断言 state 与本地文件的最终状态）；`blob` 与 base 相同时**不**调用下载（桩断言调用次数 0）；`ondemand` 根不主动下载；下载后 base-blob 的 `blob`/`size`/`mtime` 三个字段都正确写入；`403` 不重试且不影响其它根；`rename` 事件的 remap 三参正确。

### [ ] T1c 首同步：changes 追平取游标（复用 T1b 的事件应用）

- 动作：`changes?since=0&limit=2000` 循环，每个事件交给 T1b 的 `--apply-event`；每批 apply 完成后 `(seshat-state-set-cursor (plist-get resp :next-cursor))` 并 `state-save`；循环至 `:has-more` 为 nil。
- 依赖：T1b
- 验收：新增 ERT ≥6 例——循环至 `:has-more` nil（构造两批，断言调用 2 次）；每批 `set-cursor` 取 `:next-cursor`；**幂等重放**（同一批事件连续应用两次，`state` 结果相同、无重复 uid 条目）；索引缺失的条目被事件补齐（构造索引少一条 + 事件含该条，断言补齐）；每批结束调用一次 `state-save`（桩计数）；`limit=2000` 的实际传参。

### [ ] T1d 增量循环（复用 T1b 的事件应用）

- 动作：`changes?since=cursor` 循环，复用 `--apply-event`；`:has-more` 为真时**立即再拉**（不 sleep）；**游标最后写**。
- 依赖：T1c
- 验收：新增 ERT ≥5 例——只拉 `seq > cursor` 的事件；`:has-more` 为真时立即再拉（断言 transport 调用次数为 2）；带 `since=cursor` 的实际传参；**中断重放**（模拟首批后中断，再从最后落盘 cursor 继续，结果与一次跑完相同）；**游标后写**（模拟 apply 中途抛错，断言 cursor 未被推进）。

### [ ] T2 push 条件写

- 动作：按 D4 实现 `seshat-sync-push`。
- 依赖：T1d
- 验收：新增 ERT ≥12 例，覆盖——无 base 时发 `if-none-match "*"`、有 base 时发 `if-match <blob>`；成功写 base-blob；`412` 触发合并后重发一次（断言重发时带**新** base）；重发仍 `412` 则放弃且不无限循环；`409` 不重试；`403` 标记根只读并跳过同根其余条目；状态上传失败只 warning 不中断内容同步；并固定冲突判定口径：**用正则扫描合并结果中的 `^<<<<<<<` / `^>>>>>>>` 标记**判定「有冲突」，不用 `smerge-mode`（后者依赖 buffer 交互状态，在 batch 与定时器路径不可靠）；该判定抽成纯函数并单独测
- **内部可拆 2 步**：条件写主路径 → 412/409/403 分支。

### [ ] T3 move/rename 检测

- 动作：按 D5 实现 `seshat-sync-detect-renames`。
- 依赖：T2
- 验收：新增 ERT ≥10 例，覆盖——「同路径内容修改」1 例（**push 的主要输入来源**）：已登记 uid 的本地文件内容变化导致 `(size, mtime)` 与 state 基线不同 → 该 uid 出现在 `dirty-uids`（且**不**被判为 rename）；随后「本地改名被识别并调 `move-resource`（断言 uid 与 to 路径）；`size+mtime` 不同则**不**判 rename（判为删+建）；`move` 返回 `409` 时不重试且记 warning；服务端 `rename` 事件触发本地改名 + `state-remap`；快照遍历只覆盖 `mode = mirror` 的根」
- **内部可拆 2 步**：快照与比对 → 上报与 409 分支。

### [ ] T4 冲突整合 + status 修复

- 动作：按 D6 改 `seshat-conflict.el` 与 `seshat-sync-status`；并完成入口重接线——`seshat-sync-now`（`seshat-sync-cmd.el`）的编排改为 `pull → detect-renames → push`，`seshat-sync-pull-all` / `seshat-sync-push-all` 改为调用新引擎函数（保持命令名与签名不变）。
- 依赖：T2
- 验收：新增 ERT ≥8 例——`--remote-head` 走 `versions`；三方合并的远端内容走 `download-file`、祖先走 `versions`（桩断言 URL）；head 读写走 state 的 per-uid base-blob；`seshat-conflict-local-head-file` 被标 obsolete 但**仍可绑定不报错**；`seshat-sync-status` 用 uid 而非路径（桩断言 `GET /api/progress/{uid}` 的 uid 正确）；并断言**编排顺序**：桩记录 `seshat-sync-now` 的调用序列必须是 `pull → detect-renames → push`（否则本地改名产生的 dirty 与 uid 变更会漏推）；`seshat-sync-pull-all` / `-push-all` 仍可被原有键位与定时器调用（签名不变）。

### [ ] T5 文档与归档

- 动作：见「## 文档清单」。
- 依赖：T0、T1a–T1d、T2–T4
- 验收：8 个文档按要求更新；`tech-debt.md` 的 O(n²) 条目关闭；计划归档。

## 依赖关系

```
T0 ──▶ T1a ──▶ T1b ──▶ T1c ──▶ T1d ──▶ T2 ──┬──▶ T3
                                              └──▶ T4 ──▶ T5
```

T3 与 T4 均只依赖 T2，文件不重叠（T3 改 `seshat-sync.el` 新增函数，T4 改 `seshat-conflict.el` + `seshat-sync-cmd.el`），**可并行**；T5 最后。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `docs/architecture.md` | 「Emacs 客户端同步分层（M8-A）」节补引擎层：pull/push/move 检测的职责与执行顺序 | T5 |
| `docs/sync-protocol.md` | 新增「Emacs 客户端实现要点（M8-B）」：首同步两阶段策略、`resources` 分页的 mtime 同秒坑、rename 双向处理、`409`/`412`/`403` 的客户端动作 | T5 |
| `docs/configuration.md` | 若新增配置（如批量页大小、rename 检测开关）则补；否则说明「本计划零新增 defcustom」 | T5 |
| `CHANGELOG.md` | `### 新增`：增量同步引擎（游标推进、条件写、rename 检测、冲突整合）；**行为变更提示**：首次同步会建一次全库索引 | T5 |
| `openspec/decisions.md` | 三条：首同步两阶段策略、rename 双向与 `size+mtime` 判据、直接替换旧引擎而非双引擎 | T5 |
| `openspec/tech-debt.md` | 关闭 `seshat-state.el` O(n²) 条目；新增残余（rename 误判可能、无 inotify、状态上传失败用户不可见） | T5 |
| `openspec/active/roadmap.md` | M8 段更新计划 B 状态 | T5 |
| `docs/emacs-reader.md` | 测试文件数与总例数更新 | T5 |
| `docs/api.md` / `docs/errors.md` | **不改**（无服务端变更） | — |

## 验证标准

### L1

- `emacs --batch -Q -L emacs -L emacs/seshat-reader -f batch-byte-compile emacs/seshat-sync.el emacs/seshat-state.el emacs/seshat-conflict.el emacs/seshat-sync-cmd.el` → **0 warning 0 error**（若既有文件有基线警告，逐条对比零新增）。
- `check-parens` 所有改动文件通过。
- `make -C emacs/seshat-reader all` EXIT=0、警告集 33 → 33（阅读器未改，仅作回归）。

### L2

- 全仓 ERT **逐文件**跑（14 个文件 → 本计划后 16 个）。基线 **517**；要求 `unexpected = 0`、`skipped = 0`。
- **必须带齐 14 个 `-L` 目录**：仓库内 2 个（`emacs`、`emacs/seshat-reader`）+ straight `build-31.1` 下 12 个（`gt`/`pdd`/`posframe`/`etaf`/`etaf/lisp`/`etaf-ui`/`ebox`/`ebox/lisp`/`ecss`/`ecss/lisp`/`markdown-mode`/`visual-fill-column`）；缺目录会假失败（`annotation-v8` 2 例 `etaf-ui`、`translate` 整文件），跑法见 `docs/emacs-reader.md`。
- 本计划新增测试文件：`emacs/tests/seshat-sync-test.el`（T1a/T1b/T1c/T1d + T2 + T3 的用例主体）、`emacs/tests/seshat-conflict-test.el`（T4）；T0 的用例追加到既有的 `emacs/tests/seshat-state-test.el`。完成后测试文件数 14 → **16**。

### L3（真机，需服务端）

- 需服务端可用（`docker-compose.yml` 或本地 `go run ./cmd/server`）。验收清单：
  1. 空状态首次同步 → 索引建立、`cursor` 落库非 0；
  2. 改一个 org 文件 → 定时同步后服务端 `changes` 新增一条 `update`；
  3. 本地改名 → 服务端 uid 不变（`GET /api/resources/{uid}` 的 `path` 变化）；
  4. 两个客户端同时改同一文件 → 后者 `412` 并进入三方合并；
  5. 只读根（`ondemand`）不被写入。
- 若服务端不可用，记为「未验证」并在报告说明，不阻塞归档。

### 回滚

- 全部为已跟踪文件改动 + 可能的新增函数。回滚：`git checkout -- emacs/seshat-sync.el emacs/seshat-state.el emacs/seshat-conflict.el emacs/seshat-sync-cmd.el`。
- **状态库需清理**：首次同步会写 `~/.local/share/seshat/sync-state.eld`；回滚后若再次运行旧引擎，该文件不会被读（旧引擎用 `~/.emacs.d/seshat-head`），但建议备份后删除以免混淆。

## 注意事项

1. **不要改阅读器**（`emacs/seshat-reader/**`）——本计划与阅读器无关。
2. **`ondemand` 根绝不写**；所有下载统一走 `seshat-rest-download-file`（内部已硬编码 `:binary t`，不接受 `:binary` 形参，传了会 `wrong-number-of-arguments`）。
3. `resources` 分页的 **mtime 同秒坑**（F7）：`has_more` 为真且本页最后 mtime 与请求 `since-mtime` 相同 → 必须 `since-mtime + 1`，否则死循环（代价是同秒剩余记录被跳过，由 `changes` 追平补齐）。
4. `412` 重发**只能一次**，禁止无限重试；`409`/`403` 一律不重试。
5. `changes` 的 `has_more = true` 时**立即再拉**，不 sleep。
6. 首同步可能耗时较长：实现里按 `limit=2000` 分页并在每页之间允许 `C-g` 中断（不得留下半写状态——`state-save` 用原子写，中断即丢弃本页之前的部分可接受，但**游标必须最后写**）。
7. ERT 逐文件跑，且必须带齐 14 个 `-L`（见 L2）。
8. 不接触运行中的 Emacs：全部 `emacs --batch`；不调用 `elisp_mcp_*`。
9. 状态库测试一律用临时目录，禁止污染 `~/.local/share/seshat/`。

## 假设复核

T0、T1a–T1d、T2–T5 执行后逐条回填。结论取值：成立 ✓ / 被推翻 ✗ / 未验证 ?。

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| H1 | 首同步两阶段（索引 + 追平）更稳 | 待验 | |
| H2 | rename 需双向 | 待验 | |
| H3 | push 只遍历 dirty | 待验 | |
| H4 | 状态上传失败不阻塞 | 待验 | |
| H5 | 冲突合并可复用 | 待验 | |
| H6 | 命令名不变 | 待验 | |
| H7 | 需先做批量写入 | 待验 | |
