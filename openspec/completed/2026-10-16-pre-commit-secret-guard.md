# 提交前密钥防护（pre-commit 自动检测）

## 当前状态
- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅（用户 2026-10-16）、计划 ✅（用户 2026-10-16）
- 独立审查：✅ 计划审查 3 轮通过；✅ 代码审查通过（4 项 minor + 2 nit → 已修复 4 项、2 项记入 tech-debt）
- 独立二次验证：✅ 通过（隔离仓库复跑 6 条断言 + 2 条端到端 commit 链路断言全绿；主仓库 validate-config=0、run --all-files=0、git status 无副作用；落地物静态核对 6 项全「是」）
- 验证：L1 ✅ / L2 隔离 ✅（10 条断言 + 端到端 commit 链路）/ L3 ✅（主仓库 --all-files 退出码 0，无副作用）
- 结果：已完成并归档至 openspec/completed/2026-10-16-pre-commit-secret-guard.md；主仓库工作区未产生任何提交

## 目标

在 `/home/thomas/WorkSpace/notes` 落地**本地提交前密钥防护**，封堵两条泄漏路径：

1. **内容型泄漏**：暂存内容含密钥 → 由 gitleaks 扫描暂存区阻断。
2. **文件名型泄漏**：被 `.gitignore` 覆盖的敏感文件被 `git add -f` 强制添加（keystore / env / 私钥）→ 由文件名黑名单 hook 阻断。

同时补强 `.gitignore` 与文档，使后续克隆者知道必须执行 `pre-commit install`。

**可机械验证的验收目标**：
- `pre-commit validate-config` 退出码 0
- L2 隔离测试断言全绿（6 条隔离断言 + 1 条端到端钩子链路断言，见「验证标准」）
- 主仓库 `pre-commit run --all-files` 退出码 0（不阻塞既有工作区）
- 三处文档更新到位

## 背景事实（探索阶段实测证据）

- 仓库：Go 服务端 + Emacs Lisp 客户端 + Android；161 个已跟踪文件；21 个 commit；remote `git@github.com:awerdx520/seshat.git`，master 领先 1 个未推送提交。
- gitleaks 全历史扫描（`--log-opts=--all`）**0 命中**；工作区扫描仅命中 `android/keystore.properties`（未跟踪、被 `android/.gitignore` 覆盖、含非占位符口令）。
- 现状**无任何防护**：无 `.pre-commit-config.yaml`、无 `.git/hooks` 自定义钩子、无 `.github/`、无 `gitleaks.toml` / `.secrets.baseline`。
- 工具链：`pre-commit 4.7.0`（已装，`~/.cache/pre-commit` 144 MB）；`gitleaks` 位于 `/usr/sbin/gitleaks`，子命令为 `git`/`dir`/`stdin`（`detect` 仅兼容别名）；`gitleaks git` 支持 `--staged`、`--log-opts`、`--redact`（默认 100%）、`--config`、`--baseline-path`、`--exit-code`（默认 1）、`--no-banner`；`trufflehog` 未安装；`detect-secrets` 已损坏。
- GitHub 网络可达（`git ls-remote` 均 exit 0）。

## 设计

### 选型

采用 **pre-commit 框架**（用户已裁决，选项 A）。否决裸 git hook 方案：需每个克隆者手动 `git config core.hooksPath`、无全量扫描入口、将来接 CI 需重写。

### Hook 1：gitleaks（内容扫描，主力）

```yaml
  - repo: local
    hooks:
      - id: gitleaks
        name: gitleaks 密钥扫描（暂存区）
        entry: gitleaks git --staged --redact --no-banner
        language: system
        pass_filenames: false
        always_run: true
```

- `--staged`：只扫暂存区（即将提交的内容），契合 pre-commit 语义。
- `--redact`：命中值打码，禁止密钥值进入终端/日志/上下文。
- `--exit-code` 默认 1 → 命中即阻断提交。
- `pass_filenames: false`：gitleaks 自行读取暂存区，不需要 pre-commit 传文件名。
- `always_run: true`：**冗余但无害**（无 `files` 限制的 hook 在存在暂存文件时本就会运行），保留作显式声明。
- **实现时必须实测**（禁止凭空假设）：单独执行 `gitleaks git --staged --redact --no-banner` 是否有效；若该版本要求配合 `--pre-commit`，则在 entry 中补上。以实测退出码为准。

### Hook 2：no-secret-files（文件名黑名单，防 `git add -f`）

```yaml
      - id: no-secret-files
        name: 禁止提交敏感文件（keystore / env / 私钥）
        entry: bash -c 'for f in "$@"; do echo "拒绝提交疑似密钥文件：$f"; done; exit 1' --
        language: system
        files: '(^|/)(keystore\.properties|local\.properties)$|\.(keystore|jks|p12|pfx|pem|key)$|\.env(\..*)?$'
        exclude: '\.example(\.|$)'
```

- pre-commit 只对**暂存文件**执行 → 精确对应"即将提交"集合。
- `.env(\..*)?$` 是为了与根 `.gitignore` 的 `.env.*` 规则对齐；漏掉它会让 `git add -f .env.production` 绕过黑名单。
- `exclude: '\.example(\.|$)'` 经修订后成为**必需项**：新正则 `\.env(\..*)?$` 会命中 `deploy/seshat.env.example`，故必须放行 `*.example` 模板。
- `files` / `exclude` 为 Python 正则，匹配相对于仓库根的路径。
- 注意：`\.env(\..*)?$` 比根 `.gitignore` 的 `.env.*` 更宽——它按「路径以 `.env.` 结尾」判定，会同时拦下 `config.env.js` 这类文件。本仓库为 Go/Elisp/Android，无此类文件；将来若引入此类命名，需评估是否调整正则或加入 `exclude`。

### `.gitignore` 补强

根 `.gitignore` 的「# 敏感文件」段追加：`*.keystore`、`*.jks`、`*.p12`、`*.pfx`（当前仅有 `*.key` / `*.pem`；`release.keystore` 此前仅靠 `android/.gitignore` 兜底）。

### 文档

1. `docs/security.md`：新增 `## 6. 提交前自动检查`——钩子清单与职责、安装命令 `pre-commit install`（每个克隆执行一次）、手动全量扫描 `pre-commit run --all-files`、绕过与边界（`--no-verify`、CI 未部署）、误报处理（`SKIP=<hook-id>` 临时跳过或调整白名单，禁止把 `--no-verify` 当常规手段）、与 §3.5 禁止事项的呼应。
2. `README.md`：新增 `## 开发` 小节（新克隆须执行 `pre-commit install`；`pre-commit run --all-files` 全量自查）。
3. `CHANGELOG.md`：`## [Unreleased]` → `### 新增` 追加一条（中文，Keep a Changelog 风格）。

### 范围外（本次不做）

GitHub Actions CI、`gitleaks.toml` 自定义规则/白名单、第三方 hook（`detect-private-key` / `check-added-large-files`）、代码风格类 hook。如需追加须另行确认。

## 文档清单（Phase 4 对照用）

| 变更域 | 文档 | 需要的动作 |
|---|---|---|
| 开发工作流新增前置步骤 | `README.md` | 新增「## 开发」小节；顺带修正过时的「快速开始」占位文字 |
| 安全防护机制（新增一道防线） | `docs/security.md` | 新增 §6 提交前自动检查；同步更新 §3.4 排除清单 |
| 用户可感知变更 | `CHANGELOG.md` | Unreleased / 新增 追加一条 |
| 架构决策 | `openspec/decisions.md` | 记录选型取舍 |
| 运行时配置参数 | `docs/configuration.md` | 不涉及 |
| API / 错误码 | `docs/api.md`、`docs/errors.md` | 不涉及 |
| 计划归档 | `openspec/completed/` | 完成后移动 |

## 任务

- [x] **任务 1**：创建 `.pre-commit-config.yaml`（两个 local hook）并补强根 `.gitignore`；执行 `pre-commit install` 安装钩子到 `.git/hooks/pre-commit`
  验收：两个文件变更到位；`pre-commit validate-config` 退出码 0；`.git/hooks/pre-commit` 存在且非 `.sample`；`git config core.hooksPath` 未被意外设置。（依赖：无）
- [x] **任务 2**：实测并固化 gitleaks 命令行
  验收：在仓库干净暂存区状态下，钩子 entry 命令退出码 0；若 `--staged` 单独不可用则改为 `--pre-commit --staged` 并回写配置；命令行为**实测确认**（不是推断）。（依赖：任务 1）
- [x] **任务 3**：L2 隔离功能测试（在 `/tmp` 下新建临时 git 仓库，复制 `.pre-commit-config.yaml`，构造用例）
  验收（6 条断言；`git add -f` 仅负责把被 `.gitignore` 忽略的文件送入暂存区，
  它本身不触发钩子、退出码恒为 0；触发与判定一律以 `pre-commit run` 为准）：
  ① 暂存含假 API key（形如 `sk-` 开头的 20+ 位随机串）的文件后执行 `pre-commit run` → 非 0 退出且输出含 `gitleaks`；
  ② `git add -f foo.keystore` 后执行 `pre-commit run` → 非 0 退出且输出含 `no-secret-files`；
  ③ `git add -f secret.env` 后执行 `pre-commit run` → 非 0 退出且输出含 `no-secret-files`；
  ④ `git add -f .env.production` 后执行 `pre-commit run` → 非 0 退出且输出含 `no-secret-files`（验证修订后的 `.env.*` 覆盖）；
  ⑤ `git add -f deploy/seshat.env.example`（仅占位符内容）后执行 `pre-commit run` → 退出码 0（验证 `exclude` 正确放行模板，不误报）；
  ⑥ 暂存合法文件（如 `a.md`）后执行 `pre-commit run` → 退出码 0。
  也可用 `pre-commit run <hook-id> --files <path>` 做单 hook 定点验证。
  另加一条**端到端钩子链路断言**：在 `/tmp` 临时仓库中
  （`git init /tmp/xxx && cd /tmp/xxx`，先 `git -c user.email=t@example.com -c user.name=t commit --allow-empty -m init` 完成初始提交——
  **必须在安装钩子之前完成**，否则自测会被自己的钩子阻塞），随后执行 `pre-commit install`，
  再用 `git -c user.email=t@example.com -c user.name=t commit -m test` 触发真实提交：
  - 暂存含假密钥的文件 → `git commit` 被 `.git/hooks/pre-commit` 阻断（非 0 退出，且 `git log --oneline | wc -l` 未增加）；
  - 移除该文件、暂存合法文件后 → `git commit` 成功（`git log --oneline | wc -l` 增加 1）。
  测试后删除临时目录，主仓库工作区零影响。（依赖：任务 2）
  - 执行注意：逐条断言之间必须清空暂存区（`git reset` 或 `git rm --cached`），否则 ②③④ 残留的敏感文件会让 ⑤⑥ 预期「退出码 0」的断言误判为非 0；也可统一改用 `pre-commit run <hook-id> --files <path>` 做定点验证，避免互相干扰。
- [x] **任务 4**：主仓库 L3 全量验证
  验收：`pre-commit run --all-files` 退出码 0；执行前后 `git status --porcelain` 条数一致（无副作用）。（依赖：任务 3）
- [x] **任务 5**：文档更新（`docs/security.md` §6、`README.md`「## 开发」、`CHANGELOG.md` Unreleased）
  验收：三处内容到位、交叉链接有效、中文风格与现有文档一致。此外：
  - `docs/security.md` **§3.4** 的 `.gitignore` 排除清单（现为「`.env`、`.env.*`、`*.env`、`*.key`、`*.pem`、`secrets/`」）同步追加 `*.keystore`、`*.jks`、`*.p12`、`*.pfx`，保持与补强后的 `.gitignore` 一致。
  - **顺带修正（非必须，同一文件同一次编辑）**：`README.md` 末尾「## 快速开始」下的「（待 M0 里程碑完成后补充）」已明显过时（项目实际已推进到 M11），改写为当前可用的最小快速开始指引（`scripts/gen-secrets.sh` 生成密钥 → `docker compose up` 或按 `docs/deploy.md` 部署），或改为指向 `docs/deploy.md` 的一句话指引。
  （依赖：任务 1；可与任务 2–4 并行）
- [x] **任务 6**：决策记录——`openspec/decisions.md` 追加一条（pre-commit 框架 vs 裸 git hook 的取舍；为何暂不加自定义 gitleaks 白名单）
  验收：条目含日期 / 决策 / 理由。（依赖：任务 5）
- [x] **任务 7**：Phase 4 收尾——代码审查、计划归档至 `openspec/completed/`、记忆沉淀（由 Plan Agent 主导，非 general 子任务）

## 验证标准

- **L1**：`pre-commit validate-config` = 0；`gitleaks git --staged --redact --no-banner` = 0（干净暂存区）。
- **L2**：任务 3 的 6 条断言 + 端到端钩子链路断言全绿（隔离环境，不污染主仓库）。
- **L3**：`pre-commit run --all-files` = 0（主仓库真实全量验证）。

## 注意事项

- 本任务**不产生任何提交**；禁止使用 `git commit --no-verify`。
- gitleaks 输出必须带 `--redact`；任何报告/日志/回复不得回显密钥值（含 `android/keystore.properties` 内容）。
- 安装前确认 `.git/hooks` 无既有自定义钩子（已核实为空），不得改动无关钩子文件。
- `files` / `exclude` 用 Python 正则，实现时以 `pre-commit run no-secret-files --files <path>` 验证匹配行为。
- 工作区现有 20 条未提交变更（10 修改 / 10 未跟踪）：不得清理、不得 stash、不得提交。
- 首次 `pre-commit install` 后用户的下一次真实提交会触发钩子，必须保证干净场景下不误报（L3 覆盖）。
- Hook 只挡本机提交，挡不住 `--no-verify`、其他克隆者与历史遗留——CI 兜底属范围外，需另行决策。
