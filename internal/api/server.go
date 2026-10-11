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
	"time"

	"notes/internal/auth"
	"notes/internal/logging"
	"notes/internal/storage"
)

// Server 封装 REST 处理器的依赖。
type Server struct {
	db *storage.DB
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

// NewHandler 构造 REST 处理器：内部用 http.ServeMux 路由，整体套 Bearer 认证中间件。
func NewHandler(db *storage.DB, a *auth.Authenticator) http.Handler {
	s := &Server{db: db}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/progress/{document_id}", s.handleGetProgress)
	mux.HandleFunc("PUT /api/progress/{document_id}", s.handlePutProgress)
	mux.HandleFunc("POST /api/annotations", s.handleCreateAnnotation)
	mux.HandleFunc("GET /api/annotations", s.handleListAnnotations)
	mux.HandleFunc("PUT /api/annotations/{id}", s.handleUpdateAnnotation)
	mux.HandleFunc("DELETE /api/annotations/{id}", s.handleDeleteAnnotation)

	return a.Middleware(mux)
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

// parseAnnotationID 将路径参数中的批注 id 解析为正整数。
func parseAnnotationID(raw string) (int64, error) {
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInvalidArgument, "批注 id 必须是正整数")
	}
	if id <= 0 {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "批注 id 必须是正整数")
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
