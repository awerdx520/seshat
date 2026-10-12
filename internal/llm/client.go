// Package llm 提供 seshat 的 LLM 接入层：统一的对话客户端抽象与路由策略。
//
// 按 ADR-002 的混合后端设计，LLM 能力由两类后端提供：
//   - 云端 API：DeepSeek 等 OpenAI 兼容的 chat/completions 服务（见 CloudClient）；
//   - 本地处理节点：家庭机器 / NAS 上运行 Ollama 等本地推理服务（见 LocalNodeClient）。
//
// 两类后端都通过 Client 接口接入，由 Router 按 Route 选择目的地。
// 本包只负责传输与协议适配，不含任何业务语义；消息内容不经加密（无 E2EE）。
package llm

import "context"

// 对话角色常量，对应 OpenAI 兼容协议中的 role 字段。
const (
	// RoleSystem 是系统提示词角色。
	RoleSystem = "system"
	// RoleUser 是用户消息角色。
	RoleUser = "user"
	// RoleAssistant 是助手回复角色。
	RoleAssistant = "assistant"
)

// Message 是一条对话消息。Role 取值见 RoleSystem / RoleUser / RoleAssistant，
// Content 为消息正文（未加密明文）。
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Client 是与单个 LLM 后端交互的最小接口。
// Chat 发送一段对话并返回助手回复的正文；实现需尊重 ctx 的取消与超时。
type Client interface {
	Chat(ctx context.Context, messages []Message) (string, error)
}

// Route 表示一次对话请求应发送到的后端类型。
type Route string

const (
	// RouteCloud 表示使用云端 API 后端。
	RouteCloud Route = "cloud"
	// RouteLocal 表示使用本地处理节点后端。
	RouteLocal Route = "local"
)
