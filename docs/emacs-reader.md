# Emacs 阅读器使用手册

> 本文对应 M12 版本（2026-10-22），并在 2026-10-25 补入跨页文本搜索（`C-s`）与手写轨迹（`ink:`）显示。适用 Emacs 29.1 及以上，本仓库在 Emacs 31.1 实测。

Emacs 端文档阅读器（`emacs/seshat-reader/`）：MuPDF 负责栅格化、C 动态模块出图、elisp 负责版式与交互，并把**批注 / 译文 / 引用**接到 seshat 服务端。侧车（sidecar）性质——批注不写回 PDF 文件。上游来源、改名映射与本地改动见包内 [`VENDORED.md`](../emacs/seshat-reader/VENDORED.md)，展示层设计见 [`architecture.md`](architecture.md) 的「Emacs 阅读器：展示层与渲染层（M12）」节。

## 1. 能做什么（能力一览表）

| 能力 | 入口 | 说明 |
|---|---|---|
| 打开文档 | `find-file` / `M-x seshat-reader-open-doc` | PDF/EPUB 等格式由 `auto-mode-alist` 关联到 `seshat-reader-mode` |
| 逐页阅读 | `n` / `p` / `SPC` / `M-g g` | 翻页、滚动、跳页、缩放、旋转、适配、演示模式、暗色模式 |
| 目录导航 | `o`（开合） | 左侧目录面板：层级、页码、当前章高亮、TAB 折叠、`f` 单键跳转；再按一次 `o` 关闭 |
| 框选取文 | 鼠标 `down-mouse-1` 拖拽 | 松手后取文本并闪现选区矩形 |
| 批注 | `C-c C-a` / `C-c C-l` | 创建、列表开合（已显示则关）、跳页、删除、页面高亮刷新 |
| 跨页文本搜索 | `C-s`（会话内 `n` / `p` / `RET` / `C-g`；左侧结果侧栏内 `RET` / `n` / `p` / `q`） | 整本扫描、跨页跳转与回绕、命中以橙色装饰投喂，同时列进左侧搜索结果侧栏 |
| 手写轨迹显示 | 自动（`seshat-reader-annotation-ink-enabled`） | 把 Android 手写批注的 `ink:` 段渲染为页面笔迹（只显示，不输入） |
| 翻译/解释 | `C-c C-t` / `C-c C-e` | 依赖 go-translate；结果显示在面板（或 posframe）。同一组键是**开合**，且与语境一一对应：面板里显示的就是**译文**时 `C-c C-t` 关闭、否则翻译并替换内容；显示的是**解释**时 `C-c C-e` 关闭、否则解释并替换内容（不抢光标） |
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
  (require 'seshat-reader-translate nil t)
  (require 'seshat-reader-help nil t))
```

扩展模块的加载顺序有约束：`seshat-reader` 最先；`seshat-reader-sidebar` 紧随其后（零依赖承载层）；`seshat-reader-annotation` 依赖 `seshat-rest`；`seshat-reader-reference` 依赖批注的 `roots` 配置；`seshat-reader-translate` 依赖 `seshat-reader`。`seshat-reader-help`（`?` 帮助页）零依赖、可放最后，也可以**不 require**：`?` 已写进 `seshat-reader-mode-map`，而 `seshat-reader-help` 自带 `;;;###autoload`，第一次按 `?` 时由 autoload 懒加载（上面显式 require 只为把帮助页提前加载好，幂等无害）。

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
(require 'seshat-reader-help)
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
- 模式行显示 `[当前页/总页]`：原生 modeline 走 `mode-line-position`（`P<n>/<总页数>`）；doom-modeline 这类**整体接管 `mode-line-format`** 的第三方 modeline 不读 `mode-line-position`，故同一页码同时以 `:eval` 元素挂到 `mode-line-misc-info`（`seshat-reader--page-mode-line` → `seshat-reader--page-indicator`，跟随 redisplay 求值，无需重建 modeline；doom-modeline 的 misc-info segment 会 `format-mode-line` 它）。文档尚未加载完时该项显示 `[?/?]`，不报错、不阻塞 redisplay。同时在阅读 buffer 内**隐藏 doom-modeline 的行列段**——整页只有一行，`1:0` 恒无信息量，`seshat-reader-mode-line` 会把 `doom-modeline-position-column-line-format` / `-line-format` / `-column-format` 在本 buffer 设为 `("")`（`boundp` 守卫，非 doom-modeline 环境零副作用；不用 `nil`，因为该段会 `(car …)` 后 `string-replace`）。

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

- 取矩形内文本，**回显区只报行列数**——`seshat-reader-select-copy-to-kill-ring` 非 nil 时 `已复制 N 行 · M 字`，取 `nil` 时 `已选中 N 行 · M 字`；**不再回显正文**（回显正文既干扰阅读，也会把选中内容留在 `*Messages*` 里）。完整文本存进 `seshat-reader-select-last`；
- 把选区矩形投给 C 渲染层闪现高亮，时长 `seshat-reader-select-flash-duration`（默认 `2.0` 秒，`<= 0` 关闭）；
- `seshat-reader-select-copy-to-kill-ring` 默认 `nil`；设 `t` 才把文本 `kill-new` 进 kill ring（回显措辞同时由「已选中」变为「已复制」）。

**字级高亮（框选贴合文字，而不是一个大方块）**：选区几何由 `seshat-reader-select-highlight-scope` 决定取哪一段文字，再由 elisp 侧的纯函数整理成可画的横条。

- `seshat-reader-select-highlight-scope`（默认 `line`）：**整行吸附**。框只要碰到某一行（该行有任一字符的 quad 与框相交），该行**全部**文字都高亮——C 模块的 `--lines-in-rect` 返回**每行一条**矩形（该行字符 quad 的并集，阅读顺序）。窄框（只覆盖行中间几个字）因此会得到整行宽度：实测 `d2l-zh-pytorch.pdf` page 100 用 `(200,70)-(300,110)` 框 vs 同一框的整行吸附，x 范围从 **197.5–300.6**（23 个字符 quad）变成 **73.1–493.4**（1 条整行矩形），y 范围完全一致（96.2–105.2）。整行矩形**不再**经过「按行合并」这一步（它本来就是整行，合并只会把相邻两行连起来），但**垂直收缩照旧生效**。
  设成 `region` 则回到旧行为：只高亮框内的字符（`--rects-in-rect` + 按行合并），适合要精确到字的场合。老版本动态模块没有 `--lines-in-rect` 时 `line` 会**静默回落**到 `region`，不报错。
  **双栏不会被互相污染**：MuPDF 的 stext 把左右栏拆成不同的 line，判据是「**这一行自己**有字符被框碰到」，所以框只碰左栏时右栏的行不会出现在结果里。实测 `d2l-zh-pytorch.pdf` page 781 页脚：左侧行 `x 72.0–158.2` 与右侧页码 `x 524.2–540.0` 同 y（742.7 / 744.0），窄框 `(60,738)-(200,758)` 只返回左侧那 1 条，右侧页码未出现。
- `seshat-reader-select-highlight-granularity`（默认 `line`）：**仅 `region` 作用域生效**。`line` = 按行合并（y 重叠聚成行 → 行内按 x 排序 → 相邻字符水平间隙小于阈值才连成一条）；`character` = 逐字符矩形，不合并。整行吸附给出的矩形本身就是整行，不会被拆开。
- `seshat-reader-select-highlight-gap-ratio`（默认 `0.8`）：把「水平间隙 / 行高」的比值作断点，超过就断开，双栏排版因此不会被一条横条横穿（`region` 作用域）。中文正文实测约 **3.4 段/行**（字间空隙比西文大）；想让高亮更连贯可上调（如 `1.2`），想更贴字可下调。
- `seshat-reader-select-highlight-shrink-ratio`（默认 `0.8`，`1.0` = 关闭）：字符 quad 的高度（实测 ≈11.7pt）大于行距（≈10.3pt），不收缩时相邻两行的横条垂直重叠（重叠量 = quad 高 − 行距，实测 ≈1.4pt），8 条拼起来视觉上仍是一整块。该比值在合并之后**围绕每条矩形自己的垂直中心**把高度乘以它（实测 `0.8` 留出 ≈0.94pt 白缝），只影响**垂直高度**：水平范围、`seshat-reader-select-last` 的 `:rect`（整体拖拽 bbox）、写入 `location` 的段数与 x 范围都不变，**`line` / `region` 两种作用域都生效**。
有效范围 `0.3`–`1.0`，越界夹紧（`0.1`→`0.3`、`2.0`→`1.0`），非数字回落 `0.8`。
- 选区结果写进 `seshat-reader-select-last`：`:rects` 是合并后的**多段**矩形（字级高亮与批注锚的几何真值），`:rect` 保留整体 bbox 以兼容既有消费方。
- 多段矩形经 `seshat-reader-annotation--anchor` 写成**多段 location**（`page:<n>;rect:…;rect:…`），写入端上限 **500 段**（`seshat-reader-annotation--anchor-max-segments`）；解析端上限 2000 段（`seshat-reader-annotation--rect-max-segments`）。`character` 粒度下逐字符矩形可达数千条，会撞 500 段上限——此时**只写前 500 段**（页面下部因此没有高亮）并提示一次，见 §12。
- 闪现与批注高亮共用一套投喂（一次 clear → 逐条 add → 一次 refresh），短语义见下节。

闪现不受 `seshat-reader-annotation-highlight-enabled` 约束（它是框选反馈，不是批注）。**旋转页上的选区不受支持**：`location` 协议无法表达页面旋转状态，坐标会静默错误。

### 建批注（`C-c C-a`）

- `C-c C-a` = `seshat-reader-annotation-create`：默认用最近一次选区文本建**标记类**批注；带前缀 `C-u` 时先在迷你缓冲区读备注、再建**便签**。
- 运行前置：必须先有鼠标选区，否则 `user-error` 提示先拖选。选中的文本不会被清除，可对同一选区连续建多条批注（有意语义）。
- **两个正交维度**：`kind` 只表**类型**，「有无备注」由 `text` 空 / 非空表达，「选中的是哪段原文」由 `selected_text` 表达——**加备注不改 `kind`**。

| 调用方式 | `kind` | `text` | `selected_text` |
|---|---|---|---|
| `C-c C-a`（无前缀） | `highlight` | `""`（空串 = 无备注） | 选区原文 |
| `C-u C-c C-a` + 输入备注 | `note` | 备注正文 | 选区原文 |
| 选区无文本且未输入备注 | —（`user-error`，不建批注） | — | — |

- **列表标题的回退链不变**：`seshat-reader-annotation--display-text` 仍是 `text → selected_text → ink 聚合`。`highlight` 条目 `text` 为空，标题因此直接显示选区原文（不是空白行）。
- **离线队列**：create 条目携带 `:kind` 与 `:selected-text`，重放时原样带上；客户端去重键仍是 `(kind, location, text)`（`selected_text` 不参与），未改。
- **本端没有编辑批注的路径**：`seshat-rest-update-annotation` 的唯一调用者是测试，Emacs 不能修改已有批注的正文或类型（只能删除后重建）。将来接入编辑时必须显式带上原 `kind`——`UpdateAnnotationAt` 会把空 `kind` 兜底成 `note`，不带原 `kind` 的「高亮加备注」会被降级成便签。
- `document_id`：由 `seshat-reader-annotation-roots`（`("<标签>" . "<根目录>")` alist）决定，形如 `<标签>:<相对路径>`；多根命中取最长匹配；不在任何根下时降级为 `local:<绝对路径>`，并在提示里说明该批注**不跨端共享**。
- `location`：由 `seshat-reader-annotation--anchor`（**页锚 + 可选几何尾段**）构造，形如 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`——**页锚** `page:<n>` 是唯一的跳转真值（1-based 页码），`;rect:` 是**可选几何尾段**、只供渲染，坐标是**未旋转页面坐标**；`ink:`（手写笔迹）段**本端只解析不产出**（Android 才有笔事件），显示见 §5「手写轨迹显示」。函数名 2026-10-25 由 `--location` 改为 `--anchor`：它返回的是「锚」而非「location 串的通用构造器」，语义更窄也更准确（守 `location` 长度上限的 defconst `seshat-reader-annotation--location-max-length` **刻意保留原名**，它守的是 API 字段 `location`）。

### 页面高亮与装饰

高亮/下划线/删除线都由 C 渲染层的**装饰表**（`render/render-core.c`）绘制，与页面共用同一 `ctm`，因此缩放/旋转自动对齐（旋转页的坐标本身有误，见上）。

- `seshat-reader-annotation-highlight-enabled`（默认 `t`）控制是否绘制批注装饰；`nil` 时只清空已有装饰并重绘。
- `C-c C-h` = `seshat-reader-annotation-refresh-highlights`：手动刷新（重投当前文档矩形并触发 C 侧 `--refresh-highlights`）。自动刷新只发生在**批注列表拉取/刷新之后**——新建成功后的增量追加、删除后的列表重建都走这条路；**打开文档本身不拉批注，因此不会自动重绘**，需先 `C-c C-l` 一次。
- **装饰表两类几何**：`rect`（填充矩形，用于高亮与下划线/删除线细条）与 `stroke`（折线，预留给手写轨迹，elisp 侧尚未使用）。每条装饰带 RGB + alpha；rect 按颜色**分组**进同一 path 一次性填充，因此「同色重叠**不叠深**」（多段高亮叠在一起仍是一个透明度）。
- **装饰只是增强**：模块缺失（或加载的是缺 `--add-decoration` 的旧版）时提示一次即跳过，不抛错；提示措辞是「装饰模块不可用（模块未加载或缺少装饰入口）」。

**按 `kind` 选择几何与配色**（Lisp 侧纯函数 `seshat-reader-annotation--decoration-for`，C 侧不认识 `kind`）：

| `kind` | 几何 | 颜色 / 透明度 | defcustom |
|---|---|---|---|
| `highlight` | 行矩形**原样**（多段 location 一段一条） | 默认黄 `1.0 0.85 0.0` / α `0.35`（C 侧历史默认值，默认配置下改走 5 参 `--add-highlight`，像素与改造前逐字节一致） | `seshat-reader-annotation-highlight-color` / `-highlight-alpha` |
| `underline` | 行矩形**底边**细条：`(X0, Y1-1.5, X1, Y1)`，行高小于粗细时夹到上沿不产生负面积 | 蓝 `0.0 0.45 0.85` / α `1.0`（不透明细条，与半透明黄高亮可区分） | `-underline-color` / `-underline-alpha` / `-underline-thickness`（默认 `1.5` pt） |
| `strikeout` | 行矩形**垂直中线**细条：`(X0, MID-0.75, X1, MID+0.75)`，`MID = (Y0+Y1)/2` | 红 `0.85 0.1 0.1` / α `1.0` | `-strikeout-color` / `-strikeout-alpha` / `-strikeout-thickness`（默认 `1.5` pt） |

颜色/alpha/粗细全部可在 defcustom 里调；改配色后 Lisp 侧改走 9 参 `--add-decoration`（C 的 5 参 `--add-highlight` 只认默认黄）。未知 `kind`（含 `note` / `ink` / nil）按 `highlight` 处理，保持向后兼容。

### 跨页文本搜索（`C-s`）

模块 `seshat-reader-search`（自研扩展，不属上游 vendored 代码）。`C-s` 在 `seshat-reader-mode-map` 里原本未被占用；绑定后**该 buffer 内的全局 `isearch-forward` 被有意覆盖**——页面是图片，isearch 搜不到正文，只会命中 buffer 里那几个换行符。

- **交互**：`C-s` → 迷你缓冲区读搜索串 → 整本扫描后落到「当前页及其后的第一个命中」。会话期间进入 `set-transient-map` 武装的临时键表：`n` 下一个命中 / `p` 上一个命中 / `RET` 结束会话并停在当前命中页 / `C-g` 取消并回到搜索起始页。**翻页键位未变**——`n` / `p` 只在会话存续期间接管，按任何其它键即退出临时键表，立刻恢复翻页语义（`n` / `p` 不写进 `seshat-reader-mode-map` 正是为了这个）。
- **跨页与回绕**：命中序列按「页号升序 + 页内 MuPDF 命中顺序」排列；`n` 到文末回绕到第一个命中、`p` 到文首回绕到最后一个，各提示一次。
- **状态行**：`第 i/N 个命中 · 第 p 页`；`C-g` 后回到起始页并清空命中装饰。
- **整本扫描耗时**：797 页文档实测约 **1.1 秒**。扫描用 `fz_search_page` 逐页取命中，不重建文本索引；结果按页缓存在 buffer-local 哈希里，跳转不重扫。
- **双上限**（两者都不是缺陷，是防御）：
  - 单页 `seshat-reader-search-limit`（默认 `1024`）：C 侧把入参夹到 1..10000，但**实际收集**硬上限也是 1024（`SEARCH_PAGE_MAX_QUADS`）。某页返回条数达到 `min(limit, 1024)` 时状态行显式追加「（本页命中已达上限 1024，仅显示前 1024 条）」——否则用户会以为这页只有这么多命中（常见于目录页搜 `.`）。
  - 总量 `seshat-reader-search-max-matches`（默认 `20000`）：达到即**停止扫描**并提示「命中过多」。每条命中是一个五元素浮点列表，几十万条就是几十 MB，且每次跳转都要遍历一遍，故必须设总量闸。
- **搜索结果侧栏（左侧）**：同一次搜索的命中同时列进左侧 side window（`*Seshat Search*`，面板 kind `search`，与目录同侧、排在目录之后的 slot）。每条一行「`[p.N] 片段`」，片段取该命中所在**整行**文本（整行才看得出这句话在讲什么），超过 80 字符截断。**打开时光标切到侧栏**——搜索已经结束，下一步是挑结果而不是翻页。侧栏内 `RET` 跳到该行命中所在页并高亮它，`n` / `p` 逐条移动，`q` **只关自己**（其它面板保留）。搜索侧栏与其它面板一致（`q` 只关自己、`M-o` 可重开、换文档自动清理）：侧栏把自己登记进 `seshat-reader-sidebar-extra-kinds`，故 `q` 与译文 / 批注 / 目录面板一样走 `seshat-reader-sidebar-quit`，`M-o` 能重开它，换文档时随搜索状态一起清空并关闭。侧栏与页面高亮是**并存视图**：命中全集仍是阅读 buffer 的状态，侧栏只记「行 → (页号, 下标, 矩形)」，跳转复用既有的 `--goto-page` + 全量重投，不存在第二条绘制链路。为免几千条命中逐条取文卡住界面，侧栏最多列出 **200** 条（`seshat-reader-search--sidebar-max-entries`），超出时标题写明显式条数；命中全集仍在页面与状态行里。
- **双向同步**：阅读 buffer 里用 `n` / `p`（临时键表）切换命中时，左侧结果栏**跟随**——把对应条目滚到可见并高亮，**不抢光标、不切窗口**（只 `set-window-point` + `recenter`，焦点仍在阅读 buffer）。反向（侧栏里 `RET` / `n` / `p` → 阅读 buffer 跳页）同样成立，两条方向互为镜像。
- **与批注装饰共存**：搜索命中走批注模块的扩展点 `seshat-reader-annotation-extra-decorations-function`，与批注 rect、框选闪现共用 C 侧**同一张**文档级装饰表，任何一方都不独占 `--clear-highlights`。批注模块未加载时降级为自投（`--clear-highlights` → `--add-decoration` → `--refresh-highlights`）。
- **无文本层**的扫描页优雅退化为「本页无结果」，不报错；模块缺 `--search-page` 时提示「搜索不可用」。

### 手写轨迹显示（`ink:`）

Emacs 端**只显示**手写（无笔事件、无压感，输入永远在 Android）。开关 `seshat-reader-annotation-ink-enabled`（默认 `t`）；关闭时一条笔迹都不投，rect 类装饰（highlight / underline / strikeout）仍由 `seshat-reader-annotation-highlight-enabled` 独立控制，两者互不影响。

- **解析**：`seshat-reader-annotation--ink-strokes-from-location` 把 `page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,…` 按 `;` 切段，逐个 `ink:` 段解析为 `(PAGE R G B ALPHA WIDTH POINTS TRUNCATED)`。
  - 颜色只接受**恰好 8 位** `#AARRGGBB`（alpha 在最高位）；`#RGB` / `#RRGGBB` / 缺 `#` 一律丢弃整笔——其它位宽的 alpha 归属无从判断，猜错会把整笔颜色（含透明度）画错。
  - **整笔跳过**的判据：不是 `ink:` 段、缺颜色或宽度、宽/坐标非有限数（`NaN` / `inf` / 指数溢出）、坐标个数为奇数、点数为 0（契约里的降级形态，只有颜色与宽度）。任一条不满足即丢**整笔**而不是丢坏点：坐标错一个点会把整笔画歪，画一条歪线比不画更误导。
  - 点数上限 `seshat-reader-annotation--ink-max-points`（**1024**，与 C 侧 `DECORATION_MAX_POINTS` 一致）：超出则**截断为前 1024 点**并标记 `TRUNCATED`，而不是丢整笔（整笔丢弃等于用户的手写凭空消失）。正常一笔只有几十到几百点，不受影响。
- **投喂**：解析结果经 `--add-stroke`（**1-based** 页号、扁平点列表 `(x0 y0 x1 y1 …)`、圆头圆角）交给 C 侧装饰表。统一投喂顺序是 **clear → 批注 rect → 框选闪现 → 搜索命中 → ink 笔迹 → refresh**（`seshat-reader-annotation--redraw-highlights` 做单次全量重投，因此不存在第二套共存逻辑）。ink 解析失败只影响 ink，不影响 rect。
- **坐标口径**：ink 笔迹与 `rect:` **同一个 page space**（页面 pt、原点左上、y 向下），**无需 y 翻转**——数值证据：同页同一形状的 ink 线差异行中心 `80.0` 与 highlight 行中心 `80.0` 一致（PNM `612×792`，该分辨率下 1px = 1pt）。解析层按契约逐字对应、不做任何翻转。**Android 真机上的肉眼对照仍待确认**（见 §12 第 2 条）。
- 线宽与点数都按页面 pt 解释，因此缩放后与页面同变换对齐；旋转页上的坐标本身有误（见 §12 第 1 条），与 rect 高亮同一限制。

### 批注列表（`C-c C-l`）

`C-c C-l` = `seshat-reader-annotation-list`，把当前文档批注渲染到 `*Seshat Annotations*`（走承载层，默认落在右侧 side window）。列表**全量单列连续流**，不分页、无页脚，超出面板高度时滚动面板窗口。

| 键位 | 命令 | 作用 |
|---|---|---|
| `RET` | `seshat-reader-annotation-list-goto` | 跳到该行批注所在页 |
| `d` | `seshat-reader-annotation-list-delete` | 删除该行批注（服务端项走 API，`[待同步]` 项只取消本地条目、不发 HTTP） |
| `C-c C-r` | `seshat-reader-reference-insert-annotation` | 把该行批注的引用写入目标笔记（取值不触网） |
| `q` | `quit-window`（`special-mode`） | 关闭面板 |

列表页头徽章显示总条数；服务端暂时拉不到时**不报错也不清空**，只显示本地待同步条目并提示「（离线）仅显示本地待同步批注 N 条」。这些键不依赖 evil：批注列表面板显示时会被切到 evil 的 **emacs state**（见 §「面板承载」里的「面板内切 evil emacs state」条），normal state 不再抢键，故 `RET` / `q` / `M-o` / `C-c w` 等单键在 evil 用户手里同样生效（此前会被 `evil-ret` / `evil-record-macro` 吃掉）。

### 离线队列

服务端不可用时，创建/删除不报错，改为写入本地队列（提示「已存入本地，待联网同步」），批注列表仍显示待同步项并标 `[待同步]`。队列文件、自动同步开关、同步间隔、首次延迟与条目上限见 §10「队列」表。

推进时机：启动后 `initial-delay` 首次 + 每 `sync-interval` 周期 + 手动 `M-x seshat-reader-annotation-queue-sync` + `list` / `create` 成功后的机会性同步。队列文件是 `prin1` 写出的 plist 列表，采用同目录临时文件 + `rename-file` 的**原子写**；读到损坏文件时保留原文件不覆盖并报错。

## 6. 译文与解释

| 键位 | 命令 | 说明 |
|---|---|---|
| `C-c C-t` | `seshat-reader-translate-toggle` | 翻译最近一次选区；面板里已是译文时**关闭**面板（原命令 `seshat-reader-translate-selection` 仍可用 `M-x` 调用） |
| `C-c C-e` | `seshat-reader-translate-explain-toggle` | 解释最近一次选区；面板里已是解释时**关闭**面板（原命令 `seshat-reader-translate-explain-selection` 仍可用 `M-x` 调用） |
| `q`（面板内） | `seshat-reader-sidebar-quit` | 关面板（`seshat-reader-translate-panel-mode` 承载；按 buffer 名推断 kind，child frame 承载时走 `delete-frame`） |
| `C-c C-q`（面板内） | `seshat-reader-translate-follow-up` | 针对同一段原文继续追问（多轮上下文，见下文「继续追问」） |
| `C-c C-s`（面板内） | `seshat-reader-translate-save-as-annotation` | 把最近一次译文存为批注 |
| `C-c w`（面板内） | `seshat-reader-sidebar-toggle-width` | 面板宽度切换：常态 ↔ `seshat-reader-sidebar-expanded-width`（默认 `0.75`），再按一次恢复原宽度 |

- **结果缓存（仅本会话内存）**：翻译与解释的结果按键 `(KIND PRESET LANGS REQUEST-TEXT)` 存在 `seshat-reader-translate--cache` 里——同一段内容、同一预设与语言对**再次打开不再请求**，直接按模板重绘面板并回显「使用缓存结果」；解释路径的 `REQUEST-TEXT` 是装配好的「上下文 + 原文 + 指令」串，因此**上下文不同即视为不同条目**（同一句原文在不同页、邻近文字不同，各存一份）。要跳过缓存重新生成按 `C-u`（`C-c C-t` / `C-c C-e` 的 `C-u` 前缀既读目标语言也强制重算）；想整体丢弃用 `M-x seshat-reader-translate-clear-cache`。缓存**不落盘**、重启 Emacs 即清空；posframe 承载下的流式结果不写缓存（面板路径恒为非流式，写入点在 `seshat-reader-translate--record-result` 的成功分支）。

- **解释带同页上下文**：`C-c C-e` 送模型的是「结构化指令 + 同页邻近上下文（上下各 `seshat-reader-translate-context-lines` 行，上限 `seshat-reader-translate-context-max-chars` 字）+ 选区原文（上限 `seshat-reader-translate-explain-max-chars` 字）」，不再只是孤立片段；指令模板可用 `seshat-reader-translate-explain-prompt` 自定义（设 `nil` 退回「纯选区 + 预设引擎自带 prompt」的旧行为），关掉上下文用 `(setq seshat-reader-translate-context-enabled nil)`。**注意隐私**：默认会把同页邻近正文一并送出（见 [`llm.md`](llm.md)「隐私提示」）。
- 依赖 go-translate：`seshat-reader-translate-preset`（默认 `reader`）与 `seshat-reader-translate-explain-preset`（默认 `reader-explain`）按名从 `seshat-reader-translate-presets` → `gt-preset-translators` 依次取用（seshat 自有表优先，故这两个预设不必进 gt 全局表）；预设通常定义在**用户配置侧**，缺失时翻译回退内置 youdao/google，解释需显式配置端点。gt 的中转 buffer `" *Seshat gt*"` 由包隐藏，用户无需改 `display-buffer-alist`。
- 呈现方式由 `seshat-reader-translate-render`（默认 `sidebar`）决定：`sidebar` 写进面板内的**只读 Markdown 文本 buffer**（`gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链，原生折行/滚动/复制/isearch 可用，**不经 ETAF**）；`pop`（posframe 弹出、失焦消失）；`pin`（posframe 常驻）。取 `sidebar` 但 `seshat-reader-sidebar-enabled` 为 `nil` 时退回 `pop` 式 posframe。
- 正文按模板渲染：翻译用 `seshat-reader-translate-template`（默认 `"%l\n\n%q\n\n---\n\n%t\n"`），解释用 `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`）。占位符 `%k` 标题、`%l` 语言对、`%q` 原文引用块、`%t` 正文；模板非法时回退纯正文并 `message` 警告；设 `nil` 表示不套模板。
- `seshat-reader-translate-show-source`（默认 `t`）控制是否在正文前插入选中原文的引用块（不截断）。
- `seshat-reader-translate-visual-fill-column`（默认 `t`）在面板启用 `visual-fill-column-mode`（软依赖，未安装静默跳过）。
- **不抢光标**：显示译文/解释面板时不移动光标，光标留在阅读窗口（SELECT 传 `nil`），可以接着翻页/滚动；要编辑或复制译文时点进面板即可。批注列表面板不受影响（仍在内容就绪后跟随光标）。
- 语言对由 `seshat-reader-translate-fallback-langs`（默认 `(en zh)`）推导，可用命令前缀参数覆盖。
- **多引擎结果**：`seshat-reader-translate-engines-pick`（默认 `all`）——`all` 展示**全部**成功结果，每条前标注 `【引擎名】`、段间用 Markdown 分隔线 `---` 隔开（多引擎预设本就是为了一眼比对各家译文）；`first` / `last` 只展示第一个 / 最后一个**成功**结果，且**不带**来源标签。带 `gt-buffer-render-error-face` 的片段视为失败并跳过；来源取不到（单引擎不写前缀行）时退化为纯译文，不加标签也不加分隔线。旧的「拼接后不可区分」行为已不存在——想要单条输出请显式设为 `first`。
- **流式增量**：`seshat-reader-translate-stream`（默认 `t`）边生成边显示，骨架只写一次、正文区替换、完成不重写；细节见下文「译文流式渲染」。
- **继续追问**：`C-c C-q` 在面板里针对同一段原文继续提问，多轮上下文随请求发送；轮次上限 `seshat-reader-translate-follow-up-max-rounds`（默认 `6`），详见下文「继续追问」。

## 面板承载（childframe / 窗口）

阅读器的所有面板（`outline` 目录 / `annotations` 批注列表 / `translate` 译文与解释）都由承载层 `seshat-reader-sidebar` 显示，**承载方式**由 `seshat-reader-panel-carrier` 决定（M12 T8a 起默认 `childframe`）：

| carrier | 行为 | 决定几何的配置 |
|---|---|---|
| `childframe`（**默认**） | child frame 覆盖在父 frame **右上角**，不参与窗口树：显示 / 刷新 / 滚动面板都**不改变阅读窗口的像素尺寸**，因此不会触发阅读器按窗口尺寸重新适配（版面跳动） | `seshat-reader-panel-width` / `-height` / `-margin` |
| `window` | 沿用 side window / 底部窗口承载（进 `display-buffer` 窗口树，会压缩阅读区） | `seshat-reader-sidebar-position` / `-width` / `-height` / `-min-height` / `-max-height`、`seshat-reader-outline-sidebar-position` / `-width` |

- **per-kind 覆盖**：`seshat-reader-panel-carrier-alist`（默认 `((annotations . window))`）按 kind 覆盖全局 carrier，键取 `outline` / `annotations` / `translate`。默认把**批注列表留在窗口承载**：条目多、需要长列表浏览与逐条跳转，覆盖浮层既遮挡正文又放不下。解析顺序见 `seshat-reader-sidebar--carrier-for-kind`：alist 命中项 → 全局值 → 非法取值静默回落 `window`。
- **非图形回退**：`(display-graphic-p)` 为 nil（tty / 终端）时一律回退 `window`——child frame 只存在于图形终端。此外 `childframe` 路径本身带软回退：父 frame 不是图形 frame 或面板尺寸算不出来时 `--cf-show` 返回 nil，显示层**自动走窗口后端**，不抛错。
- **固定尺寸**：child frame 的面板几何在**打开那一刻**固定——宽 = 父 frame 像素宽 × `seshat-reader-panel-width`（默认 `0.34`），高 = 父 frame 像素高 × `seshat-reader-panel-height`（默认 `0.45`），距父 frame 右 / 上边缘各 `seshat-reader-panel-margin`（默认 `16`）像素。**全程不 resize**，内容超出后在面板窗口内**内部滚动**——流式输出期间遮挡区域恒定，读者视线不会被反复挤压。
  - 这套口径只对 `childframe` 生效：窗口承载的面板仍按 `seshat-reader-sidebar-height` / `-width` 决定尺寸，译文面板在**底部模式**下还会按内容行数自适应（`--fit-height-for-content`，childframe 承载下不参与）。
  - 多个 child frame 面板同时存在时由 `--cf-position` **纵向堆叠**（已有面板逐个下移），互不重叠。
- **跟随底部**：`seshat-reader-panel-follow-bottom`（默认 `t`）——流式输出期间面板自动滚到最底显示最新内容；用户**向上滚动后停止跟随**，自己滚回底部时恢复。想全程手动滚动设 `nil`。
- **去 mode-line**：child frame 的面板窗口设 window parameter `mode-line-format` 为 `none`，省掉一行无信息量的 modeline；`header-line` **保留**（仍显示「Seshat 译文」/「Seshat 解释」）。
- **面板内 `q`（各面板统一）**：一律走 `seshat-reader-sidebar-quit`——按 buffer 名推断当前面板 kind（内置三种面板 + 注册表 `seshat-reader-sidebar-extra-kinds` 里的自建面板，如搜索结果侧栏 `search`），再按**承载单元**分派 `delete-window`（窗口）或 `delete-frame`（child frame），**只关当前这一个面板**，不连带关闭其它 kind 的面板；当前 buffer 不是面板时退回 `seshat-reader-sidebar-toggle`。目录面板与译文/解释面板直接绑该命令，批注列表（含 ETAF 渲染路径）也绑到它（`seshat-reader-etaf-quit` 委托同一命令），搜索结果侧栏经注册表同样命中它。
- **per-kind 开合键（阅读窗口里）**：每个 kind 一个 toggle——`o` 目录（`seshat-reader-outline-toggle`）、`C-c C-l` 批注列表（`seshat-reader-annotation-toggle`）、`C-c C-t` / `C-c C-e` 译文与解释（`seshat-reader-translate-toggle` / `-explain-toggle`）。语义：**语境匹配时关闭，否则打开/生成并替换内容**。「已显示」由 `seshat-reader-sidebar-panel-visible-p` 判定，与承载方式无关（side window / 底部窗口 / child frame 都算），因此 childframe 承载下同样能一键关闭。译文与解释共用同一个面板 buffer 与同一个 kind（`translate'），故两个键额外比对面板记录的**语境**（`seshat-reader-translate--panel-context`，`translate' / `explain'）：只有「已显示 **且** 语境就是自己那一份」才关闭，否则重新执行对应命令覆盖面板内容——面板里是译文时按 `C-c C-e` 是**换成解释**（不是关面板再按一次），反之亦然（2026-10-26 修复，此前两键都只判「已显示」故互相误关）。原命令（`-outline-show` / `-annotation-list` / `-translate-selection` / `-explain-selection`）保留不变，`M-x` 调用语义如旧。
- **面板内切 evil emacs state**：面板（译文/解释、搜索结果侧栏、批注列表、目录）是**只读展示视图**，evil 的 normal state 会先吃掉单键——`q` 变成 `evil-record-macro`（宏录制）、`n` / `p` 走 evil 的搜索/粘贴、`RET` 由 `evil-ret` 处理，于是面板自己绑的 `q` / `n` / `p` / `RET` 全部失效。包内在面板显示的**统一漏斗**（`seshat-reader-sidebar--display`，以及面板禁用时 `show' 的 `pop-to-buffer' 回退分支）把面板 buffer 切到 **emacs state**（`evil-emacs-state`，每 buffer 独立），normal state 不再参与键解析，面板自身键位直接生效；阅读 buffer 仍是 normal state。用 state 切换而非 `evil-local-mode -1`：后者会让 evil 在本 buffer 完全退出（连 `C-v` 等一并消失）。无 evil 时 `fboundp` 守卫使其零副作用；渲染/重开后都会重新经过该漏斗，故 state 不会因切 major mode 而丢。
- **`M-o` 全部面板开合**：`seshat-reader-sidebar-toggle`（无参）——**面板开着就全部关闭，关了重开最近一个面板**。`C-c C-o` 已**解绑**，让给 org / `outline-minor-mode` 的结构操作。选 `M-o` 是因为单键、右手拇指可直接够到；它虽是 `global-map` 里 `facemenu-keymap` 的前缀，但本包把绑定写进 `seshat-reader-mode-map`（mode-map 优先），阅读器 buffer 内的 `M-o` 因此归本包，其它 buffer 的 `M-o` 行为不受影响。**`M-o` 在阅读 buffer 与所有面板内都可用**：译文/解释面板（`seshat-reader-translate-panel-map`）、批注列表、目录面板、搜索结果侧栏四个键表各自也绑了同一个命令（后三者由 `seshat-reader-sidebar` 用 `with-eval-after-load` 补注册，不改 `global-map`），故光标在面板里按 `M-o` 同样是「全部开合」，不必先切回阅读 window。「重开最近一个面板」时**位置与内容一致**：关闭时 buffer 与它的 kind 成对记下（`--last-buffer` / `--last-kind`），重开就按该 kind 的方位弹出（此前只记 buffer，`M-o` 关掉多 kind 面板后再按会弹到错误的一侧）。**「最近」= 最近显示的那个**：`--recent-kinds`（`seshat-reader-sidebar--display` 每次显示后把该 kind 提到头部）决定挑谁，再按 kind 从 `--last-buffers` 取 buffer；只有 `--recent-kinds` 为空、或其中 kind 都不在本批面板里时才回退到旧的「遍历承载单元取最后一个」——旧顺序是「窗口在前、child frame 在后」，child frame 面板因此恒压过窗口面板，与实际最后显示的那个不一致（2026-10-26 修复）。
- **`C-c w` 面板宽度切换**：`seshat-reader-sidebar-toggle-width` —— 把当前面板从常态宽度（`seshat-reader-sidebar-width` 默认 `0.25`；目录栏为 `seshat-reader-outline-sidebar-width` 默认 `0.20`）扩到 `seshat-reader-sidebar-expanded-width`（默认 **`0.75`**），**再按一次恢复扩大前的宽度**。作用对象：在面板 buffer 里按作用于该面板，在阅读 buffer 里按作用于「最近的」本包面板（`seshat-reader-sidebar--windows` 的第一个，通常是最右侧的译文/批注面板）；没有面板时只提示、不报错。实现是水平 `window-resize` 差量调整——side window 与阅读区同属一个水平窗口组合，扩大面板会等量压缩阅读区、恢复时等量归还，不新建窗口。「扩大前宽度」按 **kind** 记在会话内哈希里（`seshat-reader-sidebar--width-memory`），所以面板关掉再打开也能恢复；扩大后的宽度本身不写配置，重启 Emacs 回到常态。**仅窗口承载 + 左右分栏**生效：childframe 承载（宽度由 `seshat-reader-panel-width` 决定）与底部模式（高度语义）只提示、不改布局。键位同时写在阅读 buffer、译文面板、批注列表、目录面板、搜索结果侧栏五个 keymap 上；ETAF 渲染的批注卡片走 ETAF 自己的 `:keys`、无对外 keymap 变量，故卡片里需用 `M-x seshat-reader-sidebar-toggle-width`。
- **位置与复用**：每个 kind 的 side 由「kind → 位置」解析决定（目录默认左、译文/批注默认右），slot 按 kind 固定分配，故同一 kind 重开时**复用同一 side window**（不新建、不改侧）；运行中改方位才会重建该 kind 的窗口。
- **译文/解释面板不抢光标**：面板显示后光标留在阅读窗口（`seshat-reader-translate--render-panel` / `--stream-init` 的 SELECT 传 `nil`）。需要时点进面板，或把 `seshat-reader-sidebar-select-window` 与调用点改回非 nil。批注列表面板保持原行为（内容就绪后跟随光标）。
- **切走即隐藏**：`seshat-reader-panel-hide-on-buffer-change`（默认 `t`）挂在全局 `window-buffer-change-functions` 上——当前 buffer 不再派生自 `seshat-reader-mode` 时关闭本包 child frame 面板（覆盖浮层不属于任何窗口树，放任不管会在回邮件 / 看终端时一直悬在右上角）。面板内容仍留在 buffer 里，`M-o` 可重开；设 `nil` 则常驻。
- **与 popper 的关系**：popper 分流函数 `seshat-reader-sidebar-display-buffer` 仍只服务 `window` 承载的面板；child frame 面板**不经过** `display-buffer`，popper 的 `C-'` 开关因此不影响它（面板里那份 buffer 仍可照常用 popper 打开成普通窗口）。

## 译文流式渲染

`seshat-reader-translate-stream`（默认 `t`）开启后，译文 / 解释面板**边生成边显示**：

- **骨架只写一次**：首个增量到达时先按模板渲染一次骨架（正文 `%t` 为空）并记下正文起点 marker；
- **正文区替换**：后续每个增量只替换 marker 之后的正文区；标题、语言对、原文引用块一次成型、不重写；
- **完成不重写**：结束时只更新 header-line 状态，不 `erase-buffer` 重排，避免完成瞬间整块跳变；
- **跟随底部**：由 `seshat-reader-panel-follow-bottom` 控制（见上节），向上滚动即停止跟随。

引擎不支持流式（无 `stream` 槽）或该选项取 `nil` 时，退回「完成后一次性渲染」的旧路径，差别只是没有中间过程。**已知退化路径**：gt 升级若改动 `gt-buffer-render-output-hook` 的增量语义，本功能会**静默退化**为完成时渲染——不报错、只是生成期间面板没有更新，排查时先看 header-line 是否在生成期间变化。

## 继续追问（多轮上下文）

解释 / 译文面板里可以针对**同一段原文**继续提问，历史轮次随请求一起发送。

| 键位 | 命令 | 说明 |
|---|---|---|
| `C-c C-q` | `seshat-reader-translate-follow-up` | 迷你缓冲区读问题 → 发起追问（阅读器与面板内均可，`C-c C-a` 已被批注占用故选 `C-c C-q`） |

- **上下文形态**：历史以 OpenAI `messages` 形式随请求发送——首轮的原文与首轮解释（前两条）**始终保留**，其后是每次的「问 + 答」。实现是克隆预设里的 `gt-chatgpt-engine` 并把 `prompt` 槽换成「返回 messages 列表的函数」（gt 的 `gt-chatgpt-send` 在 prompt 为列表时按 `messages` 数组发送），**不改 gt 源码、不自行拼 JSON**。
- **面板呈现**：答案追加到面板，每轮渲染为 `---` + `### 追问 N` + `**问：**` + `**答：**`；流式时只替换**当前轮答案区**，不触碰首轮骨架与此前各轮问答。
- **轮次上限**：`seshat-reader-translate-follow-up-max-rounds`（默认 `6`）——超出后**丢弃最早的轮次**，但首轮的原文与首轮解释不在丢弃范围（否则追问失去讨论对象）；取 `0` 表示每次追问只看原文与首轮解释，不带任何历史轮次。
- **引擎限制**：预设里必须有 `gt-chatgpt-engine`（如 `reader-explain`），否则 `user-error` 并提示改配置——**不做文本拼接降级**：youdao / google 这类纯翻译引擎没有对话语义，拼进去只会产出误导性答案。
- **状态生命周期**：追问状态是面板 buffer 的 buffer-local plist（原文、首轮答案、语言对、kind、轮次），**新一次翻译 / 解释会重置**全部追问历史。

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
| `o` | `seshat-reader-outline-toggle` | 开合目录面板（已显示则关闭，未显示则重建内容后打开） |
| `Q` | `seshat-reader-close-doc` | 关闭文档 |
| `C-c C-a` / `C-c C-l` | `seshat-reader-annotation-create` / `-toggle` | 建批注 / 批注列表面板开合（已显示则关，否则拉取渲染） |
| `C-c C-h` | `seshat-reader-annotation-refresh-highlights` | 刷新页面高亮 |
| `C-s` | `seshat-reader-search` | 跨页文本搜索（会话内 `n` / `p` / `RET` / `C-g`；`n` / `p` 只在会话期间接管翻页键）。搜索成功后同时打开**左侧搜索结果侧栏**并把光标切过去，侧栏键位见 §9.5 |
| `C-c C-r` | `seshat-reader-reference-insert` | 插入选区摘录 |
| `C-c C-t` / `C-c C-e` | `seshat-reader-translate-toggle` / `-explain-toggle` | 译文 / 解释面板开合，**语境一一对应**：面板里是译文时 `C-c C-t` 关闭（`C-c C-e` 换成解释），面板里是解释时 `C-c C-e` 关闭（`C-c C-t` 换成译文），面板未显示则翻译 / 解释并弹出 |
| `C-c C-q` | `seshat-reader-translate-follow-up` | 对译文 / 解释继续追问（多轮上下文） |
| `M-o` | `seshat-reader-sidebar-toggle` | **全部面板**开合：有面板就全部关闭，没有就重开最近一个。同一键位在**所有面板**（译文/解释、批注列表、目录、搜索结果侧栏）内也生效——光标在面板里照样按得到，不必先切回阅读 window |
| `C-c w` | `seshat-reader-sidebar-toggle-width` | 面板宽度**切换**：常态宽度（`seshat-reader-sidebar-width` / `seshat-reader-outline-sidebar-width`）↔ `seshat-reader-sidebar-expanded-width`（默认 `0.75`）；再按一次恢复原宽度。同一键位在译文面板 / 批注列表 / 目录面板 / 搜索结果侧栏内也生效 |
| `?` | `seshat-reader-help` | 打开本帮助页：键位、功能简介与面板行为（`seshat-reader-help` 自带 autoload，无需 require，见「安装与加载」）。**evil 用户同样可用**：包内用 `evil-define-key*` 把 normal state 的 `?` 补绑到本命令（evil 原绑的是 `evil-search-backward`），`/`、`n`、`N` 不被改动，见 §11 最后一条 |

`C-c C-o` **已解绑**（让给 org / `outline-minor-mode` 的结构操作）：单个 kind 的开合改由各自
的键承担（`o` 目录、`C-c C-l` 批注列表、`C-c C-t` / `C-c C-e` 译文与解释），全部开合统一走
`M-o`。

另有 `next-line` / `previous-line` / `next` / `prior` / `scroll-up-command` / `scroll-down-command` / `forward-char` / `backward-char` / `beginning-of-buffer` / `end-of-buffer` / `goto-line` / `move-end-of-line` / `move-beginning-of-line` 的 remap，及 6 个鼠标命令 remap 到 `ignore`（防止误移 point 破坏页面边框绘制）。

### 9.2 目录面板（`seshat-reader-outline-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `p` / `n` | `previous-line` / `next-line` | 上下移动 |
| `RET`、`M-RET` | `seshat-reader-outline-visit-page` | 跳到该标题所在页 |
| `f` | `seshat-reader-outline-avy-jump` | avy 风格单键跳转 |
| `o` | `seshat-reader-outline-toggle` | 开合面板：已显示则关闭，未显示则重建内容后打开；`seshat-reader-outline-select-doc-window` 不再占 `o`，仅供 `RET` 跳页切回阅读窗口 |
| `s` | `seshat-reader-outline-select-doc-window` | 切回阅读窗口（回跳当前文档；`o` 改为面板开合后它换绑到 `s`） |
| `q` | `seshat-reader-sidebar-quit` | **只关当前面板**（child frame 承载时走 `delete-frame`，窗口承载走 `delete-window`；不连带关闭译文/批注面板） |
| `M-o` | `seshat-reader-sidebar-toggle` | **全部面板**开合（与阅读 buffer 内同一个键：有面板就全部关闭，没有就重开最近一个） |
| `C-c w` | `seshat-reader-sidebar-toggle-width` | 面板宽度切换（常态 ↔ `seshat-reader-sidebar-expanded-width`，再按一次恢复） |
| `TAB` | `outline-mode` 自身 | 折叠 / 展开子树 |

evil 用户同样可用上述单键（包内 `evil-define-key*` 补绑 normal state 的 `f` / `p` / `n` / `o` / `s` / `q` / `RET` / `M-RET`；另外目录面板本身在显示时也会被切到 evil 的 emacs state，见 §「面板承载」里的「面板内切 evil emacs state」条，双保险）。

### 9.3 批注列表（`seshat-reader-annotation-list-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `RET` | `seshat-reader-annotation-list-goto` | 跳到该条批注所在页 |
| `d` | `seshat-reader-annotation-list-delete` | 删除该条批注 |
| `C-c C-r` | `seshat-reader-reference-insert-annotation` | 插入该条批注的引用 |
| `q` | `seshat-reader-sidebar-quit` | 只关当前（批注列表）面板，与目录 / 译文面板一致（ETAF 渲染路径同一语义，键由 `seshat-reader-etaf--annotation-keys` 绑到 `seshat-reader-etaf-quit`，后者委托 `sidebar-quit`） |
| `M-o` | `seshat-reader-sidebar-toggle` | **全部面板**开合（与阅读 buffer 内同一个键） |
| `C-c w` | `seshat-reader-sidebar-toggle-width` | 面板宽度切换：常态 ↔ `seshat-reader-sidebar-expanded-width`，再按一次恢复原宽度 |

### 9.4 译文/解释面板（`seshat-reader-translate-panel-mode-map`）

| 键位 | 命令 | 作用 |
|---|---|---|
| `q` | `seshat-reader-sidebar-quit` | 关面板（child frame 承载时 `delete-frame`） |
| `M-o` | `seshat-reader-sidebar-toggle` | **全部面板**开合（与阅读 buffer 内同一个键） |
| `C-c w` | `seshat-reader-sidebar-toggle-width` | 面板宽度切换（常态 ↔ 扩大值，再按一次恢复） |
| `C-c C-q` | `seshat-reader-translate-follow-up` | 对当前原文继续追问 |
| `C-c C-s` | `seshat-reader-translate-save-as-annotation` | 存为批注 |

### 9.5 搜索结果侧栏（`seshat-reader-search--sidebar-map`）

`C-s` 成功后光标落在左侧结果侧栏（`*Seshat Search*`，`special-mode` + 只读），键表以
`special-mode-map` 为父表（滚动等基础键照旧可用），只覆盖下面六个键：

| 键位 | 命令 | 作用 |
|---|---|---|
| `RET` | `seshat-reader-search-sidebar-goto` | 跳到当前行命中所在页并高亮该命中（光标留在侧栏，便于继续挑结果） |
| `n` / `p` | `seshat-reader-search-sidebar-next` / `-prev` | 移动下一条 / 上一条并跳转；首条 `p`、末条 `n` 只提示「已是第一个 / 最后一个结果」，不报错 |
| `q` | `seshat-reader-sidebar-quit` | **只关搜索结果侧栏**（其它面板保留）。侧栏在 `seshat-reader-search.el` 加载末尾把自己登记进 `seshat-reader-sidebar-extra-kinds`（buffer 名 → kind `search`），故通用的关闭命令按 buffer 名就能推断出 `search`、只关自己；`seshat-reader-search-sidebar-quit` 保留为**委托同一命令**的兼容别名 |
| `M-o` | `seshat-reader-sidebar-toggle` | **全部面板**开合（光标在侧栏里也按得到，不必先切回阅读 window；绑定由 `seshat-reader-sidebar` 在 search 模块加载后补注册） |
| `C-c w` | `seshat-reader-sidebar-toggle-width` | 面板宽度切换：常态 ↔ `seshat-reader-sidebar-expanded-width`，再按一次恢复原宽度（侧栏在左侧、与目录栏同为宽度语义；绑定同样由 `seshat-reader-sidebar` 补注册） |

**与其它面板一致**：搜索侧栏与其它面板一致（`q` 只关自己、`M-o` 可重开、换文档自动清理）——① `q` 走统一的 `seshat-reader-sidebar-quit`（不再是搜索模块的私有命令）；② `M-o`（`seshat-reader-sidebar-toggle`）的「重开最近面板」按**最近显示顺序**（`--recent-kinds`）挑 kind、再按 kind 从 `--last-buffers` 取 buffer，侧栏关掉后同样能被重开；③ 换文档（同一 buffer 打开另一份 PDF）时 `seshat-reader-search--reset-state` 会清空侧栏内容与「行 → 命中」映射，并在面板显示时把它关掉，不再保留上一份文档的搜索结果。注册用一张 `buffer 名 → kind` 的注册表（`seshat-reader-sidebar-extra-kinds`）实现——`seshat-reader-sidebar` 是零依赖承载层，不 require `seshat-reader-search`，故由**创建 buffer 的模块**在加载末尾登记，不形成循环依赖。

**反向跟随（阅读 buffer → 侧栏）**：光标不在侧栏时，阅读 buffer 里用 `n` / `p` 切换命中，侧栏同样跟着走——`seshat-reader-search--sidebar-sync` 按命中下标取渲染时记下的 marker（`seshat-reader-search--sidebar-markers`，用 marker 而非行号，内容变化不漂），只对该条行的窗口 `set-window-point` + `recenter`，**不 `select-window`**、不动用户的焦点；当前条目的高亮是专用 overlay（`window` 属性钉在侧栏窗口上），不用 `hl-line-mode`——后者的 overlay 跟随当前 buffer 的 point 且限制在选中窗口，在后台窗口里根本不会亮。

## 10. 配置速查

### 版式 / 面板

| 变量 | 默认值 | 作用 | 备注 |
|---|---|---|---|
| `seshat-reader-sidebar-enabled` | `t` | 是否用面板展示批注列表与译文 | `nil` 时批注列表退回 `pop-to-buffer`，译文退回 posframe |
| `seshat-reader-sidebar-position` | `right` | 信息栏位置：`right` / `left` / `below-selected` / `at-bottom` | **M12 破坏性变更**（原 `below-selected`）；`left`/`right` 为宽度语义 |
| `seshat-reader-sidebar-width` | `0.24` | 信息栏宽度（小数=frame 比例，整数=列数） | 仅 side 模式；只对新建窗口生效 |
| `seshat-reader-outline-sidebar-position` | `left` | 目录栏位置 | 只作用于 `outline`；**搜索结果侧栏（`search`）不跟随本变量**，恒在 `left`（`--position-for-kind` 里是字面量，避免改目录方位时把搜索栏带走） |
| `seshat-reader-outline-sidebar-width` | `0.20` | 目录栏宽度 | 仅 side 模式 |
| `seshat-reader-sidebar-expanded-width` | `0.75` | `C-c w`（`seshat-reader-sidebar-toggle-width`）把当前面板扩大到的宽度（占 frame 宽比例；整数=列数） | 仅窗口承载 + 左右分栏；childframe 与底部模式只提示、不改布局。再按一次恢复原宽度 |
| `seshat-reader-sidebar-height` | `0.35` | 面板首次显示的初始高度 | 高度语义；批注列表固定用此值 |
| `seshat-reader-sidebar-min-height` | `0.25` | 译文/解释面板自适应下限 | 仅 `translate` 且未挂 ETAF |
| `seshat-reader-sidebar-max-height` | `0.8` | 自适应上限 | 与 min 共同夹紧；min > max 时以 max 为准 |
| `seshat-reader-sidebar-select-window` | `t` | 面板显示后是否把光标移入面板 | |
| `seshat-reader-sidebar-translate-buffer-name` | `"*Seshat Sidebar*"` | 译文展示 buffer 名 | gt 中转改用隐藏 buffer |
| `seshat-reader-etaf-enabled` | `t` | 批注列表是否用 ETAF 渲染 | 译文/解释不受影响 |
| `seshat-reader-panel-carrier` | `childframe` | 面板承载方式：`childframe`（覆盖在父 frame 右上角，不参与窗口树，**不改变阅读窗口尺寸**）/ `window`（side window / 底部窗口，会压缩阅读区）。非图形环境强制回退 `window` | **M12 T8a 破坏性变更**（原为窗口承载）；回退 `(setq seshat-reader-panel-carrier 'window)` |
| `seshat-reader-panel-carrier-alist` | `((annotations . window))` | 逐 kind 覆盖 `seshat-reader-panel-carrier`，键取 `outline` / `annotations` / `translate` | 默认让批注列表保留窗口承载（列表长、需逐条跳转，浮层放不下） |
| `seshat-reader-panel-width` | `0.34` | child frame 宽度 = 父 frame 像素宽 × 本值 | 仅 `childframe` 生效 |
| `seshat-reader-panel-height` | `0.45` | child frame 高度 = 父 frame 像素高 × 本值；**打开即固定、全程不 resize**，内容超出在面板内滚动 | 仅 `childframe` 生效 |
| `seshat-reader-panel-margin` | `16` | child frame 距父 frame **右 / 上**边缘的像素间距 | 仅 `childframe` 生效 |
| `seshat-reader-panel-truncate-lines` | `nil` | 面板正文是否**不折行**：`nil`（默认）= **折行**（`truncate-lines` 为 nil + 显式 `word-wrap`，可叠加 `visual-fill-column-mode`）；`t` = 不折行 + 横向滚动（`truncate-lines`/`auto-hscroll-mode` 为 t、`word-wrap` 为 nil） | 折行与 `visual-fill-column-mode` 互斥，`t` 时整体跳过；**2026-10-25 由 `t` 改为 `nil`** |
| `seshat-reader-panel-follow-bottom` | `t` | 流式输出期间是否自动跟随底部（显示最新内容）；用户向上滚动后停止跟随、回到底部时恢复 | 仅 `childframe` 生效 |
| `seshat-reader-panel-hide-on-buffer-change` | `t` | 当前 buffer 不再是阅读器 buffer 时关闭本包 child frame 面板；面板内容留在 buffer 里可 `M-o` 重开 | `nil` = 面板常驻 |

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
| `seshat-reader-annotation-highlight-enabled` | `t` | 是否绘制批注装饰（高亮 / 下划线 / 删除线） |
| `seshat-reader-annotation-ink-enabled` | `t` | 是否把批注 `ink:` 段绘制为页面手写笔迹（只控 ink，不影响 rect 类装饰） |
| `seshat-reader-annotation-highlight-color` | `(1.0 0.85 0.0)` | 高亮填充色 RGB（各 0.0–1.0），与 C 侧默认黄逐字一致 |
| `seshat-reader-annotation-highlight-alpha` | `0.35` | 高亮填充透明度 |
| `seshat-reader-annotation-underline-color` / `-underline-alpha` / `-underline-thickness` | `(0.0 0.45 0.85)` / `1.0` / `1.5` | 下划线颜色、透明度与细条高度（pt） |
| `seshat-reader-annotation-strikeout-color` / `-strikeout-alpha` / `-strikeout-thickness` | `(0.85 0.1 0.1)` / `1.0` / `1.5` | 删除线颜色、透明度与细条高度（pt） |
| `seshat-reader-select-highlight-scope` | `line` | 框选高亮的取字范围：`line`（整行吸附：框碰到某行任一字符即高亮整行）/ `region`（只高亮框内字符，旧行为） |
| `seshat-reader-select-highlight-granularity` | `line` | 字级高亮粒度（仅 `region` 作用域）：`line`（按行合并）/ `character`（逐字符） |
| `seshat-reader-select-highlight-gap-ratio` | `0.8` | 行内水平间隙断点（行高倍数）；中文正文实测约 3.4 段/行，想更连贯可上调 |
| `seshat-reader-select-highlight-shrink-ratio` | `0.8` | 高亮矩形垂直高度收缩比（围绕各自中心，只改高度、不改 x 与 `:rect`）；`1.0` 关闭收缩，有效 `0.3`–`1.0` 越界夹紧 |
| `seshat-reader-select-flash-duration` | `2.0` | 框选后闪现选区高亮的秒数，`<= 0` 关闭 |
| `seshat-reader-select-copy-to-kill-ring` | `nil` | 选区文本是否同时进 kill ring |

### 搜索

| 变量 | 默认值 | 作用 |
|---|---|---|
| `seshat-reader-search-limit` | `1024` | 单页向动态模块请求的命中上限（C 侧夹到 1..10000，**实际收集**硬上限也是 1024；达上限时状态行提示「仅显示前 1024 条」） |
| `seshat-reader-search-max-matches` | `20000` | 整次搜索保留的命中总数上限，达到即停止扫描并提示「命中过多」；`nil` 表示不限制（不推荐） |
| `seshat-reader-search-color` | `(1.0 0.45 0.0)` | 命中填充色 RGB（默认橙，与批注黄 / 下划线蓝可区分） |
| `seshat-reader-search-alpha` | `0.55` | 命中填充透明度（比批注 highlight 的 `0.35` 更实，便于在已有高亮之上辨认） |

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
| `seshat-reader-translate-stream` | `t` | 流式增量输出（骨架写一次 → 只替换正文区 → 完成不重写）；引擎不支持流式或取 `nil` 时退回「完成即整体渲染」 |
| `seshat-reader-translate-engines-pick` | `all` | 多引擎结果展示：`all`（全部成功结果，每条 `【引擎名】` 标注 + `---` 分隔）/ `first`（第一个成功结果，无标签）/ `last`（最后一个成功结果，无标签） |
| `seshat-reader-translate-follow-up-max-rounds` | `6` | 追问保留的轮数上限，超出**丢弃最早轮次**（首轮原文与首轮解释始终保留）；`0` = 不带任何历史轮次 |

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
2. 高亮链路是否需要重启：`(fboundp 'seshat-reader-dyn--add-highlight)` 与 `(fboundp 'seshat-reader-dyn--add-decoration)` 都应为 `t`——任一为 nil 表示加载的 `.so` 太旧（后者缺失时 underline / strikeout 与自定义配色都画不出来），重新 `make all` 并**重启 Emacs**。
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

**按 `?` 没反应怎么办**

先确认键位与加载状态：在阅读 buffer 里 `(key-binding (kbd "?"))` 应为 `seshat-reader-help`、`(autoloadp (symbol-function 'seshat-reader-help))` 为 `t`（或 `(require 'seshat-reader-help nil t)` 返回非 nil，说明模块可加载——autoload 已注册，无需预先 require）。若手动管理 load-path，确认 `seshat-reader-help.el` 与 `seshat-reader.el` 在**同一目录**（autoloads 与 `require` 都按文件名找）。`?` 只在阅读 buffer 里被本包接管，其它 buffer 仍是 `describe-mode`——当前 buffer 不是 `seshat-reader-mode` 当然没反应。仍为 `nil` 说明加载的是旧 `.elc`（键位表里还没有这一行）：`make clean all` 后重启 Emacs。

**面板里按 `q` / `n` / `p` / `RET` 没反应（evil 用户）**

已修：evil 的 normal state 排在 major-mode / minor-mode map 之前，会先吃掉这些单键（`q` = `evil-record-macro`、`n` / `p` = evil 的搜索/粘贴、`RET` = `evil-ret`），面板自己绑的键根本收不到。本包现在在**面板显示的统一漏斗**里把面板 buffer 切到 evil 的 **emacs state**（`evil-emacs-state`），故译文/解释面板、搜索结果侧栏、批注列表、目录面板里 `q`（关面板）、`n` / `p`（下一个/上一个）、`RET`（跳转）都直接生效；阅读 buffer 仍是 normal state。验证：evil 用户把光标放进任一面板后 `(evil-state)` 应为 `emacs`、`(key-binding (kbd "q"))` 应为 `seshat-reader-sidebar-quit`。若仍是 normal state / 键被吃掉，说明加载的是旧 `.elc`（`make clean all` 后重启 Emacs），或你在自己配置里对该面板 buffer **显式**重设了 state（如 `(evil-normal-state)` / `evil-set-initial-state`），此时以你的配置为准——删掉那条覆盖即恢复；也可手动 `M-x evil-emacs-state` 临时切回。

**追问时冒出 `*Seshat gt follow-up*` 缓冲区，PDF 被挤到左边**

已修（2026-10-26）：追问的答案原本写在隐藏中转 buffer `" *Seshat gt follow-up*"` 里，但 `gt-buffer-render` 在请求完成时会**再**调一次 `display-buffer`（不带 action），从 `display-buffer-alist` 的默认动作落到「弹窗」；`:window-config` 只挡得住初始化那一次。现在两个中转 buffer 名（`" *Seshat gt*"` 与 `" *Seshat gt follow-up*"`）都由 `seshat-reader-translate--ensure-hidden-gt-buffers` 登记为 `(display-buffer-no-window)` + `(allow-no-window . t)`，两次显示都落空。验证：`M-: (display-buffer (get-buffer-create " *Seshat gt follow-up*"))` 应返回 `nil` 且**不弹窗**；仍弹窗说明加载的是旧 `.elc`（`make clean all` 后重启 Emacs）。

**evil 下按 `?` 变成了反向搜索（`evil-search-backward`）**
已修：evil 的 normal state 把 `?` 绑在 `evil-normal-state-map`，而 state map 经 `emulation-mode-map-alists` 排在 major-mode map **之前**，所以 `seshat-reader-mode-map` 里的 `?` 被压掉。包内用 `evil-define-key*` 把 normal state 的 `?` 补绑到 `seshat-reader-help`（只写本 mode 的 auxiliary keymap，不动 evil 全局表，也不碰 `/`、`n`、`N`）。验证：evil 用户（已启用 `evil-local-mode`、normal state）在阅读 buffer 里 `(key-binding (kbd "?"))` 应为 `seshat-reader-help`；仍为 `evil-search-backward` 说明加载的是旧 `.elc`——`make clean all` 后重启 Emacs。阅读器里的搜索本来就走 `C-s`（基于页面坐标，不用 buffer 文本），故 `?` 让给帮助页；若确实想保留 evil 的反向搜索，在自己配置里覆盖即可：`(evil-define-key* 'normal seshat-reader-mode-map (kbd "?") #'evil-search-backward)`——本包只在加载时注册一次，不会抢回用户的覆盖。`M-o` 无需此类补绑（evil 未占该键），若将来某个 evil 版本占了它，用同一条 `evil-define-key*` 覆盖即可。

## 12. 已知限制

以下条目全部出自 [`../openspec/tech-debt.md`](../openspec/tech-debt.md)，如实列出，未做美化。

1. **旋转页的高亮可能错位**：选区采集明确不支持旋转页，`rect` 是未旋转页面坐标而 C 侧按含 `rotate` 的 `ctm` 绘制，两者对同一 `rect` 解释不一致。
2. **ink 笔迹只做了数值级坐标对照，未做真机肉眼确认**：ink 与 `rect:` 同为页面 pt、原点左上、y 向下，实测同一形状的差异行中心 `80.0` vs `80.0`，因此实现**不做 y 翻转**；但「同一形状在 Android 与 Emacs 上看起来一致」仍需真机对照（见 tech-debt）。另外单笔超过 1024 点会被截断为前 1024 点（不丢整笔），超长笔迹在页面上显示不完整。
3. **颜色与 alpha 可配但只在 Lisp 侧**：颜色/透明度/细条粗细是 defcustom（见 §10），改配色后走 9 参 `--add-decoration`；C 侧编译期常量仅作默认值，不读用户配置。
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
26. **`character` 粒度会撞 500 段锚上限**：逐字符矩形可达数千条，`--anchor` 按写入端上限只写前 500 段（并提示一次），页面下部因此**没有高亮**；批注本身仍可创建。`line` 粒度（默认）每页通常几十段，不受影响。解除条件见 tech-debt（先按行合并再写入，或提高上限并重估 64 KB location 长度）。
27. **同一处多段高亮不会叠深**：装饰按颜色分组进同一 path 一次填充，因此多段重叠仍是一个透明度——这是有意的（避免出现深浅不匀的色块），不是渲染缺陷。

## 13. 开发者备注

### 目录结构

| 文件 | 职责 |
|---|---|
| `seshat-reader.el` | major mode、键位表、翻页/滚动/缩放/旋转/适配、页面 overlay 与几何、跨页 strip、C 模块加载与构建 |
| `seshat-reader-help.el` | `?` 帮助页：按运行时 keymap 解析键位、功能简介与面板行为（零依赖，autoload 懒加载） |
| `seshat-reader-select.el` | 鼠标框选取文 + 选区闪现 |
| `seshat-reader-annotation.el` | 批注 CRUD、`document_id` / `location` 解析、页面高亮投喂、批注列表 |
| `seshat-reader-annotation-queue.el` | 离线队列（读写、原子写、定时同步） |
| `seshat-reader-search.el` | 跨页文本搜索：整本扫描、按页缓存、`n` / `p` 临时键表、命中装饰投喂、左侧搜索结果侧栏（`kind=search`） |
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

> **`make all` 不包含 `check-parens`**：它只做 `.so` + autoloads + 字节编译 + checkdoc，改完 `.el` 后需**单独**跑括号检查，否则括号不平衡可能被 checkdoc/编译静默放过（实测该 Makefile 无 `check-parens` 目标）。单文件可用
> `emacs --batch -Q -l <文件> --eval '(check-parens)'`，或 `elisp_check_parens` 工具。

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

现有套件：`seshat-reader-page-join-test.el`、`seshat-reader-sidebar-test.el`（**134 例**）、`seshat-reader-outline-test.el`、`seshat-reader-annotation-test.el`、`seshat-reader-annotation-queue-test.el`、`seshat-reader-annotation-v8-test.el`、`seshat-reader-annotation-decoration-test.el`（21 例）、`seshat-reader-annotation-ink-test.el`（24 例）、`seshat-reader-search-test.el`（**38 例**）、`seshat-reader-select-flash-test.el`、`seshat-reader-select-merge-test.el`（18 例）、`seshat-reader-select-scope-test.el`（7 例）、`seshat-reader-select-report-test.el`（**7 例**，M12 T8a 新增：框选回显只报行列数、`seshat-reader-select-message-limit` 已删除）、`seshat-reader-translate-test.el`（**143 例**）、`seshat-reader-reference-test.el`、`seshat-reader-resize-test.el`、`seshat-reader-etaf-test.el`、`seshat-rest-test.el`、`seshat-state-test.el`、`seshat-transport-test.el`、`seshat-conflict-test.el`（10 例）、`seshat-merge-test.el`（13 例）、`seshat-sync-cmd-test.el`（14 例）、`seshat-sync-test.el`（77 例）、`seshat-reading-test.el`（**45 例**）。**前置**：`seshat-render-core.so` 已构建，否则加载 `seshat-reader` 会触发交互式构建询问并阻塞 batch 运行。

**必须逐文件运行**：一次 `emacs --batch` 加载全部测试文件时，`seshat-reader-annotation-test.el` 与 `seshat-reader-annotation-queue-test.el` 各有 3 个列表渲染用例会失败——同时加载 `etaf` 测试后 `etaf-ui` 变为可用，批注列表改走 EBOX/ETAF 渲染，而那两个用例断言的是纯文本（如 `"没有批注"`）。这是**既有基线特性、不是回归**：全仓用例总数按逐文件求和计（当前 **25** 个文件合计 **993** 例，0 unexpected / 0 skipped；本轮「搜索命中在阅读与结果侧栏之间双向同步」带入 search 套件 30 → **38**；上一轮「追问中转 buffer 隐藏 + 面板内 evil emacs state + 翻译/解释 toggle 语境对应」带入 translate 套件 138 → **143**、sidebar 套件 132 → **134**；再上一轮「重开按最近显示顺序 + 搜索侧栏补 `C-c w`」带入 sidebar 套件 126 → **132**；再上一轮「M-o 面板键位 / 重开位置 / evil 下 ? 补绑」带入 sidebar 套件 120 → **126**；再上一轮「搜索侧栏纳入面板机制」带入 sidebar 套件 117 → **120**）。跑全仓脚本见下（`for` 循环逐文件执行，任一文件非零退出即整体失败）：

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
- 渲染层的不变量（装饰在反色/gamma **之后**、写 PNM **之前**绘制；`rect_to_page_space` 是唯一坐标换算点；装饰表在派发时快照进 `DrawThreadArgs`，stroke 点列**逐条深拷贝**）改动前先读 [`architecture.md`](architecture.md) 对应小节。
- 装饰条数 100000、坐标 ±1e6 点、每笔 stroke 1024 点、outline 标题 8192 字节、批注 `location` 64 KB / 2000 段 `rect:`（写入端 500 段）是防御上限，不要随手放宽。
