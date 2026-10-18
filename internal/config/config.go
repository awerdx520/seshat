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
	"strings"
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
	// defaultRootTag 是未配置 webdav.roots 时内置单根的标签。
	defaultRootTag = "notes"
)

// 根的两种模式（取值与 internal/registry 的 RootMode* 一致）。
const (
	// RootModeMirror 是笔记根：WebDAV 全量镜像 + git 版本化 + FTS 索引。
	RootModeMirror = "mirror"
	// RootModeOnDemand 是书库根：不挂 WebDAV、不进 FTS，只经 REST 按需读取。
	RootModeOnDemand = "ondemand"
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

// RootConfig 是一个受管理的文档根映射。
//
// 一个根由「标签 + 物理路径 + 模式」构成；标签是客户端引用（`tag:relpath`）与服务端
// 登记（resources.root）中的根标识，故必须唯一、非空且不含 ':'。
type RootConfig struct {
	Tag  string `yaml:"tag"`
	Path string `yaml:"path"`
	// Mode 取 "mirror"（笔记根）或 "ondemand"（书库根）；留空时由位置推导
	// （首根 mirror，其余 ondemand），见 Config.Validate。
	Mode string `yaml:"mode"`
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
	// Roots 是多根映射；为空时由 Validate 归一为单根（tag=notes、
	// path=webdav.root、mode=mirror），即 Root 字段在未配置 Roots 时等价 roots[0]。
	Roots []RootConfig `yaml:"roots"`
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

	// 校验并归一化（含 webdav.roots）：把非法配置挡在启动之前，
	// 后续使用方只需读取 cfg.WebDAV.Roots 的归一形态。
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// Validate 校验并归一化配置，目前只处理 webdav.roots。
//
// 归一化规则（结果写回 c.WebDAV.Roots，供后续直接使用）：
//  1. Roots 为空 → [{Tag:"notes", Path: WebDAV.Root, Mode:"mirror"}]（向后兼容单根）；
//  2. Mode 为空 → 首根 mirror、其余 ondemand；
//  3. 首根 Path 为空 → 回落 WebDAV.Root（其余根不回落，必须显式配置）；
//  4. 校验：Tag 非空、唯一、不含 ':'；Path 非空；Mode ∈ {mirror, ondemand}；
//     mirror 根至多一个且必须是首根（FTS 与 WebDAV 只挂首根）。
//
// 显式 mode 原样保留（不强制首根为 mirror）；零个 mirror 根被允许，
// 「没有镜像根」时 FTS/WebDAV 的挂载策略由调用方决定。
func (c *Config) Validate() error {
	roots, err := c.normalizeRoots()
	if err != nil {
		return err
	}
	c.WebDAV.Roots = roots
	return nil
}

// normalizeRoots 返回归一化后的根清单，不修改接收者。
func (c *Config) normalizeRoots() ([]RootConfig, error) {
	raw := c.WebDAV.Roots
	if len(raw) == 0 {
		// 规则 1：未配置 roots 时等价单根 notes。
		raw = []RootConfig{{Tag: defaultRootTag, Path: c.WebDAV.Root, Mode: RootModeMirror}}
	}

	out := make([]RootConfig, 0, len(raw))
	seen := make(map[string]struct{}, len(raw))
	mirrorIndex := -1

	for i, rc := range raw {
		tag := strings.TrimSpace(rc.Tag)
		if tag == "" {
			return nil, fmt.Errorf("webdav.roots[%d].tag 不能为空", i)
		}
		if strings.Contains(tag, ":") {
			return nil, fmt.Errorf("webdav.roots[%d].tag %q 不能包含 ':'（与 tag:path 引用语法冲突）", i, tag)
		}
		if _, dup := seen[tag]; dup {
			return nil, fmt.Errorf("webdav.roots[%d].tag %q 重复：根标签必须唯一", i, tag)
		}
		seen[tag] = struct{}{}

		// 规则 2：mode 留空按位置推导。
		mode := strings.TrimSpace(rc.Mode)
		if mode == "" {
			mode = RootModeOnDemand
			if i == 0 {
				mode = RootModeMirror
			}
		}
		switch mode {
		case RootModeMirror, RootModeOnDemand:
		default:
			return nil, fmt.Errorf("webdav.roots[%d].mode %q 非法：只允许 %q 或 %q",
				i, rc.Mode, RootModeMirror, RootModeOnDemand)
		}

		// 规则 3：仅首根回落 webdav.root。
		rootPath := strings.TrimSpace(rc.Path)
		if i == 0 && rootPath == "" {
			rootPath = strings.TrimSpace(c.WebDAV.Root)
		}
		if rootPath == "" {
			return nil, fmt.Errorf("webdav.roots[%d].path 不能为空（tag=%s）", i, tag)
		}

		// 规则 4：mirror 至多一个且必须是首根。
		if mode == RootModeMirror {
			if mirrorIndex >= 0 {
				return nil, fmt.Errorf("webdav.roots[%d] 与 webdav.roots[%d] 均为 mirror 根："+
					"mirror 根至多一个（FTS 与 WebDAV 只挂载首根）", mirrorIndex, i)
			}
			if i != 0 {
				return nil, fmt.Errorf("webdav.roots[%d].mode 为 mirror 但不是首根："+
					"mirror 根必须是首根（FTS 与 WebDAV 只挂载首根）", i)
			}
			mirrorIndex = i
		}

		out = append(out, RootConfig{Tag: tag, Path: rootPath, Mode: mode})
	}

	return out, nil
}

// applyEnv 用环境变量覆盖敏感配置项。环境变量优先级最高，
// 且敏感项不可由配置文件提供。
func applyEnv(cfg *Config) {
	cfg.DB.Key = os.Getenv(EnvDBKey)
	cfg.Auth.Token = os.Getenv(EnvAuthToken)
	cfg.LLM.CloudAPIKey = os.Getenv(EnvLLMAPIKey)
	cfg.LLM.NodeToken = os.Getenv(EnvNodeToken)
}
