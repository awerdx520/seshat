package storage

import (
	"database/sql"
	"testing"
	"time"

	"seshat/internal/logging"
)

// TestLLMTaskCreateAndPoll 验证本地任务创建后可被轮询领取，且领取时状态置为 running、
// 同一条任务不会被重复领取。
func TestLLMTaskCreateAndPoll(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("summarize", `{"messages":[{"role":"user","content":"hi"}]}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	if id <= 0 {
		t.Fatalf("CreateLLMTask() 返回 id = %d, 期望正整数", id)
	}

	task, err := db.PollLLMTask()
	if err != nil {
		t.Fatalf("PollLLMTask() 返回错误: %v", err)
	}
	if task == nil {
		t.Fatal("PollLLMTask() 返回 nil，期望领取到任务")
	}
	if task.ID != id {
		t.Fatalf("任务 id = %d, 期望 %d", task.ID, id)
	}
	if task.Kind != "summarize" || task.Route != LLMRouteLocal {
		t.Fatalf("任务字段不符: kind=%q route=%q", task.Kind, task.Route)
	}
	if task.Payload != `{"messages":[{"role":"user","content":"hi"}]}` {
		t.Fatalf("payload 未原样保留: %q", task.Payload)
	}
	if task.Status != LLMTaskRunning {
		t.Fatalf("领取后状态 = %q, 期望 %q", task.Status, LLMTaskRunning)
	}
	if task.Result != "" {
		t.Fatalf("新任务 result 应为空, 实际 %q", task.Result)
	}
	if task.CreatedAt == "" || task.UpdatedAt == "" {
		t.Fatalf("任务缺少时间戳: created=%q updated=%q", task.CreatedAt, task.UpdatedAt)
	}

	// 已领取的任务不再是 pending，第二次轮询应无任务。
	again, err := db.PollLLMTask()
	if err != nil {
		t.Fatalf("第二次 PollLLMTask() 返回错误: %v", err)
	}
	if again != nil {
		t.Fatalf("第二次轮询应无任务, 实际领取到 id=%d", again.ID)
	}
}

// TestLLMTaskPollReturnsNilWhenEmpty 验证队列为空时轮询返回 (nil, nil) 而非错误。
func TestLLMTaskPollReturnsNilWhenEmpty(t *testing.T) {
	db := openTestDB(t)

	task, err := db.PollLLMTask()
	if err != nil {
		t.Fatalf("空队列 PollLLMTask() 返回错误: %v", err)
	}
	if task != nil {
		t.Fatalf("空队列应返回 nil, 实际 %+v", task)
	}
}

// TestLLMTaskRouteDefaultsToCloudAndIsNotPolled 验证 route 缺省为 cloud，且云端任务
// 不参与本地节点轮询。
func TestLLMTaskRouteDefaultsToCloudAndIsNotPolled(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("translate", `{"messages":[]}`, "")
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}

	var route, status string
	if err := db.db.QueryRow(
		`SELECT route, status FROM llm_tasks WHERE id = ?`, id).Scan(&route, &status); err != nil {
		t.Fatalf("读取任务失败: %v", err)
	}
	if route != LLMRouteCloud {
		t.Fatalf("缺省 route = %q, 期望 %q", route, LLMRouteCloud)
	}
	if status != LLMTaskPending {
		t.Fatalf("新建任务状态 = %q, 期望 %q", status, LLMTaskPending)
	}

	if task, err := db.PollLLMTask(); err != nil {
		t.Fatalf("PollLLMTask() 返回错误: %v", err)
	} else if task != nil {
		t.Fatalf("云端任务不应被本地轮询领取, 实际 %+v", task)
	}
}

// TestLLMTaskPollPicksOldestFirst 验证多条本地任务按 id 升序（最早入队优先）领取。
func TestLLMTaskPollPicksOldestFirst(t *testing.T) {
	db := openTestDB(t)

	first, err := db.CreateLLMTask("k1", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	second, err := db.CreateLLMTask("k2", `{"a":2}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}

	got1, err := db.PollLLMTask()
	if err != nil || got1 == nil {
		t.Fatalf("首次轮询失败: task=%v err=%v", got1, err)
	}
	got2, err := db.PollLLMTask()
	if err != nil || got2 == nil {
		t.Fatalf("二次轮询失败: task=%v err=%v", got2, err)
	}
	if got1.ID != first || got2.ID != second {
		t.Fatalf("领取顺序 = [%d %d], 期望 [%d %d]", got1.ID, got2.ID, first, second)
	}
}

// TestLLMTaskCreateValidation 验证创建任务的必填与取值校验。
func TestLLMTaskCreateValidation(t *testing.T) {
	db := openTestDB(t)

	cases := []struct {
		name    string
		kind    string
		payload string
		route   string
	}{
		{"kind 为空", "", `{"a":1}`, LLMRouteLocal},
		{"payload 为空", "kind", "", LLMRouteLocal},
		{"route 非法", "kind", `{"a":1}`, "edge"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := db.CreateLLMTask(tc.kind, tc.payload, tc.route); err == nil {
				t.Fatal("应返回错误，实际为 nil")
			} else {
				assertCode(t, err, logging.ErrInvalidArgument)
			}
		})
	}
}

// TestLLMTaskComplete 验证回传结果后任务状态为 done、result 为结果正文。
func TestLLMTaskComplete(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("summarize", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	if _, err := db.PollLLMTask(); err != nil {
		t.Fatalf("PollLLMTask() 返回错误: %v", err)
	}

	const result = "这是本地推理的结果"
	if err := db.CompleteLLMTask(id, result); err != nil {
		t.Fatalf("CompleteLLMTask() 返回错误: %v", err)
	}

	var status string
	var got sql.NullString
	if err := db.db.QueryRow(
		`SELECT status, result FROM llm_tasks WHERE id = ?`, id).Scan(&status, &got); err != nil {
		t.Fatalf("读取任务失败: %v", err)
	}
	if status != LLMTaskDone {
		t.Fatalf("状态 = %q, 期望 %q", status, LLMTaskDone)
	}
	if !got.Valid || got.String != result {
		t.Fatalf("result = %+v, 期望 %q", got, result)
	}
}

// TestLLMTaskFail 验证失败回传后任务状态为 failed、result 为失败原因。
func TestLLMTaskFail(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("summarize", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	if _, err := db.PollLLMTask(); err != nil {
		t.Fatalf("PollLLMTask() 返回错误: %v", err)
	}

	if err := db.FailLLMTask(id, "Ollama 连接超时"); err != nil {
		t.Fatalf("FailLLMTask() 返回错误: %v", err)
	}

	var status, result string
	if err := db.db.QueryRow(
		`SELECT status, result FROM llm_tasks WHERE id = ?`, id).Scan(&status, &result); err != nil {
		t.Fatalf("读取任务失败: %v", err)
	}
	if status != LLMTaskFailed {
		t.Fatalf("状态 = %q, 期望 %q", status, LLMTaskFailed)
	}
	if result != "Ollama 连接超时" {
		t.Fatalf("result = %q, 期望失败原因", result)
	}
}

// TestLLMTaskTerminalErrors 验证完成/失败回传的缺失与参数错误码。
func TestLLMTaskTerminalErrors(t *testing.T) {
	db := openTestDB(t)

	assertCode(t, db.CompleteLLMTask(999, "r"), logging.ErrNotFound)
	assertCode(t, db.FailLLMTask(999, "boom"), logging.ErrNotFound)
	assertCode(t, db.CompleteLLMTask(0, "r"), logging.ErrInvalidArgument)
	assertCode(t, db.FailLLMTask(-1, "boom"), logging.ErrInvalidArgument)
	assertCode(t, db.FailLLMTask(1, "   "), logging.ErrInvalidArgument)
}

// TestLLMTaskPersistsAcrossReopen 验证任务数据在关闭/重开（迁移幂等）后仍存在。
func TestLLMTaskPersistsAcrossReopen(t *testing.T) {
	path := t.TempDir() + "/seshat.db"

	db1, err := Open(path, "")
	if err != nil {
		t.Fatalf("首次 Open() 失败: %v", err)
	}
	id, err := db1.CreateLLMTask("summarize", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	if err := db1.Close(); err != nil {
		t.Fatalf("关闭连接失败: %v", err)
	}

	db2, err := Open(path, "")
	if err != nil {
		t.Fatalf("二次 Open() 失败: %v", err)
	}
	defer func() { _ = db2.Close() }()

	task, err := db2.PollLLMTask()
	if err != nil {
		t.Fatalf("重开后 PollLLMTask() 返回错误: %v", err)
	}
	if task == nil || task.ID != id {
		t.Fatalf("重开后应领取到任务 id=%d, 实际 %+v", id, task)
	}
}

// TestLLMTaskPollReclaimsExpiredRunning 验证节点崩溃 / 失联后遗留的孤儿 running 任务在
// 租约过期后被 PollLLMTask 回收为 pending 并重新领取；租约未过期的 running 任务不会被抢走。
func TestLLMTaskPollReclaimsExpiredRunning(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("summarize", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}

	// 首次领取：任务置为 running。
	first, err := db.PollLLMTask()
	if err != nil || first == nil || first.ID != id {
		t.Fatalf("首次领取失败: task=%+v err=%v", first, err)
	}

	// 租约未过期：running 任务不应被回收，第二次轮询无任务可领。
	if again, err := db.PollLLMTask(); err != nil {
		t.Fatalf("租约未过期时轮询返回错误: %v", err)
	} else if again != nil {
		t.Fatalf("租约未过期的 running 任务不应被回收, 实际领到 id=%d", again.ID)
	}

	// 模拟节点崩溃：把 updated_at 回拨到租约截止时间之前。
	expired := time.Now().UTC().Add(-llmTaskLeaseTTL - time.Minute).Format(timestampLayout)
	if _, err := db.db.Exec(
		`UPDATE llm_tasks SET updated_at = ? WHERE id = ?`, expired, id); err != nil {
		t.Fatalf("回拨 updated_at 失败: %v", err)
	}

	// 租约过期后再轮询：孤儿任务被回收为 pending 并重新领取。
	reclaimed, err := db.PollLLMTask()
	if err != nil {
		t.Fatalf("回收轮询返回错误: %v", err)
	}
	if reclaimed == nil || reclaimed.ID != id {
		t.Fatalf("过期孤儿任务应被重新领取, 实际 %+v", reclaimed)
	}
	if reclaimed.Status != LLMTaskRunning {
		t.Fatalf("重新领取后状态 = %q, 期望 %q", reclaimed.Status, LLMTaskRunning)
	}
}

// TestLLMTaskCompleteRejectsNonRunning 验证 Complete/Fail 只允许从 running 转移：
// 对仍是 pending（未领取）的任务回传结果返回 ErrConflict，且状态与结果不被覆盖。
func TestLLMTaskCompleteRejectsNonRunning(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("summarize", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}

	assertCode(t, db.CompleteLLMTask(id, "r"), logging.ErrConflict)
	assertCode(t, db.FailLLMTask(id, "boom"), logging.ErrConflict)

	var status string
	var result sql.NullString
	if err := db.db.QueryRow(
		`SELECT status, result FROM llm_tasks WHERE id = ?`, id).Scan(&status, &result); err != nil {
		t.Fatalf("读取任务失败: %v", err)
	}
	if status != LLMTaskPending || result.Valid {
		t.Fatalf("冲突回传不应改变状态/结果: status=%q result=%+v", status, result)
	}
}

// TestLLMTaskCompleteDuplicateIsConflict 验证重复回传第二次返回 ErrConflict，
// 且首次结果不被覆盖；已完成任务再回传失败也返回 ErrConflict。
func TestLLMTaskCompleteDuplicateIsConflict(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateLLMTask("summarize", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	if _, err := db.PollLLMTask(); err != nil {
		t.Fatalf("PollLLMTask() 返回错误: %v", err)
	}

	if err := db.CompleteLLMTask(id, "第一次结果"); err != nil {
		t.Fatalf("首次 CompleteLLMTask() 返回错误: %v", err)
	}
	// 第二次回传：状态已是 done → conflict，结果不被覆盖。
	assertCode(t, db.CompleteLLMTask(id, "第二次结果"), logging.ErrConflict)
	// done 之后再回传失败 → conflict。
	assertCode(t, db.FailLLMTask(id, "失败"), logging.ErrConflict)

	var status, result string
	if err := db.db.QueryRow(
		`SELECT status, result FROM llm_tasks WHERE id = ?`, id).Scan(&status, &result); err != nil {
		t.Fatalf("读取任务失败: %v", err)
	}
	if status != LLMTaskDone || result != "第一次结果" {
		t.Fatalf("重复回传后被覆盖: status=%q result=%q", status, result)
	}
}

// TestLLMTaskRunningTransitionsStillSucceed 回归护栏：running → done 与 running → failed
// 两条合法转移在新的状态校验下仍成功。
func TestLLMTaskRunningTransitionsStillSucceed(t *testing.T) {
	db := openTestDB(t)

	doneID, err := db.CreateLLMTask("k1", `{"a":1}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}
	failedID, err := db.CreateLLMTask("k2", `{"a":2}`, LLMRouteLocal)
	if err != nil {
		t.Fatalf("CreateLLMTask() 返回错误: %v", err)
	}

	if _, err := db.PollLLMTask(); err != nil { // 领取 doneID
		t.Fatalf("首次 PollLLMTask() 返回错误: %v", err)
	}
	if _, err := db.PollLLMTask(); err != nil { // 领取 failedID
		t.Fatalf("二次 PollLLMTask() 返回错误: %v", err)
	}

	if err := db.CompleteLLMTask(doneID, "结果正文"); err != nil {
		t.Fatalf("running→done 应成功, 实际: %v", err)
	}
	if err := db.FailLLMTask(failedID, "连接超时"); err != nil {
		t.Fatalf("running→failed 应成功, 实际: %v", err)
	}

	var status string
	if err := db.db.QueryRow(`SELECT status FROM llm_tasks WHERE id = ?`, doneID).Scan(&status); err != nil {
		t.Fatalf("读取 done 任务失败: %v", err)
	}
	if status != LLMTaskDone {
		t.Fatalf("done 任务状态 = %q, 期望 %q", status, LLMTaskDone)
	}
	if err := db.db.QueryRow(`SELECT status FROM llm_tasks WHERE id = ?`, failedID).Scan(&status); err != nil {
		t.Fatalf("读取 failed 任务失败: %v", err)
	}
	if status != LLMTaskFailed {
		t.Fatalf("failed 任务状态 = %q, 期望 %q", status, LLMTaskFailed)
	}
}
