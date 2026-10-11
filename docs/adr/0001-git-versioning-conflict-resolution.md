# ADR-001：git 版本化 + ETag 乐观锁处理多端文本冲突

## 状态
已接受（2026-10-11）

## 背景
笔记系统三端（桌面 Emacs、Android、外部应用）通过 WebDAV 读写文本文件（org）。WebDAV 是整文件替换模型（PUT 覆盖），且外部应用不受控制（不会做合并）。多端并发修改同一文件时，需保证：不丢数据、可合并、可恢复。

## 决策
采用「服务端 git 版本化 + WebDAV ETag 乐观锁 + 自有客户端三方合并」：

1. 服务端用 git 管理 org/文本文件目录，每次 WebDAV 写操作（PUT/DELETE/MOVE）后自动 commit（记录来源）。
2. ETag 用 git blob hash 派生，支持 WebDAV 标准 If-Match 乐观锁。
3. 自有客户端（Emacs/Android）PUT 带 If-Match，遇 412 拉取「最新版 + 共同祖先」做三方合并后重试。
4. 外部应用直接覆盖，服务端 commit 保留旧版本，数据永不丢失。
5. 二进制附件不进 git，走内容寻址 + 「附件清单」文件纳入 git。

## 理由
- CRDT 与 WebDAV 整文件替换模型不兼容（外部应用无法产生结构化操作）。
- 纯客户端冲突副本无法覆盖不受控的外部应用。
- git 提供成熟的 3-way merge、历史、diff、revert、blame，且直接支撑「服务端管理/整理」需求。

## 替代方案
- CRDT（Yjs/automerge）：与整文件 PUT 模型冲突，放弃。
- 后写覆盖 + 冲突副本：外部应用兜不住，放弃。

## 后果
- 正面：数据不丢、自有客户端自动合并、服务端免费获得版本管理能力。
- 负面：需设计 git 自动 commit 治理（commit 数量、gc）；libgit2 集成复杂度。
