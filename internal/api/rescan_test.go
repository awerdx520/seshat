// 本文件覆盖 M7 B6 的维护端点 POST /api/resources/rescan。
//
// 测试放在 internal 测试包（package api）而非其余用例使用的外部包 api_test：
// 并发用例需要直接抢占 Server.rescanRunning（atomic.Bool）来构造「已有重扫在跑」
// 这一确定性状态。外部包无法访问未导出字段，只能靠「两次真实请求恰好重叠」去撞
// 409——而小目录的重扫在微秒级完成，这只能是概率性断言。此处以手动置位换取
// 确定性断言；除此之外的用例仍走完整 HTTP 栈（srv.handler(auth.New(...))），
// 认证中间件与路由表都真实生效。
//
// 覆盖：正常重扫的计数、删除后墓碑与 delete 事件、墓碑按原 uid 复活、并发拒绝
// （409 rescan_in_progress）、独占权在结束后归还、registry 未注入（503）、
// 缺令牌（401），以及「GET 落到 {uid} 处理器」的实际行为（400 invalid_uid）。
package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"seshat/internal/auth"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// rescanTestToken 是本文件用例使用的访问令牌（与 auth.New 构造的认证器一致）。
const rescanTestToken = "rescan-test-token"

// rescanFixture 是装配好 registry 的处理器与其根目录（根 tag 固定为 notes）。
type rescanFixture struct {
	server *Server
	root   string
}

// newRescanFixture 打开临时库、构造 registry.Service（单根 notes，物理路径为临时目录）
// 并返回未套认证的 Server；调用方可经 handler() 取得完整 HTTP 栈。
func newRescanFixture(t *testing.T) *rescanFixture {
	t.Helper()

	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	root := t.TempDir()
	svc := registry.New(db, nil)
	if err := svc.SetRoots([]registry.Root{{Tag: "notes", Path: root}}); err != nil {
		t.Fatalf("设置根清单失败: %v", err)
	}
	return &rescanFixture{server: newServer(db, nil, nil, svc, nil), root: root}
}

// handlerWithAuth 返回套了主令牌认证的完整处理器（与生产装配一致）。
func (f *rescanFixture) handlerWithAuth() http.Handler {
	return f.server.handler(auth.New(rescanTestToken))
}

// writeRootFile 在根目录下写一个文件（自动创建父目录）。
func writeRootFile(t *testing.T, root, rel, content string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("创建目录失败: %v", err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("写入文件 %s 失败: %v", rel, err)
	}
}

// removeRootFile 删除根目录下的文件。
func removeRootFile(t *testing.T, root, rel string) {
	t.Helper()
	if err := os.Remove(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
		t.Fatalf("删除文件 %s 失败: %v", rel, err)
	}
}

// rescanRequest 发送一次请求；token 非空时附加 Bearer 头（空令牌用于断言 401）。
func rescanRequest(t *testing.T, h http.Handler, method, target, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// rescanBody 把响应体解码为 map，失败即终止用例。
func rescanBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("响应体不是合法 JSON: %v (body=%q)", err, rec.Body.String())
	}
	return got
}

// rescanStats 校验 200 响应并返回六个计数字段（要求字段齐全，缺一即失败）。
func rescanStats(t *testing.T, rec *httptest.ResponseRecorder) map[string]int {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := rescanBody(t, rec)

	fields := []string{"scanned", "created", "updated", "unchanged", "deleted", "failed"}
	stats := make(map[string]int, len(fields))
	for _, name := range fields {
		raw, ok := body[name]
		if !ok {
			t.Fatalf("响应缺少字段 %q (body=%q)", name, rec.Body.String())
		}
		num, ok := raw.(float64)
		if !ok {
			t.Fatalf("字段 %q 不是数字: %v", name, raw)
		}
		stats[name] = int(num)
	}
	// 响应体只含计数：不应出现孤儿清单或文件路径等额外字段。
	if len(body) != len(fields) {
		t.Fatalf("响应字段数 = %d, 期望 %d（只回计数）: %q", len(body), len(fields), rec.Body.String())
	}
	return stats
}

// rescanErrorCode 断言响应为指定状态码并返回错误码（用于 409 / 400 之类断言）。
func rescanErrorCode(t *testing.T, rec *httptest.ResponseRecorder, status int) string {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("状态码 = %d, 期望 %d (body=%q)", rec.Code, status, rec.Body.String())
	}
	errObj, ok := rescanBody(t, rec)["error"].(map[string]any)
	if !ok {
		t.Fatalf("响应体缺少 error 对象: %q", rec.Body.String())
	}
	code, _ := errObj["code"].(string)
	if code == "" {
		t.Fatalf("错误码为空: %q", rec.Body.String())
	}
	return code
}

// resourceItemsByPath 拉取资源清单（可按是否含墓碑过滤），返回 path → 条目。
func resourceItemsByPath(t *testing.T, h http.Handler, includeDeleted bool) map[string]map[string]any {
	t.Helper()
	target := "/api/resources"
	if includeDeleted {
		target += "?include_deleted=true"
	}
	rec := rescanRequest(t, h, http.MethodGet, target, rescanTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("清单状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := rescanBody(t, rec)
	raw, ok := body["items"].([]any)
	if !ok {
		t.Fatalf("响应缺少 items 数组: %q", rec.Body.String())
	}
	out := make(map[string]map[string]any, len(raw))
	for _, it := range raw {
		obj, ok := it.(map[string]any)
		if !ok {
			t.Fatalf("items 元素不是对象: %v", it)
		}
		path, _ := obj["path"].(string)
		out[path] = obj
	}
	return out
}

// findChange 在 /api/changes 结果中查找满足条件的事件。
func findChange(t *testing.T, h http.Handler, want map[string]string) map[string]any {
	t.Helper()
	rec := rescanRequest(t, h, http.MethodGet, "/api/changes?since=0&limit=200", rescanTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("变更拉取状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := rescanBody(t, rec)
	raw, ok := body["changes"].([]any)
	if !ok {
		t.Fatalf("响应缺少 changes 数组: %q", rec.Body.String())
	}
	for _, it := range raw {
		obj, ok := it.(map[string]any)
		if !ok {
			continue
		}
		matched := true
		for k, v := range want {
			if got, _ := obj[k].(string); got != v {
				matched = false
				break
			}
		}
		if matched {
			return obj
		}
	}
	t.Fatalf("未找到满足 %v 的变更事件 (body=%q)", want, rec.Body.String())
	return nil
}

// TestRescanCreatesThenReportsUnchanged 验证首次重扫登记文件、再次重扫全部 unchanged。
//
// 两个文件（含子目录）第二次扫描不应产生任何事件：计数全零 + unchanged=2，
// 这是「重扫幂等、不推进客户端游标」的不变量。
func TestRescanCreatesThenReportsUnchanged(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()

	writeRootFile(t, f.root, "a.org", "alpha")
	writeRootFile(t, f.root, "sub/b.org", "beta")

	rec := rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken)
	first := rescanStats(t, rec)
	// 记录实际线上响应体，便于人工核对对外契约（-v 时可见）。
	t.Logf("POST /api/resources/rescan → 200 %s", strings.TrimSpace(rec.Body.String()))
	want := map[string]int{"scanned": 2, "created": 2, "updated": 0, "unchanged": 0, "deleted": 0, "failed": 0}
	for k, v := range want {
		if first[k] != v {
			t.Fatalf("首次重扫 %s = %d, 期望 %d (全部计数=%v)", k, first[k], v, first)
		}
	}

	second := rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken))
	want = map[string]int{"scanned": 2, "created": 0, "updated": 0, "unchanged": 2, "deleted": 0, "failed": 0}
	for k, v := range want {
		if second[k] != v {
			t.Fatalf("二次重扫 %s = %d, 期望 %d (全部计数=%v)", k, second[k], v, second)
		}
	}
}

// TestRescanTombstonesVanishedFile 验证磁盘文件消失后重扫写墓碑并产生 delete 事件。
func TestRescanTombstonesVanishedFile(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()

	writeRootFile(t, f.root, "a.org", "alpha")
	writeRootFile(t, f.root, "b.org", "beta")
	rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken))

	live := resourceItemsByPath(t, h, false)
	uidA, _ := live["a.org"]["uid"].(string)
	if uidA == "" {
		t.Fatalf("a.org 未登记: %v", live)
	}

	removeRootFile(t, f.root, "a.org")
	stats := rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken))
	if stats["deleted"] != 1 || stats["unchanged"] != 1 {
		t.Fatalf("重扫计数 = %v, 期望 deleted=1 unchanged=1", stats)
	}

	if _, ok := resourceItemsByPath(t, h, false)["a.org"]; ok {
		t.Fatal("墓碑资源不应出现在默认清单中")
	}
	tomb := resourceItemsByPath(t, h, true)["a.org"]
	if tomb == nil {
		t.Fatal("include_deleted=true 时应能查到墓碑")
	}
	if deletedAt, _ := tomb["deleted_at"].(string); deletedAt == "" {
		t.Fatalf("墓碑的 deleted_at 应为非空: %v", tomb)
	}

	// delete 事件必须存在，且 uid 与删除前一致（墓碑不改身份）。
	findChange(t, h, map[string]string{"op": "delete", "uid": uidA, "path": "a.org"})
}

// TestRescanRevivesTombstoneWithSameUID 验证文件重新出现时按原 uid 复活（update，不新建）。
//
// 这是 Rescan「不会让同一路径产生第二个 uid」的不变量：墓碑仍占用 (root, path)，
// 复活走 update 而非 create。
func TestRescanRevivesTombstoneWithSameUID(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()

	writeRootFile(t, f.root, "a.org", "alpha")
	rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken))
	uidA, _ := resourceItemsByPath(t, h, false)["a.org"]["uid"].(string)
	if uidA == "" {
		t.Fatal("a.org 未登记")
	}

	removeRootFile(t, f.root, "a.org")
	if stats := rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken)); stats["deleted"] != 1 {
		t.Fatalf("删除后重扫计数 = %v, 期望 deleted=1", stats)
	}

	writeRootFile(t, f.root, "a.org", "alpha revived")
	stats := rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken))
	want := map[string]int{"scanned": 1, "created": 0, "updated": 1, "unchanged": 0, "deleted": 0, "failed": 0}
	for k, v := range want {
		if stats[k] != v {
			t.Fatalf("复活重扫 %s = %d, 期望 %d (全部计数=%v)", k, stats[k], v, stats)
		}
	}

	revived := resourceItemsByPath(t, h, false)["a.org"]
	if revived == nil {
		t.Fatal("复活后应重新出现在清单中")
	}
	if got, _ := revived["uid"].(string); got != uidA {
		t.Fatalf("复活后 uid = %q, 期望沿用原 uid %q", got, uidA)
	}
	if deletedAt, _ := revived["deleted_at"].(string); deletedAt != "" {
		t.Fatalf("复活后 deleted_at 应为空: %v", revived)
	}
}

// TestRescanRejectsWhenAlreadyRunning 验证已有重扫在跑时返回 409 rescan_in_progress。
//
// 直接置位 Server.rescanRunning 构造「另一次重扫仍在进行」的确定性状态：
// 处理器必须立刻 409（不排队等待），且不得进入 registry（否则本用例会看到 200）。
// 复位后同一请求应恢复正常，证明拦截的唯一来源就是该独占权。
func TestRescanRejectsWhenAlreadyRunning(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()
	writeRootFile(t, f.root, "a.org", "alpha")

	f.server.rescanRunning.Store(true)
	code := rescanErrorCode(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken), http.StatusConflict)
	if code != "rescan_in_progress" {
		t.Fatalf("错误码 = %q, 期望 rescan_in_progress", code)
	}

	f.server.rescanRunning.Store(false)
	// 复位后应正常重扫：说明 409 来自独占权而非其它原因。
	if stats := rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken)); stats["created"] != 1 {
		t.Fatalf("复位后重扫计数 = %v, 期望 created=1", stats)
	}
}

// TestRescanSerializesConcurrentRequests 验证并发请求下只有一个重扫在跑，且独占权会归还。
//
// 判定用「每个响应都是 200 或 409，且无 500/其它状态」+「全部结束后再次请求必成功」：
// 前者证明并发不会打穿独占权（也不会因 registry 并发写而报 500），后者证明 defer
// 归还了独占权（否则重扫能力会永久失效）。
func TestRescanSerializesConcurrentRequests(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()
	writeRootFile(t, f.root, "a.org", "alpha")
	writeRootFile(t, f.root, "b.org", "beta")

	const workers = 8
	codes := make([]int, workers)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			<-start
			codes[idx] = rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken).Code
		}(i)
	}
	close(start)
	wg.Wait()

	ok, busy := 0, 0
	for i, c := range codes {
		switch c {
		case http.StatusOK:
			ok++
		case http.StatusConflict:
			busy++
		default:
			t.Fatalf("第 %d 个并发请求状态码 = %d, 期望 200 或 409（全部=%v）", i, c, codes)
		}
	}
	if ok == 0 {
		t.Fatalf("并发请求全部返回 409，说明独占权未被任何请求获得（全部=%v）", codes)
	}

	// 结束时独占权必须已归还：再发一次请求必成功。
	final := rescanStats(t, rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", rescanTestToken))
	if final["scanned"] != 2 {
		t.Fatalf("收尾重扫计数 = %v, 期望 scanned=2", final)
	}
}

// TestRescanWithoutRegistryReturns503 验证未注入 registry 时返回 503 unavailable。
//
// 能力未就绪与请求错误要分开：客户端据此判断「服务端没开登记能力」而不是改参数。
func TestRescanWithoutRegistryReturns503(t *testing.T) {
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	srv := newServer(db, nil, nil, nil, nil)
	rec := rescanRequest(t, srv.handler(auth.New(rescanTestToken)),
		http.MethodPost, "/api/resources/rescan", rescanTestToken)
	if code := rescanErrorCode(t, rec, http.StatusServiceUnavailable); code != "unavailable" {
		t.Fatalf("错误码 = %q, 期望 unavailable", code)
	}
}

// TestRescanRequiresToken 验证缺少 Bearer 令牌时返回 401（维护端点同样受认证保护）。
func TestRescanRequiresToken(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()
	writeRootFile(t, f.root, "a.org", "alpha")

	rec := rescanRequest(t, h, http.MethodPost, "/api/resources/rescan", "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("无令牌状态码 = %d, 期望 401 (body=%q)", rec.Code, rec.Body.String())
	}
	// 未认证请求不得触发扫描：登记表应保持为空（用带令牌的清单核对）。
	if items := resourceItemsByPath(t, h, true); len(items) != 0 {
		t.Fatalf("未认证请求触发了扫描，登记表非空: %v", items)
	}
}

// TestRescanGetMethodFallsThroughToUIDHandler 记录 GET /api/resources/rescan 的实际行为。
//
// 字面量段 rescan 只注册在 POST 上，而 GET 侧有更宽的模式 "GET /api/resources/{uid}"，
// 故该请求落到单资源处理器，因 "rescan" 不是合法 uid 返回 400 invalid_uid
// （不是 405）。这是可接受的既有路由行为，此处用测试固定，避免将来无声变化。
func TestRescanGetMethodFallsThroughToUIDHandler(t *testing.T) {
	f := newRescanFixture(t)
	h := f.handlerWithAuth()

	code := rescanErrorCode(t, rescanRequest(t, h, http.MethodGet, "/api/resources/rescan", rescanTestToken), http.StatusBadRequest)
	if code != "invalid_uid" {
		t.Fatalf("错误码 = %q, 期望 invalid_uid", code)
	}
}
