// Package config 负责加载与合并 seshat 服务的配置。
//
// 配置来源与优先级（后者覆盖前者）：
//  1. 内置默认值
//  2. config.yaml（可选，文件不存在时全部使用默认值）
//  3. 环境变量（仅敏感项，见下方常量）
//
// 敏感值（数据库密钥、API 令牌、LLM API key）禁止写入配置文件或任何落盘文件，
// 只能通过环境变量注入，对应的结构体字段均标记为 yaml:"-"。
package config

import (
	"errors"
	"fmt"
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

// 敏感配置项对应的环境变量名。
const (
	// EnvDBKey 提供 Config.DB.Key（数据库密钥）。
	EnvDBKey = "SESHAT_DB_KEY"
	// EnvAuthToken 提供 Config.Auth.Token（API 访问令牌）。
	EnvAuthToken = "SESHAT_AUTH_TOKEN"
	// EnvLLMAPIKey 提供 Config.LLM.CloudAPIKey（云端 LLM API key）。
	EnvLLMAPIKey = "SESHAT_LLM_API_KEY"
	// EnvNodeToken 提供 Config.LLM.NodeToken（本地 LLM 节点专用令牌）。
	// 与主访问令牌分离，使节点只能访问节点端点（最小权限）；为空时节点
	// 端点回退接受主令牌（向后兼容）。
	EnvNodeToken = "SESHAT_NODE_TOKEN"
)

// 各配置项的默认值。
const (
	defaultServerAddr    = ":8080"
	defaultServerTimeout = 30 * time.Second
	defaultDBPath        = "./data/seshat.db"
	defaultWebDAVRoot    = "./data/seshat"
	defaultWebDAVPublic  = "./data/seshat/public"
)

// Duration 包装 time.Duration，使其在 YAML 中支持 "30s" 这类字符串写法。
type Duration time.Duration

// UnmarshalYAML 实现 yaml.Unmarshaler，接受 time.ParseDuration 支持的字符串。
func (d *Duration) UnmarshalYAML(node *yaml.Node) error {
	var raw string
	if err := node.Decode(&raw); err != nil {
		return err
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return fmt.Errorf("无效的时间间隔 %q: %w", raw, err)
	}
	*d = Duration(parsed)
	return nil
}

// MarshalYAML 实现 yaml.Marshaler，输出 "30s" 形式的字符串。
func (d Duration) MarshalYAML() (any, error) {
	return time.Duration(d).String(), nil
}

// Standard 返回标准库的 time.Duration，便于与 net/http 等 API 对接。
func (d Duration) Standard() time.Duration {
	return time.Duration(d)
}

// Config 是 seshat 服务的完整配置。
type Config struct {
	Server ServerConfig `yaml:"server"`
	DB     DBConfig     `yaml:"db"`
	WebDAV WebDAVConfig `yaml:"webdav"`
	LLM    LLMConfig    `yaml:"llm"`
	Auth   AuthConfig   `yaml:"auth"`
}

// ServerConfig 是 HTTP 服务端配置。
type ServerConfig struct {
	Addr         string   `yaml:"addr"`
	ReadTimeout  Duration `yaml:"read_timeout"`
	WriteTimeout Duration `yaml:"write_timeout"`
}

// DBConfig 是 SQLite 数据库配置。
type DBConfig struct {
	Path string `yaml:"path"`
	// Key 是数据库密钥，敏感，仅从环境变量 SESHAT_DB_KEY 读取。
	Key string `yaml:"-"`
}

// WebDAVConfig 是笔记目录与公开出口配置。
type WebDAVConfig struct {
	Root   string `yaml:"root"`
	Public string `yaml:"public"`
	// PublicReadOnly 控制对外公开出口是否只读；默认 false（可读写）。
	PublicReadOnly bool `yaml:"public_read_only"`
	// PublicAllowExts 是对外公开出口允许写入的文件扩展名白名单
	// （如 [".org", ".md", ".pdf", ".epub"]）；为空表示不限制扩展名，读操作不受其约束。
	PublicAllowExts []string `yaml:"public_allow_exts"`
}

// LLMConfig 是 LLM 后端配置。
type LLMConfig struct {
	// CloudAPIKey 是云端 LLM API key，敏感，仅从环境变量 SESHAT_LLM_API_KEY 读取。
	CloudAPIKey string `yaml:"-"`
	// NodeToken 是本地处理节点专用令牌，敏感，仅从环境变量 SESHAT_NODE_TOKEN 读取。
	// 用于将节点（cmd/llmnode）与普通客户端的主令牌隔离：节点令牌只能访问节点
	// 端点（任务轮询/回传/注册），主令牌不能访问节点端点（当本项配置时）。
	// 为空时节点端点回退接受主令牌（向后兼容）。
	NodeToken    string `yaml:"-"`
	LocalNodeURL string `yaml:"local_node_url"`
}

// AuthConfig 是访问令牌配置。
type AuthConfig struct {
	// Token 是 API 访问令牌，敏感，仅从环境变量 SESHAT_AUTH_TOKEN 读取。
	Token string `yaml:"-"`
}

// Default 返回填充了默认值的配置。
func Default() *Config {
	return &Config{
		Server: ServerConfig{
			Addr:         defaultServerAddr,
			ReadTimeout:  Duration(defaultServerTimeout),
			WriteTimeout: Duration(defaultServerTimeout),
		},
		DB: DBConfig{
			Path: defaultDBPath,
		},
		WebDAV: WebDAVConfig{
			Root:   defaultWebDAVRoot,
			Public: defaultWebDAVPublic,
		},
		LLM: LLMConfig{
			LocalNodeURL: "",
		},
	}
}

// Load 加载配置：先取默认值，若 path 存在则用 YAML 覆盖，最后用环境变量覆盖敏感项。
// path 指向的配置文件不存在时不报错，直接使用默认值。
func Load(path string) (*Config, error) {
	cfg := Default()

	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := yaml.Unmarshal(data, cfg); err != nil {
			return nil, fmt.Errorf("解析配置文件 %s: %w", path, err)
		}
	case errors.Is(err, os.ErrNotExist):
		// 配置文件不存在，使用默认值。
	default:
		return nil, fmt.Errorf("读取配置文件 %s: %w", path, err)
	}

	applyEnv(cfg)

	return cfg, nil
}

// applyEnv 用环境变量覆盖敏感配置项。环境变量优先级最高，
// 且敏感项不可由配置文件提供。
func applyEnv(cfg *Config) {
	cfg.DB.Key = os.Getenv(EnvDBKey)
	cfg.Auth.Token = os.Getenv(EnvAuthToken)
	cfg.LLM.CloudAPIKey = os.Getenv(EnvLLMAPIKey)
	cfg.LLM.NodeToken = os.Getenv(EnvNodeToken)
}
