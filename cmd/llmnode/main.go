// Command llmnode 是本地处理节点 worker：运行在家庭机器 / NAS 上，通过服务端任务队列
// 领取需要本地推理的任务，调用本机 Ollama 完成推理，再把结果明文回传服务端（见 ADR-0002
// 的混合 LLM 后端设计）。
//
// 运行参数全部来自环境变量：
//
//	SESHAT_SERVER_URL  服务端根地址，必填，如 https://seshat.example.com
//	SESHAT_NODE_TOKEN  服务端节点令牌，优先使用（节点端点的专用令牌，最小权限）
//	SESHAT_AUTH_TOKEN  服务端访问令牌，未配置 SESHAT_NODE_TOKEN 时回退使用
//	OLLAMA_URL        本机 Ollama 根地址，可选，默认 http://localhost:11434
//	OLLAMA_MODEL      默认本地模型名，可选；仅当任务 payload 未自带 model 时使用
//	NODE_NAME         节点名，可选，默认取主机名
//
// 运行循环：启动时注册一次 → 轮询 GET /api/llm/tasks/poll → 有任务则调用
// POST {OLLAMA_URL}/v1/chat/completions 本地推理 → POST /api/llm/tasks/{id}/result
// 回传结果 → 无任务时休眠数秒再轮询。轮询与推理错误只记日志并重试，不退出进程；
// 收到 SIGINT/SIGTERM 时优雅退出。
//
// 本命令仅使用标准库（net/http + encoding/json），不引入外部依赖。
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// 默认值与超时常量。
const (
	// defaultOllamaURL 是本机 Ollama 的默认地址（Ollama 默认端口 11434）。
	defaultOllamaURL = "http://localhost:11434"
	// pollInterval 是无任务时两次轮询之间的休眠时长。
	pollInterval = 5 * time.Second
	// pollTimeout 是单次轮询请求的超时（轮询很快，超时应短于推理）。
	pollTimeout = 30 * time.Second
	// requestTimeout 是 HTTP 客户端整体超时（本地推理可能耗时较长）。
	requestTimeout = 5 * time.Minute
	// errorSnippetLimit 是错误信息中响应体摘要的最大字节数。
	errorSnippetLimit = 200
)

// config 保存节点运行所需的配置，全部来自环境变量（见包注释）。
type config struct {
	serverURL string // 服务端根地址，已去掉尾部斜杠
	authToken string // 服务端 Bearer 令牌
	ollamaURL string // 本机 Ollama 根地址，已去掉尾部斜杠
	model     string // 默认本地模型名，可为空
	nodeName  string // 节点名
}

// loadConfig 从环境变量装配配置并校验必填项；节点名缺省时回退到主机名。
func loadConfig() (config, error) {
	cfg := config{
		serverURL: strings.TrimRight(strings.TrimSpace(os.Getenv("SESHAT_SERVER_URL")), "/"),
		authToken: nodeAuthToken(),
		ollamaURL: strings.TrimRight(envOr("OLLAMA_URL", defaultOllamaURL), "/"),
		model:     strings.TrimSpace(os.Getenv("OLLAMA_MODEL")),
		nodeName:  strings.TrimSpace(os.Getenv("NODE_NAME")),
	}
	if cfg.serverURL == "" {
		return config{}, errors.New("环境变量 SESHAT_SERVER_URL 未设置")
	}
	if cfg.authToken == "" {
		return config{}, errors.New("环境变量 SESHAT_NODE_TOKEN 与 SESHAT_AUTH_TOKEN 均未设置")
	}
	if cfg.nodeName == "" {
		if host, err := os.Hostname(); err == nil && host != "" {
			cfg.nodeName = host
		} else {
			cfg.nodeName = "llmnode"
		}
	}
	return cfg, nil
}

// envOr 返回环境变量值；未设置或全为空白时返回 fallback。
func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

// nodeAuthToken 返回节点用于认证的令牌：优先 SESHAT_NODE_TOKEN（节点专用令牌，
// 最小权限），未配置或全为空白时回退 SESHAT_AUTH_TOKEN，兼容既有单令牌部署。
func nodeAuthToken() string {
	if tok := strings.TrimSpace(os.Getenv("SESHAT_NODE_TOKEN")); tok != "" {
		return tok
	}
	return strings.TrimSpace(os.Getenv("SESHAT_AUTH_TOKEN"))
}

// message 是一条对话消息（OpenAI 兼容协议的 role/content）。
type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// task 是服务端任务队列返回的任务（仅取节点需要的字段）。
type task struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	Payload string `json:"payload"`
	Route   string `json:"route"`
	Status  string `json:"status"`
}

// taskPayload 是任务 payload 的约定结构：messages 为对话消息；model 可选，
// 未提供时回退到配置的默认模型（OLLAMA_MODEL）。
type taskPayload struct {
	Model    string    `json:"model"`
	Messages []message `json:"messages"`
}

// chatRequest 是发给 Ollama OpenAI 兼容端点的请求体。
type chatRequest struct {
	Model    string    `json:"model,omitempty"`
	Messages []message `json:"messages"`
}

// chatResponse 是 Ollama OpenAI 兼容端点的响应体（只取首条回复）。
type chatResponse struct {
	Choices []struct {
		Message message `json:"message"`
	} `json:"choices"`
}

// node 是本地处理节点的运行时状态。
type node struct {
	cfg    config
	client *http.Client
	logger *slog.Logger
}

// newNode 用配置与日志器构造节点。
func newNode(cfg config, logger *slog.Logger) *node {
	return &node{
		cfg:    cfg,
		client: &http.Client{Timeout: requestTimeout},
		logger: logger,
	}
}

// run 阻塞运行「注册 → 轮询 → 推理 → 回传」循环，直到 ctx 被取消（收到退出信号）。
//
// 注册失败不阻塞启动（服务端可能稍后可用）；轮询与推理错误只记日志并继续下一轮，
// 使节点在网络或服务端短暂不可用时自动恢复。
func (n *node) run(ctx context.Context) error {
	if err := n.register(ctx); err != nil {
		n.logger.Warn("节点注册失败，继续运行", "node_name", n.cfg.nodeName, "error", err)
	}

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		processed, err := n.processOne(ctx)
		if err != nil {
			if ctx.Err() != nil {
				n.logger.Info("收到退出信号，节点停止")
				return nil
			}
			n.logger.Error("处理任务出错", "error", err)
		}
		if processed {
			// 刚处理完任务：立即再轮询，尽快清空队列（服务端已无 pending 任务时会
			// 返回 204，下一轮自然进入休眠）。
			continue
		}

		select {
		case <-ctx.Done():
			n.logger.Info("收到退出信号，节点停止")
			return nil
		case <-ticker.C:
		}
	}
}

// processOne 执行一轮：领取任务 → 本地推理 → 回传结果。本轮无任务时返回 (false, nil)；
// 返回值 processed 表示本轮是否领取到了任务（据此决定是否立即再轮询）。
func (n *node) processOne(ctx context.Context) (bool, error) {
	t, err := n.poll(ctx)
	if err != nil {
		return false, err
	}
	if t == nil {
		n.logger.Debug("暂无待办任务")
		return false, nil
	}

	n.logger.Info("领取任务", "id", t.ID, "kind", t.Kind)
	result, err := n.infer(ctx, t.Payload)
	if err != nil {
		// 推理失败也要回传，否则任务会永远停留在 running；失败原因写入 result 列。
		n.logger.Error("本地推理失败", "id", t.ID, "error", err)
		if reportErr := n.report(ctx, t.ID, "", err.Error()); reportErr != nil {
			return true, fmt.Errorf("回传失败原因失败: %w", reportErr)
		}
		return true, nil
	}

	if err := n.report(ctx, t.ID, result, ""); err != nil {
		return true, fmt.Errorf("回传结果失败: %w", err)
	}
	n.logger.Info("任务完成", "id", t.ID, "result_bytes", len(result))
	return true, nil
}

// register 向服务端注册本节点（启动时执行一次）。
func (n *node) register(ctx context.Context) error {
	body := map[string]string{"node_name": n.cfg.nodeName}
	var resp struct {
		NodeName string `json:"node_name"`
		Status   string `json:"status"`
	}
	url := n.cfg.serverURL + "/api/llm/nodes/register"
	if err := n.callJSON(ctx, http.MethodPost, url, body, &resp); err != nil {
		return err
	}
	n.logger.Info("节点注册成功", "node_name", resp.NodeName, "status", resp.Status)
	return nil
}

// poll 领取一条待办的本地任务；服务端返回 204（无任务）时返回 (nil, nil)。
func (n *node) poll(ctx context.Context) (*task, error) {
	ctx, cancel := context.WithTimeout(ctx, pollTimeout)
	defer cancel()

	url := n.cfg.serverURL + "/api/llm/tasks/poll"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("构造轮询请求失败: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+n.cfg.authToken)

	resp, err := n.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("轮询任务失败: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	switch {
	case resp.StatusCode == http.StatusNoContent:
		return nil, nil
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return nil, n.statusError(url, resp)
	}

	var t task
	if err := json.NewDecoder(resp.Body).Decode(&t); err != nil {
		return nil, fmt.Errorf("解析任务响应失败: %w", err)
	}
	return &t, nil
}

// infer 调用本机 Ollama 的 OpenAI 兼容端点完成一次对话推理，返回助手回复正文。
func (n *node) infer(ctx context.Context, payload string) (string, error) {
	var p taskPayload
	if err := json.Unmarshal([]byte(payload), &p); err != nil {
		return "", fmt.Errorf("任务 payload 不是合法 JSON: %w", err)
	}
	if len(p.Messages) == 0 {
		return "", errors.New("任务 payload 缺少 messages")
	}

	model := p.Model
	if model == "" {
		model = n.cfg.model
	}
	raw, err := json.Marshal(chatRequest{Model: model, Messages: p.Messages})
	if err != nil {
		return "", fmt.Errorf("序列化推理请求失败: %w", err)
	}

	url := n.cfg.ollamaURL + "/v1/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return "", fmt.Errorf("构造推理请求失败: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := n.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("调用本地 Ollama 失败: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", n.statusError(url, resp)
	}

	var out chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("解析 Ollama 响应失败: %w", err)
	}
	if len(out.Choices) == 0 {
		return "", errors.New("Ollama 响应缺少 choices")
	}
	return out.Choices[0].Message.Content, nil
}

// report 把任务结果回传服务端：errMsg 非空时作为失败原因上报（任务置为 failed），
// 否则上报结果正文（任务置为 done）。
func (n *node) report(ctx context.Context, id int64, result, errMsg string) error {
	body := map[string]string{"result": result}
	if errMsg != "" {
		body = map[string]string{"error": errMsg}
	}
	url := fmt.Sprintf("%s/api/llm/tasks/%d/result", n.cfg.serverURL, id)
	return n.callJSON(ctx, http.MethodPost, url, body, nil)
}

// callJSON 向服务端发送 JSON 请求（自动附加 Bearer 令牌）：body 非 nil 时序列化为
// 请求体，2xx 时把响应体反序列化到 out（out 为 nil 表示忽略响应体）；非 2xx 返回
// 含状态码与响应体摘要的错误。
func (n *node) callJSON(ctx context.Context, method, url string, body, out any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("序列化请求体失败: %w", err)
		}
		reader = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return fmt.Errorf("构造请求失败: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+n.cfg.authToken)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := n.client.Do(req)
	if err != nil {
		return fmt.Errorf("请求 %s 失败: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return n.statusError(url, resp)
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("解析 %s 响应失败: %w", url, err)
	}
	return nil
}

// statusError 由非 2xx 响应构造错误，附带响应体摘要（截断至 errorSnippetLimit 字节）。
func (n *node) statusError(url string, resp *http.Response) error {
	snippet, _ := io.ReadAll(io.LimitReader(resp.Body, errorSnippetLimit))
	return fmt.Errorf("请求 %s 返回 %d: %s", url, resp.StatusCode, strings.TrimSpace(string(snippet)))
}

// main 装配配置、注册退出信号处理并启动节点循环。
func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	slog.SetDefault(logger)

	cfg, err := loadConfig()
	if err != nil {
		logger.Error("配置无效", "error", err)
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 注意：不打印令牌等敏感配置。
	logger.Info("本地处理节点启动",
		"node_name", cfg.nodeName,
		"server_url", cfg.serverURL,
		"ollama_url", cfg.ollamaURL)

	n := newNode(cfg, logger)
	if err := n.run(ctx); err != nil {
		logger.Error("节点异常退出", "error", err)
		os.Exit(1)
	}
}
