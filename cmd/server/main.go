// Package main 是 seshat 服务端入口：装配配置、日志、存储、git 版本库、全文索引、
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

	"seshat/internal/api"
	"seshat/internal/attach"
	"seshat/internal/auth"
	"seshat/internal/config"
	"seshat/internal/gitver"
	"seshat/internal/index"
	"seshat/internal/llm"
	"seshat/internal/logging"
	"seshat/internal/registry"
	"seshat/internal/storage"
	"seshat/internal/webdav"
)

const (
	// defaultConfigPath 是默认配置文件路径；文件不存在时全部使用内置默认值。
	defaultConfigPath = "./config.yaml"

	// defaultAttachDir 是附件对象库根目录的默认值。config.Config 目前未提供对应
	// 字段，此处取值与 scripts/backup.sh、docs/backup.md 的默认值保持一致。
	defaultAttachDir = "./data/files/objects"

	// envLogLevel 是日志级别的环境变量名；未设置或无法识别时回退 info。
	envLogLevel = "SESHAT_LOG_LEVEL"

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

	// bootstrapTimeout 是启动登记（registry.Bootstrap）的超时上限。超大目录树的
	// 首次登记可能耗时较久，超时后放弃登记并终止启动，避免服务在半登记状态下对外
	// 服务而客户端游标无法解释；重跑即可补齐（Bootstrap 幂等）。
	bootstrapTimeout = 2 * time.Minute
)

// main 调用 run 并在失败时以非零码退出。
func main() {
	if err := run(); err != nil {
		slog.Error("seshat 服务退出", "error", err)
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

	// 4. 根映射 → 笔记目录 + git 版本库：先把 cfg.WebDAV.Roots（config.Load 的
	//    Validate 已归一：非空、首根为笔记根、tag 唯一非空）转成 registry.Root 列表，
	//    再确保笔记根目录存在并在其中初始化 git 仓库。git 版本化、FTS 索引与 WebDAV
	//    只覆盖 roots[0]；roots[1..]（书库根）只经 REST 按需读取，不建目录也不进 git。
	roots, err := registryRoots(cfg)
	if err != nil {
		return err
	}
	notesRoot := roots[0].Path
	if err := os.MkdirAll(notesRoot, 0o755); err != nil {
		return fmt.Errorf("创建笔记目录 %s: %w", notesRoot, err)
	}
	repo, err := gitver.Open(notesRoot)
	if err != nil {
		return fmt.Errorf("打开 git 版本库: %w", err)
	}

	// 5. 全文索引：复用 storage 的 SQLite 连接（notes_fts 虚表，只覆盖笔记根）。
	indexer := index.New(db)

	// 6. 身份登记：创建 registry.Service，先设置全部根映射再跑一次启动扫描（遍历所有
	//    根，逐文件登记），使「磁盘上已有内容」与「登记表」在服务对外可用前对齐。api
	//    与 webdav 的新入口内部以 reg.Roots()[0].Tag 作为登记使用的逻辑根，故
	//    SetRoots 必须先于 buildMux。
	reg := registry.New(db, repo)
	if err := reg.SetRoots(roots); err != nil {
		return fmt.Errorf("设置根映射: %w", err)
	}
	// 启动登记不随退出信号中断：此处用独立的 ctx（而非下方的 signal.NotifyContext），
	// 避免启动阶段收到 SIGTERM 时半途中止，留下「部分登记 + 剩余未知」的状态。超时
	// 兜底防止超大目录树让启动无限期挂起；Bootstrap 幂等，超时后重跑即可补齐。
	bootstrapCtx, cancelBootstrap := context.WithTimeout(context.Background(), bootstrapTimeout)
	defer cancelBootstrap()
	stats, err := reg.Bootstrap(bootstrapCtx, roots)
	if err != nil {
		return fmt.Errorf("登记文件系统: %w", err)
	}
	logger.Info("registry bootstrap 完成",
		"scanned", stats.Scanned, "created", stats.Created, "updated", stats.Updated,
		"unchanged", stats.Unchanged, "deleted", stats.Deleted, "failed", stats.Failed)

	// 7. 附件对象库：内容寻址存储。当前 REST/WebDAV 尚未消费，仅完成初始化，
	//    待后续里程碑接入附件上传/下载端点。
	attachStore := attach.NewStore(defaultAttachDir, db)

	// 8. 认证：主令牌保护普通 REST 端点与 WebDAV（REST 用 Bearer、WebDAV 用
	//    Basic）；节点令牌（SESHAT_NODE_TOKEN）单独保护本地处理节点端点（任务
	//    轮询/回传、节点注册），实现节点与客户端的最小权限隔离。nodeAuth 承载
	//    节点令牌，未配置时节点端点回退接受主令牌（向后兼容既有部署）。
	authenticator := auth.New(cfg.Auth.Token)
	nodeAuth := auth.NewWithNodeToken(cfg.Auth.Token, cfg.LLM.NodeToken)

	// 9. LLM 路由：云端 + 本地节点。当前 REST 端点尚未消费，仅初始化备用（任务
	//    明确要求暂不接入 api）。
	llmRouter := llm.NewRouter(
		llm.NewCloud(cfg.LLM.CloudAPIKey, "", ""),
		llm.NewLocal(cfg.LLM.LocalNodeURL),
	)

	// 10. 组装 HTTP 路由（reg 已 SetRoots + Bootstrap，api/webdav 入口据此取逻辑根）。
	mux, err := buildMux(cfg, db, repo, indexer, reg, authenticator, nodeAuth)
	if err != nil {
		return err
	}

	// attachStore 与 llmRouter 已按计划初始化但当前尚无消费方；保留变量供后续
	// 里程碑接入，避免误删初始化逻辑。
	_ = attachStore
	_ = llmRouter

	// 11. HTTP 服务端：监听配置地址，超时取自配置。
	srv := &http.Server{
		Addr:         cfg.Server.Addr,
		Handler:      mux,
		ReadTimeout:  cfg.Server.ReadTimeout.Standard(),
		WriteTimeout: cfg.Server.WriteTimeout.Standard(),
	}

	// 退出信号：SIGINT / SIGTERM 触发优雅关闭。
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 12. 启动日志：仅记录关键路由与「是否已配置」的布尔元信息，绝不输出令牌/密钥值。
	//     多根部署下只打印笔记根（roots[0]）的物理路径与根的个数，其余根的物理路径不落日志。
	logger.Info("seshat 服务启动",
		"addr", cfg.Server.Addr,
		"db_path", cfg.DB.Path,
		"webdav_root", notesRoot,
		"roots", len(roots),
		"webdav_public", cfg.WebDAV.Public,
		"attach_dir", defaultAttachDir,
		"auth_configured", cfg.Auth.Token != "",
		"node_token_configured", cfg.LLM.NodeToken != "",
		"cloud_llm_configured", cfg.LLM.CloudAPIKey != "",
		"local_llm_url", cfg.LLM.LocalNodeURL,
		"registry_ready", reg != nil,
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
//   - /dav/：内部 WebDAV（笔记根目录），带 git 版本化、全文索引维护与身份登记；
//   - /public/：对外 WebDAV（公开出口），按配置施加只读/扩展名白名单策略，
//     并同样叠加 git 版本化、全文索引与身份登记；其 handler 前缀为 "/public"，
//     使响应 href 与挂载点一致。
//
// reg 为身份登记服务，构造前必须已调用过 SetRoots（api/webdav 的新入口以
// reg.Roots()[0].Tag 作为登记使用的逻辑根）。reg 为 nil 时各入口退化为不登记
// 身份的旧行为。
//
// 路径基准取笔记根 cfg.WebDAV.Roots[0].Path（由 config.Validate 归一化保证存在），
// 而非已不参与多根语义的 cfg.WebDAV.Root：后者仅作为「未配置 roots」时的回落来源。
func buildMux(cfg *config.Config, db *storage.DB, repo *gitver.Repo, indexer *index.Indexer, reg *registry.Service, authenticator, nodeAuth *auth.Authenticator) (*http.ServeMux, error) {
	notesRoot, err := firstRootPath(cfg)
	if err != nil {
		return nil, err
	}

	mux := http.NewServeMux()

	// REST API + Web UI。internal/api 的处理器自带 /api/ 认证中间件与 / 首页、
	// /static/ 静态资源；挂在 "/api/" 与 "/" 两个前缀下，使 /api/* 走 API、
	// / 与 /static/* 走 Web UI（更具体的 /dav/、/public/ 优先匹配，互不干扰）。
	// 普通端点由主令牌认证，节点端点（轮询/回传/注册）由 nodeAuth 的节点令牌认证。
	apiHandler := api.NewHandlerFullWithRegistry(db, repo, indexer, reg, authenticator, nodeAuth)
	mux.Handle("/api/", apiHandler)
	mux.Handle("/", apiHandler)

	// 内部 WebDAV：Prefix 恰为 "/dav"，直接挂在 "/dav/" 即可对齐（无需改写路径）。
	// 根目录取笔记根（roots[0].Path），故 WebDAV 全量镜像只覆盖笔记根；书库根没有
	// WebDAV 挂载点，只能经 REST 按需读取。
	// 写入成功后除 commit 与 FTS 索引外，还会把该写操作登记进 registry（uid 生成/
	// 复用规则见 webdav.registryAfterWrite）。
	mux.Handle(internalMount, webdav.VersionedHandlerWithRegistry(
		notesRoot, authenticator, webdav.SourceInternal, repo, indexer, reg))

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
		offset := publicOffset(notesRoot, cfg.WebDAV.Public)
		publicHandler := webdav.NewPolicyVersionedHandlerWithRegistry(
			cfg.WebDAV.Public, authenticator, webdav.SourceExternal,
			webdav.PolicyOptions{
				ReadOnly:  cfg.WebDAV.PublicReadOnly,
				AllowExts: cfg.WebDAV.PublicAllowExts,
			},
			repo, indexer, reg, publicPrefix, offset)
		mux.Handle(publicMount, publicHandler)
	}

	return mux, nil
}

// registryRoots 把配置中的根映射转换为 registry.Root 列表。
//
// 依赖 config.Validate（config.Load 内部调用）已完成的归一化：Roots 非空、首根为
// 笔记根、tag 唯一非空且不含 ':'、path 非空。故此处只做搬运与最小防御，不再重复推导
// 默认值（重复推导会让两处默认值漂移）。归一化被绕过时（例如测试直接构造
// config.Config 而未调用 Validate）返回明确错误，避免后续 roots[0] 越界 panic 或
// 用空路径打开 git 仓库。
func registryRoots(cfg *config.Config) ([]registry.Root, error) {
	if len(cfg.WebDAV.Roots) == 0 {
		return nil, fmt.Errorf("配置缺少 webdav.roots（config.Validate 应保证至少一项）：装配错误")
	}

	roots := make([]registry.Root, 0, len(cfg.WebDAV.Roots))
	for i, rc := range cfg.WebDAV.Roots {
		tag := strings.TrimSpace(rc.Tag)
		path := strings.TrimSpace(rc.Path)
		if tag == "" || path == "" {
			return nil, fmt.Errorf("webdav.roots[%d] 的 tag 或 path 为空（config.Validate 应保证非空）：装配错误", i)
		}
		roots = append(roots, registry.Root{Tag: tag, Path: path, Mode: rc.Mode})
	}
	return roots, nil
}

// firstRootPath 返回笔记根（roots[0]）的物理路径，作为 WebDAV 挂载、git 仓库与
// public 出口偏移的路径基准。
func firstRootPath(cfg *config.Config) (string, error) {
	roots, err := registryRoots(cfg)
	if err != nil {
		return "", err
	}
	return roots[0].Path, nil
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
