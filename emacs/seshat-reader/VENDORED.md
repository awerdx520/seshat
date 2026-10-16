# VENDORED — seshat-reader 的来源、改名与本地改动说明

本目录原为 **vendor（内嵌复制）** 的 Emacs 文档阅读器源码，已于 2026-10-12 完成**自研化改名**：包内 feature、elisp 符号、文件名、C 模块对 elisp 可见的名字与构建产物一律使用 `seshat-reader-*` / `seshat-render-core`。本文件记录来源、许可边界、改名映射与本地改动。

## 来源

| 项 | 值 |
|---|---|
| 上游项目 | emacs-reader（托管于 Codeberg） |
| 本地来源路径 | `/home/thomas/thomas-emacs/.local/straight/repos/emacs-reader`（straight 管理，现已不再使用） |
| vendored commit | `df3766e8d0409150962671ce4c81e11baff3108b` |
| vendored 日期 | 2026-10-12 |
| 自研化改名日期 | 2026-10-12 |
| 许可 | GNU General Public License v3（见本目录 `COPYING`），各源文件头部版权声明予以保留 |
| 同步策略 | **不再与上游同步**（改名后已无逐文件对照能力；如需参考上游须人工比对并自行建立映射） |

> vendor 时源仓库工作区存在未提交的 PoC 改动，本目录内容复制自**工作区当前内容**而非 commit `df3766e` 的纯净版本。

## 许可边界声明

- 本目录（`notes/emacs/seshat-reader/`）及其全部派生作品受 **GPL-3** 约束，分发与修改须遵守 `COPYING` 中的条款。
- 本目录之外的 notes 仓库其余部分，其许可以各自文件/目录的声明为准，**不受本目录 GPL-3 的影响**。
- 本目录不含任何构建产物；`seshat-render-core.so`、`*.elc`、`*.o` 均按 `.gitignore` 排除，由本地构建生成。

## 改名映射（2026-10-12 自研化）

| 类别 | 上游形态 | 本仓库形态 |
|---|---|---|
| feature | `reader` / `reader-bookmark` / `reader-outline` / `reader-saveplace` | `seshat-reader` / `seshat-reader-bookmark` / `seshat-reader-outline` / `seshat-reader-saveplace` |
| 文件名 | `reader.el` 等 4 个 | `seshat-reader.el` 等 4 个 |
| elisp 符号 | `reader-*` | `seshat-reader-*` |
| major mode | `reader-mode`、`reader-outline-mode`（显示名 "Emacs Reader…"） | `seshat-reader-mode`、`seshat-reader-outline-mode`（显示名 "Seshat Reader…"） |
| C 注册名 | `reader-dyn--*`（15 个） | `seshat-reader-dyn--*` |
| C buffer-local 变量 | `reader-current-doc-*`（4 个）、`reader--recent-pagenumber-fallback` | `seshat-reader-current-doc-*`、`seshat-reader--recent-pagenumber-fallback` |
| C 模块 feature / 产物 | `render-core` / `render-core.so` | `seshat-render-core` / `seshat-render-core.so` |
| 构建文件 | `reader-autoloads.el` | `seshat-reader-autoloads.el` |
| 有意保留未改 | C 源文件名 `render/render-core.c`/`.h`、C 内部函数名（如 `get_reader_current_state`）、上游项目名与版权头 | 同左（对 elisp 不可见；不一致记入 tech-debt） |

## 按文件的本地改动清单（相对上游 commit `df3766e`）

| 文件 | 本地改动 |
|---|---|
| `seshat-reader.el`（原 `reader.el`） | ① 全量改名；② 新增 2 个 PoC 交互命令 `seshat-reader-poc-dump-page-text`、`seshat-reader-poc-text-in-rect`（后者含页号 1-based→0-based 适配与坐标 `float` 转换）；③ 可读性修正：supported-formats 列表中相邻字符串字面量补空格（`"docx""pptx"` → `"docx" "pptx"`） |
| `render/render-core.c` | ① 新增并注册 2 个模块函数 `seshat-reader-dyn--page-text`、`seshat-reader-dyn--text-in-rect`；② NaN 矩形防护；③ 注册名/buffer-local/消息字符串改名 |
| `render/render-core.h` | 上述 2 个模块函数的声明 |
| `render/elisp-helpers.c` | intern/funcall 字符串与注释中的可见名改名 |
| `Makefile`、`.gitignore` | 产物与 autoloads 命名改为新名 |
| 其余文件 | 除改名外与上游 commit `df3766e` 一致 |

## 自研扩展（非 vendored 内容）

| 文件 | 说明 |
|---|---|
| `seshat-reader-select.el` | **本仓库自研扩展**，不属上游 vendored 代码。为 `seshat-reader-mode` 提供鼠标拖拽选区取文：按住 `down-mouse-1` 拖出矩形后取其内文本（仅支持未旋转页面，不产生视觉高亮）。与 vendored 代码的交互点仅 `seshat-reader-mode-map` 的键绑定与模块函数 `seshat-reader-dyn--text-in-rect`，不修改 vendored 文件。evil 环境下 `[down-mouse-1]` 被 evil 的 motion state 遮蔽，需在用户配置侧于 normal state 重绑。**重新复制上游 vendor 时不得被覆盖或删除。** |
| `seshat-reader-annotation.el` | **本仓库自研扩展**：批注采集与侧车同步（鼠标选区 → 建批注 → 服务端 REST；列表/删除/跳页）。依赖顶层 `emacs/seshat-rest.el`，不在本目录内。**重新复制上游 vendor 时不得被覆盖或删除。** |
| `seshat-reader-translate.el` | **本仓库自研扩展**：把鼠标选区桥接到 **go-translate（gt）**，用 posframe 弹出译文/解释；gt 为**软依赖**（未加载时命令给可操作错误）；译文经 render output hook 捕获（按 `gt-result` 文本属性）供「存为批注」使用；不在本目录内依赖任何 Python / 服务端。**重新复制上游 vendor 时不得被覆盖或删除。** |
| `seshat-reader-annotation-queue.el` | **本仓库自研扩展**：批注离线队列（服务不可用时本地暂存、恢复后自动同步；原子写文件；create 幂等去重、delete 404 容忍）；不依赖服务端改动。**重新复制上游 vendor 时不得被覆盖或删除。** |

## 目录内容

- `seshat-reader.el`、`seshat-reader-bookmark.el`、`seshat-reader-outline.el`、`seshat-reader-saveplace.el` — 上游派生的 elisp 源码（已改名）
- `seshat-reader-select.el` — 本仓库自研扩展（鼠标选区取文）
- `render/*.c`、`render/*.h`（含 `emacs-module.h`）— C 模块源码
- `Makefile` — 构建脚本（`make all` 生成 `seshat-render-core.so`、`seshat-reader-autoloads.el` 与 `.elc`）
- `COPYING`、`README.org`、`NEWS`、`CONTRIBUTORS`、`.clang-format` — 上游许可与元数据
- `.gitignore` — 排除构建产物
