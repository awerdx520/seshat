// 本文件实现 M7（服务端 uid 身份与增量同步）的只读端点：GET /api/resources、
// GET /api/resources/{uid}、GET /api/resolve、GET /api/changes，以及根映射下发
// GET /api/roots（M7 B2）。
//
// 定位：这些端点只读登记表（resources / changes）与根映射，不触碰文件系统、不写库，
// 全部经 registry.Service 访问，从而与 WebDAV / REST 写路径共用同一套身份语义
// （墓碑视为不存在、路径按登记表规范化、uid 为唯一身份）。
//
// 输出约束：响应只含 root tag + 逻辑 path，绝不输出物理路径或文件内容；uid 形态校验
// 统一走 registry.IsUID（与生成端共用同一正则，避免「生成的过不了校验」）。
package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"seshat/internal/logging"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// 清单类端点的分页参数默认值与上下界（与 storage 层口径保持一致）。
const (
	// listDefaultLimit 是未传 limit 时的默认条数。
	listDefaultLimit = 500
	// listMinLimit 是 limit 的下界：更小的值夹紧为该值（0 不表示「不限」，
	// 避免调用方误以为「不传 limit」等价于「传 0」）。
	listMinLimit = 1
	// listMaxLimit 是 limit 的上界：超过则夹紧，防止单次响应过大。
	listMaxLimit = 2000
)

// resourceResponse 是资源登记的对外表示。
//
// 字段与内部 storage.Entry 一一对应但不含物理路径：root 为根 tag，path 为根内逻辑
// 相对路径。deleted_at 为空串表示存活，非空（RFC3339 UTC）表示墓碑。
type resourceResponse struct {
	UID       string `json:"uid"`
	Root      string `json:"root"`
	Path      string `json:"path"`
	Kind      string `json:"kind"`
	Blob      string `json:"blob"`
	Rev       string `json:"rev"`
	Size      int64  `json:"size"`
	Mtime     int64  `json:"mtime"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
	DeletedAt string `json:"deleted_at"`
}

// resourceListResponse 是资源清单的响应体：items 恒为数组（无结果时为空数组）。
type resourceListResponse struct {
	Items   []resourceResponse `json:"items"`
	HasMore bool               `json:"has_more"`
}

// resolveResponse 是路径解析的响应体：uid 与解析后的权威 root/path。
type resolveResponse struct {
	UID  string `json:"uid"`
	Root string `json:"root"`
	Path string `json:"path"`
}

// changeResponse 是一条变更事件的对外表示。
type changeResponse struct {
	Seq       int64  `json:"seq"`
	UID       string `json:"uid"`
	Op        string `json:"op"`
	Root      string `json:"root"`
	Path      string `json:"path"`
	OldPath   string `json:"old_path"`
	Blob      string `json:"blob"`
	Rev       string `json:"rev"`
	ChangedAt string `json:"changed_at"`
}

// changeListResponse 是增量变更的响应体：changes 恒为数组，next_cursor 为本批最后
// 一条的 seq（无记录时回传请求的 since，游标不倒退）。
type changeListResponse struct {
	Changes    []changeResponse `json:"changes"`
	NextCursor int64            `json:"next_cursor"`
	HasMore    bool             `json:"has_more"`
}

// rootResponse 是单个根的对外表示。
//
// 只含逻辑信息（tag、mode、是否默认根），**不含物理路径**：物理根绝对路径属于服务端
// 部署细节，泄露它对客户端无用且扩大攻击面（目录结构、用户名等）。客户端按 tag 引用
// 根（`tag:relpath` 与 ?root=），路径拼接完全在服务端完成。
type rootResponse struct {
	Tag  string `json:"tag"`
	Mode string `json:"mode"`
	// Default 标记默认根（即 roots[0]，客户端省略 ?root= 时使用的根）。
	Default bool `json:"default"`
}

// rootListResponse 是根清单的响应体：roots 恒为数组（未设置根时为空数组），
// 顺序与配置一致，首项 default=true。
type rootListResponse struct {
	Roots []rootResponse `json:"roots"`
}

// requireRegistry 检查身份登记服务是否已注入：未注入时写 503 并返回 false。
//
// 与 handleSearch 对 indexer 的处理保持一致（同一错误码 "unavailable"）：能力未就绪
// 是服务端装配问题，不是请求错误，故不用 4xx。
func (s *Server) requireRegistry(w http.ResponseWriter) bool {
	if s.registry != nil {
		return true
	}
	writeJSON(w, http.StatusServiceUnavailable, errorResponse{
		Error: errorPayload{Code: "unavailable", Message: "资源登记未启用"},
	})
	return false
}

// handleListResources 列举资源登记（GET /api/resources）。
//
// 查询参数：root（根 tag）、prefix（根内路径段前缀）、since（mtime >= 该 Unix 秒）、
// include_deleted（是否含墓碑，缺省 false）、limit（缺省 500，夹紧到 [1, 2000]）。
// 响应 {"items":[...],"has_more":bool}。
//
// has_more 由「多取一条」判定：向存储层请求 limit+1 条，多出则说明还有下一页，
// 避免为此在存储层新增 Count 查询（单写者 SQLite，多一次全表统计不划算）。
func (s *Server) handleListResources(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	q := r.URL.Query()
	since, err := parseQueryInt64(q.Get("since"), "since")
	if err != nil {
		writeError(w, err)
		return
	}
	includeDeleted, err := parseQueryBool(q.Get("include_deleted"), "include_deleted")
	if err != nil {
		writeError(w, err)
		return
	}
	limit, err := parseQueryLimit(q.Get("limit"))
	if err != nil {
		writeError(w, err)
		return
	}

	items, err := s.registry.List(storage.ResourceFilter{
		Root:           strings.TrimSpace(q.Get("root")),
		Prefix:         strings.TrimSpace(q.Get("prefix")),
		Since:          since,
		IncludeDeleted: includeDeleted,
		Limit:          limit + 1,
	})
	if err != nil {
		writeError(w, err)
		return
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}

	resp := resourceListResponse{
		Items:   make([]resourceResponse, 0, len(items)),
		HasMore: hasMore,
	}
	for i := range items {
		resp.Items = append(resp.Items, toResourceResponse(&items[i]))
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleGetResource 返回单个资源的元数据（GET /api/resources/{uid}）。
//
// uid 形态非法返回 400 invalid_uid；形态合法但未登记或已墓碑返回 404 unknown_uid
// （墓碑对客户端等同不存在，追溯墓碑请走 /api/changes 或 include_deleted 清单）。
func (s *Server) handleGetResource(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	uid := r.PathValue("uid")
	if !registry.IsUID(uid) {
		writeError(w, logging.NewAppError(logging.ErrInvalidUID,
			"uid 格式非法（须为 26 位 Crockford Base32）"))
		return
	}

	entry, err := s.registry.Entry(uid)
	if err != nil {
		writeLookupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toResourceResponse(entry))
}

// handleResolve 把引用 key 解析为 uid（GET /api/resolve）。
//
// 两种互斥输入形态（都写或都不写 → 400 invalid_argument）：
//   - root + path：按 (root tag, 根内路径) 精确解析（走 registry.ResolvePath）；
//   - doc_id：`tag:path` 或纯 path（纯 path 用首个根作为默认根，走 registry.Resolve）。
//
// 响应 {"uid","root","path"}，其中 root/path 取自登记表而非请求参数，即规范化后
// 的权威值（前导斜杠、重复斜杠在存储层已折叠）。未登记或已墓碑 → 404 unknown_uid。
func (s *Server) handleResolve(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	q := r.URL.Query()
	root := strings.TrimSpace(q.Get("root"))
	path := strings.TrimSpace(q.Get("path"))
	docID := strings.TrimSpace(q.Get("doc_id"))

	useDocID := docID != ""
	usePathPair := root != "" || path != ""

	var (
		uid string
		err error
	)
	switch {
	case useDocID && usePathPair:
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
			"root/path 与 doc_id 互斥，只能提供其中一种"))
		return
	case !useDocID && !usePathPair:
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
			"需要提供 root+path 或 doc_id"))
		return
	case useDocID:
		uid, err = s.registry.Resolve(docID)
	default:
		if root == "" || path == "" {
			writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
				"root 与 path 必须同时提供"))
			return
		}
		uid, err = s.registry.ResolvePath(root, path)
	}
	if err != nil {
		writeLookupError(w, err)
		return
	}

	// 回读登记行以返回权威 root/path（同时兜住「解析成功但登记行消失」的竞态）。
	entry, err := s.registry.Entry(uid)
	if err != nil {
		writeLookupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, resolveResponse{UID: entry.UID, Root: entry.Root, Path: entry.Path})
}

// handleListChanges 拉取增量变更（GET /api/changes）。
//
// 查询参数：since（游标，缺省 0，返回 seq > since 的事件）、limit（缺省 500，
// 夹紧到 [1, 2000]）。响应 {"changes":[...],"next_cursor":int,"has_more":bool}：
// 客户端取 next_cursor 作为下次 since 即可连续消费，无事件时游标不倒退。
func (s *Server) handleListChanges(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	q := r.URL.Query()
	since, err := parseQueryInt64(q.Get("since"), "since")
	if err != nil {
		writeError(w, err)
		return
	}
	limit, err := parseQueryLimit(q.Get("limit"))
	if err != nil {
		writeError(w, err)
		return
	}

	changes, nextCursor, hasMore, err := s.registry.Changes(since, limit)
	if err != nil {
		writeError(w, err)
		return
	}

	resp := changeListResponse{
		Changes:    make([]changeResponse, 0, len(changes)),
		NextCursor: nextCursor,
		HasMore:    hasMore,
	}
	for i := range changes {
		resp.Changes = append(resp.Changes, toChangeResponse(&changes[i]))
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleListRoots 下发根清单（GET /api/roots）。
//
// 响应形如
//
//	{"roots":[{"tag":"notes","mode":"mirror","default":true},
//	          {"tag":"ebooks","mode":"ondemand","default":false}]}
//
// 三个字段的语义：
//   - tag：客户端引用根的标识（`tag:relpath` 与 ?root= 均用它）；
//   - mode：mirror（笔记根：WebDAV + git + FTS）或 ondemand（书库根：只经 REST 按需读取）；
//   - default：标记默认根（roots[0]，客户端省略 ?root= 时使用的根）。
//
// 数据源是 registry.Service.Roots()（启动时由 config.WebDAV.Roots 归一化后写入的根
// 映射），故与 api / webdav 各入口使用的「逻辑根」严格同源，不存在两处配置漂移。
// 响应绝不包含物理路径：客户端只需 tag，路径拼接全在服务端完成。
func (s *Server) handleListRoots(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	roots := s.registry.Roots()
	resp := rootListResponse{Roots: make([]rootResponse, 0, len(roots))}
	for i, root := range roots {
		resp.Roots = append(resp.Roots, rootResponse{
			Tag:     root.Tag,
			Mode:    root.Mode,
			Default: i == 0,
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// writeLookupError 写登记查找类错误：未登记/已墓碑（ErrNotFound）统一改写为
// 404 unknown_uid，其余错误（参数非法、内部错误）按原错误码返回。
//
// 之所以改写：客户端需要区分「uid 形态写错」（invalid_uid，应修参数）与「uid 合法
// 但服务端没有」（unknown_uid，应重建本地缓存），故不复用宽泛的 not_found。
func writeLookupError(w http.ResponseWriter, err error) {
	var appErr *logging.AppError
	if errors.As(err, &appErr) && appErr.Code == logging.ErrNotFound {
		message := appErr.Message
		if message == "" {
			message = "资源未登记"
		}
		writeError(w, logging.NewAppError(logging.ErrUnknownUID, message))
		return
	}
	writeError(w, err)
}

// parseQueryInt64 解析整数查询参数；缺省返回 0，非法返回 ErrInvalidArgument（400）。
func parseQueryInt64(raw, name string) (int64, error) {
	if strings.TrimSpace(raw) == "" {
		return 0, nil
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInvalidArgument, "查询参数 "+name+" 必须是整数")
	}
	return n, nil
}

// parseQueryBool 解析布尔查询参数；缺省返回 false，非法返回 ErrInvalidArgument（400）。
func parseQueryBool(raw, name string) (bool, error) {
	if strings.TrimSpace(raw) == "" {
		return false, nil
	}
	v, err := strconv.ParseBool(raw)
	if err != nil {
		return false, logging.Wrap(err, logging.ErrInvalidArgument, "查询参数 "+name+" 必须是布尔值")
	}
	return v, nil
}

// parseQueryLimit 解析 limit 并夹紧到 [listMinLimit, listMaxLimit]。
//
// 与 handleSearch 的 limit 语义不同：那里 limit 必须为正整数（否则 400），这里按
// 本任务契约「默认 500、夹紧 [1,2000]」处理——非整数值仍是 400（拼写错误必须暴露），
// 越界值则视为调用方希望「尽量多/少」而非错误。
func parseQueryLimit(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return listDefaultLimit, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInvalidArgument, "查询参数 limit 必须是整数")
	}
	if n < listMinLimit {
		n = listMinLimit
	}
	if n > listMaxLimit {
		n = listMaxLimit
	}
	return n, nil
}

// toResourceResponse 将存储层资源登记转换为对外表示。
func toResourceResponse(e *storage.Entry) resourceResponse {
	return resourceResponse{
		UID:       e.UID,
		Root:      e.Root,
		Path:      e.Path,
		Kind:      e.Kind,
		Blob:      e.Blob,
		Rev:       e.Rev,
		Size:      e.Size,
		Mtime:     e.Mtime,
		CreatedAt: e.CreatedAt,
		UpdatedAt: e.UpdatedAt,
		DeletedAt: e.DeletedAt,
	}
}

// toChangeResponse 将存储层变更事件转换为对外表示。
func toChangeResponse(c *storage.Change) changeResponse {
	return changeResponse{
		Seq:       c.Seq,
		UID:       c.UID,
		Op:        c.Op,
		Root:      c.Root,
		Path:      c.Path,
		OldPath:   c.OldPath,
		Blob:      c.Blob,
		Rev:       c.Rev,
		ChangedAt: c.ChangedAt,
	}
}
