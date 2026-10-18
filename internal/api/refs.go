// 本文件实现 M7 C1 的引用查询端点 GET /api/refs 与写路径的引用刷新辅助函数。
//
// 契约：
//
//	GET /api/refs?uid=<uid>&direction=in|out
//	→ 200 {"refs":[{"source_uid","source_location","target_uid","target_location","created_at"}]}
//	→ 400 invalid_uid（uid 格式错）/ invalid_argument（direction 非 in/out）
//	→ 404 unknown_uid（uid 未登记或已墓碑）
//	→ 503 unavailable（registry 未注入）
//
// direction 缺省 out（我引用了谁）；in 表示「谁引用了我」。响应只含引用边本身，
// **不含**物理路径或文件内容：引用图是结构化元数据，客户端按 uid 自行向
// /api/resources/{uid} 取详情。
package api

import (
	"log/slog"
	"net/http"
	"strings"

	"seshat/internal/logging"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// refResponse 是一条引用边的对外表示（字段名与需求契约一致，均为下划线风格）。
//
// source_location 目前恒为空串：refs 记录「哪份文档引用了哪份文档的哪个位置」，
// 源侧位置（org 中的行/标题）暂不采集；保留该字段是为了与表结构及未来采集对齐。
type refResponse struct {
	SourceUID      string `json:"source_uid"`
	SourceLocation string `json:"source_location"`
	TargetUID      string `json:"target_uid"`
	TargetLocation string `json:"target_location"`
	CreatedAt      string `json:"created_at"`
}

// refListResponse 是引用查询的响应体：refs 恒为数组（无结果时为 []）。
type refListResponse struct {
	Refs []refResponse `json:"refs"`
}

// handleListRefs 查询某个 uid 的引用关系（GET /api/refs）。
//
// 校验顺序与其它 uid 端点一致：形态（invalid_uid）→ direction 取值（invalid_argument）
// → 登记状态（unknown_uid）。先校验形态再查库，避免把拼错的 uid 当成「未登记」。
func (s *Server) handleListRefs(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	q := r.URL.Query()
	uid := strings.TrimSpace(q.Get("uid"))
	if !registry.IsUID(uid) {
		writeError(w, logging.NewAppError(logging.ErrInvalidUID,
			"uid 格式非法（须为 26 位 Crockford Base32）"))
		return
	}

	direction := strings.TrimSpace(q.Get("direction"))
	if direction == "" {
		direction = storage.RefDirectionOut
	}
	if direction != storage.RefDirectionIn && direction != storage.RefDirectionOut {
		writeError(w, logging.NewAppError(logging.ErrInvalidArgument,
			"direction 必须是 in 或 out"))
		return
	}

	// 未登记/已墓碑的 uid 一律 404 unknown_uid：引用图以存活资源为主体。
	if _, err := s.registry.Entry(uid); err != nil {
		writeLookupError(w, err)
		return
	}

	refs, err := s.registry.ListRefs(uid, direction)
	if err != nil {
		writeError(w, err)
		return
	}

	resp := refListResponse{Refs: make([]refResponse, 0, len(refs))}
	for i := range refs {
		resp.Refs = append(resp.Refs, refResponse{
			SourceUID:      refs[i].SourceUID,
			SourceLocation: refs[i].SourceLocation,
			TargetUID:      refs[i].TargetUID,
			TargetLocation: refs[i].TargetLocation,
			CreatedAt:      refs[i].CreatedAt,
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// refreshRefsAfterWrite 在 .org 写成功后刷新该源的引用图（失败只记日志）。
//
// 只在 .org 上触发：非 .org 内容不含 seshat: 链接，且 RefreshRefs 对非 .org 会清空
// 引用——对所有写都调用会让附件覆盖无谓地改写 refs 表。
func refreshRefsAfterWrite(reg *registry.Service, rootTag, relPath string) {
	if reg == nil || !strings.HasSuffix(strings.ToLower(relPath), ".org") {
		return
	}
	if err := reg.RefreshRefs(rootTag, relPath); err != nil {
		slog.Error("api: 写文件后刷新引用失败", "root", rootTag, "path", relPath, "error", err)
	}
}
