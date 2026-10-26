// Package registry 提供服务端权威的文件身份与增量同步地基：uid 生成与校验、
// 事件应用（资源登记 + 变更日志同事务）、key 解析（uid / tag:path / 纯 path），
// 以及文件系统 → 登记表的 bootstrap / rescan。
//
// 分层约定：本包只做「身份语义 + 编排」，表级 SQL 全部委托 internal/storage
// （见 storage/apply.go 的 ApplyResourceChange）；文件遍历只读元数据（size/mtime），
// 不在任何数据库事务内做文件 IO 或内容哈希——DB 为单写者连接，长事务会阻塞全部读写。
package registry

import (
	"errors"
	"strings"
	"sync"
	"time"

	"seshat/internal/gitver"
	"seshat/internal/logging"
	"seshat/internal/pathguard"
	"seshat/internal/storage"
)

// 根的两种模式。
const (
	// RootModeMirror 是笔记根：WebDAV 全量镜像、git 版本化、FTS 索引，内容哈希可得。
	RootModeMirror = "mirror"
	// RootModeOnDemand 是书库根：不进 git、不在 WebDAV 暴露、按需经 REST 读取，
	// 故不计算内容哈希（blob 恒为空串）。
	RootModeOnDemand = "ondemand"
)

// Root 是一个受登记管理的物理根目录。
type Root struct {
	Tag  string // 根标签，唯一、非空、不含 ':'
	Path string // 物理根目录
	Mode string // "mirror"（笔记根，git + FTS）| "ondemand"（书库，按需）
}

// Event 是一次身份/内容变更。At 为空时由实现填当前 UTC。
type Event struct {
	UID     string
	Op      string // storage.OpCreate / OpUpdate / OpRename / OpDelete
	Root    string
	Path    string
	OldPath string
	Blob    string
	Rev     string
	Size    int64
	Mtime   int64
	At      string
}

// Stats 是一次扫描的统计结果（只含计数，不含文件内容）。
type Stats struct {
	Scanned   int
	Created   int
	Updated   int
	Unchanged int
	Deleted   int
	Failed    int
}

// Service 是身份登记与事件写入的编排入口。
//
// roots 由 SetRoots 写入、被 Resolve（默认根）与 Bootstrap 读取，故用读写锁保护；
// db 与 repo 在构造后不变，无需加锁。
type Service struct {
	db   *storage.DB
	repo *gitver.Repo

	mu    sync.RWMutex
	roots []Root

	// applyHook 仅供测试注入「Apply 失败」这一分支（生产恒为 nil）。
	//
	// 理由：bootstrap/rescan 的「文件仍在磁盘上但登记失败」无法用磁盘或 DB 状态构造——
	// 让 DB 整体不可写会连墓碑写入一起失败，测试就观察不到「不该写墓碑」这一行为；
	// 用非法路径注入又会被 Rescan 的删除路径同样拒绝。故留一个包内可替换的钩子。
	applyHook func(Event) (int64, error)
}

// New 构造 Service。repo 可为 nil（此时 mirror 根不计算内容哈希，blob 为空串）。
func New(db *storage.DB, repo *gitver.Repo) *Service {
	return &Service{db: db, repo: repo}
}

// Apply 应用一次变更事件，返回新 change 的 seq。
//
// 语义边界（与 WebDAV/REST 写路径共同遵守）：
//   - create：uid 已存在（存活）时视为 update（幂等重放，created_at 保持不变）；
//   - update：uid 未登记或已墓碑时先 create（复活墓碑）；
//   - rename：uid 不变、path 改为新路径，old_path 记旧路径；目标路径被其它 uid
//     占用返回 ErrConflict，uid 不存在返回 ErrNotFound；
//   - delete：写墓碑（不物理删除，path 保留删除前值）；uid 不存在返回 ErrNotFound。
//
// 资源登记与变更事件在同一事务内落库（见 storage.ApplyResourceChange）。
func (s *Service) Apply(e Event) (int64, error) {
	if !IsUID(e.UID) {
		return 0, logging.NewAppError(logging.ErrInvalidArgument,
			"uid 格式非法（须为 26 位 Crockford Base32）")
	}
	root := strings.TrimSpace(e.Root)
	if root == "" {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "事件 root 不能为空")
	}
	switch e.Op {
	case storage.OpCreate, storage.OpUpdate, storage.OpRename, storage.OpDelete:
	default:
		return 0, logging.NewAppError(logging.ErrInvalidArgument,
			"事件 op 必须是 create/update/rename/delete")
	}
	newPath, err := normalizeResourcePath(e.Path)
	if err != nil {
		return 0, err
	}

	at := strings.TrimSpace(e.At)
	if at == "" {
		at = time.Now().UTC().Format(time.RFC3339)
	}

	existing, getErr := s.db.GetResourceByUID(e.UID)
	if getErr != nil && !isNotFound(getErr) {
		return 0, getErr
	}
	live := getErr == nil && existing.DeletedAt == ""

	op := e.Op
	var (
		entry         storage.Entry
		renameOldPath string
	)

	switch e.Op {
	case storage.OpCreate, storage.OpUpdate:
		// 幂等重放与缺失补齐：事件 op 按实际落库语义归一。
		switch {
		case e.Op == storage.OpCreate && live:
			op = storage.OpUpdate
		case e.Op == storage.OpUpdate && !live:
			op = storage.OpCreate
		}
		entry = storage.Entry{
			UID:       e.UID,
			Root:      root,
			Path:      newPath,
			Kind:      storage.ResourceKindFile,
			Blob:      e.Blob,
			Rev:       e.Rev,
			Size:      e.Size,
			Mtime:     e.Mtime,
			UpdatedAt: at,
		}

	case storage.OpRename:
		if !live {
			return 0, logging.NewAppError(logging.ErrNotFound, "资源不存在，无法改名")
		}
		renameOldPath = existing.Path
		if strings.TrimSpace(e.OldPath) != "" {
			p, err := normalizeResourcePath(e.OldPath)
			if err != nil {
				return 0, err
			}
			renameOldPath = p
		}
		entry = *existing
		entry.Root = root
		entry.Path = newPath
		entry.UpdatedAt = at
		entry.DeletedAt = ""
		// 改名不改内容：事件携带的字段仅在与内容相关时才覆盖既有值。
		if e.Blob != "" {
			entry.Blob = e.Blob
		}
		if e.Rev != "" {
			entry.Rev = e.Rev
		}
		if e.Size > 0 {
			entry.Size = e.Size
		}
		if e.Mtime > 0 {
			entry.Mtime = e.Mtime
		}

	case storage.OpDelete:
		if !live {
			return 0, logging.NewAppError(logging.ErrNotFound, "资源不存在，无法删除")
		}
		// 墓碑保留删除前路径与所属根：事件里的 path/root 只作校验，均以登记为准。
		entry = *existing
		entry.DeletedAt = at
		entry.UpdatedAt = at
	}

	change := storage.Change{
		UID:       e.UID,
		Op:        op,
		Root:      entry.Root,
		Path:      entry.Path,
		Blob:      entry.Blob,
		Rev:       entry.Rev,
		ChangedAt: at,
	}
	if op == storage.OpRename {
		change.OldPath = renameOldPath
	}

	return s.db.ApplyResourceChange(entry, change)
}

// applyEvent 是 scanRoot 写入登记的唯一入口：生产路径等价于直接调用 Apply，
// 测试可通过 applyHook 注入失败以覆盖「登记失败但文件仍在磁盘上」的分支。
func (s *Service) applyEvent(e Event) (int64, error) {
	if s.applyHook != nil {
		return s.applyHook(e)
	}
	return s.Apply(e)
}

// uidRefPrefix 是**客户端协议形态**的引用前缀：Emacs 客户端产出的 seshat 链接写作
// `seshat:uid:<uid>`，故交给 Resolve 的引用 key 形如 `uid:<uid>`。
//
// 与裸 uid 形态（引用 key 直接是 26 位 uid，服务端既有的写法）并存：裸 uid 用于
// 服务端内部与既有测试，`uid:` 前缀形态给客户端用，两者解析到同一 uid、同一套
// 墓碑语义。保留裸 uid 而不强制前缀，是因为前缀并非「更正确」，只是客户端为了在
// org 文本里与 tag:path / 纯 path 形态无歧义地区分而选定的协议约定。
const uidRefPrefix = "uid:"

// Resolve 把引用 key 解析为 uid。
//
// 优先级（顺序固定，四段）：
//  1. 去空白后为空 → ErrInvalidArgument「引用 key 不能为空」；
//  2. 裸 uid 形态（26 位 Crockford Base32，见 IsUID）直接按 uid 查（墓碑视为 not found）；
//  3. 显式 uid 形态 `uid:<uid>`（客户端协议形态，前缀见 uidRefPrefix）——前缀之后
//     是合法 uid 时走与第 2 段完全相同的 uid 分支（同一个 Entry 查询、同样的墓碑语义）；
//  4. 否则按路径形态解析：含 ':' 时首个冒号前为根 tag、其后为路径；不含 ':' 时用
//     SetRoots 记录的首个根作为默认根。未调用过 SetRoots 时纯路径形态返回
//     ErrInvalidArgument（消息含「未设置默认根」），不猜测根。
//
// 第 3 段是**有条件**的一跳：只有 `uid:` 之后确实是合法 uid 才生效。否则（长度不对、
// 含 Crockford 之外的字符、前缀后为空）一律回落到第 4 段，把 "uid" 当作普通根 tag 去
// 查路径，**不返回 ErrInvalidArgument**——这条回落规则保证「根标签恰好叫 uid」的部署
// 仍然可用（否则该根的文档会永远解析不到，且报错信息会误导人去查 uid 格式）。
func (s *Service) Resolve(key string) (string, error) {
	trimmed := strings.TrimSpace(key)
	if trimmed == "" {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "引用 key 不能为空")
	}

	if IsUID(trimmed) {
		e, err := s.Entry(trimmed)
		if err != nil {
			return "", err
		}
		return e.UID, nil
	}

	// 客户端显式 uid 形态：仅当前缀之后是合法 uid 时才算命中，否则继续走路径分支。
	if strings.HasPrefix(trimmed, uidRefPrefix) {
		if uid := strings.TrimPrefix(trimmed, uidRefPrefix); IsUID(uid) {
			e, err := s.Entry(uid)
			if err != nil {
				return "", err
			}
			return e.UID, nil
		}
	}

	root, p := "", trimmed
	if i := strings.Index(trimmed, ":"); i >= 0 {
		root, p = trimmed[:i], trimmed[i+1:]
	} else {
		def, err := s.defaultRoot()
		if err != nil {
			return "", err
		}
		root = def
	}
	return s.ResolvePath(root, p)
}

// ResolvePath 把 (root, path) 解析为 uid；路径未登记或已墓碑返回 ErrNotFound。
//
// 路径先规范化为登记表使用的形态（去前导 '/'、折叠重复斜杠、拒绝含 ".." 的逃逸）。
func (s *Service) ResolvePath(root, path string) (string, error) {
	cleanRoot := strings.TrimSpace(root)
	if cleanRoot == "" {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "根 tag 不能为空")
	}
	cleanPath, err := normalizeResourcePath(path)
	if err != nil {
		return "", err
	}

	e, err := s.db.GetResourceByPath(cleanRoot, cleanPath)
	if err != nil {
		if isNotFound(err) {
			return "", logging.Wrap(err, logging.ErrNotFound, "路径未登记")
		}
		return "", err
	}
	if e.DeletedAt != "" {
		return "", logging.NewAppError(logging.ErrNotFound, "路径未登记（资源已删除）")
	}
	return e.UID, nil
}

// Entry 返回 uid 对应的存活资源登记；uid 非法返回 ErrInvalidArgument，
// 未登记或已墓碑返回 ErrNotFound。
func (s *Service) Entry(uid string) (*storage.Entry, error) {
	if !IsUID(uid) {
		return nil, logging.NewAppError(logging.ErrInvalidArgument,
			"uid 格式非法（须为 26 位 Crockford Base32）")
	}
	e, err := s.db.GetResourceByUID(uid)
	if err != nil {
		return nil, err
	}
	if e.DeletedAt != "" {
		return nil, logging.NewAppError(logging.ErrNotFound, "资源不存在（已删除）")
	}
	return e, nil
}

// List 列举资源登记（薄委托 storage.ListResources）。
func (s *Service) List(f storage.ResourceFilter) ([]storage.Entry, error) {
	return s.db.ListResources(f)
}

// Changes 拉取 seq > since 的变更批次（薄委托 storage.ListChanges）。
func (s *Service) Changes(since int64, limit int) ([]storage.Change, int64, bool, error) {
	return s.db.ListChanges(since, limit)
}

// SetRoots 设置根清单：tag 必须唯一、非空且不含 ':'；首个根即默认根。
//
// Mode 为空时按位置归一（首根 mirror、其余 ondemand），使调用方只需声明 tag 与路径。
// Path 只做非空校验：空 Path 会让 filepath.Join("", rel) 退化为进程 CWD，使「登记根」
// 静默变成「当前工作目录」并让扫描/读取越界到部署目录之外。不做绝对化或存在性校验
// ——那是 Bootstrap 的职责（此处允许先登记后建目录）。
func (s *Service) SetRoots(roots []Root) error {
	if len(roots) == 0 {
		return logging.NewAppError(logging.ErrInvalidArgument, "根清单至少需要一项")
	}

	normalized := make([]Root, 0, len(roots))
	seen := make(map[string]struct{}, len(roots))
	for i, r := range roots {
		tag := strings.TrimSpace(r.Tag)
		if tag == "" {
			return logging.NewAppError(logging.ErrInvalidArgument, "根 tag 不能为空")
		}
		if strings.Contains(tag, ":") {
			return logging.NewAppError(logging.ErrInvalidArgument, "根 tag 不能包含 ':'（与 tag:path 语法冲突）")
		}
		if _, dup := seen[tag]; dup {
			return logging.NewAppError(logging.ErrInvalidArgument, "根 tag 不能重复: "+tag)
		}
		seen[tag] = struct{}{}

		rootPath := strings.TrimSpace(r.Path)
		if rootPath == "" {
			return logging.NewAppError(logging.ErrInvalidArgument,
				"根 "+tag+" 的物理路径不能为空")
		}

		mode := strings.TrimSpace(r.Mode)
		if mode == "" {
			mode = RootModeOnDemand
			if i == 0 {
				mode = RootModeMirror
			}
		}
		normalized = append(normalized, Root{
			Tag:  tag,
			Path: rootPath,
			Mode: mode,
		})
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.roots = normalized
	return nil
}

// Roots 返回已设置的根清单副本（按设置顺序，首个为默认根）。
func (s *Service) Roots() []Root {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if len(s.roots) == 0 {
		return nil
	}
	out := make([]Root, len(s.roots))
	copy(out, s.roots)
	return out
}

// defaultRoot 返回默认根 tag（SetRoots 的首项）。
func (s *Service) defaultRoot() (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if len(s.roots) == 0 {
		return "", logging.NewAppError(logging.ErrInvalidArgument,
			"未设置默认根，请先调用 SetRoots")
	}
	return s.roots[0].Tag, nil
}

// normalizeResourcePath 把路径规范化为登记表使用的形态。
//
// 规则本体在 internal/pathguard（单一真源），本函数只做两件调用方特有的事：
//  1. 去空白（与 API 侧一致；pathguard 不做 TrimSpace，差异留在这里）；
//  2. 把 pathguard 的哨兵错误按登记层文案与错误码包装成 AppError。
//
// 零值口径（拒绝 ".." 段与点段）正是登记表需要的：含 ".." 段的路径直接拒绝
// （与 webdav/gitver 的「吸收 ..」不同——登记表的键必须可被调用方预测，静默改写会让
// 「引用某路径」与「登记某路径」指向不同字符串）。
//
// 三类被拒路径的理由都是「登记表的键会因此与其它层不一致」：
//   - 含 NUL：SQLite 文本列遇 NUL 会截断，写入的键与查回的键不再相同；
//   - 任一段为 .git（大小写不敏感，兼顾大小写不敏感的卷）：Apply 可写的键等同于
//     「可被登记的路径」，放行 .git 会让写入路径直达版本库内部目录并破坏仓库；
//   - 任一段以 '.' 开头（隐藏文件/目录）：bootstrap 遍历时整棵跳过点目录、不登记其中
//     的文件，若 Apply 接受点路径就会出现「登记表里有、扫描看不到」的不一致——Rescan
//     会把它当作磁盘上已消失的资源写墓碑，客户端也会看到无法通过扫描恢复的条目。
//
// 点段检查由 pathguard 在规范化之后做：'./a.org' 这类输入折叠后不含点段，与 WalkDir
// 给出的名字口径一致（bootstrap 侧永远不会产生 './' 前缀）。
func normalizeResourcePath(p string) (string, error) {
	trimmed := strings.TrimSpace(p)
	// 先单独处理空白输入：它的文案是「不能为空」，与「规范化后为空」（"/"、"." 等）
	// 不同，两者历史上就分开报，此处保持。
	if trimmed == "" {
		return "", logging.NewAppError(logging.ErrInvalidArgument, "资源路径不能为空")
	}
	clean, err := pathguard.CleanRel(trimmed, pathguard.Options{})
	if err != nil {
		return "", resourcePathError(err)
	}
	return clean, nil
}

// resourcePathError 把 pathguard 的哨兵错误映射为登记层的错误码与中文文案。
//
// 文案与错误码与收敛前逐字一致（既有用例按文案断言）。
func resourcePathError(err error) error {
	var msg string
	switch {
	case errors.Is(err, pathguard.ErrNUL):
		msg = "资源路径不能包含 NUL 字符"
	case errors.Is(err, pathguard.ErrParentSegment):
		msg = `资源路径不能包含 ".."`
	case errors.Is(err, pathguard.ErrGitSegment):
		msg = "资源路径不能包含 .git 段（版本库内部目录不登记）"
	case errors.Is(err, pathguard.ErrDotSegment):
		msg = "资源路径不能包含以 '.' 开头的段（隐藏文件/目录不登记）"
	case errors.Is(err, pathguard.ErrEmpty):
		msg = "资源路径规范化后为空"
	default:
		msg = "资源路径不合法"
	}
	return logging.NewAppError(logging.ErrInvalidArgument, msg)
}

// isNotFound 判断 err 是否为 ErrNotFound 错误码。
func isNotFound(err error) bool {
	var appErr *logging.AppError
	return errors.As(err, &appErr) && appErr.Code == logging.ErrNotFound
}
