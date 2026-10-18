package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

// writeConfig 在临时目录写入 YAML 内容并返回文件路径。
func writeConfig(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("写入临时配置失败: %v", err)
	}
	return path
}

// TestLoadDefaultsWhenFileMissing 验证配置文件不存在时全部使用默认值。
func TestLoadDefaultsWhenFileMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-exist.yaml")

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}

	if cfg.Server.Addr != ":8080" {
		t.Errorf("server.addr = %q, 期望 \":8080\"", cfg.Server.Addr)
	}
	if cfg.Server.ReadTimeout.Standard() != 30*time.Second {
		t.Errorf("server.read_timeout = %v, 期望 30s", cfg.Server.ReadTimeout)
	}
	if cfg.Server.WriteTimeout.Standard() != 30*time.Second {
		t.Errorf("server.write_timeout = %v, 期望 30s", cfg.Server.WriteTimeout)
	}
	if cfg.DB.Path != "./data/seshat.db" {
		t.Errorf("db.path = %q, 期望 \"./data/seshat.db\"", cfg.DB.Path)
	}
	if cfg.WebDAV.Root != "./data/seshat" {
		t.Errorf("webdav.root = %q, 期望 \"./data/seshat\"", cfg.WebDAV.Root)
	}
	if cfg.WebDAV.Public != "./data/seshat/public" {
		t.Errorf("webdav.public = %q, 期望 \"./data/seshat/public\"", cfg.WebDAV.Public)
	}
	if cfg.LLM.LocalNodeURL != "" {
		t.Errorf("llm.local_node_url = %q, 期望空", cfg.LLM.LocalNodeURL)
	}
}

// TestLoadYAMLOverridesDefaults 验证 YAML 覆盖默认值，且未出现的项保留默认值。
func TestLoadYAMLOverridesDefaults(t *testing.T) {
	path := writeConfig(t, `
server:
  addr: "127.0.0.1:9090"
  read_timeout: 5s
db:
  path: "./tmp/test.db"
llm:
  local_node_url: "http://localhost:11434"
`)

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}

	if cfg.Server.Addr != "127.0.0.1:9090" {
		t.Errorf("server.addr = %q, 期望 \"127.0.0.1:9090\"", cfg.Server.Addr)
	}
	if cfg.Server.ReadTimeout.Standard() != 5*time.Second {
		t.Errorf("server.read_timeout = %v, 期望 5s", cfg.Server.ReadTimeout)
	}
	// 未在 YAML 中出现的项应保留默认值。
	if cfg.Server.WriteTimeout.Standard() != 30*time.Second {
		t.Errorf("server.write_timeout = %v, 期望保留默认 30s", cfg.Server.WriteTimeout)
	}
	if cfg.DB.Path != "./tmp/test.db" {
		t.Errorf("db.path = %q, 期望 \"./tmp/test.db\"", cfg.DB.Path)
	}
	if cfg.WebDAV.Root != "./data/seshat" {
		t.Errorf("webdav.root = %q, 期望保留默认", cfg.WebDAV.Root)
	}
	if cfg.LLM.LocalNodeURL != "http://localhost:11434" {
		t.Errorf("llm.local_node_url = %q", cfg.LLM.LocalNodeURL)
	}
}

// TestLoadInvalidDuration 验证非法 duration 字符串会报错。
func TestLoadInvalidDuration(t *testing.T) {
	path := writeConfig(t, "server:\n  read_timeout: \"not-a-duration\"\n")

	if _, err := Load(path); err == nil {
		t.Fatal("期望解析非法 duration 时报错，实际为 nil")
	}
}

// TestSensitiveEnvOverridesAndNotPersisted 验证敏感值只能来自环境变量，
// YAML 中的同名键被忽略，且序列化结果不包含敏感值。
func TestSensitiveEnvOverridesAndNotPersisted(t *testing.T) {
	path := writeConfig(t, `
db:
  path: "./data/custom.db"
  key: "yaml-should-be-ignored"
llm:
  cloud_api_key: "yaml-should-be-ignored"
auth:
  token: "yaml-should-be-ignored"
`)

	t.Setenv(EnvDBKey, "env-db-key")
	t.Setenv(EnvAuthToken, "env-auth-token")
	t.Setenv(EnvLLMAPIKey, "env-llm-api-key")

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}

	if cfg.DB.Key != "env-db-key" {
		t.Errorf("db.key = %q, 期望来自环境变量", cfg.DB.Key)
	}
	if cfg.Auth.Token != "env-auth-token" {
		t.Errorf("auth.token = %q, 期望来自环境变量", cfg.Auth.Token)
	}
	if cfg.LLM.CloudAPIKey != "env-llm-api-key" {
		t.Errorf("llm.cloud_api_key = %q, 期望来自环境变量", cfg.LLM.CloudAPIKey)
	}
	// 非敏感项仍正常来自 YAML。
	if cfg.DB.Path != "./data/custom.db" {
		t.Errorf("db.path = %q, 期望 \"./data/custom.db\"", cfg.DB.Path)
	}

	// 序列化结果不得包含敏感值（敏感项标记为 yaml:"-"）。
	out, err := yaml.Marshal(cfg)
	if err != nil {
		t.Fatalf("Marshal 返回错误: %v", err)
	}
	for _, secret := range []string{"env-db-key", "env-auth-token", "env-llm-api-key"} {
		if strings.Contains(string(out), secret) {
			t.Errorf("序列化结果泄露敏感值 %q:\n%s", secret, out)
		}
	}
}

// TestSensitiveEmptyWithoutEnv 验证环境变量为空时敏感项为空，
// 即使 YAML 中写了敏感键也不会被采纳。
func TestSensitiveEmptyWithoutEnv(t *testing.T) {
	t.Setenv(EnvDBKey, "")
	t.Setenv(EnvAuthToken, "")
	t.Setenv(EnvLLMAPIKey, "")

	path := writeConfig(t, "db:\n  key: \"leaked-from-yaml\"\n")

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}
	if cfg.DB.Key != "" {
		t.Errorf("db.key = %q, 期望空（YAML 不得提供敏感值）", cfg.DB.Key)
	}
}

// TestLoadWebDAVPublicPolicy 验证对外出口策略项可经 YAML 配置，
// 未出现时保留默认（只读 false、白名单为空即不限制）。
func TestLoadWebDAVPublicPolicy(t *testing.T) {
	// 默认值：可读写、不限扩展名。
	cfg, err := Load(filepath.Join(t.TempDir(), "not-exist.yaml"))
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}
	if cfg.WebDAV.PublicReadOnly {
		t.Error("webdav.public_read_only 默认应为 false（可读写）")
	}
	if len(cfg.WebDAV.PublicAllowExts) != 0 {
		t.Errorf("webdav.public_allow_exts 默认应为空，实际 %v", cfg.WebDAV.PublicAllowExts)
	}

	// YAML 覆盖。
	path := writeConfig(t, `
webdav:
  public_read_only: true
  public_allow_exts:
    - ".org"
    - ".md"
`)

	cfg, err = Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}
	if !cfg.WebDAV.PublicReadOnly {
		t.Error("webdav.public_read_only = false, 期望 true")
	}
	if got := cfg.WebDAV.PublicAllowExts; len(got) != 2 || got[0] != ".org" || got[1] != ".md" {
		t.Errorf("webdav.public_allow_exts = %v, 期望 [\".org\" \".md\"]", got)
	}
}

// TestLoadRootsDefaultSingleNoteRoot 验证未配置 webdav.roots 时归一为单根
// （tag=notes、path=webdav.root、mode=mirror），保持向后兼容。
func TestLoadRootsDefaultSingleNoteRoot(t *testing.T) {
	cfg, err := Load(filepath.Join(t.TempDir(), "not-exist.yaml"))
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}

	roots := cfg.WebDAV.Roots
	if len(roots) != 1 {
		t.Fatalf("未配置 roots 时应归一为单根，实际 %d 根: %v", len(roots), roots)
	}
	got := roots[0]
	if got.Tag != "notes" || got.Path != "./data/seshat" || got.Mode != RootModeMirror {
		t.Errorf("归一后的根 = %+v, 期望 {notes ./data/seshat mirror}", got)
	}

	// 自定义 webdav.root 时，内置单根跟随该值。
	path := writeConfig(t, "webdav:\n  root: \"./srv/notes\"\n")
	cfg, err = Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}
	if len(cfg.WebDAV.Roots) != 1 || cfg.WebDAV.Roots[0].Path != "./srv/notes" {
		t.Errorf("roots = %+v, 期望单根 path 跟随 webdav.root", cfg.WebDAV.Roots)
	}
}

// TestLoadRootsExplicitMulti 验证显式多根配置按声明顺序与 mode 保留。
func TestLoadRootsExplicitMulti(t *testing.T) {
	path := writeConfig(t, `
webdav:
  root: "./data/seshat"
  roots:
    - { tag: notes,  path: "./data/seshat", mode: mirror }
    - { tag: ebooks, path: "./data/ebooks", mode: ondemand }
    - { tag: papers, path: "./data/papers",  mode: ondemand }
`)

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}

	roots := cfg.WebDAV.Roots
	if len(roots) != 3 {
		t.Fatalf("roots 数量 = %d, 期望 3: %v", len(roots), roots)
	}
	want := []RootConfig{
		{Tag: "notes", Path: "./data/seshat", Mode: RootModeMirror},
		{Tag: "ebooks", Path: "./data/ebooks", Mode: RootModeOnDemand},
		{Tag: "papers", Path: "./data/papers", Mode: RootModeOnDemand},
	}
	for i := range want {
		if roots[i] != want[i] {
			t.Errorf("roots[%d] = %+v, 期望 %+v", i, roots[i], want[i])
		}
	}
}

// TestLoadRootsModeInferred 验证 mode 留空时按位置推导：首根 mirror、其余 ondemand。
func TestLoadRootsModeInferred(t *testing.T) {
	path := writeConfig(t, `
webdav:
  roots:
    - { tag: notes,  path: "./data/seshat" }
    - { tag: ebooks, path: "./data/ebooks" }
`)

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}

	roots := cfg.WebDAV.Roots
	if len(roots) != 2 {
		t.Fatalf("roots 数量 = %d, 期望 2", len(roots))
	}
	if roots[0].Mode != RootModeMirror {
		t.Errorf("roots[0].mode = %q, 期望 %q", roots[0].Mode, RootModeMirror)
	}
	if roots[1].Mode != RootModeOnDemand {
		t.Errorf("roots[1].mode = %q, 期望 %q", roots[1].Mode, RootModeOnDemand)
	}
}

// TestLoadRootsFirstPathFallsBackToWebDAVRoot 验证首根 path 留空时回落 webdav.root。
func TestLoadRootsFirstPathFallsBackToWebDAVRoot(t *testing.T) {
	path := writeConfig(t, `
webdav:
  root: "./data/seshat"
  roots:
    - { tag: notes }
    - { tag: ebooks, path: "./data/ebooks" }
`)

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}
	if got := cfg.WebDAV.Roots[0].Path; got != "./data/seshat" {
		t.Errorf("roots[0].path = %q, 期望回落为 webdav.root 的 \"./data/seshat\"", got)
	}
}

// TestLoadRootsSingleOnDemand 验证单根显式 mode=ondemand 被接受（不强加 mirror）：
// 归一化只对「留空」的 mode 按位置推导，显式值原样保留。
func TestLoadRootsSingleOnDemand(t *testing.T) {
	path := writeConfig(t, `
webdav:
  roots:
    - { tag: ebooks, path: "./data/ebooks", mode: ondemand }
`)

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load 返回错误: %v", err)
	}
	roots := cfg.WebDAV.Roots
	if len(roots) != 1 {
		t.Fatalf("roots 数量 = %d, 期望 1", len(roots))
	}
	if roots[0].Tag != "ebooks" || roots[0].Mode != RootModeOnDemand {
		t.Errorf("roots[0] = %+v, 期望 {ebooks ... ondemand}", roots[0])
	}
}

// TestLoadRootsValidationErrors 验证非法 roots 配置在 Load 阶段即报错。
func TestLoadRootsValidationErrors(t *testing.T) {
	cases := []struct {
		name    string
		yaml    string
		wantSub string
	}{
		{
			name: "tag 重复",
			yaml: `
webdav:
  roots:
    - { tag: notes, path: "./a" }
    - { tag: notes, path: "./b" }
`,
			wantSub: "重复",
		},
		{
			name: "tag 含冒号",
			yaml: `
webdav:
  roots:
    - { tag: "no:tes", path: "./a" }
`,
			wantSub: "':'",
		},
		{
			name: "tag 为空",
			yaml: `
webdav:
  roots:
    - { tag: "", path: "./a" }
`,
			wantSub: "tag 不能为空",
		},
		{
			name: "非首根 path 为空",
			yaml: `
webdav:
  roots:
    - { tag: notes, path: "./a" }
    - { tag: ebooks }
`,
			wantSub: "path 不能为空",
		},
		{
			name: "webdav.root 与首根 path 均空",
			yaml: `
webdav:
  root: ""
  roots:
    - { tag: notes }
`,
			wantSub: "path 不能为空",
		},
		{
			name: "非法 mode",
			yaml: `
webdav:
  roots:
    - { tag: notes, path: "./a", mode: "sync" }
`,
			wantSub: "mode",
		},
		{
			name: "两个 mirror",
			yaml: `
webdav:
  roots:
    - { tag: notes,  path: "./a", mode: mirror }
    - { tag: ebooks, path: "./b", mode: mirror }
`,
			wantSub: "mirror",
		},
		{
			name: "mirror 不是首根",
			yaml: `
webdav:
  roots:
    - { tag: ebooks, path: "./b", mode: ondemand }
    - { tag: notes,  path: "./a", mode: mirror }
`,
			wantSub: "首根",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := writeConfig(t, tc.yaml)
			_, err := Load(path)
			if err == nil {
				t.Fatalf("期望 Load 返回错误，实际为 nil")
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Errorf("错误信息 = %q, 期望包含 %q", err.Error(), tc.wantSub)
			}
		})
	}
}

// TestValidateDirectly 验证 Validate 可独立调用（不经 Load），
// 并把归一化结果写回 WebDAV.Roots。
func TestValidateDirectly(t *testing.T) {
	cfg := Default()
	if len(cfg.WebDAV.Roots) != 0 {
		t.Fatalf("Default() 不应预置 roots，实际 %v", cfg.WebDAV.Roots)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("默认配置 Validate 返回错误: %v", err)
	}
	if len(cfg.WebDAV.Roots) != 1 || cfg.WebDAV.Roots[0].Tag != "notes" || cfg.WebDAV.Roots[0].Mode != RootModeMirror {
		t.Errorf("Validate 后 roots = %+v, 期望归一为单根 notes/mirror", cfg.WebDAV.Roots)
	}

	// 归一化幂等：再次 Validate 结果不变。
	before := append([]RootConfig(nil), cfg.WebDAV.Roots...)
	if err := cfg.Validate(); err != nil {
		t.Fatalf("第二次 Validate 返回错误: %v", err)
	}
	if len(cfg.WebDAV.Roots) != len(before) || cfg.WebDAV.Roots[0] != before[0] {
		t.Errorf("Validate 不幂等：before=%v after=%v", before, cfg.WebDAV.Roots)
	}

	// 无 webdav.root 且未配置 roots 时无法确定路径 → 报错（可识别为配置缺失）。
	empty := &Config{}
	if err := empty.Validate(); err == nil {
		t.Error("webdav.root 与 roots 均缺失时 Validate 应报错")
	}
}
