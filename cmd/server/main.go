// Package main 是 notes 服务端入口：装配配置、日志、存储、git 版本库、全文索引、
// 附件对象库、认证与 LLM 后端，组装 REST API 与内部/对外 WebDAV 路由，并监听端口、
// 处理进程退出信号完成优雅关闭。
//
// 组装遵循「失败即退出」：任一组件初始化失败（配置解析错误、数据库不可打开、
// git 仓库不可初始化等）都会终止启动并输出错误，避免以半可用状态对外服务。
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"notes/internal/api"
	"notes/internal/attach"
	"notes/internal/auth"
	"notes/internal/config"
	"notes/internal/gitver"
	"notes/internal/index"
	"notes/internal/llm"
	"notes/internal/logging"
	"notes/internal/storage"
	"notes/internal/webdav"
)

const (
	// defaultConfigPath 是默认配置文件路径；文件不存在时全部使用内置默认值。
	defaultConfigPath = "./config.yaml"

	// defaultAttachDir 是附件对象库根目录的默认值。config.Config 目前未提供对应
	// 字段，此处取值与 scripts/backup.sh、docs/backup.md 的默认值保持一致。
	defaultAttachDir = "./data/files/objects"

	// envLogLevel 是日志级别的环境变量名；未设置或无法识别时回退 info。
	envLogLevel = "NOTES_LOG_LEVEL"

	// internalMount 是内部 WebDAV（笔记根目录）的对外挂载前缀。webdav 包内部
	// handler 的默认 Prefix 恰为 "/dav"，故挂载点与之天然对齐。
	internalMount = "/dav/"

	// publicPrefix 是对外 WebDAV（公开出口）handler 的 URL 前缀，必须与挂载点
	// publicMount 一致：webdav.Handler 以它剥掉请求路径前缀，并据此拼接 PROPFIND
	// 等响应中的 href（此前固定为 "/dav" 导致对外 href 越界）。
	publicPrefix = "/public"

	// publicMount 是对外 WebDAV（公开出口）的对外挂载前缀。
	publicMount = "/public/"

	// shutdownTimeout 是收到退出信号后等待在途请求完成的最长时间。
	shutdownTimeout = 15 * time.Second
)

// main 调用 run 并在失败时以非零码退出。
func main() {
	if err := run(); err != nil {
		slog.Error("notes 服务退出", "error", err)
		os.Exit(1)
	}
}

// run 完成一次完整的服务生命周期：装配组件 → 组装路由 → 启动监听 → 优雅关闭。
// 返回值非 nil 表示启动或运行失败。
func run() error {
	// 1. 配置：读 config.yaml（缺失时用默认值），敏感项由环境变量覆盖。
	cfg, err := config.Load(defaultConfigPath)
	if err != nil {
		return fmt.Errorf("加载配置: %w", err)
	}

	// 2. 结构化日志：级别取自环境变量，默认 info。logging.Init 同时设置 slog 默认。
	logger := logging.Init(envOr(envLogLevel, "info"))

	// 3. 存储层：打开（或创建）SQLite 并执行 schema 迁移。SQLite 不会自动创建
	//    数据库文件的父目录，故先确保其存在（":" 内存库或当前目录无需创建）。
	if dir := filepath.Dir(cfg.DB.Path); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("创建数据库目录 %s: %w", dir, err)
		}
	}
	db, err := storage.Open(cfg.DB.Path, cfg.DB.Key)
	if err != nil {
		return fmt.Errorf("打开数据库: %w", err)
	}
	defer func() { _ = db.Close() }()

	// 4. 笔记目录 + git 版本库：目录不存在时先创建，gitver.Open 就地初始化仓库。
	if err := os.MkdirAll(cfg.WebDAV.Root, 0o755); err != nil {
		return fmt.Errorf("创建笔记目录 %s: %w", cfg.WebDAV.Root, err)
	}
	repo, err := gitver.Open(cfg.WebDAV.Root)
	if err != nil {
		return fmt.Errorf("打开 git 版本库: %w", err)
	}

	// 5. 全文索引：复用 storage 的 SQLite 连接（notes_fts 虚表）。
	indexer := index.New(db)

	// 6. 附件对象库：内容寻址存储。当前 REST/WebDAV 尚未消费，仅完成初始化，
	//    待后续里程碑接入附件上传/下载端点。
	attachStore := attach.NewStore(defaultAttachDir, db)

	// 7. 认证：单用户令牌，REST 用 Bearer、WebDAV 用 Basic，共用同一令牌。
	authenticator := auth.New(cfg.Auth.Token)

	// 8. LLM 路由：云端 + 本地节点。当前 REST 端点尚未消费，仅初始化备用（任务
	//    明确要求暂不接入 api）。
	llmRouter := llm.NewRouter(
		llm.NewCloud(cfg.LLM.CloudAPIKey, "", ""),
		llm.NewLocal(cfg.LLM.LocalNodeURL),
	)

	// 9. 组装 HTTP 路由。
	mux, err := buildMux(cfg, db, repo, indexer, authenticator)
	if err != nil {
		return err
	}

	// attachStore 与 llmRouter 已按计划初始化但当前尚无消费方；保留变量供后续
	// 里程碑接入，避免误删初始化逻辑。
	_ = attachStore
	_ = llmRouter

	// 10. HTTP 服务端：监听配置地址，超时取自配置。
	srv := &http.Server{
		Addr:         cfg.Server.Addr,
		Handler:      mux,
		ReadTimeout:  cfg.Server.ReadTimeout.Standard(),
		WriteTimeout: cfg.Server.WriteTimeout.Standard(),
	}

	// 退出信号：SIGINT / SIGTERM 触发优雅关闭。
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 11. 启动日志：仅记录关键路由与「是否已配置」的布尔元信息，绝不输出令牌/密钥值。
	logger.Info("notes 服务启动",
		"addr", cfg.Server.Addr,
		"db_path", cfg.DB.Path,
		"webdav_root", cfg.WebDAV.Root,
		"webdav_public", cfg.WebDAV.Public,
		"attach_dir", defaultAttachDir,
		"auth_configured", cfg.Auth.Token != "",
		"cloud_llm_configured", cfg.LLM.CloudAPIKey != "",
		"local_llm_url", cfg.LLM.LocalNodeURL,
	)

	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("HTTP 服务异常: %w", err)
	case <-ctx.Done():
		logger.Info("收到退出信号，开始优雅关闭")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("优雅关闭失败: %w", err)
	}
	logger.Info("服务已停止")
	return nil
}

// buildMux 组装全部路由：
//
//   - /api/ 与 /：REST API 与 Web UI（internal/api 的处理器内部已按 /api/、
//     GET /{$}、/static/ 组织路由，同时挂在两个前缀上以兼顾任务要求的 /api/
//     与 Web UI 首页/静态资源可达）；
//   - /dav/：内部 WebDAV（笔记根目录），带 git 版本化与全文索引维护；
//   - /public/：对外 WebDAV（公开出口），按配置施加只读/扩展名白名单策略，
//     并同样叠加 git 版本化与全文索引；其 handler 前缀为 "/public"，使响应
//     href 与挂载点一致。
func buildMux(cfg *config.Config, db *storage.DB, repo *gitver.Repo, indexer *index.Indexer, authenticator *auth.Authenticator) (*http.ServeMux, error) {
	mux := http.NewServeMux()

	// REST API + Web UI。internal/api 的处理器自带 /api/ 认证中间件与 / 首页、
	// /static/ 静态资源；挂在 "/api/" 与 "/" 两个前缀下，使 /api/* 走 API、
	// / 与 /static/* 走 Web UI（更具体的 /dav/、/public/ 优先匹配，互不干扰）。
	apiHandler := api.NewHandlerFull(db, repo, indexer, authenticator)
	mux.Handle("/api/", apiHandler)
	mux.Handle("/", apiHandler)

	// 内部 WebDAV：Prefix 恰为 "/dav"，直接挂在 "/dav/" 即可对齐（无需改写路径）。
	mux.Handle(internalMount, webdav.VersionedHandlerWithIndex(
		cfg.WebDAV.Root, authenticator, webdav.SourceInternal, repo, indexer))

	// 对外 WebDAV：公开目录为空则跳过。handler 前缀传 publicPrefix（与挂载点
	// 一致），使 PROPFIND 等响应生成的 href 落在 /public/ 而非默认的 /dav/；同时
	// 叠加 git 版本化与全文索引，使对外写入同样产生 commit 并进入 FTS 索引。
	if cfg.WebDAV.Public != "" {
		if err := os.MkdirAll(cfg.WebDAV.Public, 0o755); err != nil {
			return nil, fmt.Errorf("创建公开出口目录 %s: %w", cfg.WebDAV.Public, err)
		}
		// 公开出口通常是笔记根（git 仓库工作区）下的子目录，如 <root>/public。
		// webdav 包以「仓库内相对路径」计算 ETag 的 blob hash 与全文索引 key，
		// 而对外请求路径是「公开出口相对路径」，故需传入两者之间的偏移；否则
		// ETag 会解析到仓库中不存在的路径（退化为 mtime 启发式），索引 key 也会
		// 与内部端点（以笔记根为基准）错位冲突。
		offset := publicOffset(cfg.WebDAV.Root, cfg.WebDAV.Public)
		publicHandler := webdav.NewPolicyVersionedHandler(
			cfg.WebDAV.Public, authenticator, webdav.SourceExternal,
			webdav.PolicyOptions{
				ReadOnly:  cfg.WebDAV.PublicReadOnly,
				AllowExts: cfg.WebDAV.PublicAllowExts,
			},
			repo, indexer, publicPrefix, offset)
		mux.Handle(publicMount, publicHandler)
	}

	return mux, nil
}

// publicOffset 返回公开出口目录相对笔记根（git 仓库工作区根）的偏移，形如
// "public"；公开出口即笔记根、或两者关系无法确定时返回空串（空串表示挂载根
// 即仓库根）。
//
// 公开出口位于笔记根之外时（相对路径以 ".." 开头）返回空串并告警：此时对外
// 写入落在 git 仓库工作区之外，写后自动 commit 不会覆盖这些文件，ETag 也无法
// 按仓库内路径计算 blob hash（getetag 将退化为 mtime 启发式）。
func publicOffset(root, public string) string {
	rel, err := filepath.Rel(root, public)
	if err != nil {
		slog.Warn("公开出口与笔记根的相对关系无法确定，ETag 与索引将按笔记根路径解析",
			"webdav_root", root, "webdav_public", public, "error", err)
		return ""
	}
	switch {
	case rel == ".":
		// 公开出口即笔记根：无偏移。
		return ""
	case rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)):
		slog.Warn("公开出口不在笔记根目录内：对外写入不在 git 仓库工作区内，写后不会产生 commit，ETag 亦将退化为 mtime 启发式",
			"webdav_root", root, "webdav_public", public)
		return ""
	default:
		return filepath.ToSlash(rel)
	}
}

// envOr 返回环境变量值；未设置或全为空白时返回 fallback。
func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
