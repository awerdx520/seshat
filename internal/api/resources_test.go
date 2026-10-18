// 本文件覆盖 M7 A5 的四个只读端点（资源清单、单资源元数据、路径解析、增量变更）
// 与 B2 的根映射端点（GET /api/roots）。
//
// 测试沿本包既有约定：临时目录独立 SQLite、经 NewHandlerFullWithRegistry 组装
// ServeMux + Bearer 认证，从外部包视角断言 HTTP 行为。登记表用 registry.Service.Apply
// 预置（与真实写路径一致），不直接写 SQL。
package api_test

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// 测试用 uid：26 位 Crockford Base32，后缀取合法字符 E/F/G/H 以便区分。
const (
	uidNotesA = "01K8Q3M7D2X9V6T1B8N5C0RDEE"
	uidNotesB = "01K8Q3M7D2X9V6T1B8N5C0RDEF"
	uidBookC  = "01K8Q3M7D2X9V6T1B8N5C0RDEG"
	uidTombD  = "01K8Q3M7D2X9V6T1B8N5C0RDEH"
)

// newRegistryServer 打开临时库、构造 registry.Service（双根 notes/ebooks）并按 seed
// 事件预置登记表，最后组装带 registry 的 REST 处理器。
func newRegistryServer(t *testing.T, seed []registry.Event) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	svc := registry.New(db, nil)
	if err := svc.SetRoots([]registry.Root{
		{Tag: "notes", Path: t.TempDir()},
		{Tag: "ebooks", Path: t.TempDir()},
	}); err != nil {
		t.Fatalf("设置根清单失败: %v", err)
	}
	for _, e := range seed {
		if _, err := svc.Apply(e); err != nil {
			t.Fatalf("预置事件 op=%s root=%s path=%s 失败: %v", e.Op, e.Root, e.Path, err)
		}
	}
	return api.NewHandlerFullWithRegistry(db, nil, nil, svc, auth.New(testToken), nil)
}

// newNoRegistryServer 构造未注入 registry 的处理器（走旧构造函数路径）。
func newNoRegistryServer(t *testing.T) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return api.NewHandlerFull(db, nil, nil, auth.New(testToken))
}

// createEvent 构造一条 create 事件。
func createEvent(uid, root, path string, mtime int64, at string) registry.Event {
	return registry.Event{
		UID: uid, Op: storage.OpCreate, Root: root, Path: path,
		Mtime: mtime, Size: mtime, At: at,
	}
}

// seedLive 返回三条存活资源的登记事件（notes/a.org、notes/sub/b.org、ebooks/c.epub）。
func seedLive() []registry.Event {
	return []registry.Event{
		createEvent(uidNotesA, "notes", "a.org", 100, "2026-10-18T10:00:00Z"),
		createEvent(uidNotesB, "notes", "sub/b.org", 200, "2026-10-18T10:01:00Z"),
		createEvent(uidBookC, "ebooks", "c.epub", 300, "2026-10-18T10:02:00Z"),
	}
}

// resourceItems 解码资源清单响应，返回 items 数组与 has_more。
func resourceItems(t *testing.T, rec *httptest.ResponseRecorder) ([]map[string]any, bool) {
	t.Helper()
	body := decodeJSON(t, rec)
	raw, ok := body["items"].([]any)
	if !ok {
		t.Fatalf("响应缺少 items 数组: %q", rec.Body.String())
	}
	items := make([]map[string]any, 0, len(raw))
	for _, it := range raw {
		obj, ok := it.(map[string]any)
		if !ok {
			t.Fatalf("items 元素不是对象: %v", it)
		}
		items = append(items, obj)
	}
	hasMore, ok := body["has_more"].(bool)
	if !ok {
		t.Fatalf("响应缺少 has_more 布尔值: %q", rec.Body.String())
	}
	return items, hasMore
}

// pathsOf 提取资源清单里的 root+path 组合（形如 "notes:a.org"）。
func pathsOf(items []map[string]any) map[string]bool {
	got := make(map[string]bool, len(items))
	for _, it := range items {
		got[it["root"].(string)+":"+it["path"].(string)] = true
	}
	return got
}

// TestListResourcesFilters 验证清单按 root / prefix / since / include_deleted 过滤。
func TestListResourcesFilters(t *testing.T) {
	seed := append(seedLive(),
		createEvent(uidTombD, "notes", "gone.org", 400, "2026-10-18T10:03:00Z"))
	seed = append(seed, registry.Event{
		UID: uidTombD, Op: storage.OpDelete, Root: "notes", Path: "gone.org",
		Mtime: 400, At: "2026-10-18T10:04:00Z",
	})
	h := newRegistryServer(t, seed)

	// 默认：全部存活资源，墓碑被排除。
	rec := do(t, h, http.MethodGet, "/api/resources", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	items, hasMore := resourceItems(t, rec)
	if len(items) != 3 {
		t.Fatalf("存活资源数 = %d, 期望 3 (items=%v)", len(items), items)
	}
	if hasMore {
		t.Fatal("默认 limit=500 时 has_more 应为 false")
	}
	// 单资源对象的字段完整性（JSON 契约）。
	first := items[0]
	for _, key := range []string{"uid", "root", "path", "kind", "blob", "rev", "size",
		"mtime", "created_at", "updated_at", "deleted_at"} {
		if _, ok := first[key]; !ok {
			t.Fatalf("资源对象缺少字段 %q: %v", key, first)
		}
	}

	// root 过滤。
	rec = do(t, h, http.MethodGet, "/api/resources?root=ebooks", testToken, nil, nil)
	items, _ = resourceItems(t, rec)
	if got := pathsOf(items); len(got) != 1 || !got["ebooks:c.epub"] {
		t.Fatalf("root=ebooks 结果 = %v, 期望仅 ebooks:c.epub", got)
	}

	// prefix 按路径段匹配：prefix=sub 命中 sub/b.org，不命中 a.org。
	rec = do(t, h, http.MethodGet, "/api/resources?prefix=sub", testToken, nil, nil)
	items, _ = resourceItems(t, rec)
	if got := pathsOf(items); len(got) != 1 || !got["notes:sub/b.org"] {
		t.Fatalf("prefix=sub 结果 = %v, 期望仅 notes:sub/b.org", got)
	}

	// since 按 mtime >= 过滤。
	rec = do(t, h, http.MethodGet, "/api/resources?since=200", testToken, nil, nil)
	items, _ = resourceItems(t, rec)
	if got := pathsOf(items); len(got) != 2 || !got["notes:sub/b.org"] || !got["ebooks:c.epub"] {
		t.Fatalf("since=200 结果 = %v, 期望 sub/b.org 与 c.epub", got)
	}

	// include_deleted 纳入墓碑。
	rec = do(t, h, http.MethodGet, "/api/resources?include_deleted=true", testToken, nil, nil)
	items, _ = resourceItems(t, rec)
	if len(items) != 4 {
		t.Fatalf("include_deleted=true 资源数 = %d, 期望 4", len(items))
	}
	var tomb map[string]any
	for _, it := range items {
		if it["uid"] == uidTombD {
			tomb = it
		}
	}
	if tomb == nil {
		t.Fatalf("include_deleted=true 未返回墓碑资源: %v", items)
	}
	if tomb["deleted_at"] == "" {
		t.Fatalf("墓碑资源 deleted_at 应非空: %v", tomb)
	}
}

// TestListResourcesLimitClamp 验证 limit 生效、上界夹紧与非法值 400。
func TestListResourcesLimitClamp(t *testing.T) {
	h := newRegistryServer(t, seedLive())

	// limit=2：截断且 has_more=true。
	rec := do(t, h, http.MethodGet, "/api/resources?limit=2", testToken, nil, nil)
	items, hasMore := resourceItems(t, rec)
	if len(items) != 2 {
		t.Fatalf("limit=2 资源数 = %d, 期望 2 (items=%v)", len(items), items)
	}
	if !hasMore {
		t.Fatal("limit=2 且有 3 条资源时 has_more 应为 true")
	}

	// limit 超过上界：夹紧为 2000（结果仍是全部 3 条，不报错）。
	rec = do(t, h, http.MethodGet, "/api/resources?limit=5000", testToken, nil, nil)
	items, hasMore = resourceItems(t, rec)
	if len(items) != 3 || hasMore {
		t.Fatalf("limit=5000 结果 = %d 条 / has_more=%v, 期望 3 条且 false", len(items), hasMore)
	}

	// limit 下界夹紧为 1。
	rec = do(t, h, http.MethodGet, "/api/resources?limit=0", testToken, nil, nil)
	items, hasMore = resourceItems(t, rec)
	if len(items) != 1 || !hasMore {
		t.Fatalf("limit=0 结果 = %d 条 / has_more=%v, 期望夹紧为 1 条且 true", len(items), hasMore)
	}

	// 非整数 limit → 400。
	rec = do(t, h, http.MethodGet, "/api/resources?limit=abc", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")

	// 非整数 since → 400。
	rec = do(t, h, http.MethodGet, "/api/resources?since=yesterday", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")

	// 非布尔 include_deleted → 400。
	rec = do(t, h, http.MethodGet, "/api/resources?include_deleted=maybe", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestGetResourceByUID 验证单资源端点：正常 / 非法 uid 400 / 未登记 404 / 墓碑 404。
func TestGetResourceByUID(t *testing.T) {
	seed := append(seedLive(),
		createEvent(uidTombD, "notes", "gone.org", 400, "2026-10-18T10:03:00Z"))
	seed = append(seed, registry.Event{
		UID: uidTombD, Op: storage.OpDelete, Root: "notes", Path: "gone.org", At: "2026-10-18T10:04:00Z",
	})
	h := newRegistryServer(t, seed)

	rec := do(t, h, http.MethodGet, "/api/resources/"+uidNotesB, testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["uid"] != uidNotesB || body["root"] != "notes" || body["path"] != "sub/b.org" {
		t.Fatalf("资源对象 = %v, 期望 uid/root/path = %s/notes/sub/b.org", body, uidNotesB)
	}
	if body["kind"] != storage.ResourceKindFile {
		t.Fatalf("kind = %v, 期望 %q", body["kind"], storage.ResourceKindFile)
	}
	if body["mtime"] != float64(200) {
		t.Fatalf("mtime = %v, 期望 200", body["mtime"])
	}

	// 非法 uid（含被 Crockford 排除的 I）→ 400 invalid_uid。
	rec = do(t, h, http.MethodGet, "/api/resources/01K8Q3M7D2X9V6T1B8N5C0RDEI", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_uid")

	// 合法但未登记 → 404 unknown_uid。
	rec = do(t, h, http.MethodGet, "/api/resources/01K8Q3M7D2X9V6T1B8N5C0RDEZ", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "unknown_uid")

	// 已墓碑 → 404 unknown_uid。
	rec = do(t, h, http.MethodGet, "/api/resources/"+uidTombD, testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "unknown_uid")
}

// TestResolveEndpoint 验证路径解析的三种输入形态、404 与 400。
func TestResolveEndpoint(t *testing.T) {
	h := newRegistryServer(t, seedLive())

	cases := []struct {
		name  string
		query string
	}{
		{"root+path", "?root=notes&path=a.org"},
		{"doc_id 带根标签", "?doc_id=notes:a.org"},
		{"doc_id 纯路径（默认根）", "?doc_id=a.org"},
		{"doc_id 尾斜杠与前导斜杠", "?doc_id=notes:/a.org"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodGet, "/api/resolve"+tc.query, testToken, nil, nil)
			if rec.Code != http.StatusOK {
				t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
			}
			body := decodeJSON(t, rec)
			if body["uid"] != uidNotesA {
				t.Fatalf("uid = %v, 期望 %s", body["uid"], uidNotesA)
			}
			if body["root"] != "notes" || body["path"] != "a.org" {
				t.Fatalf("root/path = %v/%v, 期望 notes/a.org", body["root"], body["path"])
			}
		})
	}

	// doc_id 指向另一根。
	rec := do(t, h, http.MethodGet, "/api/resolve?doc_id=ebooks:c.epub", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	if got := decodeJSON(t, rec)["uid"]; got != uidBookC {
		t.Fatalf("uid = %v, 期望 %s", got, uidBookC)
	}

	// 未登记路径 → 404 unknown_uid。
	rec = do(t, h, http.MethodGet, "/api/resolve?root=notes&path=missing.org", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "unknown_uid")
	rec = do(t, h, http.MethodGet, "/api/resolve?doc_id=notes:missing.org", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "unknown_uid")

	// 两种形态同时给出 → 400 invalid_argument。
	rec = do(t, h, http.MethodGet, "/api/resolve?root=notes&path=a.org&doc_id=notes:a.org", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")

	// 都不给 → 400 invalid_argument。
	rec = do(t, h, http.MethodGet, "/api/resolve", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")

	// root 与 path 只给一个 → 400 invalid_argument。
	rec = do(t, h, http.MethodGet, "/api/resolve?root=notes", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")

	// 含 ".." 的逃逸路径 → 400 invalid_argument。
	rec = do(t, h, http.MethodGet, "/api/resolve?root=notes&path=../etc/passwd", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestChangesPagination 验证增量分页：全量、since、limit 夹紧、next_cursor 与 has_more。
func TestChangesPagination(t *testing.T) {
	h := newRegistryServer(t, seedLive())

	// 全量：3 条事件，next_cursor 为最后一条 seq，has_more=false。
	rec := do(t, h, http.MethodGet, "/api/changes", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	changes, ok := body["changes"].([]any)
	if !ok {
		t.Fatalf("响应缺少 changes 数组: %q", rec.Body.String())
	}
	if len(changes) != 3 {
		t.Fatalf("changes 数 = %d, 期望 3", len(changes))
	}
	if body["next_cursor"] != float64(3) {
		t.Fatalf("next_cursor = %v, 期望 3", body["next_cursor"])
	}
	if body["has_more"] != false {
		t.Fatalf("has_more = %v, 期望 false", body["has_more"])
	}
	// change 对象字段完整性（JSON 契约）。
	first, _ := changes[0].(map[string]any)
	for _, key := range []string{"seq", "uid", "op", "root", "path", "old_path", "blob",
		"rev", "changed_at"} {
		if _, ok := first[key]; !ok {
			t.Fatalf("change 对象缺少字段 %q: %v", key, first)
		}
	}
	if first["uid"] != uidNotesA || first["op"] != storage.OpCreate {
		t.Fatalf("首条 change = %v, 期望 uid=%s op=create", first, uidNotesA)
	}

	// since=1：只返回 seq>1 的 2 条。
	rec = do(t, h, http.MethodGet, "/api/changes?since=1", testToken, nil, nil)
	body = decodeJSON(t, rec)
	changes = body["changes"].([]any)
	if len(changes) != 2 {
		t.Fatalf("since=1 changes 数 = %d, 期望 2", len(changes))
	}
	if body["next_cursor"] != float64(3) {
		t.Fatalf("since=1 next_cursor = %v, 期望 3", body["next_cursor"])
	}

	// since 超出末尾：空批次且游标不倒退。
	rec = do(t, h, http.MethodGet, "/api/changes?since=99", testToken, nil, nil)
	body = decodeJSON(t, rec)
	if got := body["changes"].([]any); len(got) != 0 {
		t.Fatalf("since=99 changes 数 = %d, 期望 0", len(got))
	}
	if body["next_cursor"] != float64(99) {
		t.Fatalf("since=99 next_cursor = %v, 期望 99（游标不倒退）", body["next_cursor"])
	}

	// limit=2：截断为 2 条，has_more=true，next_cursor=2。
	rec = do(t, h, http.MethodGet, "/api/changes?limit=2", testToken, nil, nil)
	body = decodeJSON(t, rec)
	if got := body["changes"].([]any); len(got) != 2 {
		t.Fatalf("limit=2 changes 数 = %d, 期望 2", len(got))
	}
	if body["has_more"] != true {
		t.Fatalf("limit=2 has_more = %v, 期望 true", body["has_more"])
	}
	if body["next_cursor"] != float64(2) {
		t.Fatalf("limit=2 next_cursor = %v, 期望 2", body["next_cursor"])
	}

	// limit 下界夹紧为 1（而非默认 500）。
	rec = do(t, h, http.MethodGet, "/api/changes?limit=0", testToken, nil, nil)
	body = decodeJSON(t, rec)
	if got := body["changes"].([]any); len(got) != 1 {
		t.Fatalf("limit=0 changes 数 = %d, 期望夹紧为 1", len(got))
	}

	// limit 上界夹紧为 2000（3 条全返回，不报错）。
	rec = do(t, h, http.MethodGet, "/api/changes?limit=999999", testToken, nil, nil)
	body = decodeJSON(t, rec)
	if got := body["changes"].([]any); len(got) != 3 {
		t.Fatalf("limit=999999 changes 数 = %d, 期望 3", len(got))
	}

	// 非整数 since → 400。
	rec = do(t, h, http.MethodGet, "/api/changes?since=abc", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestRegistryNilEndpointsUnavailable 验证未注入 registry 时四个端点均返回 503。
func TestRegistryNilEndpointsUnavailable(t *testing.T) {
	h := newNoRegistryServer(t)

	targets := []string{
		"/api/resources",
		"/api/resources/" + uidNotesA,
		"/api/resolve?root=notes&path=a.org",
		"/api/changes",
		"/api/roots",
	}
	for _, target := range targets {
		rec := do(t, h, http.MethodGet, target, testToken, nil, nil)
		assertErrorCode(t, rec, http.StatusServiceUnavailable, "unavailable")
	}
}

// TestRegistryEndpointsRequireAuth 验证新端点仍受既有 Bearer 中间件保护（无令牌 401）。
func TestRegistryEndpointsRequireAuth(t *testing.T) {
	h := newRegistryServer(t, seedLive())

	targets := []string{
		"/api/resources",
		"/api/resources/" + uidNotesA,
		"/api/resolve?doc_id=a.org",
		"/api/changes",
		"/api/roots",
	}
	for _, target := range targets {
		rec := do(t, h, http.MethodGet, target, "", nil, nil)
		assertErrorCode(t, rec, http.StatusUnauthorized, "unauthorized")
	}
}

// newRootsServer 只用给定根清单组装处理器（不预置登记事件），供根映射端点测试使用。
func newRootsServer(t *testing.T, roots []registry.Root) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	svc := registry.New(db, nil)
	if err := svc.SetRoots(roots); err != nil {
		t.Fatalf("设置根清单失败: %v", err)
	}
	return api.NewHandlerFullWithRegistry(db, nil, nil, svc, auth.New(testToken), nil)
}

// rootObjects 解码根清单响应，返回 roots 数组与原始响应体文本。
func rootObjects(t *testing.T, rec *httptest.ResponseRecorder) ([]map[string]any, string) {
	t.Helper()
	body := decodeJSON(t, rec)
	raw, ok := body["roots"].([]any)
	if !ok {
		t.Fatalf("响应缺少 roots 数组: %q", rec.Body.String())
	}
	roots := make([]map[string]any, 0, len(raw))
	for _, it := range raw {
		obj, ok := it.(map[string]any)
		if !ok {
			t.Fatalf("roots 元素不是对象: %v", it)
		}
		roots = append(roots, obj)
	}
	return roots, rec.Body.String()
}

// TestListRootsSingleRoot 验证单根时返回 1 条、default=true、mode=mirror。
func TestListRootsSingleRoot(t *testing.T) {
	h := newRootsServer(t, []registry.Root{
		{Tag: "notes", Path: t.TempDir(), Mode: registry.RootModeMirror},
	})

	rec := do(t, h, http.MethodGet, "/api/roots", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	roots, _ := rootObjects(t, rec)
	if len(roots) != 1 {
		t.Fatalf("roots 数 = %d, 期望 1: %q", len(roots), rec.Body.String())
	}
	only := roots[0]
	if only["tag"] != "notes" {
		t.Fatalf("tag = %v, 期望 notes", only["tag"])
	}
	if only["mode"] != registry.RootModeMirror {
		t.Fatalf("mode = %v, 期望 %s", only["mode"], registry.RootModeMirror)
	}
	if only["default"] != true {
		t.Fatalf("default = %v, 期望 true（首根即默认根）", only["default"])
	}
}

// TestListRootsMultipleRoots 验证双根的顺序、mode 与 default 标记。
func TestListRootsMultipleRoots(t *testing.T) {
	h := newRootsServer(t, []registry.Root{
		{Tag: "notes", Path: t.TempDir(), Mode: registry.RootModeMirror},
		{Tag: "ebooks", Path: t.TempDir(), Mode: registry.RootModeOnDemand},
	})

	rec := do(t, h, http.MethodGet, "/api/roots", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	roots, _ := rootObjects(t, rec)
	if len(roots) != 2 {
		t.Fatalf("roots 数 = %d, 期望 2: %q", len(roots), rec.Body.String())
	}
	if roots[0]["tag"] != "notes" || roots[0]["default"] != true ||
		roots[0]["mode"] != registry.RootModeMirror {
		t.Fatalf("首根 = %v, 期望 tag=notes default=true mode=mirror", roots[0])
	}
	if roots[1]["tag"] != "ebooks" || roots[1]["default"] != false ||
		roots[1]["mode"] != registry.RootModeOnDemand {
		t.Fatalf("次根 = %v, 期望 tag=ebooks default=false mode=ondemand", roots[1])
	}
}

// TestListRootsDoesNotLeakPhysicalPath 验证响应只含 tag/mode/default，不含物理路径。
func TestListRootsDoesNotLeakPhysicalPath(t *testing.T) {
	notesDir, booksDir := t.TempDir(), t.TempDir()
	h := newRootsServer(t, []registry.Root{
		{Tag: "notes", Path: notesDir, Mode: registry.RootModeMirror},
		{Tag: "ebooks", Path: booksDir, Mode: registry.RootModeOnDemand},
	})

	rec := do(t, h, http.MethodGet, "/api/roots", testToken, nil, nil)
	roots, raw := rootObjects(t, rec)

	for _, dir := range []string{notesDir, booksDir} {
		if strings.Contains(raw, dir) {
			t.Fatalf("响应体泄露物理路径 %q: %q", dir, raw)
		}
	}
	for _, root := range roots {
		if _, ok := root["path"]; ok {
			t.Fatalf("根对象含物理路径字段 path: %v", root)
		}
		if len(root) != 3 {
			t.Fatalf("根对象字段数 = %d（%v），期望恰好 tag/mode/default 三个", len(root), root)
		}
	}
}
