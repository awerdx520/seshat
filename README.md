# Seshat — 个人笔记系统（客户端仓）

> 本仓只含客户端（Emacs + Android）；服务端已迁至 **keystone** 仓，见 [`docs/SERVER-CONTRACT.md`](docs/SERVER-CONTRACT.md)。

单用户、云 VPS 自托管的个人知识中枢；客户端双端协作，服务端能力（WebDAV + REST + git 版本化 + 静态加密 + FTS5 + LLM 增值）由 keystone 提供。

## 两端
- **桌面端**：Emacs（**32.0+**，阅读器渲染后端使用 Emacs 32 的 canvas 图像对象）+ 同步插件，复用 org-mode
- **Android 端**：Kotlin 单 App 双模块（① 电子书阅读/批注 ② org GTD）

## 核心特性
- WebDAV 文件同步（内部通道 + 对外标准出口）
- git 版本化 + ETag 乐观锁 + 三方合并（多端冲突不丢数据）
- 阅读器：epub/pdf 渲染、批注、跨页选择、目录、主题与手写
- LLM 增值（云端 API 与本地处理节点由服务端侧承载）

## 阅读器渲染：默认两阶段异步（P2-B，2026-10-29）

**行为变更**：多页连续布局下滚动进入新页，不再「同步渲染、立即清晰」，而是**布局先定型、像素后补**——先把页行按最终页高立起来（占位态），像素由 idle / 周期 timer 在命令返回后补上。因此进入新页时可能出现短暂的**「空白 → 清晰」过渡**，但**页高与滚动范围不变、不会跳变**（占位态与已渲染态页高逐像素相等）。

- **正在看的页永远同步**：point 所在页 + 沿滚动方向相邻的一页始终同步渲染，任何情况下不会停在你正读的那一页上空白。
- **超时兜底**：队列超过 `seshat-reader-render-async-timeout`（默认 `1.0` 秒）仍未排空，则下一条命令强制同步渲染本窗口可见范围。
- **回滚口径**：`(setq seshat-reader-render-async nil)` 即完全回到旧的逐页同步渲染（结果布局逐字节等价，只差渲染时机）；改完下一条命令生效，无需重启。
- **C 侧改动需重编译 + 重启**：本开关只覆盖 elisp 路径；渲染模块（`seshat-render-core.so`）改动必须 `make -C emacs/seshat-reader clean all` 重编并重启 Emacs。

| 变量 | 默认值 | 一句话 |
|---|---|---|
| `seshat-reader-render-async` | `t` | 两阶段渲染开关；`nil` = 回到逐页同步（运行时回滚口） |
| `seshat-reader-render-async-timeout` | `1.0` | 队列存活超过该秒数即强制同步本窗口可见范围（`0`/负数 ⇒ 几乎总是同步） |
| `seshat-reader-render-idle-delay` | `0.05` | **周期推进间隔**（秒），不是「idle 延迟」：idle timer 只启动首轮，队列由 `run-at-time` 周期 timer 推进 |
| `seshat-reader-render-idle-batch` | `2` | 每轮最多渲染页数（单轮成本上限）；扫描书 / 大页建议降到 `1` |

逐项语义与边界见 [docs/configuration.md](docs/configuration.md)「阅读器两阶段渲染」，用户视角见 [docs/emacs-reader.md](docs/emacs-reader.md) §7。

## 文档
- 服务端契约与迁移边界：[docs/SERVER-CONTRACT.md](docs/SERVER-CONTRACT.md)
- Emacs 阅读器使用手册（安装与加载见 §2）：[docs/emacs-reader.md](docs/emacs-reader.md)
- Android 客户端结构与构建：[docs/android.md](docs/android.md)
- 阅读器面板载体决策：[docs/adr/0005-reader-panel-carrier.md](docs/adr/0005-reader-panel-carrier.md)
- 实施计划：openspec/completed/personal-notes-system.md
- 决策日志：openspec/decisions.md
- 路线图：openspec/roadmap.md
- 技术债：openspec/tech-debt.md

## 开发
- 克隆后先安装提交前钩子（密钥扫描）：`pre-commit install`
- 钩子全量运行：`pre-commit run --all-files`（gitleaks 只扫暂存区，需全量/历史内容检查时直接跑 `gitleaks git`）
- Emacs 端 ERT 测试：`make -C emacs/tests ert`（入口与判据见 `emacs/tests/README.md`）

## 快速开始（客户端）
- Emacs：按 [docs/emacs-reader.md](docs/emacs-reader.md) §2 安装与加载，§3 起为阅读操作
- Android：构建与验证命令见 [docs/android.md](docs/android.md)
- 连接服务端：客户端配置变量（`seshat-sync-*`、`seshat-rest-*`、`seshat-reader-*`）不变；部署与运维见 keystone 仓
