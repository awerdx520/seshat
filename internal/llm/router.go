package llm

import (
	"context"
	"fmt"
)

// Router 按 Route 将对话请求分发到云端或本地后端。
type Router struct {
	// cloud 是云端后端，nil 表示未配置。
	cloud Client
	// local 是本地处理节点后端，nil 表示未配置。
	local Client
}

// NewRouter 构造 Router。cloud 与 local 中任一可为 nil（表示该后端未配置），
// 此时路由到该后端的请求会返回错误。
func NewRouter(cloud, local Client) *Router {
	return &Router{cloud: cloud, local: local}
}

// Chat 使用默认路由（云端）发送对话，实现 Client 接口。
func (r *Router) Chat(ctx context.Context, messages []Message) (string, error) {
	return r.ChatRoute(ctx, RouteCloud, messages)
}

// ChatRoute 按 route 分发对话请求：
// RouteLocal 走本地后端，其余（含 RouteCloud 与未知值）一律走云端后端。
func (r *Router) ChatRoute(ctx context.Context, route Route, messages []Message) (string, error) {
	switch route {
	case RouteLocal:
		if r.local == nil {
			return "", fmt.Errorf("llm: 本地后端未配置")
		}
		return r.local.Chat(ctx, messages)
	default:
		if r.cloud == nil {
			return "", fmt.Errorf("llm: 云端后端未配置")
		}
		return r.cloud.Chat(ctx, messages)
	}
}
