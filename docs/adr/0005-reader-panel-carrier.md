# ADR-005：阅读器面板承载由 side window 改为 child frame 覆盖

## 状态
已接受（2026-10-25）

## 背景
Emacs 阅读器的面板（`outline` 目录 / `annotations` 批注列表 / `translate` 译文与解释）从 M11.7 起由承载层 `seshat-reader-sidebar` 统一显示，M12 起默认落在**右侧 side window**（`display-buffer-in-side-window` + 独立 slot），底部模式（`below-selected` / `at-bottom`）作为备选。

问题出在承载方式与阅读器版面的耦合上。阅读器的页面几何完全由**当前窗口的像素尺寸**决定：`--contain-scale` / `--fit-scale` 按窗口宽高算缩放，居中靠 `before-string` 的 `:align-to`，窗口尺寸变化时 `--recenter-window` 同步重算并排一次 idle `--refit-window`（必要时重渲染清晰位图）。

窗口承载的面板是同一个 frame 的窗口树成员，因此：

- 显示 / 收起面板 → 阅读窗口被挤压或扩张 → 触发 `window-size-change-functions` → 重新适配 → 用户看到页面「跳一下」；
- 译文面板在**流式输出期间按内容行数自适应高度**（`--fit-height-for-content`），每来一段增量就改一次布局 → 跳动从一次性变成持续抖动；
- 面板自身滚动、重绘时也可能间接触发同一链路（同 frame 内的窗口尺寸再分配）。

即「面板刷新不得改变阅读窗口尺寸」在窗口承载下**无法由结构保证**，只能靠去抖、抑制动画、尺寸记忆等特例去掩盖。

## 决策
面板承载方式改为由 `seshat-reader-panel-carrier` 统一决定，**默认 `childframe`**：

1. **child frame 覆盖**：面板显示为贴在父 frame 右上角的 child frame，**不参与窗口树**。面板的开合、刷新、滚动在结构上不可能改变阅读窗口的像素尺寸，因此阅读器不会被拖进 refit 链路。
2. **固定几何**：宽 = 父 frame 像素宽 × `seshat-reader-panel-width`（默认 `0.34`），高 = 父 frame 像素高 × `seshat-reader-panel-height`（默认 `0.45`），距父 frame 右 / 上边缘各 `seshat-reader-panel-margin`（默认 `16`）像素，**打开那一刻固定、全程不 resize**；内容超出后在面板窗口内滚动。多个面板同时存在时由 `--cf-position` **纵向堆叠**。
3. **逐 kind 覆盖**：`seshat-reader-panel-carrier-alist`（默认 `((annotations . window))`）按 kind 覆盖全局 carrier。批注列表默认**保留窗口承载**——条目多、需要长列表浏览与逐条跳转，覆盖浮层既遮挡正文又放不下。
4. **回退路径**：① 非图形环境（`display-graphic-p` 为 nil）一律回退 `window`（child frame 只存在于图形终端）；② `childframe` 建不出 frame（父 frame 非图形、面板尺寸算不出）时 `--cf-show` 返回 nil，显示层自动走窗口后端，不抛错。
5. **窗口承载原样保留**：`seshat-reader-sidebar-position` / `-width` / `-height` / `-min-height` / `-max-height` / `seshat-reader-outline-sidebar-position` / `-width` 全部照旧，只在 carrier 为 `window` 的 kind 上生效——用户可逐 kind 混用两种承载。
6. **配套调整**：面板窗口设 window parameter `mode-line-format` 为 `none`（去 mode-line，`header-line` 保留）；面板内 `q` 统一走 `seshat-reader-sidebar-quit`（按 buffer 名推断 kind，按承载单元分派 `delete-window` / `delete-frame`）；阅读器侧 `C-c C-o` 绑无参的 `seshat-reader-sidebar-toggle`；`seshat-reader-panel-hide-on-buffer-change`（默认 `t`）在切出阅读器 buffer 时关闭 child frame 面板。

## 理由
- **根因是耦合，不是动画**：跳动来自「阅读器版面 ∝ 窗口像素尺寸」这一前提。只要面板占窗口树，任何面板驱动的尺寸变化都会重算版面。child frame 把面板移出窗口树，等于把「面板刷新不得改动阅读窗口尺寸」编码为结构性不变量，而不是继续加去抖特例。
- **固定尺寸是流式渲染的前提**：译文现在边生成边显示（`seshat-reader-translate-stream`），如果面板仍按内容自适应，整段生成过程都在改 frame 布局；固定尺寸 + 内部滚动 + 跟随底部（`seshat-reader-panel-follow-bottom`）把「新内容进入视野」与「阅读窗口尺寸不变」解耦。
- **窗口承载的能力并不需要丢弃**：side window 的「并排不遮挡」对**批注列表**仍然最优（条目多、要逐条跳转、要能长期停留），因此做成 per-kind 可覆盖，默认让批注留窗口、目录与译文浮起。
- **代价可控**：非图形回退有明确判据，多面板堆叠有确定算法（纵向顺排），popper 只影响窗口承载的面板。

## 替代方案
- **继续用 side window + 去抖 / 抑制 refit**：否决。抑制 refit 会让「窗口变窄后页面不适配」这类**真实**需求失效，去抖只能把跳动推迟到用户停止操作之后；而且流式自适应高度会让事件源源不断，去抖等于把抖动变成低频跳动。本质是掩盖耦合，不是消除耦合。
- **底部窗口（`below-selected` / `at-bottom`）**：否决为默认。底部面板压缩的是**阅读窗口高度**，与 `fit` 缩放的关系比左右分栏更直接（高度变化立刻改变 `--contain-scale`），跳动更明显；且底部整宽面板会遮住页面下方正文。
- **posframe**：否决。posframe 定位是相对**光标 / 窗口**的一次性摆放，不随父 frame 尺寸变化自动重排；面板内需要原生折行、滚动、isearch、复制与多轮追加（译文是 Markdown 只读 buffer），posframe 的浮动窗口 + 失焦消失语义与「面板长期停留、可持续追问」冲突。posframe 仍保留为 `seshat-reader-translate-render` 的 `pop` / `pin` 选项，服务一次性查看场景。
- **独立 frame（`make-frame`）而非 child frame**：否决。独立顶层 frame 会进 WM 管理（任务栏、焦点切换、Alt-Tab），与「阅读时随手看一眼译文」的使用方式不符，也失去「跟随父 frame 位置」的确定性。
- **自绘 overlay 在阅读窗口内绘制面板**：否决。overlay 无法承载可编辑 / 可滚动的独立 buffer 内容（译文是 Markdown 只读 buffer，需要 isearch 与逐轮追加），且与页面 image overlay、居中 `before-string` 争夺同一批显示资源。

## 后果
- **正面**：面板开合 / 刷新 / 流式输出不再改变阅读窗口尺寸，阅读器彻底退出「抖动—refit」循环；面板几何在会话内可预期（固定尺寸），流式输出有稳定的可视区域；子 frame 可去 mode-line，视觉更干净；两种承载可逐 kind 混用，批注仍可享受 side window 的并排语义。
- **负面**：child frame 只存在于图形终端，必须维护两条回退路径（判据 + 软回退）；面板尺寸固定后长内容只能滚动，读者失去「拖高一点」的手工调法（改用 `seshat-reader-panel-height`）；child frame 不属于任何窗口树，切走 buffer 后必须显式关闭（`seshat-reader-panel-hide-on-buffer-change`），否则会盖在别的窗口上；多面板需纵向堆叠算法，否则互相重叠。
- **风险**：popper 经 `display-buffer-alist` 接管 popup，child frame 面板不经过 `display-buffer`，`C-'` 对它无效（面板内 buffer 仍可用 popper 打开成普通窗口）；child frame 的像素级定位依赖父 frame 的可视尺寸（`frame-native-width` 一类取值），在多显示器 / 缩放比例异常的配置下可能偏位，需要按 frame 而非按屏幕求值。

## 实现要点
- 承载分派：`seshat-reader-sidebar--carrier-for-kind`（alist 命中项 → 全局值 → 非法值静默回落 `window`）是**唯一**判据，显示层不再假设「承载单元一定是窗口」。
- childframe 后端：`--cf-size`（像素几何）→ `--cf-parameters`（字符单位的初始宽高，供 `make-frame` 使用）→ `--cf-show`（复用 / 新建）→ `--cf-place`（像素级收口 + 排除自身后计算堆叠位置）→ `--cf-suppress-mode-line`；`--cf-close` 走 `delete-frame`。
- 失败回退：`--cf-show` 返回 nil 时显示层转调窗口后端（`--display-window`），对调用方透明。
- 生命周期：`--hide-cf-on-buffer-change` 挂在**全局** `window-buffer-change-functions`（buffer-local 钩子在切走时已绑错 buffer），三个早期返回保证每次换 buffer 都廉价。
