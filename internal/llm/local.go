package llm

import (
	"context"
	"net/http"
	"strings"
)

// defaultLocalNodeURL 是本地处理节点的默认地址（Ollama 默认端口 11434）。
const defaultLocalNodeURL = "http://localhost:11434"

// LocalNodeClient 通过本地处理节点（家庭机器 / NAS 上运行的 Ollama 等）
// 的 OpenAI 兼容端点访问本地 LLM。请求路径为 {nodeURL}/v1/chat/completions。
type LocalNodeClient struct {
	// baseURL 是节点地址根，已去掉尾部斜杠。
	baseURL string
	// model 是请求体中携带的本地模型名，默认空（需用 WithModel 设置）。
	model string
	// http 是执行请求的 HTTP 客户端。
	http *http.Client
	// urlConfigured 记录构造时是否显式提供了节点 URL；false 表示回退到默认地址。
	// 供 Router.LocalDirectAvailable 判断「同步直连」是否已配置（见 backend.go）。
	urlConfigured bool
}

// NewLocal 构造 LocalNodeClient。nodeURL 为空（或仅含空白）时使用默认值
// http://localhost:11434，并把该实例标记为「未显式配置 URL」
// （Router.LocalDirectAvailable 据此返回 false）。
// 默认不带模型名，可用 WithModel 指定（如 "qwen2.5:7b"）。
func NewLocal(nodeURL string) *LocalNodeClient {
	configured := strings.TrimSpace(nodeURL) != ""
	if !configured {
		nodeURL = defaultLocalNodeURL
	}
	return &LocalNodeClient{
		baseURL:       strings.TrimRight(nodeURL, "/"),
		http:          &http.Client{Timeout: defaultTimeout},
		urlConfigured: configured,
	}
}

// WithModel 设置本地模型名并返回接收者本身，便于链式调用。
func (c *LocalNodeClient) WithModel(model string) *LocalNodeClient {
	c.model = model
	return c
}

// Chat 发送对话并返回助手回复正文，实现 Client 接口。
// 本地节点通常不校验认证，因此不发送 Authorization 头。
func (c *LocalNodeClient) Chat(ctx context.Context, messages []Message) (string, error) {
	return chatCompletions(ctx, c.http, c.baseURL+"/v1/chat/completions", "", c.model, messages)
}
