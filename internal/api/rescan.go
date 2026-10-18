// 本文件实现 M7 B6 的维护端点：POST /api/resources/rescan（全量重扫登记表）。
//
// 定位：rescan 是「修复钩子漏记」的兜底手段（进程崩溃、外部工具直接改盘、git 钩子
// 失效等），不属于正常工作流，故不参与增量同步的游标语义——它只是把磁盘现状与
// resources 表重新对齐，顺带把漏记的变更补写进 changes（客户端照常按游标消费）。
//
// 并发不变量：同一时刻只允许一次重扫。理由不是性能而是正确性——Rescan 会遍历全部
// 根并逐条写登记表（DB 为单写者连接），并发重扫只会互相排队并放大失败概率，且两个
// 扫描交错时「本次未遍历到」的判定不可靠（可能把另一个扫描正在登记的资源误判为
// 已删除）。故用 Server.rescanRunning（atomic.Bool）做 CAS 抢占：抢不到立即返回
// 409 rescan_in_progress，而不是排队等待——维护端点等待会掩盖调用方的误用
// （例如客户端定时任务重叠触发），快速失败更容易被发现。
//
// 输出约束：响应只回计数，不回孤儿列表（客户端要清单请走 GET /api/changes 或
// GET /api/resources?include_deleted=true）。失败文件只在服务端日志记一条计数，
// 不输出路径以外的任何信息，也绝不输出文件内容。
package api

import (
	"log/slog"
	"net/http"

	"seshat/internal/logging"
)

// rescanResponse 是一次重扫的统计结果对外表示（只含计数）。
//
// 字段语义与 registry.Stats 一一对应：
//   - scanned：本次遍历到的普通文件数（含未变与失败）；
//   - created / updated / unchanged：新登记 / 内容有变（含墓碑复活）/ 无需变更；
//   - deleted：登记中存活但本次未遍历到、已写墓碑的资源数；
//   - failed：读元数据或写登记失败的文件数（不阻断整体扫描，重跑即可补齐）。
type rescanResponse struct {
	Scanned   int `json:"scanned"`
	Created   int `json:"created"`
	Updated   int `json:"updated"`
	Unchanged int `json:"unchanged"`
	Deleted   int `json:"deleted"`
	Failed    int `json:"failed"`
}

// handleRescan 触发一次全量重扫（POST /api/resources/rescan）。
//
// 响应 200 + 六个计数字段；已注入的根清单取自 registry.Service.Roots()（与
// /api/roots 同源），故不会与客户端看到根集合漂移。
//
// 上下文用 r.Context()：客户端断开连接即取消遍历（scanRoot 每个条目检查一次
// ctx.Err()），避免一次断开的请求把整棵树扫完。
//
// 错误：
//   - registry 为 nil → 503 unavailable（能力未就绪，与其余身份端点一致）；
//   - 已有重扫在跑 → 409 rescan_in_progress（不排队，见文件头）；
//   - 遍历/写库失败 → 按错误码映射（如根目录不可读 → 400）。
func (s *Server) handleRescan(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	// CAS 抢占：false→true 成功者获得本次独占权。抢不到说明另一次重扫尚未结束，
	// 直接 409（不阻塞等待，理由见文件头「并发不变量」）。
	if !s.rescanRunning.CompareAndSwap(false, true) {
		writeError(w, logging.NewAppError(logging.ErrRescanInProgress,
			"已有重扫在进行中，请稍后重试"))
		return
	}
	// 无论成功、失败还是 panic 展开，都必须归还独占权，否则重扫能力永久失效。
	defer s.rescanRunning.Store(false)

	stats, err := s.registry.Rescan(r.Context(), s.registry.Roots())
	if err != nil {
		writeError(w, err)
		return
	}

	// 维护动作低频，留一条审计日志（只含计数，不含路径与内容）。
	slog.Info("api: 全量重扫完成",
		"scanned", stats.Scanned,
		"created", stats.Created,
		"updated", stats.Updated,
		"unchanged", stats.Unchanged,
		"deleted", stats.Deleted,
		"failed", stats.Failed)

	writeJSON(w, http.StatusOK, rescanResponse{
		Scanned:   stats.Scanned,
		Created:   stats.Created,
		Updated:   stats.Updated,
		Unchanged: stats.Unchanged,
		Deleted:   stats.Deleted,
		Failed:    stats.Failed,
	})
}
