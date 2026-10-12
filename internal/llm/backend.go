// 本文件明确 seshat 的 LLM 双后端契约，消除「LocalNodeClient 同步直连」与
// 「llm_tasks 异步任务队列」两套机制并存的认知混乱（见 openspec/tech-debt.md #2）。
//
// 两套机制定位不同、互补而非替代，按场景二选一：
//
//   - 同步直连（LocalNodeClient，本包）：适用于本地节点与服务端同机、或需要即时
//     返回结果的短任务。能力函数（AnalyzeDocument / Summarize / ReviewNotes /
//     AnalyzeReading / GenerateCards）接收 Client，传入 Router 即可；route=local
//     时经 {nodeURL}/v1/chat/completions 直连。前提是显式配置了本地节点 URL
//     （见 Router.LocalDirectAvailable）。
//   - 异步任务队列（llm_tasks + cmd/llmnode，internal/storage / internal/api）：
//     适用于本地节点在另一台机器（家庭网络）、任务长耗时（大文档解析等），服务端
//     不宜同步等待的场景。流程为：入队 POST /api/llm/tasks → 节点轮询
//     GET /api/llm/tasks/poll → 本地推理 → 回传 POST /api/llm/tasks/{id}/result
//     → 客户端异步取结果。本包只定义提交接口 TaskSubmitter，实现由 api 层注入，
//     使 internal/llm 不反向依赖 internal/storage / internal/api。
//
// 选择依据：节点与服务端同机且需即时结果 → 同步直连；节点跨机或任务长耗时 →
// 异步入队。二者不互相打通：直连不写队列，队列不回调直连。

package llm

import "context"

// TaskSubmitter 是「长耗时 LLM 任务异步入队」的契约。
//
// 能力层在「本地节点跨机 / 任务长耗时」时可选择把一次调用提交到 llm_tasks 队列，
// 由本地处理节点轮询领取并异步回传结果，而非同步等待直连响应。
//
// 该接口由 internal/llm 定义、由 api 层（internal/api）注入实现——典型实现包裹
// internal/storage 的 CreateLLMTask，并完成 Route → route 字符串与 []byte → payload
// 字符串的适配。这样 internal/llm 不必反向依赖 storage 或 api。
//
// 参数约定：
//   - kind：任务类型标签，对应 llm_tasks.kind；
//   - payload：任务请求体的原始 JSON（与节点约定的 messages/model 结构）；
//   - route：路由目标，长任务通常为 RouteLocal；
//   - 返回值为新建任务的 id，供后续查询结果。
type TaskSubmitter interface {
	// SubmitLLMTask 将一次 LLM 调用作为任务入队，返回任务 id。
	SubmitLLMTask(ctx context.Context, kind string, payload []byte, route Route) (int64, error)
}

// LocalDirectAvailable 报告 Router 是否配置了「同步直连」的本地后端，即是否持有
// 一个显式配置了 URL 的 LocalNodeClient（见 NewLocal 与文件头的双后端契约）。
//
// 返回 false 的两种情形：
//   - Router 未持有本地后端（NewRouter 的 local 传了 nil）；
//   - 本地后端是 LocalNodeClient 但其 URL 未显式配置（NewLocal("") 回退默认地址），
//     此时应按「本地节点可能不在本机」处理，改用 TaskSubmitter 异步入队。
//
// 非 *LocalNodeClient 的本地后端（如测试替身）视为已配置，返回 true。
// 该方法只描述「直连是否已配置」，不代表 LocalNodeClient 不可调用——URL 未显式
// 配置时它仍会打到默认地址 http://localhost:11434。
func (r *Router) LocalDirectAvailable() bool {
	if r == nil || r.local == nil {
		return false
	}
	if direct, ok := r.local.(*LocalNodeClient); ok {
		return direct.urlConfigured
	}
	return true
}
