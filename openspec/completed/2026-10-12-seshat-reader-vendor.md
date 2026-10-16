# M11.2a 计划：Vendor emacs-reader 源码，本仓库自研 seshat-reader 包

> 归档说明（2026-10-12）：本计划为 M11.2a（vendor + 配置切换）的历史记录。包在此之后完成了自研化改名，文中出现的 `reader-*` 符号名与 `reader.el` 等文件名现为 `seshat-reader-*` / `seshat-reader.el`。

## 当前状态

- 阶段：已完成（归档）
- 已确认：方案 ✅、计划 ✅（用户 2026-10-12 确认）
- 状态：T1–T13 全部完成；源仓库零修改；包内验证 L1/L3 通过
- 后续：包已于同日完成自研化改名（`reader` → `seshat-reader`，见 `openspec/completed/2026-10-12-m11.2c-seshat-reader-rename.md` 或 active 下的同名计划），本计划归档
- 前置：M11.1 PoC ✅ 通过；vendor 已完成（4 个 .el + render/ 11 个源文件 + 构建/许可文件）
- 验证：L1 ✅（`make all` 退出码 0，生成 render-core.so）；L3 ✅（独立 Emacs 进程加载本仓库包，`reader-dyn--page-text 0` 与 `pdftotext -f 1 -l 1` 空白归一化后一致）
- 源仓库：零修改（HEAD 仍为 df3766e，工作区仍恰为原 3 个 M 文件）
- 关联：notes `openspec/active/roadmap.md` 的 M11 / M11.2

## 背景

用户裁决：不再修改第三方仓库（`~/thomas-emacs/.local/straight/repos/emacs-reader`，straight 管理、pin 在 `df3766e`），改为**在本仓库 vendor 其源码**，形成自研 Emacs 阅读器包，替代 emacs-reader 的功能并增加自有功能（文本选择、翻译/LLM 解释、区域框选 OCR、批注侧车）。

M11.1 PoC 已在第三方仓库验证「文本提取 + 矩形取文」可行（含新增 2 个 C 模块函数、页号 1-based/0-based 修复、NaN 矩形防护），这些改动将随 vendor 一并进入本仓库。

**注意**：PoC 改动是源仓库的**未提交工作区修改**（`M reader.el`、`M render/render-core.c`、`M render/render-core.h`），vendor 时必须从**工作区当前内容**提取，否则会静默丢失。

## 目标

1. 把 reader 的 elisp + C 源码与构建脚本复制进 `notes/emacs/seshat-reader/`（含 PoC 改动）；
2. 在本仓库内可独立构建（`make all` 生成 `render-core.so` 与 `.elc`）；
3. 用独立 Emacs 进程验证：能加载新包、打开真实 PDF、文本提取结果与 `pdftotext` 一致；
4. 记录来源与许可，确保合规与可追溯。

## 设计

### 目录结构（本仓库）

```
notes/emacs/seshat-reader/
├── reader.el / reader-bookmark.el / reader-outline.el / reader-saveplace.el   ← vendored（保留原名与 reader-* 符号）
├── render/*.{c,h}          ← vendored（含 PoC 的 2 个新函数 + 修复）
├── Makefile                ← vendored
├── .clang-format           ← vendored（C 代码格式化约定，后续会持续改 C）
├── COPYING                 ← GPL-3（必需）
├── README.org / NEWS / CONTRIBUTORS   ← vendored（保留出处）
├── .gitignore              ← 排除构建产物
└── VENDORED.md             ← 新建：来源、commit、许可边界、按文件的本地改动清单
```

### 命名策略（已裁决）

保留 vendored 代码的 `reader-*` 命名与 `reader` feature 名（避免数百处符号重命名的高风险）；**自研扩展**文件使用 `seshat-reader-*` 前缀（后续里程碑）。

### 搬运清单

| 类别 | 处理 |
|---|---|
| `reader.el`、`reader-bookmark.el`、`reader-outline.el`、`reader-saveplace.el` | 复制（不带 `.elc`）；**从工作区当前内容复制** |
| `render/*.{c,h}`（5 个 `.c` + 6 个 `.h`，含 `emacs-module.h`） | 复制（**不带** `.o`）；**从工作区当前内容复制** |
| `Makefile`、`COPYING`、`README.org`、`NEWS`、`CONTRIBUTORS`、`.clang-format` | 复制 |
| `*.elc`、`render-core.so`、`*.o`、`reader-autoloads.el` | **不复制**（本地重建；实证 `reader.el` 不 require autoloads，`render-core.so` 由 `require 'render-core` 加载） |
| `default.nix`、`manifest.scm`、`test/vm/*`、`extras/*`、`doc/*`、`.dir-locals.el`、`.envrc` | 不复制（与功能无关） |
| `VENDORED.md`、`.gitignore` | 新建 |

包内 `.gitignore` 需与源仓库对齐，至少含：`*.elc`、`*.o`、`*.so`、`*.dylib`、`*.dll`、`reader-autoloads.el`、`*~`。

### 配置切换（后置，需用户确认）

`~/thomas-emacs/lisp/init-reader.el` 现用 `use-package reader` + straight recipe + `versions.lock.el` 锁定。切换到本仓库包需：移除 straight recipe 与 lock 条目，改为 `load-path` 指向 `notes/emacs/seshat-reader/` 后 `(require 'reader)`。**该改动影响用户日常环境，须单独确认后执行。**

## 任务

- [x] T1 记录基线：源仓库 `git -C ~/thomas-emacs/.local/straight/repos/emacs-reader rev-parse HEAD` 与 `status --short`（须显示 PoC 的 3 个 `M` 文件）；`git -C /home/thomas/WorkSpace/notes status --short`；记录 `emacs --version`（依赖：无）
- [x] T2 建目录与忽略规则：创建 `notes/emacs/seshat-reader/render/`，写入包内 `.gitignore`（见「搬运清单」末条）（依赖：T1）
- [x] T3 复制 elisp：4 个 `.el` 从**源工作区当前内容**复制到包根（不得用 `git archive`/`checkout HEAD` 等方式，否则丢失 PoC 改动）（依赖：T2）
- [x] T4 复制 C 源码：`render/` 下 `.c`/`.h` 从**源工作区当前内容**复制（排除 `.o`）（依赖：T2）
- [x] T5 复制构建与许可 + 一致性核对：复制 `Makefile`/`COPYING`/`README.org`/`NEWS`/`CONTRIBUTORS`/`.clang-format`；随后执行 `diff -r <源>/render <包>/render`（排除 `.o` 与构建产物）与 `diff <源>/reader.el <包>/reader.el`，**结果须为空**（证明 PoC 改动已完整带入）（依赖：T3、T4）
- [x] T6 新建 `VENDORED.md`：记录来源仓库路径、commit `df3766e8d0409150962671ce4c81e11baff3108b`、许可、vendored 日期、同步策略（手动）、**许可边界声明**（本目录受 GPL-3 约束，仓库其余部分许可以各自文件为准）、**按文件的本地改动清单**（`reader.el`：2 个 PoC 命令 + 页号适配；`render/render-core.c`/`.h`：2 个新函数 + 页号修复 + NaN 防护）（依赖：T3、T4、T5）
- [x] T7 硬编码路径检查：搜索 vendored 代码中指向 `thomas-emacs`/`straight`/`/home/` 的字符串（预期无命中，仍作防御性检查），结果记入报告（依赖：T3、T4）
- [x] T8 构建验证（L1）：在包目录 `make clean && make all`，要求退出码 0、C 无 error、生成 `render-core.so`；`check-parens` 通过；byte-compile 无 error。**注意 `make all` 隐含 `checkdoc` 目标**（对 4 个 `.el`）：上游既有 checkdoc 告警可容忍（退出码仍为 0），若出现 error 须记录（依赖：T7）
- [x] T9 加载与功能验证（L3）：用独立 `emacs --batch -Q` 进程，`load-path` 指向**本仓库包目录**，`(require 'reader)`，打开 `/home/thomas/WorkSpace/notes/d2l-zh-pytorch.pdf`（**该样本已在 M11.1 实测含文本层**：第 1/3 页与 `pdftotext` 逐字一致）。步骤：① 前置有效性检查 `pdftotext -f 1 -l 1 <pdf> - | head` 须非空；② `(reader-dyn--page-text 0)` 与 `pdftotext -f 1` 对照；③ `(reader-dyn--text-in-rect 0 50.0 100.0 545.0 300.0)` 取文本；④ 全程无崩溃（依赖：T8）
- [x] T10 迁移 PoC 文档：把 `thomas-emacs/openspec/active/2026-10-12-emacs-reader-text-poc.md` 内容复制到 `notes/openspec/active/2026-10-12-m11.1-emacs-reader-text-poc.md`，并在文首加说明「此为 M11.1 PoC 历史记录，文内路径为当时环境；相关代码已 vendor 至 notes/emacs/seshat-reader」；**thomas-emacs 的原件暂不删除**（依赖：无）
- [x] T11 更新路线图：`notes/openspec/active/roadmap.md` 的 M11 小节增加 M11.2 条目并标注状态；M11.1 行的文档引用改指 notes 内新位置（依赖：T10）
- [x] T12 更新 CHANGELOG：`notes/CHANGELOG.md` 记录本包引入（依赖：T9）
- [x] T13（后置，需用户确认）配置切换（✅ 2026-10-12 完成：`thomas-emacs/lisp/init-reader.el` 已改为 `add-to-list load-path` + `(require 'seshat-reader nil t)`）：修改 `~/thomas-emacs/lisp/init-reader.el`，用本仓库包替代 straight 的 reader，并清理 recipe 与 `versions.lock.el` 条目。**执行前须：建立 git 安全点（或备份 `init-reader.el` 与 `versions.lock.el` 原始内容）；回滚 = 用备份恢复两个文件**（依赖：T9）

## 文档清单

| 文档 | 用途 |
|---|---|
| notes/emacs/seshat-reader/VENDORED.md | 来源、许可边界、按文件改动清单 |
| notes/emacs/seshat-reader/README.org | vendored 上游说明（保留） |
| notes/openspec/active/2026-10-12-seshat-reader-vendor.md | 本计划 |
| notes/openspec/active/2026-10-12-m11.1-emacs-reader-text-poc.md | 迁入的 PoC 结论 |
| notes/openspec/active/roadmap.md | M11.2 状态与文档引用更新 |
| notes/CHANGELOG.md | 变更记录 |

## 验证标准

- L1：包目录 `make clean && make all` 退出码 0，C 无 error，生成 `render-core.so`；`reader.el` check-parens 通过；byte-compile 无 error；记录 `emacs --version`
- L2：本轮无自动化测试（vendored 上游无测试套件）——以 L3 替代；后续可在 M11.2b 补 ERT
- L3：独立 Emacs 进程从**本仓库包目录**加载成功，打开 `d2l-zh-pytorch.pdf`，判定口径为：`(reader-dyn--page-text 0)`（0-based）与 `pdftotext -f 1`（1-based）对照，**空白归一化（折叠连续空行、去尾随空白）后逐字一致**（MuPDF 文本块间可能多输出空行，属渲染行为，不计差异）；`(reader-dyn--text-in-rect ...)` 返回非空；全程无崩溃。若样本被判定无文本层（`pdftotext` 输出为空且 reader 返回 `nil`），则判定「样本无效，须换文本型样本重测」而非通过

## 注意事项

- **许可合规**：保留 `COPYING` 与各文件头版权声明；`VENDORED.md` 显式声明**许可边界**（本目录 GPL-3，仓库其余部分不受影响）；notes 仓库根当前无统一 LICENSE
- **PoC 保真**：必须从源**工作区**提取（含未提交改动），并以 T5 的 `diff` 核对为空作为客观证明
- **不改 vendored 逻辑**：除已存在的 PoC 改动外不得新增逻辑改动；所有自研功能放入新文件（`seshat-reader-*`）
- **不搬运构建产物与无关文件**：Nix/Guix 脚手架、VM 测试脚本、logo、开发笔记、构建产物
- **构建依赖**：gcc + MuPDF 开发库（`/usr/include/mupdf`，版本 ≥ 1.26，见 Makefile 的 `REQUIRED_VERSION`）
- **native-comp**：`.eln` 缓存在用户的 eln-cache（如 `~/thomas-emacs/.local/cache/eln-cache/`），**不在包目录**，无需 ignore
- **配置切换风险**：T13 改动用户日常 Emacs 环境，必须单独确认；执行前建立安全点，回滚方式明确
