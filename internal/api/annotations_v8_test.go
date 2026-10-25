// 本文件覆盖 M10.3 T1 的服务端 v8 契约扩展：kind / selected_text 的 API 往返、
// 按 kind 分支的 text 校验（note 必填、highlight/ink 可空）、以及创建接口的幂等
// 去重（命中既有记录返回 200、新建返回 201）。
package api_test

import (
	"net/http"
	"testing"
)

// TestAnnotationsKindAndSelectedTextRoundTrip 验证创建 → 列表 → 更新 → 再列表
// 四步中 kind 与 selected_text 均正确往返。
func TestAnnotationsKindAndSelectedTextRoundTrip(t *testing.T) {
	h := newTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid":           uidDoc,
		"location":      "chapter:2@10-20",
		"kind":          "highlight",
		"text":          "",
		"selected_text": "选中的原文",
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}
	createdBody := decodeJSON(t, created)
	if createdBody["kind"] != "highlight" || createdBody["selected_text"] != "选中的原文" {
		t.Fatalf("创建响应 kind/selected_text 不符: %q", created.Body.String())
	}
	id, ok := createdBody["id"].(float64)
	if !ok || id <= 0 {
		t.Fatalf("创建响应缺少有效 id: %q", created.Body.String())
	}

	list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil))
	if len(list) != 1 {
		t.Fatalf("批注条数 = %d, 期望 1", len(list))
	}
	if list[0]["kind"] != "highlight" || list[0]["selected_text"] != "选中的原文" || list[0]["text"] != "" {
		t.Fatalf("列表读回字段不符: %v", list[0])
	}

	updated := do(t, h, http.MethodPut, "/api/annotations/1", testToken, map[string]string{
		"location":      "chapter:2@10-20",
		"kind":          "note",
		"text":          "补的备注",
		"selected_text": "选中的原文",
	}, nil)
	if updated.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", updated.Code, updated.Body.String())
	}
	updatedBody := decodeJSON(t, updated)
	if updatedBody["kind"] != "note" || updatedBody["text"] != "补的备注" || updatedBody["selected_text"] != "选中的原文" {
		t.Fatalf("更新响应字段不符: %q", updated.Body.String())
	}

	list = decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil))
	if len(list) != 1 {
		t.Fatalf("更新后批注条数 = %d, 期望 1", len(list))
	}
	if list[0]["kind"] != "note" || list[0]["text"] != "补的备注" || list[0]["selected_text"] != "选中的原文" {
		t.Fatalf("更新后列表读回字段不符: %v", list[0])
	}
}

// TestAnnotationCreateNonNoteAllowsEmptyText 验证 highlight / ink 以及未知 kind
// 都允许空 text（服务端不做 kind 枚举校验），且均返回 201。
func TestAnnotationCreateNonNoteAllowsEmptyText(t *testing.T) {
	h := newTestHandler(t)

	cases := []struct {
		name     string
		kind     string
		location string
	}{
		{"高亮", "highlight", "chapter:1@0-8"},
		{"笔迹", "ink", "page:3;ink:pen,1.50,10,20"},
		{"未知 kind", "underline", "page:1"},
	}
	for _, tc := range cases {
		rec := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
			"uid":      uidDoc,
			"location": tc.location,
			"kind":     tc.kind,
			"text":     "",
		}, nil)
		if rec.Code != http.StatusCreated {
			t.Fatalf("%s: 状态码 = %d, 期望 201 (body=%q)", tc.name, rec.Code, rec.Body.String())
		}
		if body := decodeJSON(t, rec); body["kind"] != tc.kind || body["text"] != "" {
			t.Fatalf("%s: 响应字段不符: %q", tc.name, rec.Body.String())
		}
	}

	list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil))
	if len(list) != len(cases) {
		t.Fatalf("批注条数 = %d, 期望 %d", len(list), len(cases))
	}
}

// TestAnnotationCreateNoteRejectsEmptyText 验证 kind=note（含缺省 kind）时空 text
// 仍返回 400 invalid_argument。
func TestAnnotationCreateNoteRejectsEmptyText(t *testing.T) {
	h := newTestHandler(t)

	for _, payload := range []map[string]string{
		{"uid": uidDoc, "location": "loc", "kind": "note", "text": ""},
		{"uid": uidDoc, "location": "loc", "text": ""},
	} {
		rec := do(t, h, http.MethodPost, "/api/annotations", testToken, payload, nil)
		assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
	}

	if list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil)); len(list) != 0 {
		t.Fatalf("校验失败不应落库, 实际 %d 条", len(list))
	}
}

// TestAnnotationCreateKindDefaultsToNote 验证不传 kind 时落库为 note、
// selected_text 为空串。
func TestAnnotationCreateKindDefaultsToNote(t *testing.T) {
	h := newTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid":      uidDoc,
		"location": "page:7",
		"text":     "备注正文",
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}
	body := decodeJSON(t, created)
	if body["kind"] != "note" {
		t.Fatalf("缺省 kind = %v, 期望 note", body["kind"])
	}
	if selected, ok := body["selected_text"]; !ok || selected != "" {
		t.Fatalf("缺省 selected_text = %v, 期望空串", selected)
	}
}

// TestAnnotationCreateIdempotentReturns200 验证幂等去重：同
// (uid, kind, location, text) 第二次 POST 返回 200、id 不变、行数不增。
func TestAnnotationCreateIdempotentReturns200(t *testing.T) {
	h := newTestHandler(t)

	payload := map[string]string{
		"uid":           uidDoc,
		"location":      "chapter:3@5-15",
		"kind":          "highlight",
		"text":          "",
		"selected_text": "选中原文",
	}

	first := do(t, h, http.MethodPost, "/api/annotations", testToken, payload, nil)
	if first.Code != http.StatusCreated {
		t.Fatalf("首次 POST 状态码 = %d, 期望 201 (body=%q)", first.Code, first.Body.String())
	}
	firstBody := decodeJSON(t, first)

	// 第二次请求 selected_text 不同：不参与去重键，仍应命中既有记录。
	second := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid":           uidDoc,
		"location":      "chapter:3@5-15",
		"kind":          "highlight",
		"text":          "",
		"selected_text": "另一份选中",
	}, nil)
	if second.Code != http.StatusOK {
		t.Fatalf("重复 POST 状态码 = %d, 期望 200 (body=%q)", second.Code, second.Body.String())
	}
	secondBody := decodeJSON(t, second)
	if secondBody["id"] != firstBody["id"] {
		t.Fatalf("重复 POST 返回 id = %v, 期望既有 id %v", secondBody["id"], firstBody["id"])
	}
	if secondBody["updated_at"] != firstBody["updated_at"] {
		t.Fatalf("重复 POST 不应刷新 updated_at: %v → %v", firstBody["updated_at"], secondBody["updated_at"])
	}
	if secondBody["selected_text"] != "选中原文" {
		t.Fatalf("重复 POST 应原样返回既有记录: %q", second.Body.String())
	}

	list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil))
	if len(list) != 1 {
		t.Fatalf("批注条数 = %d, 期望 1（幂等不应新增行）", len(list))
	}
}

// TestAnnotationCreateSameLocationDifferentKind 验证同 location、不同 kind 各建一条
// （均为 201，列表两行）。
func TestAnnotationCreateSameLocationDifferentKind(t *testing.T) {
	h := newTestHandler(t)

	const loc = "page:3"
	for _, kind := range []string{"highlight", "ink"} {
		rec := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
			"uid": uidDoc, "location": loc, "kind": kind, "text": "",
		}, nil)
		if rec.Code != http.StatusCreated {
			t.Fatalf("kind=%s 状态码 = %d, 期望 201 (body=%q)", kind, rec.Code, rec.Body.String())
		}
	}

	list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil))
	if len(list) != 2 {
		t.Fatalf("批注条数 = %d, 期望 2（同 location 不同 kind 不去重）", len(list))
	}
	seen := map[any]bool{}
	for _, item := range list {
		seen[item["kind"]] = true
	}
	if !seen["highlight"] || !seen["ink"] {
		t.Fatalf("两类批注未各存一条: %v", list)
	}
}

// TestAnnotationUpdateToHighlightWithEmptyText 验证更新时把 note 改为 highlight
// 且 text 置空可成功（kind 与 text 一起更新）。
func TestAnnotationUpdateToHighlightWithEmptyText(t *testing.T) {
	h := newTestHandler(t)

	created := do(t, h, http.MethodPost, "/api/annotations", testToken, map[string]string{
		"uid": uidDoc, "location": "chapter:4@0-6", "kind": "note", "text": "原始备注",
	}, nil)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST 状态码 = %d, 期望 201 (body=%q)", created.Code, created.Body.String())
	}

	updated := do(t, h, http.MethodPut, "/api/annotations/1", testToken, map[string]string{
		"location":      "chapter:4@0-6",
		"kind":          "highlight",
		"text":          "",
		"selected_text": "选中原文",
	}, nil)
	if updated.Code != http.StatusOK {
		t.Fatalf("PUT 状态码 = %d, 期望 200 (body=%q)", updated.Code, updated.Body.String())
	}
	body := decodeJSON(t, updated)
	if body["kind"] != "highlight" || body["text"] != "" || body["selected_text"] != "选中原文" {
		t.Fatalf("更新响应字段不符: %q", updated.Body.String())
	}

	list := decodeList(t, do(t, h, http.MethodGet, "/api/annotations?uid="+uidDoc, testToken, nil, nil))
	if len(list) != 1 || list[0]["kind"] != "highlight" || list[0]["text"] != "" {
		t.Fatalf("更新后列表读回不符: %v", list)
	}
}
