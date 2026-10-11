// 本文件实现 LLM 任务队列的持久化（M6.2 本地处理节点 worker 的数据层）。
//
// 设计取舍：混合 LLM 后端（ADR-0002）下，任务统一入队到 llm_tasks 表——需要本地
// 推理的任务以 route='local' 入队，由家庭机器 / NAS 上的处理节点轮询领取；route='cloud'
// 的任务由服务端直接调用云端 API，不参与节点轮询。本轮不建通用任务框架，只暴露
// 「创建 / 领取 / 完成 / 失败」四个操作，状态机为 pending → running → done|failed。
//
// payload 与 result 均为明文文本（payload 是任务请求体的原始 JSON，result 是结果正文
// 或失败原因）；本层不做解析与加密，转发语义由调用方与节点共同约定。
package storage

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"notes/internal/logging"
)

// LLM 任务的路由目标常量。
const (
	// LLMRouteCloud 表示任务由服务端直接调用云端 API 完成（默认路由）。
	LLMRouteCloud = "cloud"
	// LLMRouteLocal 表示任务交由本地处理节点（家庭机器 / NAS 上的 Ollama 等）完成。
	LLMRouteLocal = "local"
)

// LLM 任务的状态常量，对应队列状态机的四个阶段。
const (
	// LLMTaskPending 表示任务已入队、等待处理。
	LLMTaskPending = "pending"
	// LLMTaskRunning 表示任务已被节点领取、正在处理。
	LLMTaskRunning = "running"
	// LLMTaskDone 表示任务已成功完成，result 为结果正文。
	LLMTaskDone = "done"
	// LLMTaskFailed 表示任务处理失败，result 为错误信息。
	LLMTaskFailed = "failed"
)

// LLMTask 是队列中的一条 LLM 任务记录。
type LLMTask struct {
	ID        int64
	Kind      string
	Payload   string
	Route     string
	Status    string
	Result    string
	CreatedAt string
	UpdatedAt string
}

// CreateLLMTask 新建一条 LLM 任务，状态为 pending，时间戳由服务端以当前 UTC 时间填充，
// 返回自增 id。route 为空时默认 cloud；kind/payload 为空、或 route 非 cloud/local 时
// 返回 ErrInvalidArgument 包装的错误。
func (d *DB) CreateLLMTask(kind, payload, route string) (int64, error) {
	if strings.TrimSpace(kind) == "" {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "kind 不能为空")
	}
	if strings.TrimSpace(payload) == "" {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "payload 不能为空")
	}
	if route == "" {
		route = LLMRouteCloud
	}
	if route != LLMRouteCloud && route != LLMRouteLocal {
		return 0, logging.NewAppError(logging.ErrInvalidArgument, "route 必须是 cloud 或 local")
	}

	now := time.Now().UTC().Format(timestampLayout)
	res, err := d.db.Exec(
		`INSERT INTO llm_tasks(kind, payload, route, status, result, created_at, updated_at)
		 VALUES(?, ?, ?, ?, NULL, ?, ?)`,
		kind, payload, route, LLMTaskPending, now, now)
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "创建 LLM 任务失败")
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, logging.Wrap(err, logging.ErrInternal, "读取新 LLM 任务 id 失败")
	}
	return id, nil
}

// PollLLMTask 领取一条待处理的本地任务：按 id 升序取最早的一条 route='local' 且
// status='pending' 的记录，在同一事务内将其置为 running 并返回（含更新后的状态与时间戳）。
//
// 无待办任务时返回 (nil, nil)——「暂无任务」是轮询的正常结果，不是错误，调用方据此
// 休眠后再试；事务内条件更新（WHERE status='pending'）保证同一条任务不会被重复领取。
func (d *DB) PollLLMTask() (*LLMTask, error) {
	tx, err := d.db.Begin()
	if err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "开始领取 LLM 任务事务失败")
	}
	defer func() { _ = tx.Rollback() }()

	var (
		t      LLMTask
		result sql.NullString
	)
	err = tx.QueryRow(
		`SELECT id, kind, payload, route, status, result, created_at, updated_at
		 FROM llm_tasks WHERE route = ? AND status = ? ORDER BY id LIMIT 1`,
		LLMRouteLocal, LLMTaskPending).
		Scan(&t.ID, &t.Kind, &t.Payload, &t.Route, &t.Status, &result, &t.CreatedAt, &t.UpdatedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, logging.Wrap(err, logging.ErrInternal, "查询待办 LLM 任务失败")
	}
	t.Result = result.String

	now := time.Now().UTC().Format(timestampLayout)
	if _, err := tx.Exec(
		`UPDATE llm_tasks SET status = ?, updated_at = ? WHERE id = ? AND status = ?`,
		LLMTaskRunning, now, t.ID, LLMTaskPending); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "标记 LLM 任务为运行中失败")
	}
	if err := tx.Commit(); err != nil {
		return nil, logging.Wrap(err, logging.ErrInternal, "提交领取 LLM 任务事务失败")
	}

	t.Status = LLMTaskRunning
	t.UpdatedAt = now
	return &t, nil
}

// CompleteLLMTask 将任务标记为成功并把 result 记为结果正文；任务不存在时返回 ErrNotFound，
// id 非正整数时返回 ErrInvalidArgument。
func (d *DB) CompleteLLMTask(id int64, result string) error {
	if id <= 0 {
		return logging.NewAppError(logging.ErrInvalidArgument, "任务 id 必须是正整数")
	}

	now := time.Now().UTC().Format(timestampLayout)
	res, err := d.db.Exec(
		`UPDATE llm_tasks SET status = ?, result = ?, updated_at = ? WHERE id = ?`,
		LLMTaskDone, result, now, id)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "回传 LLM 任务结果失败")
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取更新影响行数失败")
	}
	if affected == 0 {
		return logging.Wrap(sql.ErrNoRows, logging.ErrNotFound, "LLM 任务不存在")
	}
	return nil
}

// FailLLMTask 将任务标记为失败，并把 errMsg 记入 result 列作为失败原因；
// errMsg 为空时返回 ErrInvalidArgument，任务不存在时返回 ErrNotFound。
func (d *DB) FailLLMTask(id int64, errMsg string) error {
	if id <= 0 {
		return logging.NewAppError(logging.ErrInvalidArgument, "任务 id 必须是正整数")
	}
	if strings.TrimSpace(errMsg) == "" {
		return logging.NewAppError(logging.ErrInvalidArgument, "失败原因不能为空")
	}

	now := time.Now().UTC().Format(timestampLayout)
	res, err := d.db.Exec(
		`UPDATE llm_tasks SET status = ?, result = ?, updated_at = ? WHERE id = ?`,
		LLMTaskFailed, errMsg, now, id)
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "标记 LLM 任务失败失败")
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return logging.Wrap(err, logging.ErrInternal, "读取更新影响行数失败")
	}
	if affected == 0 {
		return logging.Wrap(sql.ErrNoRows, logging.ErrNotFound, "LLM 任务不存在")
	}
	return nil
}
