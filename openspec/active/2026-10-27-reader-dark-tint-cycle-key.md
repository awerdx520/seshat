# 阅读器暗色配色预设：一键循环切换命令与 `T` 键位

## 当前状态
- 阶段：Phase 4（Review & Document）· 文档同步完成，L3 目测待用户
- 已确认：方案 ✅（用户 2026-10-27 确认，放置层选定 B：**命令进包、键位由配置层绑定**）、计划 ✅（用户 2026-10-27 确认，plan-reviewer 有条件通过后已修订）
- 下一步：**L3 由用户重启 Emacs 后自测**（不做 `load` 热生效，遵循 I2：非用户显式要求不回写运行实例）。自测清单见 T7 条目末尾「L3 自测清单」。通过后：勾 T7 → 假设复盘 → 归档到 `openspec/completed/`
- 独立审查：plan-reviewer ⚠️ **有条件通过**（无阻塞项；4 个重要级 I1–I4 + 7 个建议 S1–S7）→ **已逐条修订**，处置表见「## 审查与修订」
- 与在飞计划的关系：`openspec/active/2026-10-27-reader-dark-tint-presets.md`（已到 Phase 4，T7 真机目测未做）。本计划**只读**它在 T3 产出的 `seshat-reader-dark-tint-presets` / `seshat-reader-dark-tint` / `seshat-reader--dark-tint-colors` / `seshat-reader-dyn--doc-tint` 契约，**不改**其语义、不改 C 侧、不重编 `.so`。
- **共同编辑点（必须串行，不得并行）**：与在飞暗色计划共有**三处**：
  1. `thomas-emacs/lisp/init-reader.el` —— 本计划 T6 在 `:general` 表单内加 `"T"` 绑定与注释；暗色计划 T6「配置侧收尾」要删 `+seshat-reader-dark-after-render` 的 advice 定义与 `advice-add` 注册。本计划只碰 `:general` 与相邻注释，**不碰** advice 相关代码。
  2. `thomas-emacs/CHANGELOG.md` —— 两计划都要追加条目（本计划记 `T` 绑定；暗色计划记「删 advice + 设 charcoal 默认」）。**追加式写入，不得覆盖对方条目**。
  3. `openspec/active/2026-10-27-reader-dark-tint-presets.md` —— 本计划 T7 只在其「当前状态」加一行注记，**不改任务内容**。
- 与 T7 目测的关系：本计划的 L3 目测（连续按 `T` 走遍 5 档）可直接覆盖暗色计划 T7 验收项 ⑥「切预设后立即刷新」。

## 目标

让 5 档暗色配色可以「按一个键逐档试」，不必 `M-x customize-variable` / `setq` 之后再手动 toggle 或 `C-l`：

1. 包内新增命令 `seshat-reader-dark-tint-cycle`：按预设表顺序循环、支持反向、当前值非预设时从表首起、暗色未开时自动开启、即时重绘。
2. 配置层（thomas-emacs）把该命令绑到阅读 buffer 的 `T`；`d`（暗色开关）保持不变。
3. 阅读器帮助页（`?`）能查到「暗色模式」与「切换配色预设」两行。
4. 文档 / NEWS / CHANGELOG 与实现同步，不出现「只能 customize」这类过期表述。

**不做**：C 侧改动（`--doc-tint` 已足够）、`d` 键语义变更、配色持久化落盘（`customize` 已覆盖）、buffer-local 配色（与进程级语义冲突）。

## 根本问题（第一性原理）

| 事实 | 依据 |
|---|---|
| 5 档配色是 elisp 侧 alist（`graphite` 存 `(-1 . -1)` 哨兵）+ 一个 defcustom，C 侧只认两个 `#xRRGGBB` 整数 | `emacs/seshat-reader/seshat-reader.el` 的 `seshat-reader-dark-tint-presets` / `seshat-reader--dark-tint-colors` |
| 改 `seshat-reader-dark-tint` **不会**重绘已打开的 buffer | 该 defcustom 的 docstring；`docs/configuration.md`「改后需重新 toggle」 |
| 重绘的唯一入口＝下发 `--doc-tint` + `seshat-reader--redisplay-all-windows`（后者会先清 spec 缓存） | `seshat-reader-dark-mode` 的 body |
| 预设表顺序即自然循环顺序，`graphite` 是「回退到旧满量程反色」的一档 | 表定义 |
| 包内**没有**切换预设的命令，用户只能 customize 或 `setq` | 全仓 grep 无 cycle 类命令 |
| `T`（大写）未被包内任何 keymap 占用；已占用的小写/符号键有 `d` `t` `e` `w` `a` `m` `/` `?` 等 | grep `(kbd "T")` 零命中；Phase 3 T1 用 `lookup-key` 机械复核 |
| 暗色开关与配色都是**进程级**用户偏好，`seshat-reader-dark-tint` 是全局 defcustom（无 buffer-local） | C 侧 `render/render-theme.c` 的 static；elisp 侧无 `make-variable-buffer-local` |

⇒ 缺的不是能力，而是一个**把「改值 + 下发 + 重绘」打包成一步**的命令。缺的是一步操作，不是新机制。

## 假设清单

| # | 假设 | 来源 |
|---|---|---|
| A1 | `seshat-reader-dark-tint` 是全局 defcustom，切换即对整个 Emacs 所有 reader buffer 生效，与 C 侧进程级 static 自洽 | 事实✓（源码已核对） |
| A2 | `graphite` 在表内存 `(-1 . -1)`，`seshat-reader--dark-tint-colors` 对它返回 `nil` → 下发的 `-1` 即「清 tint、走旧反色路径」 | 事实✓（源码已核对） |
| A3 | 不 toggle `seshat-reader-dark-mode`、直接「下发 tint + `--redisplay-all-windows`」与「开启 dark-mode」等效，且只重绘一次 | 假设?（依据：那两步正是 dark-mode body 的全部副作用；T2 的 stub 断言调用序列，L3 目测确认无闪/无残留） |
| A4 | `T` 在 `seshat-reader-mode-map` 空闲且不会被 keymap preset 重装覆盖 | 假设?（grep 零命中；`seshat-reader--install-keymap-preset` 只 unset 自己的 preset 键；T2 加 `lookup-key` 断言钉住） |
| A5 | thomas-emacs 的 straight build 目录是到 `/home/thomas/Workspace/seshat` 的软链，故仓库内 `make all` 后主实例 `(load (locate-library "seshat-reader") nil nil)` 即热生效，无需 `straight-rebuild-package` | 事实✓（历史实测；T1 当日用 `ls -l` 复核，若发现不是软链则改为 `straight-rebuild-package` 并在执行记录标注） |
| A6 | 帮助页测试只断言子串存在、不锁行序，`feature-keys` 加两行不会破坏既有断言 | 事实✓（`emacs/tests/seshat-reader-sidebar-test.el` 的帮助页用例只做 `string-match-p`） |
| A7 | `emacs/seshat-reader/NEWS` 的 `Version 0.4.0` 段是当前未发布的开发段，可直接前置追加条目 | 假设?（T1 用 `git tag --list` 判定：若 `0.4.0` 已打 tag，则**新开** unreleased 段而非改已发布段） |

## 设计

### D1 命令契约 `seshat-reader-dark-tint-cycle`

位置：`emacs/seshat-reader/seshat-reader.el`，紧邻 `seshat-reader-dark-mode`（不新建文件——该命令与预设表、dark-mode 强耦合，分文件会让「下发逻辑」出现第二处调用点）。

| 维度 | 规则 |
|---|---|
| 签名 | `(defun seshat-reader-dark-tint-cycle (&optional n) ...)` + `(interactive "p")` |
| 顺序 | 按 `seshat-reader-dark-tint-presets` 的**表序**：`graphite → midnight → charcoal → night-sepia → sepia`；末尾回绕 |
| 步长 | `n` 缺省 1（前进一档）；负数（`C-u -` 前缀）反向；`n` 的绝对值可 >1 |
| 当前值不在表内 | 若 `seshat-reader-dark-tint` 是自定义 `(BG . FG)` cons 或 `nil`，循环起点视为「表首之前」，即下一次前进得到表首 `graphite` |
| 执行顺序（**不得颠倒**） | ① 先 `(setq seshat-reader-dark-tint NEW)`；② 若当前 buffer 是 reader buffer 且 `seshat-reader-dark-mode` 为 nil → `(seshat-reader-dark-mode 1)`（它按**新值**下发并重绘，cycle 不再重复下发）；③ 若 dark-mode 已开启 → `(seshat-reader--push-dark-tint)` + `seshat-reader--redisplay-all-windows` 各一次。**先开 mode 再 setq 会下发旧值**。 |
| 非 reader buffer | 只 `setq` 全局偏好 + `message`，不调用模块函数、不重绘 |
| 反馈 | `message` 形如 `Dark tint: night-sepia`；`graphite` 额外注明「满量程反色（旧观感）」 |
| 返回值 | 新的预设符号（`message` 的返回值不参与） |
| docstring | **禁止**出现字面键位串（如 `T`、`C-u`）——checkdoc 会报 "Keycode ... embedded in doc string" 并使 `make all` 的 Warning 计数 +1，破坏「零新增」判据。用描述性措辞（如 "cycling forwards" / "a negative prefix argument"） |

### D2 单一真源：抽出 `seshat-reader--push-dark-tint`

`seshat-reader-dark-mode` 的 body 当前是「`--doc-invert` → 开时解析并 `--doc-tint` → `--redisplay-all-windows`」。把中间那步抽成内部函数：

```
(defun seshat-reader--push-dark-tint ()
  "把 `seshat-reader-dark-tint' 解析后的两个端点色下发到原生模块。...")
```

- 语义：解析 `seshat-reader-dark-tint` → `(seshat-reader-dyn--doc-tint BG FG)`，`graphite`/非法值下发 `-1 -1`。
- 返回值：仅供调试与未来扩展，`seshat-reader-dark-mode` 与 `seshat-reader-dark-tint-cycle` **均不消费**。注意 `graphite` 也照常调用 `--doc-tint`（传 `-1 -1`），因此「返回值表示不下发 tint」**不等于**「没有调用模块函数」——二者不要混谈。
- `seshat-reader-dark-mode` 与 `seshat-reader-dark-tint-cycle` **都**调用它 → 下发逻辑全仓仅一处（当前 `--doc-tint` 生产调用点恰好 1 处，改后仍为 1 处，只是外面包了一层）。
- 既有 **12** 例 theme 测试（`emacs/tests/seshat-reader-theme-test.el`）的 stub 与断言**保持不变**——stub 的是模块函数与 redisplay，抽函数不改变它们的调用形态。若某例因抽函数而需改，必须在执行记录里逐例说明「为什么不是削弱断言」。

### D3 键位（配置层，thomas-emacs）

`/home/thomas/thomas-emacs/lisp/init-reader.el` 的 `:general` 表单（当前只有 `"d" #'seshat-reader-dark-mode`）增加一行 `"T" #'seshat-reader-dark-tint-cycle`，并在上方注释补一句：`d` 管开关、`T` 管配色档位；二者都必须绑在 `seshat-reader-mode-map` 本体（该 buffer 关闭 evil，leader 前缀不生效）。

### D4 帮助页

`emacs/seshat-reader/seshat-reader-help.el` 的 `seshat-reader-help--feature-keys` 追加两行（暗色模式、切换配色预设）。键位由 `substitute-command-keys` 在 `seshat-reader-mode-map` 上运行时解析，配置层绑的 `d` / `T` 会显示真实键位；包内无默认键位时显示命令名，属预期。

### D5 语义边界

- 配色仍是**进程级偏好**：`T` 改的是全局 `seshat-reader-dark-tint`，同一 Emacs 内所有 reader buffer 一起变（与 C 侧 static 自洽）。**不做** buffer-local。
- `d`（开关）与 `T`（档位）正交：关暗色后档位保留，再按 `d` 或按 `T` 都回到同一档。

## 任务

- [x] **T1 基线 + 安全点 + 事实复核**（依赖：无）
  1. 安全点：`git -C /home/thomas/Workspace/seshat stash create`（取返回的 commit SHA 记录为安全点，**不**改动工作目录）；`git -C /home/thomas/thomas-emacs stash create` 同理。
  2. 记录 dirty 清单（两仓库），后续 commit 必须用显式路径，避开并发会话文件。
  3. L1 基线：`cd emacs/seshat-reader && rm -f *.elc && make all` → 记录 EXIT 码与 `grep -cE "Warning|Error"` 计数（当日实测值即基线，判据「零新增」，不写死历史数字）。
  4. L2 基线：记录当日全量 ERT 例数（历史参考：31 文件 / 1166 例，来自暗色计划批次 3a；**以当日实测为准**）。
  5. 复核：`(lookup-key seshat-reader-mode-map (kbd "T"))` 应为 nil；`ls -l` 确认 straight build 软链（A5）；`git tag --list` 判定 NEWS 段（A7）。
  **验收**：安全点 SHA、两组基线数字、三项复核结论全部写入「执行记录」。
  **执行记录（批次 0 ✅）**：安全点 seshat `5e914fa0212800ea15a31bd59606252b31deda3e`、thomas-emacs `c3fe2e3920995d6b19c4f04f79ea86248c6c08fc`（`stash create` 返回，工作区未改动）；L1 `make all` EXIT=`0`（2.7s）、`Warning|Error` = `24`（分文件：`seshat-reader.el 22` / `seshat-reader-saveplace.el 1` / `seshat-reader-bookmark.el 1`；`checkdoc-file` 段零输出）、产物 `13` 个 `.elc` + `.so` 字节 `103080`；L2 全量逐文件 `31` 文件 / `Ran` 合计 `1226` 例 / `unexpected = 0` / `skipped = 0`、非零 rc 文件「无」、总耗时 `36.3s`（逐文件汇总 `/tmp/t1-ert-summary.log`）；复核：`T-lookup=nil`（`d-lookup=nil`，包内不绑 `d`）、build 目录软链「是」（`seshat-reader.el` 与 `.elc` 均软链到 `/home/thomas/Workspace/seshat/emacs/seshat-reader/`，A5 成立 → `make all` 后 `load` 即热生效）、`git tag` 无 `0.4.0`（3 个 tag 均为 `pre-*` 历史标记，A7 成立 → NEWS 直接追加）。dirty 清单见报告（`14` 项：seshat 9 / thomas-emacs 5；本计划唯一新增未跟踪文件即本计划文件，其余均为并发会话/既有工作区状态，均非本计划改动）。

- [x] **T2 测试先行（红）**（依赖：T1）
  在 `emacs/tests/seshat-reader-theme-test.el` 新增用例（复用现有 helper `seshat-reader-theme-test--with-dark-toggle`，它已 stub `--doc-invert` / `--doc-tint` / `--redisplay-all-windows`）：
  1. 前进：从 `charcoal` 调 `(seshat-reader-dark-tint-cycle)` → 变量变为 `night-sepia`，且 `tint-args` 等于 `((#x201d18 #xc0b49c))`，`redisplay-calls` = 1。
  2. 反向：从 `charcoal` 传 `-1` → `midnight`，`tint-args` 等于 `((#x1c1c22 #xc8c4ba))`。
  3. 回绕：从 `sepia` 前进 → `graphite`，`tint-args` 等于 `((-1 -1))`。
  4. 非预设起点：`(let ((seshat-reader-dark-tint '(#x101010 . #xeeeeee))) ...)` 前进 → `graphite`。
  5. 暗色关着时调用 → 自动开启（`invert-args` = `'(1)`）且**只**重绘 1 次（不得 2 次）。
  6. 非 reader buffer（`(with-temp-buffer ...)` 里直接调用）→ 变量改变，但 `tint-args` / `redisplay-calls` 均为空/0。
     **该例不得复用 `seshat-reader-theme-test--with-dark-toggle`**——该 helper 会把 `major-mode` 强制设为 `seshat-reader-mode`，复用就不再是「非 reader buffer」。请另写一份只 stub `seshat-reader-dyn--doc-tint` / `seshat-reader-dyn--doc-invert` / `seshat-reader--redisplay-all-windows` 的 `cl-letf`，在 `(with-temp-buffer ...)`（`fundamental-mode`）里调用。
  另在 `emacs/tests/seshat-reader-evil-keymap-test.el` 加 1 例：`(should-not (lookup-key seshat-reader-mode-map (kbd "T")))`——钉住「包内不占 T」这条前提（A4），并注明该断言由配置层负责绑定、包内只保证键位可用。
     该例是**守护断言**：`T` 本就空闲，T2 阶段即绿，**不参与红灯留痕**（红灯只由 6 例 cycle 用例提供）；若它先失败，说明 `T` 已被占用（环境变化信号），需停下来核对。
  **验收**：新用例**先失败**（命令尚未实现 → `void-function` 或断言不符），失败信息记录在「执行记录」（TDD 红灯留痕）。
  **执行记录（批次 1 ✅ 红灯留痕）**：`emacs/tests/seshat-reader-theme-test.el` 新增 6 例（前进 / 反向 / 回绕 / 非预设起点 / 暗色关着时自动开启且只重绘 1 次 / 非 reader buffer 只改偏好）；`emacs/tests/seshat-reader-evil-keymap-test.el` 新增 1 例守护断言（`T` 空闲，T2 即绿，不参与红灯）。红灯证据：theme-test `Ran 18 tests, 12 results as expected, 6 unexpected`，失败项全部为 `void-function seshat-reader-dark-tint-cycle`（关键行：`Test seshat-reader-theme-test-cycle-wraps-around-to-sentinel condition:` / `    (void-function seshat-reader-dark-tint-cycle)` / `FAILED  seshat-reader-theme-test-cycle-backwards` / `FAILED  seshat-reader-theme-test-cycle-enables-dark-mode-once` / `FAILED  seshat-reader-theme-test-cycle-forwards`，其余三例同为 `FAILED` + 同一 `void-function` 条件）；evil-keymap-test `Ran 10 tests, 10 results as expected, 0 unexpected`。实现尚未落地，符合 TDD 红灯要求。L1：两文件 `check-parens` 通过（宿主 `emacs --batch`——elisp MCP 纯实例连续两次「启动失败」，按回退纪律改宿主，见报告）。

- [x] **T3 实现（绿）**（依赖：T2）
  按 D1 实现 `seshat-reader--push-dark-tint` 与 `seshat-reader-dark-tint-cycle`；`seshat-reader-dark-mode` body 改用 `--push-dark-tint`（行为不变）。
  **验收**：T2 全部新用例转绿；既有 **12** 例 theme 用例（含 `seshat-reader-theme-test--dark-and-presentation-order-independent`，即 P1 批次 8 的 T9 顺序无关性用例）、`seshat-reading-test` 的 dark-mode 用例、`seshat-reader-multipage-test` 的两处 dark-mode 用例**全部保持绿**；`--doc-tint` 生产调用点仍为 1 处（`grep -c` 记录）。
  **执行记录（批次 2 ✅）**：`seshat-reader--push-dark-tint` 定义于 `3503`（在 `--dark-tint-colors` 之后、`dark-mode` 之前）；`dark-mode` body 改为单次调用（调用点在 `3532`）；`seshat-reader-dark-tint-cycle` 定义于 `3535`（`dark-mode` 之后）。定位当前位置**未新增任何 `require`**——`seshat-reader.el` 只 `require` 了 `image`，既无 `cl-lib` 也无 `seq`，故按预案走手写 `while` 线性查找（当前值不在表内时 idx 保持 `-1`，前进即得表首；`(mod (+ idx step) len)` 用 Emacs `mod` 保非负，反向回绕正确）。L1 `make all` EXIT=0、`Warning|Error` = `24`（基线 24，**零新增**；分文件 `seshat-reader.el 22` / `seshat-reader-saveplace.el 1` / `seshat-reader-bookmark.el 1`）、checkdoc 段落零输出；定向 ERT：theme `18`/evil-keymap `10`/reading `49`/multipage `90`/sidebar `143` 全绿（`0 unexpected`，`0 skipped`，`Ran` 行原文见报告）；不变量：`--doc-tint` 生产调用点 `1` 处（行号 `3509`，在 `--push-dark-tint` 内；另一处 `3427` 为 `declare-function`）、cycle 定义 1 处 + 帮助页引用 1 处；括号检查 `parens-ok`（两文件，宿主 `emacs -Q --batch` 的 `check-parens`）。修复循环：未触发。

- [x] **T4 帮助页**（依赖：T3，可与 T3 同批）
  `seshat-reader-help--feature-keys` 追加两行（D4）。
  **验收**：`seshat-reader-sidebar-test` 的帮助页相关用例全绿；手动核对帮助页内容含两行新描述。
  **执行记录（批次 2 ✅）**：两行插入 `seshat-reader-help--feature-keys` 表尾、`(seshat-reader-help . "本帮助页")` 之前（`seshat-reader-help.el` 第 `105` 行 `seshat-reader-dark-mode` / 第 `106` 行 `seshat-reader-dark-tint-cycle`），其余不动（键位仍由 `substitute-command-keys` 运行时解析）。batch 渲染核对实得 `M-x seshat-reader-dark-mode 开合暗色模式` / `M-x seshat-reader-dark-tint-cycle 切换暗色配色预设（按预设表循环，可反向）` / `?            本帮助页`——包内无默认键位故显示 `M-x` 前缀，符合 D4 预期。`seshat-reader-sidebar-test` `Ran 143 tests, 143 results as expected, 0 unexpected`，帮助页相关用例全绿。

- [x] **T5 验证 L1 + L2**（依赖：T3、T4）
  1. L1：`cd emacs/seshat-reader && rm -f *.elc && make all` → EXIT 0、`Warning|Error` 计数**零新增**（对照 T1 基线）；`make checkdoc` 零新增。
  2. 括号：对改动的 `.el` 逐个 `elisp_check_parens`。
  3. 定向 ERT：`seshat-reader-theme-test` / `seshat-reader-evil-keymap-test` / `seshat-reading-test` / `seshat-reader-multipage-test` / `seshat-reader-sidebar-test`。
  4. 全量 ERT：**逐文件**跑（单进程一次跑全量会出 6 例 annotation 既有假失败），累计例数与 T1 基线对照（新增应 ≥7 例），`unexpected = 0` 且 `skipped = 0`。
  **验收**：全部判据数字写入「执行记录」；失败进入修复循环（L1 ≤3 轮、L2 ≤2 轮），耗尽则回滚到 T1 安全点并报告。
  **执行记录（批次 3 ✅）**：L1 `make all` EXIT=0、`Warning|Error` = `24`（基线 24，零新增；分文件 `seshat-reader.el 22` / `seshat-reader-saveplace.el 1` / `seshat-reader-bookmark.el 1`）、checkdoc 0（`checkdoc-file` 段仅命令行回显，无 warning/error 行）、产物 `13` 个 `.elc` + `.so` 字节 `103080`；全量 ERT **逐文件** `31` 文件 / `Ran` 合计 `1233` 例（基线 1226，**+7**：theme `18`（+6）/ evil-keymap `10`（+1），文件数不变）/ `unexpected = 0` / `skipped = 0` / 非零 rc「无」、耗时 `59.7s`（逐文件汇总 `/tmp/t5-ert-summary.log`，全 31 行 `rc=0`、无 fail 日志）；不变量：`--doc-tint` 生产调用点 `1`（行 `3509`，在 `--push-dark-tint` 内；另一处 `3427` 为 `declare-function`）、cycle 定义 1（`seshat-reader.el:3535`）+ 帮助页 1（`seshat-reader-help.el:106`）、无 buffer-local（`make-variable-buffer-local` / `setq-local seshat-reader-dark-tint` 零命中）；括号四文件 `parens-ok`（`seshat-reader.el` / `seshat-reader-help.el` / `seshat-reader-theme-test.el` / `seshat-reader-evil-keymap-test.el`，用宿主 `emacs -Q --batch` 的 `check-parens` 替代 `elisp_check_parens`——elisp MCP pure 实例此前连续两次启动失败，按回退纪律与本次任务指令改宿主，被检内容与判据不变）。修复循环：未触发（首轮全绿）；安全点未使用。

- [x] **T6 配置层绑定（thomas-emacs）**（依赖：T5）
  按 D3 改 `init-reader.el` + `CHANGELOG.md` 记一条。
  **验收**：`cd /home/thomas/thomas-emacs && make full-check` 通过（thomas-emacs 的 L1 结构性门禁：check-parens + mcp-register-check + test；`validate` 目标属 `~/.config/eca` 仓，本仓不适用）；`ls -l` 复核 `init-reader.el` 的 diff 只含 `:general` 一行 + 注释，**未触碰** `+seshat-reader-dark-after-render`。
  **执行记录（批次 4 ✅）**：`lisp/init-reader.el` 在 `:general` 内 `"d"` 之后追加 `"T" #'seshat-reader-dark-tint-cycle`（第 `155` 行），并在相邻注释补 `d`/`T` 分工说明（`git diff` 仅这两处：`3` 行注释新增 + `:general` 内 `1` 增 `1` 改；**未触碰** `+seshat-reader-dark-after-render` 与 `add-hook 'seshat-reader-mode-hook` 注册，`git diff -- lisp/init-reader.el | grep -c after-render` = `0`）；`CHANGELOG.md` 在 `## [未发布]` 段首追加一条（`8` 行新增，未覆盖既有条目）。验证：验收句原写的目标在本仓**不存在**（`make: *** 没有规则可制作目标“validate”。 停止。`，EXIT=`2`；该目标是 ECA 配置仓的，计划 T6 验收句属跨仓笔误，已在本批改为 `make full-check`）——改跑本仓等价 L1 结构性门禁 `make full-check`（`check-parens` + `mcp-register-check` + `test`，见 `Makefile`）：EXIT=`0`（「所有文件括号检查通过。」/「MCP registration OK（20 自定义 spec 全部通过校验）」/`Ran 276 tests, 275 results as expected, 0 unexpected, 1 skipped`，skip 为既有 `test-eca-stream-flush-interval`）；`init-reader.el` 括号 `ok`（宿主 `emacs -Q --batch` 的 `check-parens` → `parens-ok`）；`git diff --stat` = `CHANGELOG.md | 8 ++++++++` + `lisp/init-reader.el | 5 ++++-`（`2 files changed, 12 insertions(+), 1 deletion(-)`）。与暗色计划 T6 配置侧的串行约束已遵守（该计划的配置侧改动仍未做）。

- [ ] **T7 文档同步 + L3 目测**（依赖：T5、T6；其中文档同步只依赖 T5，L3 目测依赖 T6 的键位绑定，由用户执行）
  1. 按「文档清单」逐项更新（`docs/emacs-reader.md` / `docs/configuration.md` / `emacs/seshat-reader/NEWS` / `CHANGELOG.md`）。
  2. 在 `openspec/active/2026-10-27-reader-dark-tint-presets.md` 的「当前状态」追加一行注记：T7 目测可用本计划的 `T` 连续切档（**只加注记，不改其任务内容**）。
  3. L3（用户）：热生效到主实例（`make all` 后 `(load (locate-library "seshat-reader") nil nil)`，若 A5 复核为否改用 `straight-rebuild-package`）→ 打开 PDF 连按 `T` 走一遍 5 档，确认：无闪/无残留、`graphite` 与旧观感一致、非预设自定义值起步行为符合 D1、暗色关闭时按 `T` 会自动开启。
  **验收**：文档逐项打勾；L3 逐项记录结论。
  **执行记录（批次 5 · 文档部分 ✅，L3 待用户）**：`docs/emacs-reader.md` 四处（① 文件头「连续阅读」行补「含 **5 档配色档位循环** `M-x seshat-reader-dark-tint-cycle`，包内无默认键位」；② 暗色模式行下**新增**「暗色配色档位循环」行（循环顺序 / 负前缀反向 / 表外自定义值从表首起步 / 暗色关闭时自动开启且只重绘一次 / 非 reader buffer 只改偏好），暗色模式行本身保留「无默认键位」；③ 完整键位表：判定为**包内默认绑定表**（表头 `### 9.1 阅读（seshat-reader-mode-map）`，列头 `| 键位 | 命令 | 作用 |`，表内已有「**vim 预设**」「**仅 emacs 预设**」等按包内绑定标注的条目），故**不**新增 `T` 行，改为在表下加一段引用块说明「本表只列包内 `seshat-reader-mode-map` 的默认绑定 + 暗色开关与配色档位循环两条命令无默认键位 + 配置层绑法示例（`d` / `T` 必须绑在 `seshat-reader-mode-map` 本体）」；④ 测试清单 `seshat-reader-theme-test` **18** 例 / `seshat-reader-evil-keymap-test` **10** 例、总 **1233 例 / 31 文件**，并同步「必须逐文件运行」段的逐文件求和数字）；`docs/configuration.md` 在「改后需重新 toggle」条目后新增「想逐档试配色用循环命令（即时重绘）」条目，并保留「`setq` / `customize` 本身不触发重绘」这一原始事实；`emacs/seshat-reader/NEWS` 的 `* Version 0.4.0` 段在 `--doc-tint` 条目后追加 cycle 条目（英文 Org，`=...=` 内联标记，与既有条目同风格），并把原「Changing `=seshat-reader-dark-tint=` does not repaint」条改为「可用该命令切换（即时重绘），或 toggle / `=C-l=`」；`CHANGELOG.md`（seshat 仓根）在 `### 新增` 顶部追加一条（简体中文，含命令名、循环顺序与反向用法、包内无默认键位、帮助页已收录、全量 ERT 31 文件 / 1233 例 0 失败）；暗色计划 `2026-10-27-reader-dark-tint-presets.md` 的「当前状态」加一行注记（`git diff` 为 `+1` 行，未改任何任务/验收内容）；本计划 T6 的跨仓笔误改为 `make full-check`（验收句 / 执行顺序表 / 验证标准三处，并把 T6 执行记录里的目标名同步为「验收句原写的目标」以免与本次自检口径冲突）。**L3 目测待用户执行**（热生效方式见计划 T7 第 3 条）。
  **热生效说明**：`make all` 的 `.elc` 是软链回本仓库，主实例下次 `load` / 重启即生效；本批**未**主动写主实例（遵循 I2：仅用户显式要求时才 `set_task config` + `load`）。
  **L3 自测清单（用户执行，2026-10-27 决定：重启 Emacs 自测，不用热生效）**：
  1. **必须重启 daemon**（不只是 client）——`.elc` 是软链回本仓库的新产物，daemon 进程只在启动时 `load`，仅重开 client frame 拿不到新代码。
  2. `(fboundp 'seshat-reader-dark-tint-cycle)` → `t`；`(lookup-key seshat-reader-mode-map (kbd "T"))` → `seshat-reader-dark-tint-cycle`（= 配置层加载成功）。两条任一不符则先排查，不要怀疑功能。
  3. 打开任意 PDF（`seshat-reading-mode`），按 `T`：echo 应显示 `Dark tint: night-sepia`（从默认 `charcoal` 前进一档），画面立即换色。
  4. 连按 `T` 走完 5 档并回绕到 `charcoal`；每档确认：无闪烁、无残留旧色页、滚动后仍保持当前档。
  5. `C-u - T`（负前缀）反向一档。
  6. 按 `d` 关闭暗色（回到白底），再按 `T`：应**自动开启暗色**且只重绘一次（不闪两下）。
  7. 在非阅读 buffer（如 `*scratch*`）`M-x seshat-reader-dark-tint-cycle`：只改全局偏好（`seshat-reader-dark-tint` 变化），画面与已打开的 PDF 不变。
  8. 阅读 buffer 按 `?`：帮助页应出现「开合暗色模式」「切换暗色配色预设」两行；因配置层已绑 `d` / `T`，两行应显示真实键位而非 `M-x`。
  9. `graphite` 一档与改动前的满量程反色观感一致（回退口有效）。
  逐项打勾后把结论补在本条下；任一项不符则记录现象（哪一档、有无闪烁、echo 文案）并停下来报我。

## 执行顺序（每批独立验收）

| 批次 | 任务 | 验收层 | 风险 |
|---|---|---|---|
| 0 | T1 基线 + 安全点 + 三项复核 | — | 低 |
| 1 | T2 测试先行（红） | L1（括号/编译） | 低 |
| 2 | T3 + T4 实现与帮助页（绿） | L1 + L2（定向 ERT） | 中（抽函数触及 dark-mode body） |
| 3 | T5 全量验证 | L1 + L2 | 低 |
| 4 | T6 配置层（thomas-emacs） | L1（`make full-check`） | 低 |
| 5 | T7 文档 + L3 目测（用户） | L3 | 低 |

- 批次 2 内 T3/T4 合并为一次改动（help 表两行依赖命令已定义，否则帮助页会显示「（未加载）」）。
- 跨仓改动（T6）单独一批，便于分别回滚。

## 文档清单

| 文档 | 需更新内容 |
|---|---|
| `docs/emacs-reader.md`（**四处**） | ① 文件头键位摘要段（约 line 12，「暗色模式」所在列）：补「配置层绑定的 `T` 循环切换配色档位」；② 暗色模式行（约 line 168）：补命令名 `seshat-reader-dark-tint-cycle` 与循环语义，并**保留**「包内**无默认键位**」这一表述（本计划不在包内绑键）；③ 「完整键位表」（约 line 502）：新增 `T` 行，注明由配置层绑定；④ 「构建与测试」的测试清单（约 line 985）：按 T5 实测例数更新（预计 theme-test **18**、evil-keymap **10**），不写死未验证的数字 |
| `docs/configuration.md`（「改后需重新 toggle」段） | 补一句：可用该命令逐档循环，页面即时重绘，无需 toggle 或 `C-l` |
| `emacs/seshat-reader/NEWS` | 按 A7 判定结果：`0.4.0` 未发版 → 在该段 dark-tint 条目后追加 cycle 命令一条；已发版 → 新开 unreleased 段 |
| `CHANGELOG.md`（seshat 仓根） | 新增功能一条（含命令名、键位由配置层绑定、循环顺序与反向用法） |
| `CHANGELOG.md`（thomas-emacs） | 配置层 `T` 绑定一条 |
| `lisp/init-reader.el`（thomas-emacs）注释 | `d` / `T` 分工与「必须绑在 mode-map 本体」的理由 |
| `openspec/active/2026-10-27-reader-dark-tint-presets.md` | 「当前状态」加一行注记（T7 可用 `T` 逐档目测），不改任务内容 |
| `openspec/decisions.md` | **不需要**：无跨模块架构决策（命令位置、单一真源属包内实现细节，已在本文档 D1/D2 记录） |
| `openspec/tech-debt.md` | **不需要**：本计划未新增已知限制（无 buffer-local 配色、无新增性能约束）。**例外**：若 L3 目测发现连按切档有明显卡顿，登记一条「切档重渲染可见页 ±2 页，连按有延迟」并注明属既有开销而非本计划引入 |

## 验证标准

- **L1**：`make all` EXIT 0 且 `Warning|Error` 零新增；`make checkdoc` 零新增；改动 `.el` 括号平衡；`elisp_check_parens` 全通过；thomas-emacs `make full-check` 通过（`check-parens` + `mcp-register-check` + `test`）。
- **L2**：定向 ERT 全绿；全量 ERT（逐文件）`unexpected = 0`、`skipped = 0`，例数较基线增加 ≥7。
- **L3**：用户连按 `T` 逐项目测通过（D1 六条契约逐条可见）。
- **不变量**：
  - `--doc-tint` 生产调用点 = **1**（抽函数后仍为 1）。
  - 包内不绑定 `T`（`lookup-key` = nil），键位来源只有配置层。
  - `seshat-reader-dark-tint` 保持全局（无 `make-variable-buffer-local`）。

## 注意事项

1. **共同编辑点串行**：`init-reader.el` 与暗色计划 T6 配置侧冲突，必须串行；本计划不碰 advice。
2. **docstring 不写键位字面量**（checkdoc Keycode 警告会让「零新增」判据失败）。
3. **并发会话**：本仓库常有其他会话改动工作区；每次 `git add` 后用 `git status --porcelain` 复核，commit 用 `-- <显式路径>`。
4. **全量 ERT 必须逐文件**（单进程有 6 例 annotation 既有假失败，不是回归）。
5. **`#x26262b` 是整数不是字符串**：测试断言里颜色一律写十六进制字面量，与既有 theme 测试同口径。
6. **命令不得 toggle `dark-mode` 两次**（会重绘两次、肉眼闪）；已开启时直接下发 + 单次重绘。
7. 预设计划已登记「切档会重渲染可见页 ±2 页」，连按 `T` 有轻微延迟属已知开销，不当作缺陷。
8. 若 A5 复核发现 build 目录**不是**软链，改用 `M-x straight-rebuild-package` 并在执行记录标注，不得两法混用。
9. **回滚粒度（重要）**：`git stash create` 快照整个工作区且**不含未跟踪文件**。T5 失败需回滚时，**只** `git checkout <安全点> -- <本计划涉及的显式路径>`（`emacs/seshat-reader/seshat-reader.el`、`emacs/seshat-reader/seshat-reader-help.el`、`emacs/tests/seshat-reader-theme-test.el`、`emacs/tests/seshat-reader-evil-keymap-test.el`、本计划文件），**禁止** `git stash apply` 全量恢复——那会连带丢弃并发会话在 T1 之后的所有改动。未跟踪的构建产物（`.elc` / `.so`）回滚后重跑 `make all` 即可。
10. **共同编辑文件有三个**（见「## 当前状态」）：`init-reader.el`、thomas-emacs `CHANGELOG.md`、暗色计划的「当前状态」注记；三者一律**追加式**改动，不得覆盖对方条目。

## 审查与修订

plan-reviewer 独立审查结论：**有条件通过**（无阻塞项）。逐条处置：

| 编号 | 级别 | 问题 | 处置 |
|---|---|---|---|
| I1 | 重要 | theme-test 既有例数写作 11，实际 **12**（多出 `--dark-and-presentation-order-independent`） | 已改：T2 / T3 / 验证标准统一为 12，并点名该用例 |
| I2 | 重要 | 共同编辑点漏列 `thomas-emacs/CHANGELOG.md` | 已补为**三处**共同编辑文件 |
| I3 | 重要 | 回滚粒度与并发会话的交互未说清 | 已补注意事项第 9 条：只 `git checkout` 显式路径，禁止全量 `stash apply` |
| I4 | 重要 | `docs/emacs-reader.md` 更新位置不完整（实际 4 处） | 已改为逐处列出 line 12 / 168 / 502 / 985 |
| S1 | 建议 | T7 依赖未含 T6 | 已改：依赖 T5、T6，并区分「文档同步」与「L3 目测」 |
| S2 | 建议 | D1「暗色状态」顺序有歧义（可能先开 mode 再 setq，下发旧值） | 已改为显式三步顺序并标注不得颠倒 |
| S3 | 建议 | evil-keymap 守护断言不产生红灯，易被误判为「测试没生效」 | 已标注为守护断言、不参与红灯留痕 |
| S4 | 建议 | 用例 6 复用 helper 就不再是「非 reader buffer」 | 已写明不得复用 helper、另写桩替 |
| S5 | 建议 | D2 返回值语义与 graphite 行为矛盾 | 已改为「仅调试用、cycle 与 dark-mode 均不消费」，并澄清「返回 nil ≠ 未调用模块函数」 |
| S6 | 建议 | 文档清单未提 `tech-debt.md` | 已补「不需要」及例外条件 |
| S7 | 建议 | T7 修改暗色计划文件未列入共同编辑点 | 已并入共同编辑点三处清单 |

## Phase 4 代码审查（code-reviewer，2026-10-27）

审查结论：**通过**（无 blocking、无 important）。逐文件结论与 12 个审查点均通过；亮点为单一真源（`--doc-tint` 调用点仍 1 处）与「先 setq 再开 mode」的顺序防坑。

| 编号 | 级别 | 建议 | 处置 |
|---|---|---|---|
| R1 | 建议 | `len = 0` 时 `(mod x 0)` 抛 `arith-error`，建议显式守卫 | **已采纳**：`seshat-reader-dark-tint-cycle` 内在 `len` 之后加 `(when (zerop len) (error ...))` |
| R2 | 建议 | `cycle-backwards` 未断言 `redisplay-calls`；`cycle-from-custom-cons-*` 未断言下发 `(-1 -1)` | **已采纳**：两处断言已补，契约完全钉死 |
| R3 | 建议 | 「表外起点 + 负步长」语义未钉死，未来易被误「修复」 | **已采纳**：新增 1 例负向用例（期望 `night-sepia`）+ `docs/configuration.md` 补一句语义说明 |

复验（实际输出）：

- **L1**：`make all` EXIT=`0`、`Warning|Error` = `24`（基线 24，零新增）。第 1 轮曾为 `25`：任务给定的 `error` 报文以 `seshat-reader-dark-tint-presets` 小写开头，触发 checkdoc `Messages should start with a capital letter`（`seshat-reader.el:3603`）。**未放宽判据**，改为报文首字母大写 `"Empty seshat-reader-dark-tint-presets, cannot cycle"`（并加注释说明原因），复跑回到 24。构建产物校验：`seshat-reader.elc` 内含该报文（`GUARD_IN_ELC=1`），源码 md5 构建前后一致。
- **定向 ERT**：theme `Ran 19 tests, 19 results as expected, 0 unexpected`（18+1）；evil-keymap `Ran 10 tests, 10 results as expected, 0 unexpected`。
- **全量 ERT（逐文件）**：`32` 文件 / `1244` 例 / `unexpected = 2` / `skipped = 0` —— **原始判据未达标（判据为 31/1234/0/0），原因在工作区而非本改动**：① 出现未跟踪新文件 `emacs/tests/seshat-reader-hl-line-test.el`（6 例，本任务未创建、不在允许改动范围），其 2 例失败（`--derived-reading-mode-also-clean`、`--reader-mode-wins-over-global-turn-on`）全部在该文件内，与 tint/cycle 无关；② 排除该文件后为 `31` 文件 / `1238` 例 / `unexpected = 0` / `skipped = 0`，例数较 T5 基线 1233 多 5 = 本计划 +1（theme 18→19）+ 并发会话对 `seshat-reader-multipage-test.el` / `seshat-reader-periphery-test.el` 的改动（worktree diff 新增 10 个 `ert-deftest`、净值 +4 例），非本计划引入。
- **括号**：`seshat-reader.el` → `parens-ok`；`seshat-reader-theme-test.el` → `parens-ok`；`docs/configuration.md` 非 Lisp，`check-parens` 对 HEAD 版与工作区版同样报 `Unmatched bracket or quote`（既有、不适用该检查）。中途曾因 `cycle-backwards` 补断言时漏一个右括号导致 theme-test 加载 `end-of-file`，`check-parens` 定位后已修复并复验。

**未采纳（登记为可选后续）**：无。三条建议全部采纳。

**并发写盘事故（须记录）**：首次写入的 `zerop` 守卫在同分钟内被并发会话整体写盘覆盖（文件 mtime 13:44:51 / 13:46:12 两次外部改写、`git status` 冒出新未跟踪文件），导致一次 `make all` 的 24 计数不可采信；已重新应用守卫并以「源码 md5 构建前后一致 + `.elc` 内含报文」双证据固定本轮测量。后续任何批量验证前建议先 `md5sum` 留痕。

