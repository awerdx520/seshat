// Package api 实现 notes 服务端的状态同步 REST 接口：阅读进度与批注的 CRUD。
//
// 定位：文件内容（org/附件/电子书）走 WebDAV 同步，本包只承载「结构化小状态」。
// 所有端点均要求 Bearer 令牌认证（复用 internal/auth），错误统一以
// {"error":{"code","message"}} 的 JSON 返回，其中 code 取自 internal/logging 的错误码。
package api

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"notes/internal/auth"
	"notes/internal/gitver"
	"notes/internal/logging"
	"notes/internal/storage"
)

// Server 封装 REST 处理器的依赖。
type Server struct {
	db *storage.DB

	// repo 提供版本查询能力（文件历史、某版本内容、共同祖先）；
	// 为 nil 时不注册版本查询路由（仅挂载状态同步端点）。
	repo *gitver.Repo
}

// progressResponse 是阅读进度的对外表示。
type progressResponse struct {
	DocumentID string `json:"document_id"`
	Position   string `json:"position"`
	UpdatedAt  string `json:"updated_at"`
}

// annotationResponse 是批注的对外表示。
type annotationResponse struct {
	ID         int64  `json:"id"`
	DocumentID string `json:"document_id"`
	Location   string `json:"location"`
	Text       string `json:"text"`
	CreatedAt  string `json:"created_at"`
	UpdatedAt  string `json:"updated_at"`
}

// progressRequest 是设置进度的请求体。
type progressRequest struct {
	Position  string `json:"position"`
	UpdatedAt string `json:"updated_at"`
}

// annotationCreateRequest 是创建批注的请求体。
type annotationCreateRequest struct {
	DocumentID string `json:"document_id"`
	Location   string `json:"location"`
	Text       string `json:"text"`
}

// annotationUpdateRequest 是更新批注的请求体。
type annotationUpdateRequest struct {
	Location string `json:"location"`
	Text     string `json:"text"`
}

// errorResponse 是统一错误响应体。
type errorResponse struct {
	Error errorPayload `json:"error"`
}

// errorPayload 是错误详情：稳定错误码 + 面向用户的可读信息。
type errorPayload struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// fileHistoryResponse 是文件历史查询的响应体：当前 HEAD 与含该文件的提交列表。
type fileHistoryResponse struct {
	Head    string                 `json:"head"`
	History []historyEntryResponse `json:"history"`
}

// historyEntryResponse 是单个历史提交的对外表示。
type historyEntryResponse struct {
	Hash    string `json:"hash"`
	Message string `json:"message"`
	When    string `json:"when"`
}

// fileContentResponse 是某版本文件内容的响应体。
type fileContentResponse struct {
	Hash    string `json:"hash"`
	Content string `json:"content"`
}

// mergeBaseResponse 是两个版本共同祖先的响应体。
type mergeBaseResponse struct {
	MergeBase string `json:"merge_base"`
}

// llmTaskCreateRequest 是创建 LLM 任务的请求体；route 缺省为 cloud。
type llmTaskCreateRequest struct {
	Kind    string `json:"kind"`
	Payload string `json:"payload"`
	Route   string `json:"route"`
}

// llmTaskCreatedResponse 是创建任务的响应体：新任务的 id 与初始状态。
type llmTaskCreatedResponse struct {
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

// llmTaskResponse 是任务的对外表示（节点轮询领取时返回完整内容）。
type llmTaskResponse struct {
	ID        int64  `json:"id"`
	Kind      string `json:"kind"`
	Payload   string `json:"payload"`
	Route     string `json:"route"`
	Status    string `json:"status"`
	Result    string `json:"result"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

// llmTaskResultRequest 是节点回传任务结果的请求体。
//
// result 与 error 至少提供一个：error 非空时任务标记为 failed（error 作为失败原因），
// 否则标记为 done（result 作为结果正文，允许为空字符串）。
type llmTaskResultRequest struct {
	Result string `json:"result"`
	Error  string `json:"error"`
}

// nodeRegisterRequest 是本地处理节点注册的请求体。
type nodeRegisterRequest struct {
	NodeName string `json:"node_name"`
}

// nodeRegisterResponse 是节点注册的响应体。
type nodeRegisterResponse struct {
	NodeName     string `json:"node_name"`
	Status       string `json:"status"`
	RegisteredAt string `json:"registered_at"`
}

// NewHandler 构造 REST 处理器：内部用 http.ServeMux 路由，整体套 Bearer 认证中间件。
//
// 该入口保持既有签名不变，仅挂载状态同步端点（进度/批注）；需要版本查询
// 端点（文件历史、某版本内容、共同祖先）时改用 NewHandlerWithRepo。
func NewHandler(db *storage.DB, a *auth.Authenticator) http.Handler {
	return a.Middleware(newServer(db, nil).routes())
}

// NewHandlerWithRepo 在 NewHandler 的基础上追加版本查询端点，复用同一套 mux
// 与 Bearer 认证中间件。
//
// repo 提供文件历史/某版本内容/共同祖先能力；repo 为 nil 时不注册版本查询
// 路由（请求落到 ServeMux 默认 404）。
func NewHandlerWithRepo(db *storage.DB, repo *gitver.Repo, a *auth.Authenticator) http.Handler {
	return a.Middleware(newServer(db, repo).routes())
}

// newServer 组装处理器依赖。
func newServer(db *storage.DB, repo *gitver.Repo) *Server {
	return &Server{db: db, repo: repo}
}

// routes 构建全部 REST 路由；版本查询路由仅在 repo 非 nil 时注册。
func (s *Server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/progress/{document_id}", s.handleGetProgress)
	mux.HandleFunc("PUT /api/progress/{document_id}", s.handlePutProgress)
	mux.HandleFunc("POST /api/annotations", s.handleCreateAnnotation)
	mux.HandleFunc("GET /api/annotations", s.handleListAnnotations)
	mux.HandleFunc("PUT /api/annotations/{id}", s.handleUpdateAnnotation)
	mux.HandleFunc("DELETE /api/annotations/{id}", s.handleDeleteAnnotation)

	// LLM 任务队列端点（M6.2）：任务创建、本地处理节点轮询、结果回传与节点注册。
	// 四者均复用同一 Bearer 认证中间件与统一 JSON 错误体。
	mux.HandleFunc("POST /api/llm/tasks", s.handleCreateLLMTask)
	mux.HandleFunc("GET /api/llm/tasks/poll", s.handlePollLLMTask)
	mux.HandleFunc("POST /api/llm/tasks/{id}/result", s.handleLLMTaskResult)
	mux.HandleFunc("POST /api/llm/nodes/register", s.handleRegisterNode)

	if s.repo != nil {
		// {path...} 匹配含子目录的多段路径（如 sub/a.org），文件历史与某版本
		// 内容共用此单一通配路由，由 hash 查询参数区分（见 handleVersion）。
		// 不设 {path}/{hash} 两段式路由：它只匹配两段，子目录文件的
		// GET /api/versions/sub/a.org/<hash>（3 段）会落到历史处理器，内容端点
		// 不可达；改用查询参数传 hash 后，任意深度路径均可取到指定版本内容。
		mux.HandleFunc("GET /api/merge-base", s.handleMergeBase)
		mux.HandleFunc("GET /api/versions/{path...}", s.handleVersion)
	}
	return mux
}

// handleGetProgress 返回文档的最新阅读进度；携带 If-Modified-Since 且进度未更新时返回 304。
func (s *Server) handleGetProgress(w http.ResponseWriter, r *http.Request) {
	documentID := r.PathValue("document_id")

	progress, err := s.db.GetProgress(documentID)
	if err != nil {
		writeError(w, err)
		return
	}

	// 增量同步：客户端携带上次获取的 updated_at（HTTP 日期格式），
	// 若资源未在此之后变化，则返回 304（无响应体）以免重复传输。
	if since := r.Header.Get("If-Modified-Since"); since != "" {
		if sinceTime, parseErr := http.ParseTime(since); parseErr == nil {
			if updatedAt, parseErr := time.Parse(time.RFC3339, progress.UpdatedAt); parseErr == nil &&
				!updatedAt.After(sinceTime) {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
	}

	writeJSON(w, http.StatusOK, toProgressResponse(progress))
}

// handlePutProgress 设置（覆盖）文档的阅读进度。
func (s *Server) handlePutProgress(w http.ResponseWriter, r *http.Request) {
	var req progressRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}

	documentID := r.PathValue("document_id")
	if err := s.db.SetProgress(documentID, req.Position, req.UpdatedAt); err != nil {
		writeError(w, err)
		return
	}

	// 回读以返回服务端实际保存的值（含回填/规范化后的 updated_at）。
	progress, err := s.db.GetProgress(documentID)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toProgressResponse(progress))
}

// handleCreateAnnotation 创建批注并返回 201 + 完整记录（含服务端生成的 id 与时间戳）。
func (s *Server) handleCreateAnnotation(w http.ResponseWriter, r *http.Request) {
	var req annotationCreateRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}

	annotation, err := s.db.CreateAnnotation(req.DocumentID, req.Location, req.Text)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, toAnnotationResponse(annotation))
}

// handleListAnnotations 按 document_id 列出批注。
func (s *Server) handleListAnnotations(w http.ResponseWriter, r *http.Request) {
	documentID := r.URL.Query().Get("document_id")

	items, err := s.db.ListAnnotations(documentID)
	if err != nil {
		writeError(w, err)
		return
	}

	resp := make([]annotationResponse, 0, len(items))
	for i := range items {
		resp = append(resp, toAnnotationResponse(&items[i]))
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleUpdateAnnotation 整体替换批注内容（created_at 保持不变）。
func (s *Server) handleUpdateAnnotation(w http.ResponseWriter, r *http.Request) {
	id, err := parseAnnotationID(r.PathValue("id"))
	if err != nil {
		writeError(w, err)
		return
	}

	var req annotationUpdateRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}

	annotation, err := s.db.UpdateAnnotation(id, req.Location, req.Text)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toAnnotationResponse(annotation))
}

// handleDeleteAnnotation 删除批注；成功返回 204（无响应体）。
func (s *Server) handleDeleteAnnotation(w http.ResponseWriter, r *http.Request) {
	id, err := parseAnnotationID(r.PathValue("id"))
	if err != nil {
		writeError(w, err)
		return
	}

	if err := s.db.DeleteAnnotation(id); err != nil {
		writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleVersion 是 GET /api/versions/{path...} 的统一处理器，由 hash 查询
// 参数分派两种语义：
//
//   - 无 hash：返回文件历史 {"head":"<hash>","history":[{hash,message,when}]}；
//   - 有 hash：返回该版本的内容 {"hash":"...","content":"..."}（文件不存在
//     404、版本无法解析 400）。
//
// 之所以把「历史」与「某版本内容」合并为单一路由、以查询参数区分，是因为
// 两段式 {path}/{hash} 只匹配两层路径，含子目录的文件（如 sub/a.org）无法
// 拼出其内容端点；查询参数形式对任意深度路径均可用。
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	if hash := r.URL.Query().Get("hash"); hash != "" {
		s.handleFileContent(w, r, hash)
		return
	}
	s.handleFileHistory(w, r)
}

// handleFileHistory 返回文件的历史提交列表与当前 HEAD。
//
// 响应形如 {"head":"<hash>","history":[{"hash","message","when"}]}，历史按
// 提交时间倒序（新到旧）。仓库尚无提交时为 {"head":"","history":[]}。
func (s *Server) handleFileHistory(w http.ResponseWriter, r *http.Request) {
	path := r.PathValue("path")

	// HEAD 取最近一次提交的 hash（Log(1) 返回 "<hash> <message>"）。
	head := ""
	if entries, err := s.repo.Log(1); err != nil {
		writeError(w, err)
		return
	} else if len(entries) > 0 {
		head, _, _ = strings.Cut(entries[0], " ")
	}

	history, err := s.repo.FileHistory(path)
	if err != nil {
		writeError(w, err)
		return
	}

	items := make([]historyEntryResponse, 0, len(history))
	for _, entry := range history {
		items = append(items, historyEntryResponse{
			Hash:    entry.Hash,
			Message: entry.Message,
			When:    entry.When.Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, fileHistoryResponse{Head: head, History: items})
}

// handleFileContent 返回文件在指定版本处的内容；hash 由 handleVersion 从
// hash 查询参数解析后传入，路径取自 {path...}。
//
// 响应形如 {"hash":"...","content":"..."}；文件在该版本不存在时返回 404，
// 版本无法解析时返回 400。
func (s *Server) handleFileContent(w http.ResponseWriter, r *http.Request, hash string) {
	path := r.PathValue("path")

	content, err := s.repo.FileContent(path, hash)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, fileContentResponse{Hash: hash, Content: content})
}

// handleMergeBase 返回两个版本的共同祖先。
//
// 查询参数 a、b 为 git revision 字符串；响应形如 {"merge_base":"<hash>"}。
// 缺少参数或版本无法解析时返回 400；两者无共同祖先时返回 409。
func (s *Server) handleMergeBase(w http.ResponseWriter, r *http.Request) {
	a := r.URL.Query().Get("a")
	b := r.URL.Query().Get("b")
	if a == "" || b == "" {
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
			"查询参数 a 与 b 均为必填"))
		return
	}

	base, err := s.repo.MergeBase(a, b)
	if err != nil {
		// gitver.MergeBase 对「无共同祖先」返回未包装的普通 error（其余情形
		// 为带错误码的 AppError，如版本无法解析）。据此把无共同祖先映射为 409。
		var appErr *logging.AppError
		if errors.As(err, &appErr) {
			writeError(w, err)
			return
		}
		writeJSON(w, http.StatusConflict, errorResponse{
			Error: errorPayload{Code: string(logging.ErrConflict), Message: err.Error()},
		})
		return
	}
	writeJSON(w, http.StatusOK, mergeBaseResponse{MergeBase: base})
}

// handleCreateLLMTask 创建一条 LLM 任务并入队，成功返回 201 + {id,status:"pending"}。
//
// route 缺省为 cloud（默认走云端 API）；标记 route=local 的任务进入本地处理节点
// 的轮询队列（见 handlePollLLMTask）。kind 与 payload 为必填：payload 是任务请求体
// 的原始 JSON 文本，对队列透明，由任务类型与执行方（云端调用方或本地节点）解释。
func (s *Server) handleCreateLLMTask(w http.ResponseWriter, r *http.Request) {
	var req llmTaskCreateRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}

	id, err := s.db.CreateLLMTask(req.Kind, req.Payload, req.Route)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, llmTaskCreatedResponse{ID: id, Status: storage.LLMTaskPending})
}

// handlePollLLMTask 供本地处理节点轮询领取一条待办的本地任务，领取时置为 running。
//
// 有任务返回 200 + 完整任务内容（含 payload）；无待办任务返回 204（无响应体），
// 节点据此休眠数秒后再试——「暂无任务」是轮询的正常结果，不是错误。
func (s *Server) handlePollLLMTask(w http.ResponseWriter, r *http.Request) {
	task, err := s.db.PollLLMTask()
	if err != nil {
		writeError(w, err)
		return
	}
	if task == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, toLLMTaskResponse(task))
}

// handleLLMTaskResult 接收节点回传的任务结果：error 非空时标记 failed（error 为失败原因），
// 否则标记 done（result 为结果正文）。成功返回 204（无响应体）。
func (s *Server) handleLLMTaskResult(w http.ResponseWriter, r *http.Request) {
	id, err := parsePositiveID(r.PathValue("id"), "任务")
	if err != nil {
		writeError(w, err)
		return
	}

	var req llmTaskResultRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}

	if strings.TrimSpace(req.Error) != "" {
		if err := s.db.FailLLMTask(id, req.Error); err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if err := s.db.CompleteLLMTask(id, req.Result); err != nil {
		writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleRegisterNode 记录本地处理节点的注册，成功返回 200 + 注册信息。
//
// MVP 实现：把节点最近一次注册时间写入 meta 表（键 llm_node:<name>）并记日志，
// 不维护心跳与在线状态（是否在线由后续轮询行为推断）。node_name 为空返回 400。
func (s *Server) handleRegisterNode(w http.ResponseWriter, r *http.Request) {
	var req nodeRegisterRequest
	if err := decodeBody(r, &req); err != nil {
		writeError(w, err)
		return
	}
	if strings.TrimSpace(req.NodeName) == "" {
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument, "node_name 不能为空"))
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if err := s.recordNodeRegistration(req.NodeName, now); err != nil {
		writeError(w, err)
		return
	}
	slog.Info("api: 本地处理节点注册", "node_name", req.NodeName)
	writeJSON(w, http.StatusOK, nodeRegisterResponse{
		NodeName:     req.NodeName,
		Status:       "registered",
		RegisteredAt: now,
	})
}

// recordNodeRegistration 把节点最近一次注册时间写入 meta 表（后写覆盖）。
//
// 此处经 storage.DB.SQL() 直接操作 meta 表：该表是简单键值映射，尚无专门领域方法，
// 正是 SQL() 访问器声明的适用场景（见 storage 包注释）。
func (s *Server) recordNodeRegistration(name, at string) error {
	sqlDB := s.db.SQL()
	if sqlDB == nil {
		return nil
	}
	_, err := sqlDB.Exec(
		`INSERT INTO meta(key, value) VALUES(?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		"llm_node:"+name, at)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "记录节点注册失败")
	}
	return nil
}

// toLLMTaskResponse 将存储层任务转换为对外表示。
func toLLMTaskResponse(t *storage.LLMTask) llmTaskResponse {
	return llmTaskResponse{
		ID:        t.ID,
		Kind:      t.Kind,
		Payload:   t.Payload,
		Route:     t.Route,
		Status:    t.Status,
		Result:    t.Result,
		CreatedAt: t.CreatedAt,
		UpdatedAt: t.UpdatedAt,
	}
}

// parseAnnotationID 将路径参数中的批注 id 解析为正整数。
func parseAnnotationID(raw string) (int64, error) {
	return parsePositiveID(raw, "批注")
}

// parsePositiveID 将路径参数解析为正整数资源 id（label 为错误信息中的资源名，如「批注」「任务」）。
func parsePositiveID(raw, label string) (int64, error) {
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInvalidArgument, label+" id 必须是正整数")
	}
	if id <= 0 {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, label+" id 必须是正整数")
	}
	return id, nil
}

// decodeBody 解析请求体 JSON；非法请求体返回 ErrInvalidArgument。
func decodeBody(r *http.Request, dst any) error {
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(dst); err != nil {
		return logging.Wrap(err, logging.ErrInvalidArgument, "请求体不是合法 JSON")
	}
	return nil
}

// toProgressResponse 将存储层进度转换为对外表示。
func toProgressResponse(p *storage.Progress) progressResponse {
	return progressResponse{DocumentID: p.DocumentID, Position: p.Position, UpdatedAt: p.UpdatedAt}
}

// toAnnotationResponse 将存储层批注转换为对外表示。
func toAnnotationResponse(a *storage.Annotation) annotationResponse {
	return annotationResponse{
		ID:         a.ID,
		DocumentID: a.DocumentID,
		Location:   a.Location,
		Text:       a.Text,
		CreatedAt:  a.CreatedAt,
		UpdatedAt:  a.UpdatedAt,
	}
}

// writeJSON 写出 JSON 响应；编码失败时仅记录日志（状态码已提交，无法回退）。
func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		slog.Error("api: 序列化响应失败", "error", err)
	}
}

// writeError 将错误映射为统一 JSON 响应：错误码决定 HTTP 状态码。
func writeError(w http.ResponseWriter, err error) {
	code := logging.ErrInternal
	message := "内部错误"

	var appErr *logging.AppError
	if errors.As(err, &appErr) {
		code = appErr.Code
		if appErr.Message != "" {
			message = appErr.Message
		}
	}

	writeJSON(w, statusForCode(code), errorResponse{
		Error: errorPayload{Code: string(code), Message: message},
	})
}

// statusForCode 将应用错误码映射为 HTTP 状态码。
func statusForCode(code logging.Code) int {
	switch code {
	case logging.ErrInvalidArgument:
		return http.StatusBadRequest
	case logging.ErrUnauthorized:
		return http.StatusUnauthorized
	case logging.ErrForbidden:
		return http.StatusForbidden
	case logging.ErrNotFound:
		return http.StatusNotFound
	case logging.ErrConflict:
		return http.StatusConflict
	default:
		return http.StatusInternalServerError
	}
}
