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
	"strconv"
	"time"

	"seshat/internal/logging"
)

// rescanMinInterval 是两次全量重扫之间的最小间隔。var 而非常量：测试需要临时置 0
// 以便连续调用；生产恒为 60s。
//
// 取 60s 的理由：rescan 是修补漏记的兜底手段（客户端定时任务 / 手工触发），不是正常
// 工作流的一部分；一次全量遍历会读遍所有根并逐条写登记表，比正常写请求贵几个数量级。
// 60s 足以挡住「重试循环」「多客户端同时触发」这类误用，又不至于让人工排障时等太久。
var rescanMinInterval = 60 * time.Second

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
//   - 距上次重扫结束不足 rescanMinInterval → 429 rate_limited + Retry-After；
//   - 已有重扫在跑 → 409 rescan_in_progress（不排队，见文件头）；
//   - 遍历/写库失败 → 按错误码映射（如根目录不可读 → 400）。
func (s *Server) handleRescan(w http.ResponseWriter, r *http.Request) {
	if !s.requireRegistry(w) {
		return
	}

	// 限流：距上一次重扫**结束**不足 rescanMinInterval 则 429。
	//
	// 顺序是设计要点：本检查排在 CAS 之前，且命中时**不抢占独占权、不写 lastAt**。
	// 若在这里写 lastAt，被拒的客户端每次重试都会把窗口往后推，等于把自己永久
	// 锁在窗口外（也等于给了任意客户端一条无限延长禁用窗口的途径）。
	if last := s.rescanLastAt.Load(); last != 0 {
		since := time.Since(time.Unix(0, last))
		if since < rescanMinInterval {
			// 向上取整且至少 1 秒：Retry-After 不接受 0/负数，向下取整会让客户端
			// 在窗口尚未结束时就被放回来（间隔 60s、剩余 1.2s 时向下取整是 1s，
			// 客户端 1s 后重试仍会被拒，形成乒乓）。
			remaining := rescanMinInterval - since
			secs := int((remaining + time.Second - 1) / time.Second)
			if secs < 1 {
				secs = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(secs))
			writeError(w, logging.NewAppError(logging.ErrRateLimited,
				"重扫过于频繁，请稍后重试"))
			return
		}
	}

	// CAS 抢占：false→true 成功者获得本次独占权。抢不到说明另一次重扫尚未结束，
	// 直接 409（不阻塞等待，理由见文件头「并发不变量」）。
	if !s.rescanRunning.CompareAndSwap(false, true) {
		writeError(w, logging.NewAppError(logging.ErrRescanInProgress,
			"已有重扫在进行中，请稍后重试"))
		return
	}
	// 无论成功、失败还是 panic 展开，都必须归还独占权，否则重扫能力永久失效；
	// 同时记下本次重扫的「结束」时刻，作为下一次请求的限流基准。
	//
	// 两步的顺序不可颠倒：先写 lastAt 再清 running。反过来的话，「running 已清、
	// lastAt 还没写」之间存在一个真实时序窗口，窗口内到达的新请求会看到旧的
	// lastAt 而直接抢到 CAS —— 限流被静默绕过。反之（先写 lastAt）的最坏后果只是
	// 同刻到达者在窗口里看到 429，语义上仍正确（上一次确实刚结束）。
	//
	// 失败路径同样写 lastAt：否则客户端可以用注定失败的请求无限刷频（每次都真实
	// 遍历一遍全部根，正是限流要挡的那件事）。
	defer func() {
		s.rescanLastAt.Store(time.Now().UnixNano())
		s.rescanRunning.Store(false)
	}()

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
