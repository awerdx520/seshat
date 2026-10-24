# Emacs 阅读器使用手册

> 本文对应 M12 版本（2026-10-22）。适用 Emacs 29.1 及以上，本仓库在 Emacs 31.1 实测。

Emacs 端文档阅读器（`emacs/seshat-reader/`）：MuPDF 负责栅格化、C 动态模块出图、elisp 负责版式与交互，并把**批注 / 译文 / 引用**接到 seshat 服务端。侧车（sidecar）性质——批注不写回 PDF 文件。上游来源、改名映射与本地改动见包内 [`VENDORED.md`](../emacs/seshat-reader/VENDORED.md)，展示层设计见 [`architecture.md`](architecture.md) 的「Emacs 阅读器：展示层与渲染层（M12）」节。

## 1. 能做什么（能力一览表）

| 能力 | 入口 | 说明 |
|---|---|---|
| 打开文档 | `find-file` / `M-x seshat-reader-open-doc` | PDF/EPUB 等格式由 `auto-mode-alist` 关联到 `seshat-reader-mode` |
| 逐页阅读 | `n` / `p` / `SPC` / `M-g g` | 翻页、滚动、跳页、缩放、旋转、适配、演示模式、暗色模式 |
| 目录导航 | `o`（开合） | 左侧目录面板：层级、页码、当前章高亮、TAB 折叠、`f` 单键跳转 |
| 框选取文 | 鼠标 `down-mouse-1` 拖拽 | 松手后取文本并闪现选区矩形 |
| 批注 | `C-c C-a` / `C-c C-l` | 创建、列出、跳页、删除、页面高亮刷新 |
| 翻译/解释 | `C-c C-t` / `C-c C-e` | 依赖 go-translate；结果显示在面板（或 posframe） |
| 跨页衔接 | `seshat-reader-page-join-lines` | 默认关闭的 opt-in 特性 |
| 引用闭环 | `C-c C-r` / `M-x org-store-link` | `seshat:` 链接、摘录写入、`:complete` 补全、`:export` 导出 |
| 离线队列 | 自动 | 服务端不可用时本地暂存批注，恢复后自动同步 |
| 位置记忆 | saveplace / bookmark | 按文件记住页码，重启 Emacs 后可回到原页 |

## 2. 安装与加载

| 依赖 | 版本 / 说明 |
|---|---|
| MuPDF | **≥ 1.26.0**（`Makefile` 的 `REQUIRED_VERSION := 1.26.0`，低于此版本构建直接报错） |
| gcc、make、pkg-config | 构建 C 模块（`render/*.c` → `seshat-render-core.so`） |
| Emacs | 29.1+（`seshat-reader.el` 头部 `Package-Requires` 仍声明 26.1，以实际可用版本为准；31.1 实测） |
| go-translate（gt） | **软依赖**，仅翻译/解释需要，缺失时报错提示安装 |
| markdown-mode、visual-fill-column、avy、evil | **软依赖**，缺失静默降级，不写入 `Package-Requires` |

### straight 方式

本仓库 Thomas 配置（`thomas-emacs/lisp/init-reader.el`）的形态，关键在于 `:pre-build` 让安装期就构建 C 模块：

```elisp
(use-package seshat-reader
  :straight (seshat-reader
             :type git
             :host github
             :repo "awerdx520/seshat"
             :branch "master"
             :files ("emacs/seshat-reader/*" "emacs/seshat-rest.el")
             :pre-build (("make" "-C" "emacs/seshat-reader" "all"))
             :build (:not autoloads compile native-compile))
  :config
  (require 'seshat-rest nil t)
  (require 'seshat-reader-select nil t)
  (require 'seshat-reader-annotation nil t)
  (require 'seshat-reader-sidebar nil t)
  (require 'seshat-reader-reference nil t)
  (require 'seshat-reader-translate nil t))
```

扩展模块的加载顺序有约束：`seshat-reader` 最先；`seshat-reader-sidebar` 紧随其后（零依赖承载层）；`seshat-reader-annotation` 依赖 `seshat-rest`；`seshat-reader-reference` 依赖批注的 `roots` 配置；`seshat-reader-translate` 依赖 `seshat-reader`。

### 手动 load-path + make

```bash
make -C emacs/seshat-reader all      # 产物：seshat-render-core.so、*.elc、seshat-reader-autoloads.el
```

```elisp
(add-to-list 'load-path (expand-file-name "~/Workspace/seshat/emacs"))
(add-to-list 'load-path (expand-file-name "~/Workspace/seshat/emacs/seshat-reader"))
(require 'seshat-reader)
(require 'seshat-reader-annotation)
(require 'seshat-reader-reference)
(require 'seshat-reader-translate)
```

ETAF 渲染层是可选外部依赖：`Makefile` 先探测 `~/Workspace/emacs-taf` / `~/WorkSpace/emacs-taf` 源码树，缺失时回退 straight 的 `build-*` 目录；两者都没有时 `seshat-reader-etaf.el` **不参与 `.elc` 编译**（运行期由 `(require 'seshat-reader-etaf nil t)` 软加载并降级）。可用 `make ETAF_ROOT=/path/to/emacs-taf` 覆盖位置。

### 首次构建 `.so`

模块不存在时加载 `seshat-reader` 会询问 `Build seshat-reader's dynamic module?`，回答 `y` 后走 `seshat-reader-build`（内部执行 `make seshat-render-core<模块后缀>` 并 `compile`）。也可随时手动 `M-x seshat-reader-build` 或 shell 里 `make all`。

**改了 C 必须 `make clean all`**：`make clean` 会清掉 `*.o`、`seshat-render-core.so`、`*.elc` 与 autoloads；只跑 `make all` 时时间戳未变的 `.o` 不会重编，容易出现「改了 C 但行为没变」。

**重要**：Emacs 已运行时替换 `.so` **必须重启 Emacs**。动态模块加载后不能卸载，覆盖磁盘上的 `.so` 不会影响已加载的模块实例；`make all` 顺带重编的 `.elc` 同理只在下次启动（或显式 `unload-feature` + 重新 `require`）后生效。

## 3. 打开与基本阅读

- `find-file` 打开即进 `seshat-reader-mode`：`seshat-reader.el` 加载时按 `seshat-reader-supported-formats` 注册 `auto-mode-alist`（小写扩展名）；`init-reader.el` 另补一套大小写不敏感关联，故 `.PDF` / `.Pdf` 也能直接进阅读器。**注意**：加载项目层 `emacs/seshat-reading.el` 后 `auto-mode-alist` 被 `seshat-reading-mode` 接管（渲染仍 100% 来自 reader），见下节「阅读模式」。
- `M-x seshat-reader-open-doc` 交互式读文件名，候选只含 `seshat-reader-supported-formats` 中的扩展名。
- 打开的瞬间按 `seshat-reader-default-fit` 的初值适配——默认 `contain`（取 `min(按高, 按宽)`，整页可见），可设为 `width` / `height` 让新窗口一开始就按该维度填满；`W` / `H` 在会话内覆盖它，见第 12 节。
- 模式行默认显示 `P<n>/<总页数>`（`seshat-reader-mode-line`）。

> **窗口尺寸变化后自动重贴合**：开关目录（`o`）或批注面板（`C-c C-l`）会改变阅读区宽度，阅读器会在同一次重绘内按当前的**适配模式**（`fit-mode`，见下段；未选择时为 `contain`）把页面缩放到目标几何，并由 idle 阶段补一次清晰化重渲染（几何不变，画面只从模糊变清晰）。用户手动缩放过的窗口（`+` / `-` / `=` / `0`）会保留缩放比例，只归位滚动位置。拖分割线期间不会逐帧重渲染，停手后只重算一次。
>
> **居中位置由 redisplay 在布局时计算**：页面能完整放下时，居中不是 Lisp 算出来的偏移量，而是页面 overlay 上一个 `before-string` 的 `(space :align-to (+ center (-0.5 . IMAGE)))`——`:align-to` 在布局阶段求值，因此窗口变宽变窄的那一帧页面就已经居中，不会出现「先跳到一侧、再居中」的中间帧（旧实现靠 `line-prefix` + `hscroll` 两段补偿，实测窗口变窄后首帧偏 −524px）。页面比窗口宽时改用 `line-prefix` + 横向滚动，左对齐。

> **`W` / `H` 是持久适配模式，不是一次性缩放**：按 `W` 后该窗口的适配模式记为 `width`（载体是 window parameter `fit-mode`，取值 `contain` / `width` / `height`），此后窗口尺寸变化**仍按宽度填满**（纵向溢出靠滚动），不会再被 `contain` 覆盖成按高度；`H` 同理记为 `height`。未显式选择时取 `seshat-reader-default-fit` 的初值 `contain`（整页可见，取 `min(按高, 按宽)`）——首次打开、书签恢复的窗口都按这一初值起步。手动缩放（`=` / `+` / `-` / `0`）会把该窗口标成 manual 且**优先于**适配模式，此后尺寸变化只归位滚动、不再自动适配；再按一次 `W` / `H` 便回到持久适配模式。适配模式按窗口记录、不跨会话保存，重开文档回到 `seshat-reader-default-fit` 的初值（默认 `contain`）。新窗口（含新 frame、书签恢复打开的窗口）的起点由 `seshat-reader-default-fit` 决定——默认 `contain`，可设为 `width` / `height` 让每个新窗口一开始就按该维度适配；该选项不改变已打开窗口，也不改变 `W` / `H` 的会话内语义。

窗口变窄时页面会**缩小**以完整可见，而不是保持原尺寸被两侧裁切。自动 fit 分两段：**首次打开**取 `seshat-reader-default-fit` 的归一化初值（默认 `contain`）；**尺寸变化后**沿用窗口已记录的 `fit-mode`（由首次打开或 `W` / `H` 写入），因此改该选项不影响已打开窗口，只影响此后新开的窗口。旧值 `seshat-reader-fit-to-width` / `-fit-to-height` 仍被接受（分别归一为 `width` / `contain`）。

| 操作 | 键位 | 备注 |
|---|---|---|
| 下一页 / 上一页 | `n` / `p` | 队列化命令，可连续快速按键 |
| 下一屏 / 上一屏 | `C-v` / `M-v` | 屏幕级滚动 |
| 下/上滚一屏到底则翻页 | `SPC` / `DEL`、`S-SPC` | 交替阅读最顺手 |
| 下/上一行则越界翻页 | `C-n` / `C-p` | 同时 remap 了 `next-line` / `previous-line` |
| 跳页 | `M-g g`（或 `M-g M-g`） | 读页码，转 0-based 后交给 MuPDF |
| 首页 / 末页 | `M-<` / `M->` | |
| 放大 / 缩小 | `=`、`+` / `-` | 倍率见 `seshat-reader-enlarge-factor`（1.25）/ `-shrink-factor`（0.75） |
| 缩放滚轮 | `C-<wheel-up>` / `C-<wheel-down>` | |
| 复位缩放 | `0` | |
| 整页适配 / 整宽适配 | `H` / `W` | 持久模式：写入窗口 `fit-mode`，之后尺寸变化仍按该维度适配 |
| 旋转 | `r` / `R` | 顺时针 / 逆时针各 90° |
| 重渲染当前页 | `g` | 用于外部修改或渲染异常 |
| 关闭文档 | `Q` | |
| 演示模式 | `M-x seshat-reader-presentation-mode` | 隐藏模式行并 fit-to-height；无默认键位 |
| 暗色模式 | `M-x seshat-reader-dark-mode` | 反色显示；无默认键位 |

可用格式（取自包内 `README.org` 的 Supported Formats，经 MuPDF）：

| 类别 | 格式 |
|---|---|
| 主要支持 | PDF、EPUB、MOBI、FB2、XPS/OpenXPS、CBZ |
| LibreOffice 系（可读，体验一般） | ODT、ODS、ODP、ODG |
| 微软系（不推荐，仅够查文字） | DOCX、PPTX、XLSX |

上游对 Office 文档的定位是「快速查看文本内容」，不能编辑，排版也不要期望过高。

## 阅读模式：通用阅读 vs Seshat 阅读

`seshat-reader-mode` 是渲染与交互的实现（翻页、目录、缩放、暗色、演示模式，全部由本地动态模块提供），本身**不认识 Seshat 服务端**。`seshat-reading-mode` 派生自它，只叠加「库身份」这一层：

| mode | 用途 | 库身份 | 网络 |
|---|---|---|---|
| `seshat-reading-mode`（默认） | 打开即阅读；库外文档就是通用阅读器 | mode-line 显示 `[库]` / `[未入库]` / `[库外]` / `[状态异常]` | 打开时**零请求**；只有 `M-x seshat-reading-refresh` 会向服务端确认 |
| `seshat-reader-mode`（仍可用） | 纯渲染，无任何 Seshat 痕迹 | 无 | 无 |

`seshat-reading.el` 加载后接管 `auto-mode-alist`（遍历把指向 `seshat-reader-mode` 的项就地改为本 mode），因此**所有受支持格式默认进 `seshat-reading-mode`**。想回到纯 reader：`(add-to-list 'auto-mode-alist '("\\.pdf\\'" . seshat-reader-mode))`（后加载者优先）。

### 库身份四态

| 状态 | 含义 | 显示 |
|---|---|---|
| `library` | 在库根下且状态库有 uid | ` [库]` |
| `unregistered` | 在库根下但本地状态无 uid（服务端可能也没有） | ` [未入库]` |
| `external` | 不在任何 `seshat-sync-roots` 根下 | ` [库外]` |
| `broken` | 状态库损坏（`.bak` 存在且 roots 为空） | ` [状态异常]` |

### 显式入库

库外文档不会自动入库。`M-x seshat-library-add` 会：

1. 让你选目标 `mirror` 根与库内相对路径；
2. **复制**文件到该根（**保留原件**）；
3. 上传（`If-None-Match: *`，仅创建）；同名已存在时询问是否覆盖；
4. 登记 uid 与基线（`base blob` 的 size/mtime 取自**复制后的目标文件**，避免下轮同步误判为本地修改）；
5. mode-line 变为 ` [库]`。

`M-x seshat-reading-refresh` 用于「在根下但本地状态没有 uid」的情况——它是**唯一**会向服务端发请求的阅读路径；服务端确认存在则转 `[库]`。

### 库外文档的批注

**不支持**：`seshat-reader-annotation--uid` 对不在任何根下的文件抛 `user-error`（这是既有行为，本计划未改）。库外文档只会**不再反复打印「降级为 local:」的警告**（`--doc-id` 的可选 QUIET 参数）。「库外本地批注 + 入库后迁移」记在 `openspec/tech-debt.md`。

## 4. 目录与跳转

目录面板由 `seshat-reader-outline` 渲染，显示位置由 `seshat-reader-outline-sidebar-position`（默认 `left`）与 `seshat-reader-outline-sidebar-width`（默认 `0.20`）决定，与右侧信息面板分居两侧。

- 开合：`o`（`seshat-reader-outline-show`，**目录面板开关**——已显示则关闭，未显示则按当前文档大纲重建内容后打开）。`o` 与 `seshat-reader-sidebar-toggle-outline` 语义一致（关闭都走 `seshat-reader-sidebar--toggle-kind`，尺寸记忆与恢复行为相同），区别只在 `o` 会顺带刷新目录内容；后者**不再绑键**（与 `o` 功能重复，用户要求移除），仍可 `M-x seshat-reader-sidebar-toggle-outline` 调用，只动目录、不动右侧批注/译文面板。**光标在目录面板内时，`o` 同样关闭面板**（一次即关；此前绑的是「切回阅读窗口」，需按第二次才关）。
- 行内容：缩进层级 + 折叠符号（`▾` / `▸`，无子节点用 2 空格占位）+ 标题按钮 + 右缘页码；当前章用 `line-prefix` 画竖线标记。
- `p` / `n` 移动光标，`RET` / `M-RET` 跳到该标题所在页，`o` 关闭面板（面板内按一次即关，无需先切回阅读窗口），`q` 关闭面板。
- `TAB` 折叠由 `outline-mode` 自身承载（`outline-hide-subtree`）；注意折叠符号**不随折叠状态刷新**，属已知限制（见 §12）。
- `f` 触发 avy 风格单键跳转（`seshat-reader-outline-avy-jump`）：候选是当前可见区的目录按钮，标签由 overlay `before-string` 承载，`read-key` 逐键匹配。avy 未安装时功能等价——标签字符表退化为内置表（与 `avy-keys` 默认值一致）。
- evil 用户：包内已用 `evil-define-key*` 为 normal state 补绑 `f` / `p` / `n` / `o` / `q` / `RET` / `M-RET`，否则这些键会被 `evil-find-char` / `evil-record-macro` / `evil-ret` 抢走。用的是 auxiliary keymap，只在本 major mode 生效，不污染全局。

其它跳转入口：

| 入口 | 键位 / 命令 | 说明 |
|---|---|---|
| imenu | `seshat-reader-mode-hook` 上的 `imenu-add-menubar-index` | 大纲就是 imenu 索引，可直接选条目跳页 |
| bookmark | `M-x bookmark-set` / `bookmark-jump` | `bookmark-make-record-function` 已设置为 `seshat-reader-bookmark-make-record` |
| 位置记忆 | `save-place-mode` | 经 `save-place-after-find-file-hook` 与 `save-place-to-alist` 的 advice 记录页码，重开文件自动回页 |

## 5. 框选与批注

### 框选取文

`seshat-reader-select` 只绑一个事件：`[down-mouse-1]` → `seshat-reader-select-drag`（`seshat-reader-mode` 与 `special-mode` 都不占用该事件）。拖拽松手后：

- 取矩形内文本，回显区显示截断摘要（上限 200 字符），完整文本存进 `seshat-reader-select-last`；
- 把选区矩形投给 C 渲染层闪现高亮，时长 `seshat-reader-select-flash-duration`（默认 `2.0` 秒，`<= 0` 关闭）；
- `seshat-reader-select-copy-to-kill-ring` 默认 `nil`；设 `t` 才把文本 `kill-new` 进 kill ring。

闪现不受 `seshat-reader-annotation-highlight-enabled` 约束（它是框选反馈，不是批注）。**旋转页上的选区不受支持**：`location` 协议无法表达页面旋转状态，坐标会静默错误。

### 建批注（`C-c C-a`）

- `C-c C-a` = `seshat-reader-annotation-create`：默认用最近一次选区文本；带前缀 `C-u` 时在迷你缓冲区手输正文。
- 运行前置：必须先有鼠标选区，否则 `user-error` 提示先拖选。选中的文本不会被清除，可对同一选区连续建多条批注（有意语义）。
- `document_id`：由 `seshat-reader-annotation-roots`（`("<标签>" . "<根目录>")` alist）决定，形如 `<标签>:<相对路径>`；多根命中取最长匹配；不在任何根下时降级为 `local:<绝对路径>`，并在提示里说明该批注**不跨端共享**。
- `location`：形如 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`，页码 1-based、坐标是**未旋转页面坐标**；`ink:`（手写笔迹）段在本端不解析不渲染。

### 页面高亮

- 高亮由 C 渲染层绘制（`render/render-core.c`），与页面共用同一 `ctm`，因此缩放/旋转自动对齐（旋转页的坐标本身有误，见上）。
- `seshat-reader-annotation-highlight-enabled`（默认 `t`）控制是否绘制；`nil` 时只清空已有矩形并重绘。
- `C-c C-h` = `seshat-reader-annotation-refresh-highlights`：手动刷新（重投当前文档矩形并触发 C 侧 `--refresh-highlights`）。自动刷新只发生在**批注列表拉取/刷新之后**——新建成功后的增量追加、删除后的列表重建都走这条路；**打开文档本身不拉批注，因此不会自动重绘**，需先 `C-c C-l` 一次。
- 高亮颜色与透明度是 C 侧编译期常量（`HIGHLIGHT_COLOR_R/G/B` = 1.0/0.85/0.0、`HIGHLIGHT_ALPHA` = 0.35），elisp 侧不暴露（见 §12）。

### 批注列表（`C-c C-l`）

`C-c C-l` = `seshat-reader-annotation-list`，把当前文档批注渲染到 `*Seshat Annotations*`（走承载层，默认落在右侧 side window）。列表**全量单列连续流**，不分页、无页脚，超出面板高度时滚动面板窗口。

| 键位 | 命令 | 作用 |
|---|---|---|
| `RET` | `seshat-reader-annotation-list-goto` | 跳到该行批注所在页 |
| `d` | `seshat-reader-annotation-list-delete` | 删除该行批注（服务端项走 API，`[待同步]` 项只取消本地条目、不发 HTTP） |
| `C-c C-r` | `seshat-reader-reference-insert-annotation` | 把该行批注的引用写入目标笔记（取值不触网） |
| `q` | `quit-window`（`special-mode`） | 关闭面板 |

列表页头徽章显示总条数；服务端暂时拉不到时**不报错也不清空**，只显示本地待同步条目并提示「（离线）仅显示本地待同步批注 N 条」。这些键不依赖 evil；evil 环境下会被 evil 覆盖，需在配置侧处理。

### 离线队列

服务端不可用时，创建/删除不报错，改为写入本地队列（提示「已存入本地，待联网同步」），批注列表仍显示待同步项并标 `[待同步]`。队列文件、自动同步开关、同步间隔、首次延迟与条目上限见 §10「队列」表。

推进时机：启动后 `initial-delay` 首次 + 每 `sync-interval` 周期 + 手动 `M-x seshat-reader-annotation-queue-sync` + `list` / `create` 成功后的机会性同步。队列文件是 `prin1` 写出的 plist 列表，采用同目录临时文件 + `rename-file` 的**原子写**；读到损坏文件时保留原文件不覆盖并报错。

## 6. 译文与解释

| 键位 | 命令 | 说明 |
|---|---|---|
| `C-c C-t` | `seshat-reader-translate-selection` | 翻译最近一次选区 |
| `C-c C-e` | `seshat-reader-translate-explain-selection` | 解释最近一次选区 |
| `q`（面板内） | `seshat-reader-sidebar-toggle` | 关面板（`seshat-reader-translate-panel-mode` 承载） |
| `C-c C-s`（面板内） | `seshat-reader-translate-save-as-annotation` | 把最近一次译文存为批注 |

- 依赖 go-translate：`seshat-reader-translate-preset`（默认 `reader`）与 `seshat-reader-translate-explain-preset`（默认 `reader-explain`）按名从 `gt-preset-translators` 取用，两个预设需在**用户配置侧**定义；缺失时翻译回退内置 youdao/google，解释需显式配置端点。gt 的中转 buffer `" *Seshat gt*"` 由包隐藏，用户无需改 `display-buffer-alist`。
- 呈现方式由 `seshat-reader-translate-render`（默认 `sidebar`）决定：`sidebar` 写进面板内的**只读 Markdown 文本 buffer**（`gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链，原生折行/滚动/复制/isearch 可用，**不经 ETAF**）；`pop`（posframe 弹出、失焦消失）；`pin`（posframe 常驻）。取 `sidebar` 但 `seshat-reader-sidebar-enabled` 为 `nil` 时退回 `pop` 式 posframe。
- 正文按模板渲染：翻译用 `seshat-reader-translate-template`（默认 `"%l\n\n%q\n\n---\n\n%t\n"`），解释用 `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`）。占位符 `%k` 标题、`%l` 语言对、`%q` 原文引用块、`%t` 正文；模板非法时回退纯正文并 `message` 警告；设 `nil` 表示不套模板。
- `seshat-reader-translate-show-source`（默认 `t`）控制是否在正文前插入选中原文的引用块（不截断）。
- `seshat-reader-translate-visual-fill-column`（默认 `t`）在面板启用 `visual-fill-column-mode`（软依赖，未安装静默跳过）。
- 语言对由 `seshat-reader-translate-fallback-langs`（默认 `(en zh)`）推导，可用命令前缀参数覆盖。

## 7. 跨页衔接

`seshat-reader-page-join-lines` 控制当前页上方的衔接条高度，**单位是页面文本行高**（允许小数），翻页时在当前页 image 上方插入一行显示上一页底部，形成阅读上下文。

| 取值 | 行为 |
|---|---|
| `0`（**默认**） | 完全关闭，翻页行为与 M12 之前一致 |
| `1` 或小数 | 插入对应高度的衔接条；改动在**下次翻页**生效 |

默认关闭的原因不是懒得开：strip 行插在 `point-min` 之前，破坏了页面 overlay 的几何假设（`--set-window-vscroll` 的上限与落点按「strip 高 + 图高」算，而页面 image 并不含 strip），`fit-to-height` 下任何正 vscroll 都会把页顶挤出窗口、造成裁切；缩放/旋转后缓存的上一页 spec 仍是旧尺寸，衔接条比例也会不匹配。详见 §12 与 [`../openspec/tech-debt.md`](../openspec/tech-debt.md)。

衔接条高度还参与垂直滚动上限的计算：`seshat-reader--page-max-vscroll-pixels` 按「图高 + strip 高 − 窗口像素高」夹紧，而窗口尺寸变化时的 `seshat-reader--clamp-window-vscroll` 也走同一上限。因此 strip 开着时缩放或改变窗口尺寸不会把上一页条带挤出窗口（配合默认的 `seshat-reader-page-join-lines` = `0`，默认配置下这条路径不涉及 strip）。

## 8. 引用闭环

链接格式：`seshat:<doc-id>[#<location>]`，例如 `seshat:ebook:d2l-zh-pytorch.pdf#page:112`。`doc-id` 与批注的 `document_id` 同源（`seshat-reader-annotation-roots` 决定），`location` 与批注的 `location` 同构，不新增解析器。**`doc-id` 不得包含 `#` 或 `%`**——含这两个字符时生成链接直接 `user-error` 并提示重命名文件（不做百分号转义）。

| 入口 | 键位 / 命令 | 行为 |
|---|---|---|
| 摘录选区 | `C-c C-r`（`seshat-reader-reference-insert`） | 把选区正文按 `seshat-reader-reference-format` 组块写入目标笔记 |
| 存链接 | `M-x org-store-link` | 把当前文档（含当前页）存为 `seshat:` 链接；笔记里 `C-c C-o` 跳回 |
| 复制链接 | `M-x seshat-reader-reference-copy-link` | 只复制链接串到 kill ring |
| 批注引用 | 批注列表内 `C-c C-r` | 插入该条批注的引用，服务端项与 `[待同步]` 项都支持，取值不触网 |
| 补全 | 笔记里插入 `seshat:` 链接时的 `:complete` | 候选来自 `seshat-reader-annotation-roots` 下的书库文件，当前文档优先 |
| 导出 | org 导出时的 `:export` | 输出「文件名 第 N 页」的可读文本，**不输出裸 `seshat:` 串**（假链接比纯文本更有害） |

`seshat-reader-reference-target-file`（默认 `nil`）：`nil` 时首次交互询问落点文件并在**会话内**记忆；也可设为固定路径（可含 `~`）。

`seshat-reader-reference-insert-position`（默认 `end-of-file`）：

| 取值 | 落点 | 回退条件 |
|---|---|---|
| `end-of-file` | 目标文件末尾（M12 之前的行为） | — |
| `headline` | 当前 headline **子树末尾** | 目标文件无 visiting buffer，或不在 org-mode |
| `point` | 目标文件 visiting buffer 的 `point` 处 | 同上 |

摘录块模板 `seshat-reader-reference-format` 默认 `"#+begin_quote\n%s\n#+end_quote\n来源：[[%s][%s]]\n"`，三个 `%s` 依次是正文、链接、链接描述。

## 9. 完整键位表

### 9.1 阅读（`seshat-reader-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `n` / `p` | `seshat-reader-next-page` / `-previous-page` | 下/上一页 |
| `C-n` / `C-p` | `seshat-reader-scroll-down-or-next-page` / `-scroll-up-or-prev-page` | 下/上一行，越界翻页 |
| `SPC` | `seshat-reader-scroll-down-screen-or-next-page` | 下滚一屏，到底翻页 |
| `DEL` / `S-SPC` | `seshat-reader-scroll-up-screen-or-prev-page` | 上滚一屏，到顶翻页 |
| `C-v` / `M-v` | `seshat-reader-scroll-down-screen` / `-scroll-up-screen` | 下/上滚一屏 |
| `<wheel-up>` / `<wheel-down>` | `seshat-reader-mwheel-scroll-up` / `-down` | 滚轮纵向 |
| `S-<wheel-up>` / `S-<wheel-down>` | `seshat-reader-mwheel-scroll-left` / `-right` | 滚轮横向 |
| `C-f` / `C-b` | `seshat-reader-scroll-right` / `-scroll-left` | 横向滚动 |
| `C-e` / `C-a` | `seshat-reader-scroll-right-most` / `-scroll-left-most` | 横向到右/左缘 |
| `M-<` / `M->` | `seshat-reader-first-page` / `-last-page` | 首页 / 末页 |
| `M-g g`、`M-g M-g` | `seshat-reader-goto-page` | 跳页 |
| `g` | `seshat-reader-refresh-doc-buffer` | 重渲染当前页 |
| `=` / `+` | `seshat-reader-enlarge-size` | 放大 ×1.25 |
| `-` | `seshat-reader-shrink-size` | 缩小 ×0.75 |
| `C-<wheel-up>` / `C-<wheel-down>` | `seshat-reader-mwheel-enlarge-size` / `-shrink-size` | 滚轮缩放 |
| `0` | `seshat-reader-reset-size` | 复位缩放 |
| `H` / `W` | `seshat-reader-fit-to-height` / `-fit-to-width` | 整页 / 整宽适配 |
| `r` / `R` | `seshat-reader-rotate-clockwise` / `-counter-clockwise` | 顺/逆时针 90° |
| `o` | `seshat-reader-outline-show` | 开合目录面板（已显示则关闭，未显示则重建内容后打开） |
| `Q` | `seshat-reader-close-doc` | 关闭文档 |
| `C-c C-a` / `C-c C-l` | `seshat-reader-annotation-create` / `-list` | 建批注 / 批注列表 |
| `C-c C-h` | `seshat-reader-annotation-refresh-highlights` | 刷新页面高亮 |
| `C-c C-r` | `seshat-reader-reference-insert` | 插入选区摘录 |
| `C-c C-t` / `C-c C-e` | `seshat-reader-translate-selection` / `-explain-selection` | 翻译 / 解释 |

另有 `next-line` / `previous-line` / `next` / `prior` / `scroll-up-command` / `scroll-down-command` / `forward-char` / `backward-char` / `beginning-of-buffer` / `end-of-buffer` / `goto-line` / `move-end-of-line` / `move-beginning-of-line` 的 remap，及 6 个鼠标命令 remap 到 `ignore`（防止误移 point 破坏页面边框绘制）。

### 9.2 目录面板（`seshat-reader-outline-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `p` / `n` | `previous-line` / `next-line` | 上下移动 |
| `RET`、`M-RET` | `seshat-reader-outline-visit-page` | 跳到该标题所在页 |
| `f` | `seshat-reader-outline-avy-jump` | avy 风格单键跳转 |
| `o` | `seshat-reader-outline-show` | 关闭面板（面板内按一次即关）；`seshat-reader-outline-select-doc-window` 不再占 `o`，仅供 `RET` 跳页切回阅读窗口 |
| `s` | `seshat-reader-outline-select-doc-window` | 切回阅读窗口（回跳当前文档；`o` 改为面板开合后它换绑到 `s`） |
| `q` | `quit-window` | 关闭面板 |
| `TAB` | `outline-mode` 自身 | 折叠 / 展开子树 |

evil 用户同样可用上述单键（包内 `evil-define-key*` 补绑 normal state 的 `f` / `p` / `n` / `o` / `s` / `q` / `RET` / `M-RET`）。

### 9.3 批注列表（`seshat-reader-annotation-list-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `RET` | `seshat-reader-annotation-list-goto` | 跳到该条批注所在页 |
| `d` | `seshat-reader-annotation-list-delete` | 删除该条批注 |
| `C-c C-r` | `seshat-reader-reference-insert-annotation` | 插入该条批注的引用 |
| `q` | `quit-window` | 关闭面板 |

### 9.4 译文/解释面板（`seshat-reader-translate-panel-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `q` | `seshat-reader-sidebar-toggle` | 关面板 |
| `C-c C-s` | `seshat-reader-translate-save-as-annotation` | 存为批注 |

## 10. 配置速查

### 版式 / 面板

| 变量 | 默认值 | 作用 | 备注 |
|---|---|---|---|
| `seshat-reader-sidebar-enabled` | `t` | 是否用面板展示批注列表与译文 | `nil` 时批注列表退回 `pop-to-buffer`，译文退回 posframe |
| `seshat-reader-sidebar-position` | `right` | 信息栏位置：`right` / `left` / `below-selected` / `at-bottom` | **M12 破坏性变更**（原 `below-selected`）；`left`/`right` 为宽度语义 |
| `seshat-reader-sidebar-width` | `0.24` | 信息栏宽度（小数=frame 比例，整数=列数） | 仅 side 模式；只对新建窗口生效 |
| `seshat-reader-outline-sidebar-position` | `left` | 目录栏位置 | 只作用于 `outline` |
| `seshat-reader-outline-sidebar-width` | `0.20` | 目录栏宽度 | 仅 side 模式 |
| `seshat-reader-sidebar-height` | `0.35` | 面板首次显示的初始高度 | 高度语义；批注列表固定用此值 |
| `seshat-reader-sidebar-min-height` | `0.25` | 译文/解释面板自适应下限 | 仅 `translate` 且未挂 ETAF |
| `seshat-reader-sidebar-max-height` | `0.8` | 自适应上限 | 与 min 共同夹紧；min > max 时以 max 为准 |
| `seshat-reader-sidebar-select-window` | `t` | 面板显示后是否把光标移入面板 | |
| `seshat-reader-sidebar-translate-buffer-name` | `"*Seshat Sidebar*"` | 译文展示 buffer 名 | gt 中转改用隐藏 buffer |
| `seshat-reader-etaf-enabled` | `t` | 批注列表是否用 ETAF 渲染 | 译文/解释不受影响 |

### 阅读

| 变量 | 默认值 | 作用 |
|---|---|---|
| `seshat-reader-enlarge-factor` | `1.25` | 放大倍率 |
| `seshat-reader-shrink-factor` | `0.75` | 缩小倍率 |
| `seshat-reader-default-fit` | `contain` | 新窗口 / 新文档的**初始适配模式**：`contain`（整页可见）/ `width`（填满宽度）/ `height`（填满高度）；`W` / `H` 只覆盖当前窗口且不跨会话；旧值 `seshat-reader-fit-to-width` / `-fit-to-height` 仍被接受（分别归一为 `width` / `contain`） |
| `seshat-reader-page-join-lines` | `0` | 跨页衔接条高度（页面文本行高倍数），`0` 关闭 |

### 批注 / 选区

| 变量 | 默认值 | 作用 |
|---|---|---|
| `seshat-reader-annotation-roots` | `nil` | 书库根映射 alist，决定 `document_id` |
| `seshat-reader-annotation-highlight-enabled` | `t` | 是否绘制批注矩形高亮 |
| `seshat-reader-select-flash-duration` | `2.0` | 框选后闪现选区高亮的秒数，`<= 0` 关闭 |
| `seshat-reader-select-copy-to-kill-ring` | `nil` | 选区文本是否同时进 kill ring |

### 翻译 / 解释

| 变量 | 默认值 | 作用 |
|---|---|---|
| `seshat-reader-translate-preset` | `reader` | 翻译用的 gt 预设名 |
| `seshat-reader-translate-explain-preset` | `reader-explain` | 解释用的 gt 预设名 |
| `seshat-reader-translate-render` | `sidebar` | `sidebar` / `pop` / `pin` |
| `seshat-reader-translate-show-source` | `t` | 是否在正文前插入原文引用块 |
| `seshat-reader-translate-template` | `"%l\n\n%q\n\n---\n\n%t\n"` | 翻译面板模板 |
| `seshat-reader-translate-explain-template` | `"%q\n\n---\n\n%t\n"` | 解释面板模板（不复用翻译模板） |
| `seshat-reader-translate-visual-fill-column` | `t` | 面板启用 `visual-fill-column-mode` |
| `seshat-reader-translate-capture-window` | `120` | 捕获译文的时间窗口（秒） |
| `seshat-reader-translate-fallback-langs` | `(en zh)` | 语言回退 |

### 引用

| 变量 | 默认值 | 作用 |
|---|---|---|
| `seshat-reader-reference-target-file` | `nil` | 摘录落点文件（`nil` = 首次询问、会话内记忆） |
| `seshat-reader-reference-insert-position` | `end-of-file` | `end-of-file` / `headline` / `point` |
| `seshat-reader-reference-format` | `"#+begin_quote\n%s\n#+end_quote\n来源：[[%s][%s]]\n"` | 摘录块模板（正文、链接、描述） |

### 队列

| 变量 | 默认值 | 作用 |
|---|---|---|
| `seshat-reader-annotation-queue-file` | `~/.local/share/seshat/annotation-queue.eld` | 离线队列文件 |
| `seshat-reader-annotation-queue-auto-sync` | `t` | 服务恢复后自动推进 |
| `seshat-reader-annotation-queue-sync-interval` | `300` | 周期同步间隔（秒） |
| `seshat-reader-annotation-queue-initial-delay` | `10` | 首次自动同步延迟（秒） |
| `seshat-reader-annotation-queue-max-entries` | `1000` | 队列条目上限 |

> 服务端侧的 REST 地址与令牌（`seshat-rest-base-url` / `seshat-rest-token`）见 [`configuration.md`](configuration.md) 的「Emacs 客户端配置（批注侧车）」节；令牌只从环境变量 `SESHAT_AUTH_TOKEN` 读取，禁止写入配置文件。

## 11. 常见问题与排查

**目录里的中文显示成 `\346\226\207` 这种转义**

旧版本把大纲标题当 unibyte 字符串处理导致的乱码。确认是否已修：随便打开一本中文目录的 PDF，按 `o` 打开目录面板（已打开时再按一次为关闭）后看标题是否为正常汉字；或 `M-: (multibyte-string-p (plist-get (car seshat-reader-current-doc-outline) :title))` 应为 `t`（大纲是 `(:title STR :page N [:children ...])` 的 plist 列表，页号 0-based）。仍乱码说明加载的是旧 `.elc`——`make clean all` 后重启 Emacs。

**页面不居中 / 只显示页面一部分**

M12 回归（strip 行破坏页面几何 + `--center-page` 在 `window-size-change-functions` 里拿到 frame 而非 window）已修。确认加载的是新代码：`(boundp 'seshat-reader--window-size-change)` 应为 `t`；再看 `seshat-reader-page-join-lines` 是否为 `0`（非 0 时 `fit-to-height` 下仍可能裁切，见 §12）。窗口尺寸变化后仍不居中，先 `g` 重渲染，再 `H` 重新适配。

**框选没反应 / 建了批注但页面上没高亮**

按顺序排查：

1. `(key-binding [down-mouse-1])` 应为 `seshat-reader-select-drag`；若为 nil，说明 `seshat-reader-select` 未加载（`(featurep 'seshat-reader-select)`）。
2. 高亮链路是否需要重启：`(fboundp 'seshat-reader-dyn--add-highlight)` 应为 `t`——为 nil 表示加载的 `.so` 太旧，重新 `make all` 并**重启 Emacs**。
3. `seshat-reader-annotation-highlight-enabled` 是否为 `t`。
4. 批注数据是否真的拉到过：`C-c C-l` 打开列表，看目标批注是否在列表里（矩形是从列表项投给 C 层的）。
5. 仍无高亮就 `C-c C-h` 手动刷新；再不行 `g` 重渲染当前页。

**目录面板里 `f` 变成 `evil-find-char`**

包内已用 `evil-define-key*` 补绑；若仍旧行为，说明加载的是本次补绑之前的版本——重启 Emacs。自定义配置里不必再补绑，除非你用 `evil-define-key` 覆盖了同一 state。

**退出 PDF 后目录面板还留着**

已修（`kill-buffer-hook` 上挂全局回调，关文档时关闭并清空面板）。仍复现则检查是否有其它包把该面板窗口固定（`window-parameters` 的 `no-delete-other-windows` 等），或面板是不受本钩子管理的手工切分窗口。

**ETAF 在终端 frame 挂起**

既有已知问题：pty / `emacs -nw` 下 `etaf-mount` 可能挂起，GUI frame 正常。建议 GUI 使用，或在终端里 `(setq seshat-reader-etaf-enabled nil)`。

**headless / daemon 下哪些功能不可用**

| 功能 | daemon / headless 表现 |
|---|---|
| 高亮重绘 | 依赖真实窗口与 `window-text-pixel-size`，无窗口时不生效（守护进程里的 frame 尚未创建） |
| posframe（`translate-render` 取 `pop` / `pin`） | 需要可见 frame，通常不可用 |
| ETAF 渲染 | 见上一条，终端/无 frame 下可能挂起 |
| 批注、引用、队列、翻译文本 | 与窗口无关，功能正常 |

## 12. 已知限制

以下条目全部出自 [`../openspec/tech-debt.md`](../openspec/tech-debt.md)，如实列出，未做美化。

1. **旋转页的高亮可能错位**：选区采集明确不支持旋转页，`rect` 是未旋转页面坐标而 C 侧按含 `rotate` 的 `ctm` 绘制，两者对同一 `rect` 解释不一致。
2. **`ink:` 段不显示**：手写笔迹只解析 `rect:`，移动端用笔标注的批注在桌面只看到列表摘要。
3. **高亮颜色与透明度不可配**：颜色/alpha 是 C 侧编译期常量，只有总开关。
4. **多窗口下高亮刷新与 strip 缓存有局限**：`C-c C-h` 只重建当前窗口的 ±5 页缓存；strip 的上一页 spec 缓存是 buffer 级、按当前选中窗口记录页号。
5. **目录折叠符号不与 `TAB` 联动**：行模型的 `collapsed` 集合恒传 `nil`，`TAB` 折叠后符号仍停在 `▾`（折叠本身有效，只是符号不刷新）。
6. **大纲页号乱序时当前章标记可能错**：`--current-path` 隐含「页号单调不减」的假设，乱序目录下标记会指错节点（跳转本身正确）。
7. **面板高度只在新建窗口时生效**：改 `seshat-reader-sidebar-height` 不会让已显示面板重排；译文/解释重新执行即按内容自适应，批注列表需关闭再打开；per-kind 尺寸仅会话内记忆，重启 Emacs 回到默认值。
8. **缩放/旋转后 strip 的上一页 spec 是旧尺寸**：不清空 `seshat-reader--page-image-specs`，衔接条比例与新页不匹配；设 `page-join-lines` 为 0 可规避。
9. **`page-join-lines` 非 0 时 `fit-to-height` 可能裁切页面**：strip 插在 `point-min` 前破坏页面几何，这是默认值取 0 的原因。
10. **ETAF 只用内置双色板**：不读用户主题变量，切换明暗主题后需重新打开面板；终端 frame 下可能挂起。
11. **批注列表全量渲染无虚拟化**：条目数很大（数百条以上）时首次渲染成本线性增长。
12. **底部单窗口模式下批注与译文互斥**：`below-selected` / `at-bottom` 仍是单窗口「后显示者接管」（M11 语义，非缺陷）。
13. **`doc-id` 含 `#` 或 `%` 的文件无法引用**：生成链接直接 `user-error`，需重命名文件。
14. **EPUB 的 `location` 语义未定**：页码协议对 EPUB 只做到粗粒度定位。
15. **队列写是无锁 read-modify-write**：多 Emacs 实例共享同一队列文件时存在丢更新风险。
16. **页面比窗口宽时只能手动左右滚动**：手动放大到超出窗口（`+` / `=` / `W`）后不会自动跟随翻页，需 `S-<wheel>` 或 `scroll-left` / `scroll-right` 自己看；`unconstrained` 路径的下界夹紧也未实现（见 tech-debt 的「`--center-page` 以 `unconstrained` 设 hscroll」与「`--set-window-vscroll` 缺下界夹紧」两条）。
17. **`W` / `H` 的选择不跨会话**：该选择记在窗口参数 `fit-mode` 上，窗口关闭或重开 Emacs 后新窗口回到 `seshat-reader-default-fit` 的初值（默认 `contain`）。要让新窗口默认按宽 / 按高，把该选项设为 `width` / `height`；在这两种模式下页面必然在另一维溢出、需滚动查看——这是「填满一维」的固有代价，不是缺陷。旧值 `seshat-reader-fit-to-width` / `-fit-to-height` 仍被接受（分别归一为 `width` / `contain`）。
18. **手动缩放的来源不随书签保存**：书签只存 `scale` 数值、不存 `fit` / `manual` 来源，恢复后按 `fit` 处理——一旦窗口尺寸变化就会重新贴合，上次手选的比例可能被重置。
19. **同一文档重设到同一窗口时页面可能贴右边缘**：用 `set-window-buffer` 把**同一条文档**重新指给同一个窗口（而非新窗口 / 新 frame）时，Emacs 同样归零 hscroll 但不触发 `window-buffer-change-functions`，兜底 recentre 覆盖不到；需重开文档或触发一次尺寸变化（见 tech-debt）。
20. **尺寸变化期间的画面是位图插值缩放，清晰化有延迟**：几何在同一帧内到位（改的是 image spec 的 `:width` / `:height`，不是位图），清晰度靠 idle 阶段重渲染一次补齐，因此缩放后约 0.15 秒内页面是「正确尺寸 + 略模糊」，拖分割线过程中始终是缩放位图。只读表格等细线条内容时观感差异明显（见 tech-debt「位图缩放与 `image-flush` 的交互未在真机长时间验证」）。
21. **反复缩放会让旧尺寸的位图滞留在 image cache**：cache 以 spec 内容（含 `:width` / `:height`）为键，改写尺寸后旧键条目到 `image-cache-eviction-delay`（默认 300s）才回收；拖分割线可在数秒内造出几十个 A4 级条目。已在改写前 `image-flush` 缓解，长时间拖拽的峰值内存仍缺真机观测（见 tech-debt「image cache 条目累积」）。
22. **manual 窗口在极端情形下会多一次重渲染**：`--refit-window` 的清晰度闸（比较已渲染分辨率 `render-scale` 与目标 `scale`）写在 `unless manual` 守卫之外；manual 窗口正常不改 `scale`、两者恒相等故不触发，但若将来 manual 路径写入不同值，会出现一次隐蔽的额外重渲染（见 tech-debt「image cache 条目累积」的附记）。
23. **居中机制两套并存**：页面能完整放下时由 redisplay 求值居中（`before-string` + `:align-to`）；页面比窗口宽时仍走旧的 `line-prefix` + 横向滚动，只能**左对齐**、不居中。两套机制由 `--center-page` 的几何判定选择，`--centered-p` 与它各有判据（见 tech-debt）。
24. **跨页衔接 strip 与新的居中方式未验证**：strip 行靠 center overlay 的 `line-prefix` 获得缩进，而「页面放得下」的分支会主动清空该 prefix；`page-join-lines` 默认 `0`（关闭）因此默认配置不受影响，一旦开启 strip 可能比页面左移半个余量（见 tech-debt）。
25. **首次打开的首帧位图是显示层缩放**：`--first-fit` 先把 image spec 改到最终几何（不重渲染），在 idle 重渲染前位图是插值放大的旧分辨率——表现为「尺寸一开始就正确、但略模糊，约 0.15 秒后转清晰」，不再有原先的「先小后大」两次变化。

## 13. 开发者备注

### 目录结构

| 文件 | 职责 |
|---|---|
| `seshat-reader.el` | major mode、键位表、翻页/滚动/缩放/旋转/适配、页面 overlay 与几何、跨页 strip、C 模块加载与构建 |
| `seshat-reader-select.el` | 鼠标框选取文 + 选区闪现 |
| `seshat-reader-annotation.el` | 批注 CRUD、`document_id` / `location` 解析、页面高亮投喂、批注列表 |
| `seshat-reader-annotation-queue.el` | 离线队列（读写、原子写、定时同步） |
| `seshat-reader-sidebar.el` | 面板承载层（零依赖：位置、宽度/高度、slot、per-kind 尺寸记忆） |
| `seshat-reader-outline.el` | 目录面板：行模型、渲染、avy 跳转、evil 补绑、关文档清理 |
| `seshat-reader-translate.el` | 翻译/解释：gt 预设取用、面板 Markdown 渲染、存为批注 |
| `seshat-reader-reference.el` | `seshat:` 协议（`:follow` / `:store` / `:complete` / `:export`）、摘录写入 |
| `seshat-reader-etaf.el` | 批注列表的可选 ETAF 渲染层（硬依赖 `etaf-ui`，缺失则不编译） |
| `seshat-reader-saveplace.el` | saveplace 集成（`save-place-after-find-file-hook` + `save-place-to-alist` advice） |
| `seshat-reader-bookmark.el` | bookmark 记录与跳转 |
| `render/render-core.c` | 模块入口、页面栅格化、`ctm`、高亮绘制、缓存与窗口状态 |
| `render/render-threads.c` / `.h` | 渲染线程池、job 提交与缓存页生命周期 |
| `render/render-theme.c` / `.h` | 反色 / gamma 等整页像素变换 |
| `render/mupdf-helpers.c` / `.h` | MuPDF 文档与页面封装 |
| `render/elisp-helpers.c` / `.h` | emacs-module 参数编解码辅助 |

### 构建与测试

```bash
make -C emacs/seshat-reader all       # .so + .elc + autoloads + checkdoc
make -C emacs/seshat-reader clean all # 改 C 之后必须
```

ERT 套件在**顶层** `emacs/tests/`（不在包目录内），`load-path` 至少要含两个目录，涉及 gt 的用例还需 gt / pdd / posframe 的 straight build 目录，否则相关用例被 `ert-skip` 跳过：

```bash
cd /home/thomas/Workspace/seshat && \
"emacs" --batch -Q \
  -L "emacs" -L "emacs"/seshat-reader \
  -L /home/thomas/thomas-emacs/.local/straight/build-31.1/gt \
  -L /home/thomas/thomas-emacs/.local/straight/build-31.1/pdd \
  -L /home/thomas/thomas-emacs/.local/straight/build-31.1/posframe \
  -l "emacs"/tests/seshat-reader-sidebar-test.el \
  -f ert-run-tests-batch-and-exit
```

换机器或 Emacs 版本时先探测实际父目录：

```bash
GTROOT=$(dirname "$(find "$HOME" -maxdepth 6 -type d \
         -path '*/straight/build-*/gt' 2>/dev/null | head -n1)")
echo "$GTROOT"
```

现有套件：`seshat-reader-page-join-test.el`、`seshat-reader-sidebar-test.el`、`seshat-reader-outline-test.el`、`seshat-reader-annotation-test.el`、`seshat-reader-annotation-queue-test.el`、`seshat-reader-annotation-v8-test.el`、`seshat-reader-select-flash-test.el`、`seshat-reader-translate-test.el`、`seshat-reader-reference-test.el`、`seshat-reader-resize-test.el`、`seshat-reader-etaf-test.el`、`seshat-rest-test.el`、`seshat-state-test.el`、`seshat-transport-test.el`、`seshat-conflict-test.el`（10 例）、`seshat-merge-test.el`（13 例）、`seshat-sync-cmd-test.el`（14 例）、`seshat-sync-test.el`（77 例）、`seshat-reading-test.el`（32 例）。**前置**：`seshat-render-core.so` 已构建，否则加载 `seshat-reader` 会触发交互式构建询问并阻塞 batch 运行。

**必须逐文件运行**：一次 `emacs --batch` 加载全部测试文件时，`seshat-reader-annotation-test.el` 与 `seshat-reader-annotation-queue-test.el` 各有 3 个列表渲染用例会失败——同时加载 `etaf` 测试后 `etaf-ui` 变为可用，批注列表改走 EBOX/ETAF 渲染，而那两个用例断言的是纯文本（如 `"没有批注"`）。这是**既有基线特性、不是回归**：全仓用例总数按逐文件求和计（当前 19 个文件合计 **669** 例，0 unexpected / 0 skipped）。跑全仓脚本见下（`for` 循环逐文件执行，任一文件非零退出即整体失败）：

```bash
cd /home/thomas/Workspace/seshat && rm -f emacs/seshat-reader/*.elc && \
L="-L emacs -L emacs/seshat-reader"; \
for d in gt pdd posframe etaf etaf/lisp etaf-ui ebox ebox/lisp ecss ecss/lisp \
         markdown-mode visual-fill-column; do \
  L="$L -L /home/thomas/thomas-emacs/.local/straight/build-31.1/$d"; done; \
for f in emacs/tests/*-test.el; do \
  emacs --batch -Q $L -l "$f" -f ert-run-tests-batch-and-exit || exit 1; done
```

### 改 C 的纪律

- 本目录是 vendored + 自研化改名的代码：任何 C 侧改动都必须在该文件「按文件的本地改动清单」中登记，否则下次对照上游时改动会丢失依据。
- 渲染层的不变量（高亮在反色/gamma **之后**、写 PNM **之前**绘制；`rect_to_page_space` 是唯一坐标换算点；高亮表在派发时快照进 `DrawThreadArgs`）改动前先读 [`architecture.md`](architecture.md) 对应小节。
- 高亮条数 100000、坐标 ±1e6 点、outline 标题 8192 字节、批注 `location` 64 KB / 2000 段 `rect:` 是防御上限，不要随手放宽。
