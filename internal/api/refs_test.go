// 本文件覆盖 M7 C1 的引用查询端点 GET /api/refs。
//
// 测试沿本包既有约定：临时目录独立 SQLite、经 NewHandlerFullWithRegistry 组装
// ServeMux + Bearer 认证，从外部包视角断言 HTTP 行为。引用数据经 registry.RefreshRefs
// 从真实 .org 内容解析产生（与写路径同一入口），不直接写 SQL。
package api_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// 引用端点用例的固定 uid（26 位 Crockford Base32；与其它测试文件的常量不重复）。
const (
	uidRef1   = "01K8Q3M7D2X9V6T1B8N5C0RDEQ"
	uidRef2   = "01K8Q3M7D2X9V6T1B8N5C0RDER"
	uidRefSrc = "01K8Q3M7D2X9V6T1B8N5C0RDES"
	// uidRef3 是「未被任何人引用」的文档，用于验证反向查询返回空数组。
	uidRef3 = "01K8Q3M7D2X9V6T1B8N5C0RDET"
)

// newRefsServer 构造带引用数据的处理器：登记三个 .org（两个目标 + 一个源），
// 源内容含两条 seshat: 链接（uid 形态 + tag:path 形态），经 RefreshRefs 落库。
func newRefsServer(t *testing.T) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	rootDir := t.TempDir()
	svc := registry.New(db, nil)
	if err := svc.SetRoots([]registry.Root{{Tag: "notes", Path: rootDir}}); err != nil {
		t.Fatalf("设置根清单失败: %v", err)
	}

	for _, tc := range []struct{ uid, path, content string }{
		{uidRef1, "target1.org", "* 目标一\n"},
		{uidRef2, "target2.org", "* 目标二\n"},
		{uidRef3, "target3.org", "* 无人引用\n"},
		{uidRefSrc, "src.org", "[[seshat:" + uidRef1 + "]]\n" +
			"[[seshat:notes:target2.org#p.5][目标二第 5 页]]\n"},
	} {
		full := filepath.Join(rootDir, filepath.FromSlash(tc.path))
		if err := os.WriteFile(full, []byte(tc.content), 0o644); err != nil {
			t.Fatalf("写入 %s 失败: %v", tc.path, err)
		}
		if _, err := svc.Apply(registry.Event{
			UID: tc.uid, Op: storage.OpCreate, Root: "notes", Path: tc.path,
		}); err != nil {
			t.Fatalf("预置登记 %s 失败: %v", tc.path, err)
		}
	}
	if err := svc.RefreshRefs("notes", "src.org"); err != nil {
		t.Fatalf("预置引用失败: %v", err)
	}

	return api.NewHandlerFullWithRegistry(db, nil, nil, svc, auth.New(testToken), nil)
}

// refsOf 解码引用响应，返回 refs 数组（缺失或类型不对即终止用例）。
func refsOf(t *testing.T, rec *httptest.ResponseRecorder) []map[string]any {
	t.Helper()
	body := decodeJSON(t, rec)
	raw, ok := body["refs"].([]any)
	if !ok {
		t.Fatalf("响应缺少 refs 数组: %q", rec.Body.String())
	}
	refs := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		obj, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("refs 元素不是对象: %v", item)
		}
		refs = append(refs, obj)
	}
	return refs
}

// TestListRefsOut 验证默认方向（out）返回源文档的全部出边，且响应字段恰为契约规定的
// 五项（不泄露物理路径或文件内容）。
func TestListRefsOut(t *testing.T) {
	h := newRefsServer(t)

	rec := do(t, h, http.MethodGet, "/api/refs?uid="+uidRefSrc, testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}

	refs := refsOf(t, rec)
	if len(refs) != 2 {
		t.Fatalf("引用条数 = %d, 期望 2: %q", len(refs), rec.Body.String())
	}

	wantFields := []string{"source_uid", "source_location", "target_uid", "target_location", "created_at"}
	locations := map[string]string{}
	for _, ref := range refs {
		if len(ref) != len(wantFields) {
			t.Fatalf("引用字段数 = %d, 期望 %d（不得多出物理路径等字段）: %v",
				len(ref), len(wantFields), ref)
		}
		for _, field := range wantFields {
			if _, ok := ref[field]; !ok {
				t.Fatalf("缺少字段 %q: %v", field, ref)
			}
		}
		if ref["source_uid"] != uidRefSrc {
			t.Errorf("source_uid = %v, 期望 %s", ref["source_uid"], uidRefSrc)
		}
		if ref["created_at"] == "" {
			t.Error("created_at 为空，期望回填时间戳")
		}
		locations[ref["target_uid"].(string)] = ref["target_location"].(string)
	}
	if _, ok := locations[uidRef1]; !ok {
		t.Errorf("缺少指向 uid 形态目标的边: %v", locations)
	}
	if loc, ok := locations[uidRef2]; !ok || loc != "p.5" {
		t.Errorf("tag:path 目标边 = (%q, %v), 期望 location p.5", loc, ok)
	}
}

// TestListRefsIn 验证 direction=in 反查「谁引用了我」。
func TestListRefsIn(t *testing.T) {
	h := newRefsServer(t)

	rec := do(t, h, http.MethodGet, "/api/refs?uid="+uidRef1+"&direction=in", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	refs := refsOf(t, rec)
	if len(refs) != 1 {
		t.Fatalf("反向引用条数 = %d, 期望 1: %q", len(refs), rec.Body.String())
	}
	if refs[0]["source_uid"] != uidRefSrc || refs[0]["target_uid"] != uidRef1 {
		t.Fatalf("反向边 = %v, 期望 source=%s target=%s", refs[0], uidRefSrc, uidRef1)
	}

	// 没有被引用的文档反向为空数组（不是 null）。
	empty := do(t, h, http.MethodGet, "/api/refs?uid="+uidRef3+"&direction=in", testToken, nil, nil)
	if empty.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200", empty.Code)
	}
	if refs := refsOf(t, empty); len(refs) != 0 {
		t.Fatalf("uidRef3 的反向引用 = %v, 期望为空", refs)
	}
}

// TestListRefsInvalidDirection 验证 direction 非 in/out 返回 400 invalid_argument。
func TestListRefsInvalidDirection(t *testing.T) {
	h := newRefsServer(t)

	rec := do(t, h, http.MethodGet, "/api/refs?uid="+uidRefSrc+"&direction=xx", testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusBadRequest, "invalid_argument")
}

// TestListRefsInvalidUID 验证 uid 形态非法返回 400 invalid_uid（含缺省/垃圾值）。
func TestListRefsInvalidUID(t *testing.T) {
	h := newRefsServer(t)

	for _, target := range []string{
		"/api/refs",
		"/api/refs?uid=",
		"/api/refs?uid=not-a-uid",
		"/api/refs?uid=" + uidRefSrc[:25],
	} {
		rec := do(t, h, http.MethodGet, target, testToken, nil, nil)
		assertErrorCode(t, rec, http.StatusBadRequest, "invalid_uid")
	}
}

// TestListRefsUnknownUID 验证合法但未登记的 uid 返回 404 unknown_uid。
func TestListRefsUnknownUID(t *testing.T) {
	h := newRefsServer(t)

	rec := do(t, h, http.MethodGet, "/api/refs?uid="+uidAbsent, testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "unknown_uid")
}

// TestListRefsNoRegistry 验证未注入 registry 的处理器返回 503 unavailable。
func TestListRefsNoRegistry(t *testing.T) {
	h := newNoRegistryServer(t)

	rec := do(t, h, http.MethodGet, "/api/refs?uid="+uidRefSrc, testToken, nil, nil)
	assertErrorCode(t, rec, http.StatusServiceUnavailable, "unavailable")
}

// TestListRefsRequiresAuth 验证无令牌返回 401（与其它 /api/ 端点一致）。
func TestListRefsRequiresAuth(t *testing.T) {
	h := newRefsServer(t)

	rec := do(t, h, http.MethodGet, "/api/refs?uid="+uidRefSrc, "", nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("状态码 = %d, 期望 401 (body=%q)", rec.Code, rec.Body.String())
	}
}
