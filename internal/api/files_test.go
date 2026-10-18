// 本文件覆盖 M7 B3 的文件内容端点：GET / PUT / DELETE /api/files/{path...} 与
// POST /api/resources/{uid}/move。
//
// 测试沿本包既有约定：临时目录 + 独立 SQLite + 真实 gitver 仓库（笔记根即仓库根），
// 经 NewHandlerFullWithRegistry 组装 ServeMux + Bearer 认证，从外部包视角断言
// HTTP 行为；登记状态一律由端点自身经 registry.Apply 产生，不直接写 SQL。
package api_test

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// fileEnv 是 B3 端点的测试环境：笔记根（mirror，同时是 git 仓库根）与书库根
// （ondemand）各一个临时目录，共享一个临时库与真实 registry.Service。
type fileEnv struct {
	handler  http.Handler
	repo     *gitver.Repo
	svc      *registry.Service
	notesDir string
	ebookDir string
}

// newFileEnv 组装 B3 测试环境。
func newFileEnv(t *testing.T) *fileEnv {
	t.Helper()
	notesDir := t.TempDir()
	ebookDir := t.TempDir()

	repo, err := gitver.Open(notesDir)
	if err != nil {
		t.Fatalf("打开笔记根仓库失败: %v", err)
	}
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	svc := registry.New(db, repo)
	if err := svc.SetRoots([]registry.Root{
		{Tag: "notes", Path: notesDir, Mode: registry.RootModeMirror},
		{Tag: "ebooks", Path: ebookDir, Mode: registry.RootModeOnDemand},
	}); err != nil {
		t.Fatalf("设置根清单失败: %v", err)
	}

	return &fileEnv{
		handler:  api.NewHandlerFullWithRegistry(db, repo, nil, svc, auth.New(testToken), nil),
		repo:     repo,
		svc:      svc,
		notesDir: notesDir,
		ebookDir: ebookDir,
	}
}

// doRaw 发送一次原始字节请求（文件内容端点不能用 JSON 序列化）。
func doRaw(t *testing.T, h http.Handler, method, target, token string,
	body []byte, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()

	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req := httptest.NewRequest(method, target, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// changes 拉取全部变更事件（GET /api/changes?since=0&limit=100）。
func changes(t *testing.T, h http.Handler) []map[string]any {
	t.Helper()
	rec := do(t, h, http.MethodGet, "/api/changes?since=0&limit=100", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("拉取变更失败: %d %s", rec.Code, rec.Body.String())
	}
	raw, ok := decodeJSON(t, rec)["changes"].([]any)
	if !ok {
		t.Fatalf("响应缺少 changes 数组: %q", rec.Body.String())
	}
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		obj, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("changes 元素不是对象: %v", item)
		}
		out = append(out, obj)
	}
	return out
}

// opsOf 提取变更事件的 op 序列。
func opsOf(items []map[string]any) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = append(out, item["op"].(string))
	}
	return out
}

// putFile 发送一次 PUT 文件请求并返回响应。
func putFile(t *testing.T, h http.Handler, target, content string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	return doRaw(t, h, http.MethodPut, target, testToken, []byte(content), headers)
}

// writeFileOK 创建（或覆盖）文件并要求成功，返回响应体。
func writeFileOK(t *testing.T, h http.Handler, target, content string) map[string]any {
	t.Helper()
	rec := putFile(t, h, target, content, nil)
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("PUT %s 状态码 = %d, 期望 200/201 (body=%q)", target, rec.Code, rec.Body.String())
	}
	return decodeJSON(t, rec)
}

// TestPutFileCreates 验证新建：201 + created=true + uid 合法 + create 事件。
func TestPutFileCreates(t *testing.T) {
	env := newFileEnv(t)

	rec := putFile(t, env.handler, "/api/files/a.org", "hello\n", nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("状态码 = %d, 期望 201 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["created"] != true {
		t.Errorf("created = %v, 期望 true", body["created"])
	}
	uid, _ := body["uid"].(string)
	if !registry.IsUID(uid) {
		t.Fatalf("uid = %q, 期望 26 位 Crockford Base32", uid)
	}
	if body["root"] != "notes" || body["path"] != "a.org" {
		t.Errorf("root/path = %v/%v, 期望 notes/a.org", body["root"], body["path"])
	}
	if etag, _ := body["etag"].(string); etag == "" || etag != body["blob"] {
		t.Errorf("etag/blob = %v/%v, 期望相等且非空", body["etag"], body["blob"])
	}
	if rev, _ := body["rev"].(string); rev == "" {
		t.Error("rev 不应为空（写入已产生提交）")
	}
	if seq, _ := body["seq"].(float64); seq <= 0 {
		t.Errorf("seq = %v, 期望 > 0", body["seq"])
	}

	if items := changes(t, env.handler); len(items) != 1 || items[0]["op"] != "create" {
		t.Fatalf("变更事件 = %v, 期望 [create]", opsOf(items))
	}
	// 落盘确实发生（工作区文件内容正确）。
	content, err := os.ReadFile(filepath.Join(env.notesDir, "a.org"))
	if err != nil || string(content) != "hello\n" {
		t.Fatalf("工作区内容 = %q,%v, 期望 hello", string(content), err)
	}
}

// TestPutFileUpdatesSameUID 验证无条件覆盖：200 + uid 不变 + update 事件。
func TestPutFileUpdatesSameUID(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")

	rec := putFile(t, env.handler, "/api/files/a.org", "v2\n", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["uid"] != created["uid"] {
		t.Errorf("uid = %v, 期望与首次写入一致 %v", body["uid"], created["uid"])
	}
	if body["created"] != false {
		t.Errorf("created = %v, 期望 false", body["created"])
	}
	if items := changes(t, env.handler); len(items) != 2 ||
		items[0]["op"] != "create" || items[1]["op"] != "update" {
		t.Fatalf("变更事件 = %v, 期望 [create update]", opsOf(items))
	}

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if read.Code != http.StatusOK || read.Body.String() != "v2\n" {
		t.Fatalf("读取 = %d %q, 期望 200 v2", read.Code, read.Body.String())
	}
}

// TestPutFileIfMatch 验证条件写：ETag 匹配则成功，不匹配返回 412 且内容不变。
func TestPutFileIfMatch(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")
	etag := created["etag"].(string)

	ok := putFile(t, env.handler, "/api/files/a.org", "v2\n",
		map[string]string{"If-Match": `"` + etag + `"`})
	if ok.Code != http.StatusOK {
		t.Fatalf("If-Match 匹配时状态码 = %d, 期望 200 (body=%q)", ok.Code, ok.Body.String())
	}

	bad := putFile(t, env.handler, "/api/files/a.org", "v3\n",
		map[string]string{"If-Match": `"deadbeef"`})
	assertErrorCode(t, bad, http.StatusPreconditionFailed, "etag_mismatch")

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if read.Body.String() != "v2\n" {
		t.Fatalf("412 后内容 = %q, 期望保持不变 v2", read.Body.String())
	}

	// 不存在的资源 + If-Match 也应是 412（前提不成立），而不是被当成新建。
	missing := putFile(t, env.handler, "/api/files/nope.org", "x\n",
		map[string]string{"If-Match": `"` + etag + `"`})
	assertErrorCode(t, missing, http.StatusPreconditionFailed, "etag_mismatch")
}

// TestPutFileIfNoneMatchStar 验证 If-None-Match: * 只允许创建：已存在返回 412。
func TestPutFileIfNoneMatchStar(t *testing.T) {
	env := newFileEnv(t)

	first := putFile(t, env.handler, "/api/files/a.org", "v1\n",
		map[string]string{"If-None-Match": "*"})
	if first.Code != http.StatusCreated {
		t.Fatalf("首次创建状态码 = %d, 期望 201 (body=%q)", first.Code, first.Body.String())
	}
	second := putFile(t, env.handler, "/api/files/a.org", "v2\n",
		map[string]string{"If-None-Match": "*"})
	assertErrorCode(t, second, http.StatusPreconditionFailed, "etag_mismatch")
}

// TestPutFileReadOnlyRoot 验证书库根（ondemand）拒绝写：403 root_read_only。
func TestPutFileReadOnlyRoot(t *testing.T) {
	env := newFileEnv(t)

	rec := putFile(t, env.handler, "/api/files/c.epub?root=ebooks", "binary", nil)
	assertErrorCode(t, rec, http.StatusForbidden, "root_read_only")

	del := doRaw(t, env.handler, http.MethodDelete, "/api/files/c.epub?root=ebooks",
		testToken, nil, nil)
	assertErrorCode(t, del, http.StatusForbidden, "root_read_only")

	// 未知根 tag 是客户端拼写错误 → 400 invalid_argument。
	unknown := putFile(t, env.handler, "/api/files/a.org?root=nope", "x", nil)
	assertErrorCode(t, unknown, http.StatusBadRequest, "invalid_argument")
}

// TestGetFileContentAndETag 验证读内容：文本与二进制字节逐一相等，且带 ETag 头。
func TestGetFileContentAndETag(t *testing.T) {
	env := newFileEnv(t)
	binary := []byte{0x00, 0x01, 0xff, 0xfe, 'a', 0x00}

	if rec := putFile(t, env.handler, "/api/files/t.txt", "纯文本\n", nil); rec.Code != http.StatusCreated {
		t.Fatalf("写入文本失败: %d %s", rec.Code, rec.Body.String())
	}
	if rec := doRaw(t, env.handler, http.MethodPut, "/api/files/dir/blob.zzz", testToken, binary, nil); rec.Code != http.StatusCreated {
		t.Fatalf("写入二进制失败: %d %s", rec.Code, rec.Body.String())
	}

	text := doRaw(t, env.handler, http.MethodGet, "/api/files/t.txt", testToken, nil, nil)
	if text.Code != http.StatusOK {
		t.Fatalf("读文本状态码 = %d, 期望 200", text.Code)
	}
	if text.Body.String() != "纯文本\n" {
		t.Errorf("文本内容 = %q", text.Body.String())
	}
	etag := text.Header().Get("ETag")
	if !strings.HasPrefix(etag, `"`) || !strings.HasSuffix(etag, `"`) || len(etag) < 10 {
		t.Errorf("ETag = %q, 期望形如 \"<blob>\"", etag)
	}

	bin := doRaw(t, env.handler, http.MethodGet, "/api/files/dir/blob.zzz", testToken, nil, nil)
	if !bytes.Equal(bin.Body.Bytes(), binary) {
		t.Errorf("二进制内容 = %v, 期望 %v", bin.Body.Bytes(), binary)
	}
	if ct := bin.Header().Get("Content-Type"); ct != "application/octet-stream" {
		t.Errorf("Content-Type = %q, 期望 application/octet-stream（扩展名未知）", ct)
	}
	if bin.Header().Get("ETag") == etag {
		t.Error("不同内容的 ETag 不应相同")
	}

	// 未登记但磁盘存在的文件也可读（读路径只看文件系统，登记只影响写与清单）。
	missing := doRaw(t, env.handler, http.MethodGet, "/api/files/nope.org", testToken, nil, nil)
	if missing.Code != http.StatusNotFound {
		t.Errorf("读不存在文件状态码 = %d, 期望 404", missing.Code)
	}
}

// TestGetFileRange 验证单区间 Range：206 + 片段，非法区间 416。
func TestGetFileRange(t *testing.T) {
	env := newFileEnv(t)
	writeFileOK(t, env.handler, "/api/files/r.txt", "0123456789")

	part := doRaw(t, env.handler, http.MethodGet, "/api/files/r.txt", testToken, nil,
		map[string]string{"Range": "bytes=0-3"})
	if part.Code != http.StatusPartialContent {
		t.Fatalf("状态码 = %d, 期望 206 (body=%q)", part.Code, part.Body.String())
	}
	if part.Body.String() != "0123" {
		t.Errorf("片段 = %q, 期望 0123", part.Body.String())
	}
	if cr := part.Header().Get("Content-Range"); cr != "bytes 0-3/10" {
		t.Errorf("Content-Range = %q, 期望 bytes 0-3/10", cr)
	}

	full := doRaw(t, env.handler, http.MethodGet, "/api/files/r.txt", testToken, nil, nil)
	if full.Code != http.StatusOK || full.Body.String() != "0123456789" {
		t.Fatalf("无 Range 时应返回完整内容: %d %q", full.Code, full.Body.String())
	}

	invalid := doRaw(t, env.handler, http.MethodGet, "/api/files/r.txt", testToken, nil,
		map[string]string{"Range": "bytes=99-"})
	if invalid.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("非法区间状态码 = %d, 期望 416 (body=%q)", invalid.Code, invalid.Body.String())
	}
	if cr := invalid.Header().Get("Content-Range"); cr != "bytes */10" {
		t.Errorf("416 的 Content-Range = %q, 期望 bytes */10", cr)
	}
}

// TestMoveResource 验证按 uid 移动：uid 不变、from/to 正确、rename 事件。
func TestMoveResource(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "hello\n")
	uid := created["uid"].(string)

	rec := do(t, env.handler, http.MethodPost, "/api/resources/"+uid+"/move", testToken,
		map[string]any{"to": "sub/b.org"}, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["uid"] != uid {
		t.Errorf("uid = %v, 期望不变 %s", body["uid"], uid)
	}
	if body["from"] != "a.org" || body["to"] != "sub/b.org" {
		t.Errorf("from/to = %v/%v, 期望 a.org/sub/b.org", body["from"], body["to"])
	}

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/sub/b.org", testToken, nil, nil)
	if read.Code != http.StatusOK || read.Body.String() != "hello\n" {
		t.Fatalf("新路径读取 = %d %q, 期望 200 hello", read.Code, read.Body.String())
	}
	old := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if old.Code != http.StatusNotFound {
		t.Errorf("旧路径状态码 = %d, 期望 404", old.Code)
	}

	items := changes(t, env.handler)
	if len(items) != 2 || items[1]["op"] != "rename" {
		t.Fatalf("变更事件 = %v, 期望 [create rename]", opsOf(items))
	}
	if items[1]["old_path"] != "a.org" || items[1]["path"] != "sub/b.org" {
		t.Errorf("rename 事件 old_path/path = %v/%v", items[1]["old_path"], items[1]["path"])
	}
}

// TestMoveResourceErrors 验证移动的错误分支：uid 非法 400、未登记 404、只读根 403、
// 目标路径逃逸 400。
func TestMoveResourceErrors(t *testing.T) {
	env := newFileEnv(t)

	badUID := do(t, env.handler, http.MethodPost, "/api/resources/not-a-uid/move", testToken,
		map[string]any{"to": "x.org"}, nil)
	assertErrorCode(t, badUID, http.StatusBadRequest, "invalid_uid")

	unknown := do(t, env.handler, http.MethodPost, "/api/resources/"+uidNotesA+"/move", testToken,
		map[string]any{"to": "x.org"}, nil)
	assertErrorCode(t, unknown, http.StatusNotFound, "unknown_uid")

	created := writeFileOK(t, env.handler, "/api/files/a.org", "hello\n")
	uid := created["uid"].(string)
	escape := do(t, env.handler, http.MethodPost, "/api/resources/"+uid+"/move", testToken,
		map[string]any{"to": "../etc/passwd"}, nil)
	assertErrorCode(t, escape, http.StatusBadRequest, "invalid_argument")
	// 逃逸被拒后原文件必须完好。
	if read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil); read.Code != http.StatusOK {
		t.Errorf("逃逸被拒后原文件不可读: %d", read.Code)
	}
}

// TestDeleteFile 验证删除文件：200 + 墓碑 + delete 事件 + 内容不可再读。
func TestDeleteFile(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "hello\n")
	uid := created["uid"].(string)

	rec := doRaw(t, env.handler, http.MethodDelete, "/api/files/a.org", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["uid"] != uid {
		t.Errorf("uid = %v, 期望 %s", body["uid"], uid)
	}
	if uids, ok := body["uids"].([]any); !ok || len(uids) != 1 || uids[0] != uid {
		t.Errorf("uids = %v, 期望 [%s]", body["uids"], uid)
	}

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if read.Code != http.StatusNotFound {
		t.Errorf("删除后读取状态码 = %d, 期望 404", read.Code)
	}
	items := changes(t, env.handler)
	if len(items) != 2 || items[1]["op"] != "delete" {
		t.Fatalf("变更事件 = %v, 期望 [create delete]", opsOf(items))
	}

	// 重复删除：登记已墓碑 → 404 unknown_uid（幂等删除由客户端按此判断）。
	again := doRaw(t, env.handler, http.MethodDelete, "/api/files/a.org", testToken, nil, nil)
	assertErrorCode(t, again, http.StatusNotFound, "unknown_uid")
}

// TestDeleteDirectory 验证目录删除：uids 覆盖目录下全部存活资源。
func TestDeleteDirectory(t *testing.T) {
	env := newFileEnv(t)
	first := writeFileOK(t, env.handler, "/api/files/dir/a.org", "A\n")
	second := writeFileOK(t, env.handler, "/api/files/dir/deep/b.org", "B\n")

	rec := doRaw(t, env.handler, http.MethodDelete, "/api/files/dir", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	uids, ok := body["uids"].([]any)
	if !ok || len(uids) != 2 {
		t.Fatalf("uids = %v, 期望长度 2", body["uids"])
	}
	got := map[string]bool{uids[0].(string): true, uids[1].(string): true}
	if !got[first["uid"].(string)] || !got[second["uid"].(string)] {
		t.Errorf("uids = %v, 期望包含 %v 与 %v", uids, first["uid"], second["uid"])
	}
	if body["uid"] != "" {
		t.Errorf("目录删除的 uid = %v, 期望空串（只看 uids）", body["uid"])
	}

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/dir/a.org", testToken, nil, nil)
	if read.Code != http.StatusNotFound {
		t.Errorf("目录删除后读取状态码 = %d, 期望 404", read.Code)
	}
	ops := opsOf(changes(t, env.handler))
	if len(ops) != 4 || ops[0] != "create" || ops[1] != "create" ||
		ops[2] != "delete" || ops[3] != "delete" {
		t.Fatalf("变更事件 = %v, 期望 [create create delete delete]", ops)
	}
}

// TestFilePathEscapeRejected 验证路径逃逸被拒：含 NUL 的路径 400，且根外文件不受影响。
func TestFilePathEscapeRejected(t *testing.T) {
	env := newFileEnv(t)

	// NUL 字节不是合法的文件系统路径字符，cleanRelPath 直接拒绝（400）。
	nul := doRaw(t, env.handler, http.MethodPut, "/api/files/a%00b.org", testToken, []byte("x"), nil)
	assertErrorCode(t, nul, http.StatusBadRequest, "invalid_argument")

	// 根外文件必须完好：PUT 无论怎么写都只能在根内落盘。
	outside := filepath.Join(filepath.Dir(env.notesDir), "outside-b3.org")
	if err := os.WriteFile(outside, []byte("outside\n"), 0o644); err != nil {
		t.Fatalf("写入根外文件失败: %v", err)
	}
	t.Cleanup(func() { _ = os.Remove(outside) })
	if content, err := os.ReadFile(outside); err != nil || string(content) != "outside\n" {
		t.Fatalf("根外文件被改动: %q,%v", string(content), err)
	}
}

// TestFilesRequireAuth 验证未认证请求被拒（401），写端点与读端点一致。
func TestFilesRequireAuth(t *testing.T) {
	env := newFileEnv(t)

	cases := []struct {
		method string
		target string
		body   []byte
	}{
		{http.MethodGet, "/api/files/a.org", nil},
		{http.MethodPut, "/api/files/a.org", []byte("x")},
		{http.MethodDelete, "/api/files/a.org", nil},
		{http.MethodPost, "/api/resources/" + uidNotesA + "/move", []byte(`{"to":"b.org"}`)},
	}
	for _, c := range cases {
		rec := doRaw(t, env.handler, c.method, c.target, "", c.body, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s 未认证状态码 = %d, 期望 401", c.method, c.target, rec.Code)
		}
	}
}

// TestPutFileJSONBodyIsBytes 验证内容按原始字节写入（不是 JSON 解码）：
// 带引号与换行的内容原样落盘，ETag 与 GET 返回一致。
func TestPutFileJSONBodyIsBytes(t *testing.T) {
	env := newFileEnv(t)
	raw := "{\"not\":\"json\"}\n第二行\n"

	rec := putFile(t, env.handler, "/api/files/raw.org", raw, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("状态码 = %d, 期望 201 (body=%q)", rec.Code, rec.Body.String())
	}
	written, err := os.ReadFile(filepath.Join(env.notesDir, "raw.org"))
	if err != nil || string(written) != raw {
		t.Fatalf("落盘内容 = %q,%v, 期望原样 %q", string(written), err, raw)
	}
	etag := decodeJSON(t, rec)["etag"].(string)
	read := doRaw(t, env.handler, http.MethodGet, "/api/files/raw.org", testToken, nil, nil)
	if got := read.Header().Get("ETag"); got != `"`+etag+`"` {
		t.Errorf("GET ETag = %q, 期望与 PUT 返回的 etag 一致 %q", got, etag)
	}
}

// TestPutFileNotModifiedOnIfNoneMatchGET 验证条件读：If-None-Match 命中返回 304。
func TestPutFileNotModifiedOnIfNoneMatchGET(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")
	etag := created["etag"].(string)

	rec := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil,
		map[string]string{"If-None-Match": `"` + etag + `"`})
	if rec.Code != http.StatusNotModified {
		t.Fatalf("状态码 = %d, 期望 304 (body=%q)", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 0 {
		t.Errorf("304 不应带响应体，得到 %q", rec.Body.String())
	}
}

// TestPutFileRecreateAfterDelete 验证「删除后重建同名路径」复用墓碑 uid：
// 身份稳定（客户端缓存的 uid 仍有效），且不撞 UNIQUE(root, path) 约束。
func TestPutFileRecreateAfterDelete(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")
	uid := created["uid"].(string)

	if rec := doRaw(t, env.handler, http.MethodDelete, "/api/files/a.org", testToken, nil, nil); rec.Code != http.StatusOK {
		t.Fatalf("删除状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}

	again := putFile(t, env.handler, "/api/files/a.org", "v2\n", nil)
	if again.Code != http.StatusCreated {
		t.Fatalf("重建状态码 = %d, 期望 201 (body=%q)", again.Code, again.Body.String())
	}
	body := decodeJSON(t, again)
	if body["uid"] != uid {
		t.Errorf("重建后 uid = %v, 期望复用墓碑 uid %s", body["uid"], uid)
	}
	items := changes(t, env.handler)
	if got := opsOf(items); len(got) != 3 || got[0] != "create" || got[1] != "delete" || got[2] != "create" {
		t.Fatalf("变更事件 = %v, 期望 [create delete create]", got)
	}
	read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if read.Body.String() != "v2\n" {
		t.Errorf("重建后内容 = %q, 期望 v2", read.Body.String())
	}
}

// TestFilesRejectDotSegments 验证点位路径在所有文件端点上被拒（400 invalid_argument）：
// 任一段为 .git（大小写不敏感）或任一段以 '.' 开头（隐藏文件/目录）。
//
// 规则与 internal/registry/service.go 的 normalizeResourcePath 一致（两处必须同步）：
// 放行 .git 等于把版本库内部目录交给读写端点，放行点路径会造成「API 能写、扫描看不到」
// 的登记表不一致。
func TestFilesRejectDotSegments(t *testing.T) {
	env := newFileEnv(t)

	for _, target := range []string{
		"/api/files/.git/config",
		"/api/files/.GIT/HEAD",
		"/api/files/sub/.git/config",
		"/api/files/.hidden.org",
		"/api/files/sub/.hidden/a.org",
	} {
		put := putFile(t, env.handler, target, "x", nil)
		assertErrorCode(t, put, http.StatusBadRequest, "invalid_argument")

		get := doRaw(t, env.handler, http.MethodGet, target, testToken, nil, nil)
		assertErrorCode(t, get, http.StatusBadRequest, "invalid_argument")

		del := doRaw(t, env.handler, http.MethodDelete, target, testToken, nil, nil)
		assertErrorCode(t, del, http.StatusBadRequest, "invalid_argument")
	}

	// 移动的目标路径同样受同一条规则约束。
	created := writeFileOK(t, env.handler, "/api/files/a.org", "hello\n")
	uid := created["uid"].(string)
	move := do(t, env.handler, http.MethodPost, "/api/resources/"+uid+"/move", testToken,
		map[string]any{"to": ".git/HEAD"}, nil)
	assertErrorCode(t, move, http.StatusBadRequest, "invalid_argument")

	// 被拒的移动不能留下副作用：原文件仍在原处、内容不变。
	if read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil); read.Code != http.StatusOK ||
		read.Body.String() != "hello\n" {
		t.Fatalf("被拒的 move 改动了原文件: %d %q", read.Code, read.Body.String())
	}
}

// TestFilesRejectSymlink 验证符号链接不被跟随：
//   - 目标本身是符号链接：GET 404（读侧语义，不暴露根外内容）、PUT/DELETE 400；
//   - 父目录是符号链接且真实路径在根外：GET/PUT/move 一律 400；
//   - 无论哪种情形，根外文件的内容都不被读取或修改。
func TestFilesRejectSymlink(t *testing.T) {
	env := newFileEnv(t)

	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "secret.org")
	const secret = "根外机密\n"
	if err := os.WriteFile(outsideFile, []byte(secret), 0o644); err != nil {
		t.Fatalf("写入根外文件失败: %v", err)
	}

	leak := filepath.Join(env.notesDir, "leak")
	if err := os.Symlink(outsideFile, leak); err != nil {
		t.Skipf("环境不支持符号链接，跳过: %v", err)
	}

	get := doRaw(t, env.handler, http.MethodGet, "/api/files/leak", testToken, nil, nil)
	assertErrorCode(t, get, http.StatusNotFound, "not_found")

	put := putFile(t, env.handler, "/api/files/leak", "覆盖尝试\n", nil)
	assertErrorCode(t, put, http.StatusBadRequest, "invalid_argument")

	del := doRaw(t, env.handler, http.MethodDelete, "/api/files/leak", testToken, nil, nil)
	assertErrorCode(t, del, http.StatusBadRequest, "invalid_argument")

	if content, err := os.ReadFile(outsideFile); err != nil || string(content) != secret {
		t.Fatalf("根外文件被改动: %q,%v", string(content), err)
	}
	if info, err := os.Lstat(leak); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("符号链接本身被删除或改写: %v,%v", info, err)
	}

	// 父目录是符号链接：整条路径词法上仍在根内，真实路径却在根外。
	linkDir := filepath.Join(env.notesDir, "linkdir")
	if err := os.Symlink(outsideDir, linkDir); err != nil {
		t.Skipf("环境不支持符号链接，跳过: %v", err)
	}

	escapedGet := doRaw(t, env.handler, http.MethodGet, "/api/files/linkdir/secret.org", testToken, nil, nil)
	assertErrorCode(t, escapedGet, http.StatusBadRequest, "invalid_argument")

	escapedPut := putFile(t, env.handler, "/api/files/linkdir/new.org", "x\n", nil)
	assertErrorCode(t, escapedPut, http.StatusBadRequest, "invalid_argument")
	if _, err := os.Stat(filepath.Join(outsideDir, "new.org")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("根外目录被写入: err=%v", err)
	}

	created := writeFileOK(t, env.handler, "/api/files/a.org", "hello\n")
	uid := created["uid"].(string)
	move := do(t, env.handler, http.MethodPost, "/api/resources/"+uid+"/move", testToken,
		map[string]any{"to": "linkdir/moved.org"}, nil)
	assertErrorCode(t, move, http.StatusBadRequest, "invalid_argument")
	if _, err := os.Stat(filepath.Join(outsideDir, "moved.org")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("move 把文件搬到了根外: err=%v", err)
	}
}

// TestGetFileRangeLargeFile 验证大文件按 Range 只返回片段（流式响应）：
// 8 MiB 文件取 100 字节区间，206 + 正确的 Content-Range 与片段内容。
func TestGetFileRangeLargeFile(t *testing.T) {
	env := newFileEnv(t)

	const size = 8 << 20
	big := bytes.Repeat([]byte("abcdefgh"), size/8)
	if rec := putFile(t, env.handler, "/api/files/big.bin", string(big), nil); rec.Code != http.StatusCreated {
		t.Fatalf("写入大文件失败: %d %s", rec.Code, rec.Body.String())
	}

	head := doRaw(t, env.handler, http.MethodGet, "/api/files/big.bin", testToken, nil, nil)
	if head.Code != http.StatusOK {
		t.Fatalf("完整读取状态码 = %d, 期望 200", head.Code)
	}
	if head.Body.Len() != size {
		t.Errorf("完整读取长度 = %d, 期望 %d", head.Body.Len(), size)
	}
	if lm := head.Header().Get("Last-Modified"); lm == "" {
		t.Error("Last-Modified 不应为空（由 ServeContent 生成）")
	}

	part := doRaw(t, env.handler, http.MethodGet, "/api/files/big.bin", testToken, nil,
		map[string]string{"Range": "bytes=1024-1123"})
	if part.Code != http.StatusPartialContent {
		t.Fatalf("状态码 = %d, 期望 206 (body=%q)", part.Code, part.Body.String())
	}
	if want := fmt.Sprintf("bytes 1024-1123/%d", size); part.Header().Get("Content-Range") != want {
		t.Errorf("Content-Range = %q, 期望 %q", part.Header().Get("Content-Range"), want)
	}
	if !bytes.Equal(part.Body.Bytes(), big[1024:1124]) {
		t.Errorf("片段长度/内容不符: len=%d", part.Body.Len())
	}

	// 尾部后缀区间同样可用（ServeContent 语义），且不会把整个文件读进响应。
	tail := doRaw(t, env.handler, http.MethodGet, "/api/files/big.bin", testToken, nil,
		map[string]string{"Range": "bytes=-16"})
	if tail.Code != http.StatusPartialContent || !bytes.Equal(tail.Body.Bytes(), big[size-16:]) {
		t.Fatalf("后缀区间 = %d %q, 期望最后 16 字节", tail.Code, tail.Body.String())
	}
}

// TestPutFileIfNoneMatchStarDiskOnly 验证 If-None-Match: * 的存在性判据包含磁盘与
// 登记表两侧：
//   - 文件在磁盘上存在但未登记（旁路写入）→ 412，内容不变；
//   - 登记表有存活资源但磁盘文件被旁路删除 → 同样 412（不能把「身份已存在」当成新建）。
func TestPutFileIfNoneMatchStarDiskOnly(t *testing.T) {
	env := newFileEnv(t)

	ghost := filepath.Join(env.notesDir, "ghost.org")
	if err := os.WriteFile(ghost, []byte("ghost\n"), 0o644); err != nil {
		t.Fatalf("写入旁路文件失败: %v", err)
	}

	rec := putFile(t, env.handler, "/api/files/ghost.org", "v2\n",
		map[string]string{"If-None-Match": "*"})
	assertErrorCode(t, rec, http.StatusPreconditionFailed, "etag_mismatch")

	if content, err := os.ReadFile(ghost); err != nil || string(content) != "ghost\n" {
		t.Fatalf("412 后磁盘内容 = %q,%v, 期望保持不变", string(content), err)
	}

	// 反向情形：登记表存活、磁盘消失。
	writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")
	if err := os.Remove(filepath.Join(env.notesDir, "a.org")); err != nil {
		t.Fatalf("旁路删除文件失败: %v", err)
	}
	ghostOnly := putFile(t, env.handler, "/api/files/a.org", "v2\n",
		map[string]string{"If-None-Match": "*"})
	assertErrorCode(t, ghostOnly, http.StatusPreconditionFailed, "etag_mismatch")
	if _, err := os.Stat(filepath.Join(env.notesDir, "a.org")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("412 后仍创建了文件: err=%v", err)
	}
}

// TestPutFileIfMatchEmptyETagRejected 验证显式空 ETag（`If-Match: ""`）不会退化为
// 无条件写：空 etag 在 etagMatches 里永不匹配（既匹配已存在文件，也不匹配缺失文件）。
func TestPutFileIfMatchEmptyETagRejected(t *testing.T) {
	env := newFileEnv(t)
	writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")

	rec := putFile(t, env.handler, "/api/files/a.org", "v2\n", map[string]string{"If-Match": `""`})
	assertErrorCode(t, rec, http.StatusPreconditionFailed, "etag_mismatch")

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if read.Body.String() != "v1\n" {
		t.Fatalf("412 后内容 = %q, 期望保持不变 v1", read.Body.String())
	}

	missing := putFile(t, env.handler, "/api/files/new.org", "x\n", map[string]string{"If-Match": `""`})
	assertErrorCode(t, missing, http.StatusPreconditionFailed, "etag_mismatch")
}

// TestDeleteDirectorySubtreeConvergence 验证目录删除只收敛到该子树：名字共享前缀的
// 兄弟目录（"dir2" 之于 "dir"）不能被一起写墓碑。
func TestDeleteDirectorySubtreeConvergence(t *testing.T) {
	env := newFileEnv(t)
	first := writeFileOK(t, env.handler, "/api/files/dir/a.org", "A\n")
	sibling := writeFileOK(t, env.handler, "/api/files/dir2/b.org", "B\n")

	rec := doRaw(t, env.handler, http.MethodDelete, "/api/files/dir", testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	uids, ok := body["uids"].([]any)
	if !ok || len(uids) != 1 || uids[0] != first["uid"] {
		t.Fatalf("uids = %v, 期望仅含 %v（不收兄弟目录）", body["uids"], first["uid"])
	}

	read := doRaw(t, env.handler, http.MethodGet, "/api/files/dir2/b.org", testToken, nil, nil)
	if read.Code != http.StatusOK || read.Body.String() != "B\n" {
		t.Fatalf("兄弟目录文件被误删: %d %q", read.Code, read.Body.String())
	}
	res := do(t, env.handler, http.MethodGet, "/api/resources/"+sibling["uid"].(string), testToken, nil, nil)
	if res.Code != http.StatusOK {
		t.Fatalf("兄弟目录资源登记被误墓碑: %d %s", res.Code, res.Body.String())
	}

	if ops := opsOf(changes(t, env.handler)); len(ops) != 3 ||
		ops[0] != "create" || ops[1] != "create" || ops[2] != "delete" {
		t.Fatalf("变更事件 = %v, 期望 [create create delete]", ops)
	}
}

// TestPutFileConcurrentSameIfMatch 验证条件写与写入同处一个临界区：
// 两个并发的相同 If-Match PUT，恰好一个 200、另一个 412，落盘内容属于胜出者。
func TestPutFileConcurrentSameIfMatch(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")
	headers := map[string]string{"If-Match": `"` + created["etag"].(string) + `"`}

	bodies := []string{"v2\n", "v3\n"}
	codes := make([]int, len(bodies))
	var wg sync.WaitGroup
	for i := range bodies {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			rec := doRaw(t, env.handler, http.MethodPut, "/api/files/a.org", testToken,
				[]byte(bodies[i]), headers)
			codes[i] = rec.Code
		}(i)
	}
	wg.Wait()

	ok, conflict := 0, 0
	for _, code := range codes {
		switch code {
		case http.StatusOK:
			ok++
		case http.StatusPreconditionFailed:
			conflict++
		default:
			t.Fatalf("并发 PUT 状态码 = %d, 期望 200 或 412", code)
		}
	}
	if ok != 1 || conflict != 1 {
		t.Fatalf("并发 If-Match PUT: 200=%d 412=%d, 期望各 1", ok, conflict)
	}

	content, err := os.ReadFile(filepath.Join(env.notesDir, "a.org"))
	if err != nil {
		t.Fatalf("读取落盘内容失败: %v", err)
	}
	if string(content) != bodies[0] && string(content) != bodies[1] {
		t.Fatalf("落盘内容 = %q, 期望为胜出者的内容之一", string(content))
	}
}

// TestPutFileIfMatchAndIfNoneMatchBothChecked 验证 If-Match 与 If-None-Match 同时
// 出现时两者都校验（修复前是 switch 二选一，复合前提被静默放宽成单条件）：
//   - If-Match 匹配 + If-None-Match: *：* 要求「不存在」与「内容匹配」互斥 → 412；
//   - If-Match 匹配 + If-None-Match 等于当前 ETag：If-None-Match 不满足 → 412；
//   - If-Match 匹配 + If-None-Match 指向别的 ETag：两个前提都成立 → 200。
func TestPutFileIfMatchAndIfNoneMatchBothChecked(t *testing.T) {
	env := newFileEnv(t)
	created := writeFileOK(t, env.handler, "/api/files/a.org", "v1\n")
	etag := created["etag"].(string)

	// 1) If-Match 正确 + If-None-Match: *（要求目标不存在）→ 412。
	conflict := putFile(t, env.handler, "/api/files/a.org", "v2\n", map[string]string{
		"If-Match":      `"` + etag + `"`,
		"If-None-Match": "*",
	})
	assertErrorCode(t, conflict, http.StatusPreconditionFailed, "etag_mismatch")

	// 2) If-Match 正确 + If-None-Match 恰是当前 ETag → 412（If-None-Match 不满足）。
	sameETag := putFile(t, env.handler, "/api/files/a.org", "v3\n", map[string]string{
		"If-Match":      `"` + etag + `"`,
		"If-None-Match": `"` + etag + `"`,
	})
	assertErrorCode(t, sameETag, http.StatusPreconditionFailed, "etag_mismatch")

	// 两次被拒都不得改动内容。
	read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil)
	if read.Code != http.StatusOK || read.Body.String() != "v1\n" {
		t.Fatalf("412 后读取 = %d %q, 期望 200 v1", read.Code, read.Body.String())
	}

	// 3) 两个前提同时成立：If-Match 命中当前内容，If-None-Match 指向另一个 ETag → 200。
	both := putFile(t, env.handler, "/api/files/a.org", "v4\n", map[string]string{
		"If-Match":      `"` + etag + `"`,
		"If-None-Match": `"deadbeef"`,
	})
	if both.Code != http.StatusOK {
		t.Fatalf("两个前提都成立时状态码 = %d, 期望 200 (body=%q)", both.Code, both.Body.String())
	}
	if read := doRaw(t, env.handler, http.MethodGet, "/api/files/a.org", testToken, nil, nil); read.Body.String() != "v4\n" {
		t.Fatalf("写入后内容 = %q, 期望 v4", read.Body.String())
	}
}

// TestFilesRejectSymlinkAliasInsideRoot 验证父目录链中出现指向根内的软链（alias ->
// real，两者都在根内）也被拒：uid 与物理路径必须一一对应，否则同一实体会有两个
// 逻辑路径，登记表只认其中一个。
//
// 断言：别名路径的 GET/PUT/DELETE 一律 400 invalid_argument；真实路径读写正常；
// 被拒的写不产生任何副作用（真实文件内容不变）。
func TestFilesRejectSymlinkAliasInsideRoot(t *testing.T) {
	env := newFileEnv(t)

	realDir := filepath.Join(env.notesDir, "real")
	if err := os.MkdirAll(realDir, 0o755); err != nil {
		t.Fatalf("创建真实目录失败: %v", err)
	}
	writeFileOK(t, env.handler, "/api/files/real/x.org", "baseline\n")

	// 相对软链，目标在根内（不同于既有用例的「指向根外」）。
	if err := os.Symlink("real", filepath.Join(env.notesDir, "alias")); err != nil {
		t.Skipf("环境不支持符号链接，跳过: %v", err)
	}

	getAlias := doRaw(t, env.handler, http.MethodGet, "/api/files/alias/x.org", testToken, nil, nil)
	assertErrorCode(t, getAlias, http.StatusBadRequest, "invalid_argument")

	putAlias := putFile(t, env.handler, "/api/files/alias/x.org", "hijack\n", nil)
	assertErrorCode(t, putAlias, http.StatusBadRequest, "invalid_argument")

	delAlias := doRaw(t, env.handler, http.MethodDelete, "/api/files/alias/x.org", testToken, nil, nil)
	assertErrorCode(t, delAlias, http.StatusBadRequest, "invalid_argument")

	// 深层别名（alias 之下的子目录）同样被拒。
	putDeep := putFile(t, env.handler, "/api/files/alias/sub/y.org", "y\n", nil)
	assertErrorCode(t, putDeep, http.StatusBadRequest, "invalid_argument")

	// 真实路径不受影响：可读、内容未被别名写入污染。
	getReal := doRaw(t, env.handler, http.MethodGet, "/api/files/real/x.org", testToken, nil, nil)
	if getReal.Code != http.StatusOK || getReal.Body.String() != "baseline\n" {
		t.Fatalf("真实路径读取 = %d %q, 期望 200 baseline", getReal.Code, getReal.Body.String())
	}
	content, err := os.ReadFile(filepath.Join(realDir, "x.org"))
	if err != nil {
		t.Fatalf("读取真实文件失败: %v", err)
	}
	if string(content) != "baseline\n" {
		t.Fatalf("真实文件被别名路径改动: %q", string(content))
	}
	if _, err := os.Stat(filepath.Join(realDir, "sub")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("别名路径的写入落到了真实目录: err=%v", err)
	}
}

// TestPutFileDanglingSymlinkParent 验证父目录是悬空软链时返回 400 而不是 500：
// 逐级 Lstat 对悬空链同样成功且模式为 symlink，故在拼路径阶段就被拒绝，
// 不会走到 open/WriteFile 后抛 ENOENT 变成服务端错误。
func TestPutFileDanglingSymlinkParent(t *testing.T) {
	env := newFileEnv(t)

	dangling := filepath.Join(env.notesDir, "dangling")
	if err := os.Symlink(filepath.Join(t.TempDir(), "nonexistent", "dir"), dangling); err != nil {
		t.Skipf("环境不支持符号链接，跳过: %v", err)
	}

	put := putFile(t, env.handler, "/api/files/dangling/x.org", "x\n", nil)
	assertErrorCode(t, put, http.StatusBadRequest, "invalid_argument")

	// 读侧同样是 400（写侧用 400 明示非法参数，读侧此处也走同一条父目录链检查）。
	get := doRaw(t, env.handler, http.MethodGet, "/api/files/dangling/x.org", testToken, nil, nil)
	assertErrorCode(t, get, http.StatusBadRequest, "invalid_argument")

	// 目标软链本身未被删除或替换。
	if info, err := os.Lstat(dangling); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("悬空软链被改动: %v,%v", info, err)
	}
}

// TestGetFileActiveContentForcedDownload 验证存储型 XSS 链被切断：主动内容
// （.html/.svg/.js/.xml 等）一律降级为 application/octet-stream + attachment，
// 且所有文件下载都带 nosniff；被动内容（.org）保持原有 Content-Type 且不被
// 强制下载。
func TestGetFileActiveContentForcedDownload(t *testing.T) {
	env := newFileEnv(t)

	const payload = `<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`
	evil := []string{
		"evil.svg", "evil.html", "evil.js", "evil.xml", "evil.mjs", "evil.xhtml", "evil.xsl", "evil.htm",
		// Go 内建 MIME 会把 .shtml/.ehtml 映射为 text/html、.xht 映射为
		// application/xhtml+xml，显式声明下 nosniff 不再兜底，故都必须在黑名单里。
		"evil.shtml", "evil.ehtml", "evil.xht", "evil.svgz", "evil.mht", "evil.rdf",
	}
	for _, name := range evil {
		if rec := putFile(t, env.handler, "/api/files/"+name, payload, nil); rec.Code != http.StatusCreated {
			t.Fatalf("写入 %s 失败: %d %s", name, rec.Code, rec.Body.String())
		}
	}

	for _, name := range evil {
		rec := doRaw(t, env.handler, http.MethodGet, "/api/files/"+name, testToken, nil, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("读取 %s 状态码 = %d, 期望 200", name, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/octet-stream" {
			t.Errorf("%s Content-Type = %q, 期望 application/octet-stream（主动内容强制降级）", name, ct)
		}
		wantDisp := `attachment; filename="` + name + `"`
		if cd := rec.Header().Get("Content-Disposition"); cd != wantDisp {
			t.Errorf("%s Content-Disposition = %q, 期望 %q", name, cd, wantDisp)
		}
		if nosniff := rec.Header().Get("X-Content-Type-Options"); nosniff != "nosniff" {
			t.Errorf("%s X-Content-Type-Options = %q, 期望 nosniff", name, nosniff)
		}
		// 内容本身仍可下载（读端点不能被降级为「不返回内容」）。
		if rec.Body.String() != payload {
			t.Errorf("%s 响应体 = %q, 期望与写入内容一致", name, rec.Body.String())
		}
	}

	// 被动内容：Content-Type 保持按扩展名推断（.org => text/org; charset=utf-8，
	// 具体取值由 mime 库决定），且不得被强制下载。
	writeFileOK(t, env.handler, "/api/files/note.org", "* 标题\n")
	note := doRaw(t, env.handler, http.MethodGet, "/api/files/note.org", testToken, nil, nil)
	if note.Code != http.StatusOK {
		t.Fatalf("读取 note.org 状态码 = %d, 期望 200", note.Code)
	}
	wantCT := mime.TypeByExtension(".org")
	if wantCT == "" {
		wantCT = "application/octet-stream"
	}
	if ct := note.Header().Get("Content-Type"); ct != wantCT {
		t.Errorf("note.org Content-Type = %q, 期望 %q（被动内容不得降级）", ct, wantCT)
	}
	if cd := note.Header().Get("Content-Disposition"); cd != "" {
		t.Errorf("note.org Content-Disposition = %q, 期望为空（被动内容不强制下载）", cd)
	}
	if nosniff := note.Header().Get("X-Content-Type-Options"); nosniff != "nosniff" {
		t.Errorf("note.org X-Content-Type-Options = %q, 期望 nosniff（所有下载一律设置）", nosniff)
	}
}

// TestGetFileContentDispositionSanitizesFilename 验证下载文件名的头注入面：
// filename 只取路径最后一段，且引号/反斜杠/控制字符被替换，故文件名里的 " 不会
// 提前闭合参数，也不会引入进新的响应头。
func TestGetFileContentDispositionSanitizesFilename(t *testing.T) {
	env := newFileEnv(t)

	// 引号以 %22 传入（HTTP 头里的裸引号用户可控，这是真实攻击面）。
	const target = "/api/files/ev%22il.svg"
	if rec := putFile(t, env.handler, target, "<svg/>", nil); rec.Code != http.StatusCreated {
		t.Fatalf("写入带引号文件名失败: %d %s", rec.Code, rec.Body.String())
	}

	rec := doRaw(t, env.handler, http.MethodGet, target, testToken, nil, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("读取状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}

	cd := rec.Header().Get("Content-Disposition")
	if want := `attachment; filename="ev_il.svg"`; cd != want {
		t.Errorf("Content-Disposition = %q, 期望 %q（文件名内的引号必须被替换）", cd, want)
	}
	if strings.Count(cd, `"`) != 2 {
		t.Errorf("Content-Disposition = %q, 期望恰好一对引号", cd)
	}
	for _, r := range cd {
		if r == '\r' || r == '\n' || r < 0x20 || r == 0x7f {
			t.Fatalf("Content-Disposition 含控制字符（头注入）: %q", cd)
		}
	}
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Error("X-Content-Type-Options 缺失")
	}
}
