// 本文件覆盖 M7 B4 状态端点的 uid 契约：uid 是唯一键、形态非法 400 invalid_uid、
// 未登记或已墓碑 404 unknown_uid，且响应体不再含 document_id 字段。
//
// 组装方式沿本包既有约定：临时目录独立 SQLite、经 NewHandlerFullWithRegistry 挂入
// 身份登记服务，登记表用 registry.Service.Apply 预置（与真实写路径一致）。
package api_test

import (
	"net/http"
	"strconv"
	"testing"

	"seshat/internal/registry"
	"seshat/internal/storage"
)

// 状态端点用例的固定 uid（26 位 Crockford Base32，后缀 J/K/M/N 均为合法字符）。
const (
	uidStateA    = "01K8Q3M7D2X9V6T1B8N5C0RDEJ"
	uidStateB    = "01K8Q3M7D2X9V6T1B8N5C0RDEK"
	uidStateTomb = "01K8Q3M7D2X9V6T1B8N5C0RDEM"
	uidStateNone = "01K8Q3M7D2X9V6T1B8N5C0RDEN"
)

// seedStateResources 返回两条存活资源与一条墓碑资源的登记事件，覆盖「已登记」与
// 「已墓碑」两类 uid 状态。
func seedStateResources() []registry.Event {
	seed := []registry.Event{
		createEvent(uidStateA, "notes", "a.org", 100, "2026-10-18T11:00:00Z"),
		createEvent(uidStateB, "notes", "b.org", 200, "2026-10-18T11:01:00Z"),
		createEvent(uidStateTomb, "notes", "gone.org", 300, "2026-10-18T11:02:00Z"),
	}
	return append(seed, registry.Event{
		UID: uidStateTomb, Op: storage.OpDelete, Root: "notes", Path: "gone.org",
		Mtime: 300, At: "2026-10-18T11:03:00Z",
	})
}

// TestProgressUIDRoundTrip 验证已登记 uid 的进度 PUT/GET 往返，且响应体以 uid 为键。
func TestProgressUIDRoundTrip(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	put := do(t, h, http.MethodPut, "/api/progress/"+uidStateA, testToken, map[string]string{
		"position":   "chapter-3:42",
		"updated_at": "2026-10-18T11:10:00Z",
	}, nil)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", put.Code, put.Body.String())
	}
	if got := decodeJSON(t, put)["uid"]; got != uidStateA {
		t.Fatalf("PUT 响应 uid = %v, 期望 %s", got, uidStateA)
	}

	get := do(t, h, http.MethodGet, "/api/progress/"+uidStateA, testToken, nil, nil)
	if get.Code != http.StatusOK {
		t.Fatalf("GET 状态码 = %d, 期望 200 (body=%q)", get.Code, get.Body.String())
	}
	body := decodeJSON(t, get)
	if body["uid"] != uidStateA || body["position"] != "chapter-3:42" ||
		body["updated_at"] != "2026-10-18T11:10:00Z" {
		t.Fatalf("GET 响应不符: %q", get.Body.String())
	}

	// 同一路径重复写入为后写覆盖。
	put2 := do(t, h, http.MethodPut, "/api/progress/"+uidStateA, testToken, map[string]string{
		"position":   "chapter-4:1",
		"updated_at": "2026-10-18T11:20:00Z",
	}, nil)
	if put2.Code != http.StatusOK {
		t.Fatalf("二次 PUT 状态码 = %d, 期望 200", put2.Code)
	}
	if got := decodeJSON(t, do(t, h, http.MethodGet, "/api/progress/"+uidStateA, testToken, nil, nil))["position"]; got != "chapter-4:1" {
		t.Fatalf("后写覆盖失败, position = %v", got)
	}
}

// TestProgressUIDWithoutRegistry 验证未注入 registry 的旧构造函数下只做形态校验：
// 合法但未登记的 uid 仍可读写（不然既有无登记能力的部署会整体失去状态端点）。
func TestProgressUIDWithoutRegistry(t *testing.T) {
	h := newNoRegistryServer(t)

	put := do(t, h, http.MethodPut, "/api/progress/"+uidStateA, testToken, map[string]string{
		"position":   "p1",
		"updated_at": "2026-10-18T11:10:00Z",
	}, nil)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", put.Code, put.Body.String())
	}
	if got := decodeJSON(t, do(t, h, http.MethodGet, "/api/progress/"+uidStateA, testToken, nil, nil))["position"]; got != "p1" {
		t.Fatalf("GET position = %v, 期望 p1", got)
	}
}

// TestStatusInvalidUID 验证形态非法的 uid 在所有状态入口一律返回 400 invalid_uid。
func TestStatusInvalidUID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	cases := []struct {
		name   string
		method string
		target string
		body   any
	}{
		{"进度 GET 短串", http.MethodGet, "/api/progress/bad-uid", nil},
		{"进度 PUT 短串", http.MethodPut, "/api/progress/bad-uid", map[string]string{"position": "p1"}},
		// 含 I 的 26 位串：Crockford Base32 排除 I/L/O/U，形态非法。
		{"进度 GET 非法字符", http.MethodGet, "/api/progress/01K8Q3M7D2X9V6T1B8N5C0RDEI", nil},
		{"进度 GET 小写", http.MethodGet, "/api/progress/01k8q3m7d2x9v6t1b8n5c0rdej", nil},
		{"批注列表缺 uid", http.MethodGet, "/api/annotations", nil},
		{"批注列表非法 uid", http.MethodGet, "/api/annotations?uid=bad-uid", nil},
		{"批注创建非法 uid", http.MethodPost, "/api/annotations", map[string]string{
			"uid": "bad-uid", "location": "loc", "text": "text",
		}},
		{"批注创建空 uid", http.MethodPost, "/api/annotations", map[string]string{
			"location": "loc", "text": "text",
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, tc.method, tc.target, testToken, tc.body, nil)
			assertErrorCode(t, rec, http.StatusBadRequest, "invalid_uid")
		})
	}
}

// TestStatusUnknownUID 验证形态合法但未登记的 uid 返回 404 unknown_uid（含写路径，
// 避免对未登记资源留下孤儿状态）。
func TestStatusUnknownUID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	cases := []struct {
		name   string
		method string
		target string
		body   any
	}{
		{"进度 GET", http.MethodGet, "/api/progress/" + uidStateNone, nil},
		{"进度 PUT", http.MethodPut, "/api/progress/" + uidStateNone, map[string]string{"position": "p1"}},
		{"批注列表", http.MethodGet, "/api/annotations?uid=" + uidStateNone, nil},
		{"批注创建", http.MethodPost, "/api/annotations", map[string]string{
			"uid": uidStateNone, "location": "loc", "text": "text",
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, tc.method, tc.target, testToken, tc.body, nil)
			assertErrorCode(t, rec, http.StatusNotFound, "unknown_uid")
		})
	}
}

// TestStatusTombstonedUID 验证已墓碑的 uid 对状态端点等同不存在（404 unknown_uid）。
func TestStatusTombstonedUID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	get := do(t, h, http.MethodGet, "/api/progress/"+uidStateTomb, testToken, nil, nil)
	assertErrorCode(t, get, http.StatusNotFound, "unknown_uid")

	put := do(t, h, http.MethodPut, "/api/progress/"+uidStateTomb, testToken, map[string]string{
		"position": "p1",
	}, nil)
	assertErrorCode(t, put, http.StatusNotFound, "unknown_uid")
}

// TestAnnotationsCreateWithUID 验证批注创建以请求体 uid 定位文档，响应回显 uid。
func TestAnnotationsCreateWithUID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	rec := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid":      uidStateA,
		"location": "chapter-1:10",
		"text":     "第一条批注",
	}, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["uid"] != uidStateA {
		t.Fatalf("创建响应 uid = %v, 期望 %s", body["uid"], uidStateA)
	}
	if _, ok := body["document_id"]; ok {
		t.Fatalf("创建响应不应含 document_id 字段: %q", rec.Body.String())
	}
}

// TestAnnotationsListFiltersByUID 验证批注列表按 uid 隔离（a 两条、b 一条）。
func TestAnnotationsListFiltersByUID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	// location 逐条不同：同 (uid, kind, location, text) 会被服务端幂等去重（返回 200、
	// 不新增行），本用例验证的是按 uid 隔离，故需构造互不相同的批注。
	for _, tc := range []struct{ uid, location string }{
		{uidStateA, "loc-1"},
		{uidStateA, "loc-2"},
		{uidStateB, "loc-1"},
	} {
		rec := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
			"uid": tc.uid, "location": tc.location, "text": "text",
		}, nil)
		if rec.Code != http.StatusCreated {
			t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", rec.Code, rec.Body.String())
		}
	}

	for _, tc := range []struct {
		uid  string
		want int
	}{
		{uidStateA, 2},
		{uidStateB, 1},
	} {
		items := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+tc.uid, testToken, nil, nil))
		if len(items) != tc.want {
			t.Fatalf("uid=%s 批注条数 = %d, 期望 %d", tc.uid, len(items), tc.want)
		}
		for _, it := range items {
			if it["uid"] != tc.uid {
				t.Fatalf("列表混入其它 uid 的批注: %v", it)
			}
		}
	}
}

// TestAnnotationsUpdateDeleteByID 验证批注的更新/删除仍按 id 定位（不需要 uid 校验），
// 且更新后的记录保留原 uid。
func TestAnnotationsUpdateDeleteByID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	created := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid": uidStateB, "location": "loc", "text": "原始",
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}
	id, ok := decodeJSON(t, created)["id"].(float64)
	if !ok || id <= 0 {
		t.Fatalf("创建响应缺少有效 id: %q", created.Body.String())
	}
	path := "/api/annotations/" + strconv.Itoa(int(id))

	update := do(t, h, http.MethodPut, path, testToken, map[string]string{
		"location": "loc-2", "text": "修改后",
	}, nil)
	if update.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", update.Code, update.Body.String())
	}
	updatedBody := decodeJSON(t, update)
	if updatedBody["text"] != "修改后" || updatedBody["location"] != "loc-2" {
		t.Fatalf("更新响应不符: %q", update.Body.String())
	}
	if updatedBody["uid"] != uidStateB {
		t.Fatalf("更新后 uid = %v, 期望 %s", updatedBody["uid"], uidStateB)
	}

	if rec := do(t, h, http.MethodDelete, path, testToken, nil, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE 状态码 = %d, 期望 204 (body=%q)", rec.Code, rec.Body.String())
	}
	if items := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidStateB, testToken, nil, nil)); len(items) != 0 {
		t.Fatalf("删除后批注条数 = %d, 期望 0", len(items))
	}
}

// TestStatusResponsesOmitDocumentID 断言进度与批注的所有响应体都不含 document_id
// 字段、且都带 uid（破坏性契约的机械守卫：字段名回退会立刻失败）。
func TestStatusResponsesOmitDocumentID(t *testing.T) {
	h := newRegistryServer(t, seedStateResources())

	assertNoDocumentID := func(t *testing.T, body map[string]any, where string) {
		t.Helper()
		if _, ok := body["document_id"]; ok {
			t.Fatalf("%s 响应不应含 document_id 字段: %v", where, body)
		}
		if body["uid"] != uidStateA {
			t.Fatalf("%s 响应 uid = %v, 期望 %s", where, body["uid"], uidStateA)
		}
	}

	put := do(t, h, http.MethodPut, "/api/progress/"+uidStateA, testToken, map[string]string{
		"position": "p1",
	}, nil)
	assertNoDocumentID(t, decodeJSON(t, put), "进度 PUT")

	get := do(t, h, http.MethodGet, "/api/progress/"+uidStateA, testToken, nil, nil)
	assertNoDocumentID(t, decodeJSON(t, get), "进度 GET")

	created := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid": uidStateA, "location": "loc", "text": "text",
	}, nil)
	assertNoDocumentID(t, decodeJSON(t, created), "批注 POST")

	list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidStateA, testToken, nil, nil))
	if len(list) != 1 {
		t.Fatalf("批注条数 = %d, 期望 1", len(list))
	}
	assertNoDocumentID(t, list[0], "批注列表")
}
