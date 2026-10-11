package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// 云端后端默认值。
const (
	// defaultCloudBaseURL 是云端 OpenAI 兼容 API 的默认地址（DeepSeek）。
	defaultCloudBaseURL = "https://api.deepseek.com/v1"
	// defaultCloudModel 是云端默认模型。
	defaultCloudModel = "deepseek-chat"
)

// defaultTimeout 是所有后端 HTTP 请求的兜底超时。
const defaultTimeout = 60 * time.Second

// CloudClient 通过 OpenAI 兼容的 chat/completions 接口访问云端 LLM（默认 DeepSeek）。
type CloudClient struct {
	// baseURL 是后端地址根，已去掉尾部斜杠，请求路径在其后追加 /chat/completions。
	baseURL string
	// apiKey 是 Bearer 令牌，为空时不发送 Authorization 头。
	apiKey string
	// model 是请求体中携带的模型名。
	model string
	// http 是执行请求的 HTTP 客户端。
	http *http.Client
}

// NewCloud 构造 CloudClient。
// apiKey 为空时不发送 Authorization 头（后端通常会返回 401）。
// baseURL 为空时使用默认值 https://api.deepseek.com/v1；
// model 为空时使用默认值 deepseek-chat。
func NewCloud(apiKey, baseURL, model string) *CloudClient {
	if baseURL == "" {
		baseURL = defaultCloudBaseURL
	}
	if model == "" {
		model = defaultCloudModel
	}
	return &CloudClient{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		model:   model,
		http:    &http.Client{Timeout: defaultTimeout},
	}
}

// Chat 发送对话并返回助手回复正文，实现 Client 接口。
func (c *CloudClient) Chat(ctx context.Context, messages []Message) (string, error) {
	return chatCompletions(ctx, c.http, c.baseURL+"/chat/completions", c.apiKey, c.model, messages)
}

// chatRequest 是 OpenAI 兼容 chat/completions 的请求体。
type chatRequest struct {
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
}

// chatResponse 是 OpenAI 兼容 chat/completions 的响应体（只取所需字段）。
type chatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

// chatCompletions 执行一次 OpenAI 兼容的 chat/completions 调用并返回首条回复正文。
// endpoint 为完整请求地址；apiKey 非空时以 Bearer 形式认证。
// 非 2xx 响应返回包含状态码与响应体摘要的错误。
func chatCompletions(ctx context.Context, httpClient *http.Client, endpoint, apiKey, model string, messages []Message) (string, error) {
	if len(messages) == 0 {
		return "", fmt.Errorf("llm: 对话消息为空")
	}

	payload, err := json.Marshal(chatRequest{Model: model, Messages: messages})
	if err != nil {
		return "", fmt.Errorf("llm: 序列化请求体失败: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("llm: 构造请求失败: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("llm: 请求 %s 失败: %w", endpoint, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return "", fmt.Errorf("llm: 读取响应失败: %w", err)
	}

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return "", fmt.Errorf("llm: 后端返回 %d: %s", resp.StatusCode, summarize(body))
	}

	var parsed chatResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", fmt.Errorf("llm: 解析响应失败: %w", err)
	}
	if len(parsed.Choices) == 0 {
		return "", fmt.Errorf("llm: 响应不含 choices: %s", summarize(body))
	}

	return parsed.Choices[0].Message.Content, nil
}

// maxResponseBytes 限制读取的响应体大小，避免异常响应撑爆内存。
const maxResponseBytes = 1 << 20 // 1 MiB

// maxSummaryBytes 限制错误信息中响应体摘要的长度。
const maxSummaryBytes = 200

// summarize 返回响应体的单行摘要，供错误信息使用。
func summarize(body []byte) string {
	s := strings.TrimSpace(string(body))
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > maxSummaryBytes {
		s = s[:maxSummaryBytes] + "…"
	}
	return s
}
