// 本文件是 cmd/server 的进程内集成测试（M7 任务 A7）：用 httptest.NewServer 架起
// 真实 buildMux 返回的 mux，对「WebDAV 写 → registry 登记 → REST 读」的端到端契约
// 断言，覆盖批次 A 的交付（schema v6 + registry + gitver.Head + WebDAV 钩子 +
// 四个只读端点 + main 装配）。
//
// 取舍说明（集成测试 vs 起真实进程 + curl）：httptest 走的是同一条 buildMux 装配
// 路径与同一套认证中间件/写后钩子链，只是把「监听真实端口」换成了内存 listener。
// 好处是无端口占用、无进程生命周期与端口等待循环、不依赖外部 curl，因此可作为长期
// 回归测试留在仓库里（go test ./... 即覆盖）；差别仅在于不验证 main 的配置加载、
// 信号处理与监听参数，那些不属于批次 A 的对外契约。
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"seshat/internal/auth"
	"seshat/internal/config"
	"seshat/internal/gitver"
	"seshat/internal/index"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

const (
	// testToken 是测试用主访问令牌（REST 走 Bearer、WebDAV 走 Basic 的密码部分）。
	testToken = "test-token"
	// testBasicUser 是 WebDAV Basic 认证的用户名；服务端只校验密码部分的令牌，
	// 用户名任意，此处固定为 seshat 以贴合真实客户端形态。
	testBasicUser = "seshat"
	// testRootTag 是笔记根的逻辑标签，与 main.go 的 roots[0].Tag 一致。
	testRootTag = "notes"
)

// 认证方式枚举（doRequest 的 authKind 参数取值）。
const (
	authNone   = "none"
	authBearer = "bearer"
	authBasic  = "basic"
)

// resourceItem 是 GET /api/resources 单项的测试侧投影（只取断言需要的字段）。
type resourceItem struct {
	UID       string `json:"uid"`
	Root      string `json:"root"`
	Path      string `json:"path"`
	DeletedAt string `json:"deleted_at"`
}

// resourceList 是 GET /api/resources 的响应体。
type resourceList struct {
	Items   []resourceItem `json:"items"`
	HasMore bool           `json:"has_more"`
}

// changeItem 是 GET /api/changes 单条事件的测试侧投影。
type changeItem struct {
	Seq     int64  `json:"seq"`
	UID     string `json:"uid"`
	Op      string `json:"op"`
	Root    string `json:"root"`
	Path    string `json:"path"`
	OldPath string `json:"old_path"`
}

// changeList 是 GET /api/changes 的响应体。
type changeList struct {
	Changes    []changeItem `json:"changes"`
	NextCursor int64        `json:"next_cursor"`
	HasMore    bool         `json:"has_more"`
}

// errorBody 是统一错误体。
type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// newTestEnv 在临时目录里搭一套完整的服务依赖（临时 SQLite + 临时笔记根 + git 仓库 +
// FTS 索引 + registry），跑一次 bootstrap，然后用 buildMux 组装真实 mux 并交给
// httptest.Server 提供 HTTP 服务。
//
// 笔记根里预置 a.org（内容 v1），使 bootstrap 先登记一次；后续步骤仍按「PUT 新建 →
// PUT 覆盖 → MOVE → DELETE」顺序驱动，与真实客户端的写入路径一致。
func newTestEnv(t *testing.T) (*httptest.Server, *registry.Service, *storage.DB, string) {
	t.Helper()

	dir := t.TempDir()
	db, err := storage.Open(filepath.Join(dir, "test.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}

	root := filepath.Join(dir, "notes")
	if err := os.MkdirAll(root, 0o755); err != nil {
		_ = db.Close()
		t.Fatalf("创建笔记根 %s 失败: %v", root, err)
	}
	if err := os.WriteFile(filepath.Join(root, "a.org"), []byte("v1"), 0o644); err != nil {
		_ = db.Close()
		t.Fatalf("写入初始文件 a.org 失败: %v", err)
	}

	repo, err := gitver.Open(root)
	if err != nil {
		_ = db.Close()
		t.Fatalf("初始化 git 版本库失败: %v", err)
	}

	indexer := index.New(db)
	reg := registry.New(db, repo)
	roots := []registry.Root{{Tag: testRootTag, Path: root, Mode: registry.RootModeMirror}}
	if err := reg.SetRoots(roots); err != nil {
		_ = db.Close()
		t.Fatalf("设置根映射失败: %v", err)
	}
	if _, err := reg.Bootstrap(context.Background(), roots); err != nil {
		_ = db.Close()
		t.Fatalf("启动登记失败: %v", err)
	}

	// Public 留空：跳过对外出口，本测试只覆盖内部 WebDAV 出口（/dav/）。
	// Roots 必须与上面 reg.SetRoots 的清单一致：M7 B2 起 buildMux 的路径基准（内部
	// WebDAV 挂载根、public 出口偏移）取 cfg.WebDAV.Roots[0].Path，夹具补齐该字段属于
	// 「同步调用点」而非放宽断言。
	cfg := &config.Config{WebDAV: config.WebDAVConfig{
		Root:   root,
		Public: "",
		Roots:  []config.RootConfig{{Tag: testRootTag, Path: root, Mode: config.RootModeMirror}},
	}}
	mux, err := buildMux(cfg, db, repo, indexer, reg,
		auth.New(testToken), auth.NewWithNodeToken(testToken, ""))
	if err != nil {
		_ = db.Close()
		t.Fatalf("buildMux 失败: %v", err)
	}

	srv := httptest.NewServer(mux)
	t.Cleanup(func() {
		srv.Close()
		_ = db.Close()
	})
	return srv, reg, db, root
}

// basicHeader 构造 WebDAV 的 Basic 认证头（base64(user:token)）。
func basicHeader(user, token string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+token))
}

// doRequest 按指定方式认证后发起请求，返回响应与响应体。
// authKind 取 authNone / authBearer / authBasic。
func doRequest(t *testing.T, method, rawURL string, body []byte, authKind string) (*http.Response, []byte) {
	t.Helper()
	return doRequestWithHeaders(t, method, rawURL, body, authKind, nil)
}

// doRequestWithHeaders 在 doRequest 基础上附加请求头（MOVE 的 Destination 等）。
func doRequestWithHeaders(t *testing.T, method, rawURL string, body []byte, authKind string, headers map[string]string) (*http.Response, []byte) {
	t.Helper()

	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, rawURL, reader)
	if err != nil {
		t.Fatalf("构造 %s %s 请求失败: %v", method, rawURL, err)
	}
	switch authKind {
	case authBearer:
		req.Header.Set("Authorization", "Bearer "+testToken)
	case authBasic:
		req.Header.Set("Authorization", basicHeader(testBasicUser, testToken))
	case authNone:
		// 不设置认证头，用于验证 401。
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s 请求失败: %v", method, rawURL, err)
	}
	defer func() { _ = resp.Body.Close() }()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取 %s %s 响应体失败: %v", method, rawURL, err)
	}
	return resp, data
}

// decodeResourceList 解析 GET /api/resources 的响应体。
func decodeResourceList(t *testing.T, data []byte) resourceList {
	t.Helper()
	var list resourceList
	if err := json.Unmarshal(data, &list); err != nil {
		t.Fatalf("解析 resources 响应失败: %v（响应体 %s）", err, data)
	}
	return list
}

// decodeChangeList 解析 GET /api/changes 的响应体。
func decodeChangeList(t *testing.T, data []byte) changeList {
	t.Helper()
	var list changeList
	if err := json.Unmarshal(data, &list); err != nil {
		t.Fatalf("解析 changes 响应失败: %v（响应体 %s）", err, data)
	}
	return list
}

// decodeErrorCode 解析统一错误体里的 error.code。
func decodeErrorCode(t *testing.T, data []byte) string {
	t.Helper()
	var body errorBody
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatalf("解析错误响应失败: %v（响应体 %s）", err, data)
	}
	return body.Error.Code
}

// TestBuildMuxBatchAEndToEnd 是批次 A 的端到端验收：11 步顺序断言，共同覆盖
// 「uid 跨改名稳定」「删除写墓碑」「changes seq 连续」「uid 校验与错误码」四类不变量。
func TestBuildMuxBatchAEndToEnd(t *testing.T) {
	srv, _, _, root := newTestEnv(t)

	// uid1 在步骤 2 取得，后续步骤跨子测试复用（各子测试顺序执行，不并行）。
	var uid1 string

	t.Run("步骤1_WebDAV_PUT_新建", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodPut, srv.URL+"/dav/a.org", []byte("v1"), authBasic)
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			t.Fatalf("PUT /dav/a.org 状态码 = %d，期望 2xx（响应体 %s）", resp.StatusCode, body)
		}
	})

	t.Run("步骤2_REST_清单取得_uid", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodGet,
			srv.URL+"/api/resources?root="+testRootTag+"&prefix=a.org", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/resources 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeResourceList(t, body)
		if len(list.Items) != 1 {
			t.Fatalf("items 长度 = %d，期望 1（响应体 %s）", len(list.Items), body)
		}
		item := list.Items[0]
		if item.Path != "a.org" {
			t.Fatalf("items[0].path = %q，期望 %q", item.Path, "a.org")
		}
		if item.Root != testRootTag {
			t.Fatalf("items[0].root = %q，期望 %q", item.Root, testRootTag)
		}
		if !registry.IsUID(item.UID) {
			t.Fatalf("items[0].uid = %q，不符合 26 位 Crockford Base32 形态", item.UID)
		}
		uid1 = item.UID
		t.Logf("步骤2 实际值：uid=%s path=%s root=%s", item.UID, item.Path, item.Root)
	})

	t.Run("步骤3_PUT_覆盖_uid_不变", func(t *testing.T) {
		if uid1 == "" {
			t.Fatalf("前序步骤未取得 uid1，无法断言 uid 稳定性")
		}
		resp, body := doRequest(t, http.MethodPut, srv.URL+"/dav/a.org", []byte("v2"), authBasic)
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			t.Fatalf("覆盖 PUT /dav/a.org 状态码 = %d，期望 2xx（响应体 %s）", resp.StatusCode, body)
		}

		resp, body = doRequest(t, http.MethodGet,
			srv.URL+"/api/resources?root="+testRootTag+"&prefix=a.org", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("覆盖后 GET /api/resources 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeResourceList(t, body)
		if len(list.Items) != 1 {
			t.Fatalf("覆盖后 items 长度 = %d，期望 1（响应体 %s）", len(list.Items), body)
		}
		if got := list.Items[0].UID; got != uid1 {
			t.Fatalf("覆盖后 uid = %q，期望与首次 uid %q 相同", got, uid1)
		}
	})

	t.Run("步骤4_MOVE_后_uid_不变且路径更新", func(t *testing.T) {
		if uid1 == "" {
			t.Fatalf("前序步骤未取得 uid1，无法断言改名后 uid 稳定性")
		}
		resp, body := doRequestWithHeaders(t, "MOVE", srv.URL+"/dav/a.org", nil, authBasic,
			map[string]string{"Destination": srv.URL + "/dav/b.org"})
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			t.Fatalf("MOVE /dav/a.org → /dav/b.org 状态码 = %d，期望 2xx（响应体 %s）", resp.StatusCode, body)
		}

		resp, body = doRequest(t, http.MethodGet, srv.URL+"/api/resources?root="+testRootTag, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("MOVE 后 GET /api/resources 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeResourceList(t, body)
		if len(list.Items) != 1 {
			t.Fatalf("MOVE 后 items 长度 = %d，期望 1（响应体 %s）", len(list.Items), body)
		}
		item := list.Items[0]
		if item.UID != uid1 {
			t.Fatalf("MOVE 后 uid = %q，期望改名前的 %q（改名不得改变身份）", item.UID, uid1)
		}
		if item.Path != "b.org" {
			t.Fatalf("MOVE 后 path = %q，期望 %q", item.Path, "b.org")
		}
	})

	t.Run("步骤5_DELETE_写墓碑", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodDelete, srv.URL+"/dav/b.org", nil, authBasic)
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			t.Fatalf("DELETE /dav/b.org 状态码 = %d，期望 2xx（响应体 %s）", resp.StatusCode, body)
		}
		if _, statErr := os.Stat(filepath.Join(root, "b.org")); !os.IsNotExist(statErr) {
			t.Fatalf("DELETE 后磁盘上仍存在 b.org（stat 错误 = %v）", statErr)
		}

		// 默认视图不含墓碑。
		resp, body = doRequest(t, http.MethodGet, srv.URL+"/api/resources?root="+testRootTag, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("DELETE 后 GET /api/resources 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		if list := decodeResourceList(t, body); len(list.Items) != 0 {
			t.Fatalf("DELETE 后默认视图 items 长度 = %d，期望 0（响应体 %s）", len(list.Items), body)
		}

		// include_deleted=true 时应看到一条墓碑。
		resp, body = doRequest(t, http.MethodGet,
			srv.URL+"/api/resources?root="+testRootTag+"&include_deleted=true", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/resources?include_deleted=true 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeResourceList(t, body)
		if len(list.Items) != 1 {
			t.Fatalf("含墓碑视图 items 长度 = %d，期望 1（响应体 %s）", len(list.Items), body)
		}
		if list.Items[0].DeletedAt == "" {
			t.Fatalf("含墓碑视图的 deleted_at 为空串，期望 RFC3339 时间戳（响应体 %s）", body)
		}
		if list.Items[0].UID != uid1 {
			t.Fatalf("墓碑 uid = %q，期望删除前的 %q", list.Items[0].UID, uid1)
		}
	})

	// nextCursor 在步骤 6 取得，步骤 7 用它验证「无新事件时游标不倒退」。
	var nextCursor int64

	t.Run("步骤6_changes_seq_连续", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodGet, srv.URL+"/api/changes?since=0", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/changes 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeChangeList(t, body)
		if len(list.Changes) < 4 {
			t.Fatalf("changes 条数 = %d，期望至少 4（create/update、update、rename、delete）（响应体 %s）",
				len(list.Changes), body)
		}

		ops := make(map[string]int, 4)
		for i, c := range list.Changes {
			if c.Seq != int64(i+1) {
				t.Fatalf("第 %d 条变更 seq = %d，期望 %d（seq 必须从 1 起连续递增无空洞）",
					i, c.Seq, i+1)
			}
			ops[c.Op]++
			if c.Root != testRootTag {
				t.Fatalf("seq %d 的 root = %q，期望 %q", c.Seq, c.Root, testRootTag)
			}
			if c.UID != uid1 {
				t.Fatalf("seq %d 的 uid = %q，期望全程为 %q", c.Seq, c.UID, uid1)
			}
			switch c.Op {
			case "rename":
				if c.OldPath != "a.org" || c.Path != "b.org" {
					t.Fatalf("rename 事件的 old_path/path = %q/%q，期望 %q/%q",
						c.OldPath, c.Path, "a.org", "b.org")
				}
			case "delete":
				if c.Path != "b.org" {
					t.Fatalf("delete 事件的 path = %q，期望删除前路径 %q", c.Path, "b.org")
				}
			}
		}

		// op 覆盖：写入类事件（create 或 update）+ rename + delete 都必须出现。
		if ops["update"] == 0 && ops["create"] == 0 {
			t.Fatalf("op 序列 %v 既无 update 也无 create，期望包含写入事件", ops)
		}
		if ops["rename"] != 1 {
			t.Fatalf("rename 事件数 = %d，期望 1（op 序列 %v）", ops["rename"], ops)
		}
		if ops["delete"] != 1 {
			t.Fatalf("delete 事件数 = %d，期望 1（op 序列 %v）", ops["delete"], ops)
		}

		last := list.Changes[len(list.Changes)-1]
		if list.NextCursor != last.Seq {
			t.Fatalf("next_cursor = %d，期望等于最后一条 seq %d", list.NextCursor, last.Seq)
		}
		if list.HasMore {
			t.Fatalf("has_more = true，期望 false（事件总数未触及 limit）")
		}
		nextCursor = list.NextCursor
		t.Logf("步骤6 实际值：%d 条事件，seq %d..%d，op 计数 %v，next_cursor=%d",
			len(list.Changes), list.Changes[0].Seq, last.Seq, ops, list.NextCursor)
	})

	t.Run("步骤7_since_游标无新事件", func(t *testing.T) {
		if nextCursor == 0 {
			t.Fatalf("前序步骤未取得 next_cursor")
		}
		resp, body := doRequest(t, http.MethodGet,
			srv.URL+"/api/changes?since="+strconv.FormatInt(nextCursor, 10), nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/changes?since=%d 状态码 = %d，期望 200（响应体 %s）", nextCursor, resp.StatusCode, body)
		}
		list := decodeChangeList(t, body)
		if len(list.Changes) != 0 {
			t.Fatalf("since=%d 的 changes 长度 = %d，期望 0（响应体 %s）", nextCursor, len(list.Changes), body)
		}
		if list.NextCursor != nextCursor {
			t.Fatalf("空批次的 next_cursor = %d，期望回传请求的 since %d（游标不得倒退）",
				list.NextCursor, nextCursor)
		}
		if list.HasMore {
			t.Fatalf("空批次的 has_more = true，期望 false")
		}
	})

	t.Run("步骤8_已墓碑_uid_返回_unknown_uid", func(t *testing.T) {
		if uid1 == "" {
			t.Fatalf("前序步骤未取得 uid1")
		}
		resp, body := doRequest(t, http.MethodGet, srv.URL+"/api/resources/"+uid1, nil, authBearer)
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("GET /api/resources/%s 状态码 = %d，期望 404（响应体 %s）", uid1, resp.StatusCode, body)
		}
		if code := decodeErrorCode(t, body); code != "unknown_uid" {
			t.Fatalf("error.code = %q，期望 %q（响应体 %s）", code, "unknown_uid", body)
		}
	})

	t.Run("步骤9_非法_uid_返回_invalid_uid", func(t *testing.T) {
		invalid := strings.Repeat("A", 25) // 25 位：形态非法（要求 26 位）
		resp, body := doRequest(t, http.MethodGet, srv.URL+"/api/resources/"+invalid, nil, authBearer)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("GET /api/resources/%s 状态码 = %d，期望 400（响应体 %s）", invalid, resp.StatusCode, body)
		}
		if code := decodeErrorCode(t, body); code != "invalid_uid" {
			t.Fatalf("error.code = %q，期望 %q（响应体 %s）", code, "invalid_uid", body)
		}
	})

	t.Run("步骤10_无认证_返回_401", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodGet, srv.URL+"/api/resources", nil, authNone)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("无认证 GET /api/resources 状态码 = %d，期望 401（响应体 %s）", resp.StatusCode, body)
		}
		if got := resp.Header.Get("WWW-Authenticate"); !strings.Contains(got, "Bearer") {
			t.Fatalf("WWW-Authenticate = %q，期望包含 Bearer", got)
		}
	})

	t.Run("步骤11_resolve_未登记路径_返回_unknown_uid", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodGet,
			srv.URL+"/api/resolve?root="+testRootTag+"&path=nope.org", nil, authBearer)
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("GET /api/resolve 未登记路径状态码 = %d，期望 404（响应体 %s）", resp.StatusCode, body)
		}
		if code := decodeErrorCode(t, body); code != "unknown_uid" {
			t.Fatalf("error.code = %q，期望 %q（响应体 %s）", code, "unknown_uid", body)
		}
	})
}

// 以下为批次 B（M7 B1–B6）的端到端验收：多根清单、REST 写 → uid 状态链路、批注、
// 书库只读根、rescan 墓碑与 changes 游标。所有夹具都建立在进程内 httptest 之上
// （同批次 A 的取舍），不启动真实进程、不使用 curl。

const (
	// testEbooksTag 是书库根（ondemand 模式）的逻辑标签。
	testEbooksTag = "ebooks"
	// testEbookContent 是预置书库文件的字节内容：GET /api/files 需原样读回，
	// 且「写被 403 拒绝后内容未变」这条断言依赖它是一个确定值。
	testEbookContent = "EPUB-BYTES-FOR-READONLY-ROOT"
)

// batchBRootItem 是 GET /api/roots 单个根的测试侧投影。
//
// 故意声明 Path 字段：响应若不慎带上物理路径，这里能解出非空值从而断言失败，
// 而不是靠肉眼比对 JSON。
type batchBRootItem struct {
	Tag     string `json:"tag"`
	Mode    string `json:"mode"`
	Default bool   `json:"default"`
	Path    string `json:"path"`
}

// batchBRootList 是 GET /api/roots 的响应体。
type batchBRootList struct {
	Roots []batchBRootItem `json:"roots"`
}

// batchBFileWrite 是 PUT /api/files/{path...} 的响应投影。
type batchBFileWrite struct {
	UID     string `json:"uid"`
	Root    string `json:"root"`
	Path    string `json:"path"`
	Created bool   `json:"created"`
	Seq     int64  `json:"seq"`
}

// batchBProgress 是进度端点的响应投影。document_id 字段已随 M7 删除，故意不声明：
// 另以「解析为 map 后检查键不存在」的方式断言其未被重新引入。
type batchBProgress struct {
	UID       string `json:"uid"`
	Position  string `json:"position"`
	UpdatedAt string `json:"updated_at"`
}

// batchBAnnotation 是批注端点的响应投影。
type batchBAnnotation struct {
	ID       int64  `json:"id"`
	UID      string `json:"uid"`
	Location string `json:"location"`
	Text     string `json:"text"`
}

// batchBRescan 是 POST /api/resources/rescan 的响应投影（只含计数）。
type batchBRescan struct {
	Scanned   int `json:"scanned"`
	Created   int `json:"created"`
	Updated   int `json:"updated"`
	Unchanged int `json:"unchanged"`
	Deleted   int `json:"deleted"`
	Failed    int `json:"failed"`
}

// newTestEnvMultiRoot 与 newTestEnv 同构，但搭两个根：笔记根（mirror，预置 a.org）
// 与书库根（ondemand，预置 book.epub），供批次 B 的多根 / 只读根 / rescan 场景使用。
//
// 之所以新增 helper 而不改 newTestEnv：批次 A 的用例依赖「只登记一个根」的夹具
// （例如 /api/resources?root=notes 期望恰好 1 条），改签名或行为会让那些断言失真。
func newTestEnvMultiRoot(t *testing.T) (srv *httptest.Server, reg *registry.Service, db *storage.DB, notesRoot, ebooksRoot string) {
	t.Helper()

	dir := t.TempDir()
	db, err := storage.Open(filepath.Join(dir, "test.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}

	// 笔记根：mirror 模式，进 git / FTS，是 WebDAV 的内部挂载点。
	notesRoot = filepath.Join(dir, "notes")
	if err := os.MkdirAll(notesRoot, 0o755); err != nil {
		_ = db.Close()
		t.Fatalf("创建笔记根 %s 失败: %v", notesRoot, err)
	}
	if err := os.WriteFile(filepath.Join(notesRoot, "a.org"), []byte("v1"), 0o644); err != nil {
		_ = db.Close()
		t.Fatalf("写入初始文件 a.org 失败: %v", err)
	}

	// 书库根：ondemand 模式，不进 git、不挂 WebDAV，只经 REST 按需读取。
	ebooksRoot = filepath.Join(dir, "ebooks")
	if err := os.MkdirAll(ebooksRoot, 0o755); err != nil {
		_ = db.Close()
		t.Fatalf("创建书库根 %s 失败: %v", ebooksRoot, err)
	}
	if err := os.WriteFile(filepath.Join(ebooksRoot, "book.epub"), []byte(testEbookContent), 0o644); err != nil {
		_ = db.Close()
		t.Fatalf("写入初始文件 book.epub 失败: %v", err)
	}

	repo, err := gitver.Open(notesRoot)
	if err != nil {
		_ = db.Close()
		t.Fatalf("初始化 git 版本库失败: %v", err)
	}

	indexer := index.New(db)
	reg = registry.New(db, repo)
	roots := []registry.Root{
		{Tag: testRootTag, Path: notesRoot, Mode: registry.RootModeMirror},
		{Tag: testEbooksTag, Path: ebooksRoot, Mode: registry.RootModeOnDemand},
	}
	if err := reg.SetRoots(roots); err != nil {
		_ = db.Close()
		t.Fatalf("设置根映射失败: %v", err)
	}
	// Bootstrap 遍历全部根：笔记根的 a.org 与书库根的 book.epub 都会被登记，
	// 因此后续「书库根可读」「rescan 只删 1 条」都以两个根共存为前提。
	if _, err := reg.Bootstrap(context.Background(), roots); err != nil {
		_ = db.Close()
		t.Fatalf("启动登记失败: %v", err)
	}

	// Roots 必须与上面 reg.SetRoots 的清单一致（与 newTestEnv 同理）。
	cfg := &config.Config{WebDAV: config.WebDAVConfig{
		Root:   notesRoot,
		Public: "",
		Roots: []config.RootConfig{
			{Tag: testRootTag, Path: notesRoot, Mode: config.RootModeMirror},
			{Tag: testEbooksTag, Path: ebooksRoot, Mode: config.RootModeOnDemand},
		},
	}}
	mux, err := buildMux(cfg, db, repo, indexer, reg,
		auth.New(testToken), auth.NewWithNodeToken(testToken, ""))
	if err != nil {
		_ = db.Close()
		t.Fatalf("buildMux 失败: %v", err)
	}

	srv = httptest.NewServer(mux)
	t.Cleanup(func() {
		srv.Close()
		_ = db.Close()
	})
	return srv, reg, db, notesRoot, ebooksRoot
}

// TestBuildMuxBatchBEndToEnd 是批次 B 的端到端验收，9 个子步骤顺序执行，共同覆盖
// 六项契约：多根清单不含物理路径、REST 写 → uid 状态链路（无 document_id）、批注
// 创建/列举、书库根只读、rescan 写墓碑、changes 游标连续且覆盖四类 op。
func TestBuildMuxBatchBEndToEnd(t *testing.T) {
	srv, _, _, notesRoot, ebooksRoot := newTestEnvMultiRoot(t)

	// 跨子测试复用的实际值（子测试顺序执行，不并行）：note.org 的 uid 与
	// book.epub 的 uid。uid 是跨改名稳定的身份，故步骤 6 改名后仍沿用。
	var (
		noteUID  string
		ebookUID string
	)

	t.Run("步骤1_多根清单_不含物理路径", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodGet, srv.URL+"/api/roots", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/roots 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		var list batchBRootList
		if err := json.Unmarshal(body, &list); err != nil {
			t.Fatalf("解析 /api/roots 响应失败: %v（响应体 %s）", err, body)
		}
		if len(list.Roots) != 2 {
			t.Fatalf("根条数 = %d，期望 2（响应体 %s）", len(list.Roots), body)
		}
		first, second := list.Roots[0], list.Roots[1]
		if first.Tag != testRootTag || first.Mode != "mirror" || !first.Default {
			t.Fatalf("首根 = %+v，期望 tag=%q mode=mirror default=true", first, testRootTag)
		}
		if second.Tag != testEbooksTag || second.Mode != "ondemand" || second.Default {
			t.Fatalf("次根 = %+v，期望 tag=%q mode=ondemand default=false", second, testEbooksTag)
		}
		// 物理路径属部署细节，绝不下发：既查专属 path 字段，也查根绝对路径串。
		if first.Path != "" || second.Path != "" {
			t.Fatalf("根条目含 path 字段（首 %q / 次 %q），期望响应不含物理路径（响应体 %s）",
				first.Path, second.Path, body)
		}
		for _, leak := range []string{notesRoot, ebooksRoot} {
			if strings.Contains(string(body), leak) {
				t.Fatalf("根清单泄露物理路径 %q（响应体 %s）", leak, body)
			}
		}
		t.Logf("步骤1 实际值：%d 个根，首根 %+v，次根 %+v", len(list.Roots), first, second)
	})

	t.Run("步骤2_REST写新建_取uid", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodPut, srv.URL+"/api/files/note.org", []byte("hello"), authBearer)
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("PUT /api/files/note.org 状态码 = %d，期望 201（新建）（响应体 %s）", resp.StatusCode, body)
		}
		var wr batchBFileWrite
		if err := json.Unmarshal(body, &wr); err != nil {
			t.Fatalf("解析 PUT /api/files 响应失败: %v（响应体 %s）", err, body)
		}
		if !wr.Created {
			t.Fatalf("PUT 响应 created = false，期望 true（新建）（响应体 %s）", body)
		}
		if wr.Root != testRootTag || wr.Path != "note.org" {
			t.Fatalf("PUT 响应 root/path = %q/%q，期望 %q/%q", wr.Root, wr.Path, testRootTag, "note.org")
		}
		if !registry.IsUID(wr.UID) {
			t.Fatalf("PUT 响应 uid = %q，不符合 26 位 Crockford Base32 形态", wr.UID)
		}
		if _, statErr := os.Stat(filepath.Join(notesRoot, "note.org")); statErr != nil {
			t.Fatalf("PUT 后磁盘上不存在 note.org（stat 错误 = %v）", statErr)
		}
		noteUID = wr.UID
		t.Logf("步骤2 实际值：uid=%s seq=%d", wr.UID, wr.Seq)
	})

	t.Run("步骤3_进度uid往返_无document_id", func(t *testing.T) {
		if noteUID == "" {
			t.Fatalf("前序步骤未取得 note.org 的 uid")
		}
		resp, body := doRequest(t, http.MethodPut, srv.URL+"/api/progress/"+noteUID,
			[]byte(`{"position":"page:1"}`), authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("PUT /api/progress/%s 状态码 = %d，期望 200（响应体 %s）", noteUID, resp.StatusCode, body)
		}
		var put batchBProgress
		if err := json.Unmarshal(body, &put); err != nil {
			t.Fatalf("解析 PUT progress 响应失败: %v（响应体 %s）", err, body)
		}
		if put.UID != noteUID || put.Position != "page:1" {
			t.Fatalf("PUT progress 响应 uid/position = %q/%q，期望 %q/page:1（响应体 %s）",
				put.UID, put.Position, noteUID, body)
		}
		if strings.Contains(string(body), "document_id") {
			t.Fatalf("PUT progress 响应仍含 document_id 字段（响应体 %s）", body)
		}

		resp, body = doRequest(t, http.MethodGet, srv.URL+"/api/progress/"+noteUID, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/progress/%s 状态码 = %d，期望 200（响应体 %s）", noteUID, resp.StatusCode, body)
		}
		var got map[string]any
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("解析 GET progress 响应失败: %v（响应体 %s）", err, body)
		}
		if got["uid"] != noteUID {
			t.Fatalf("GET progress 的 uid = %v，期望 %q（响应体 %s）", got["uid"], noteUID, body)
		}
		if got["position"] != "page:1" {
			t.Fatalf("GET progress 的 position = %v，期望 %q（响应体 %s）", got["position"], "page:1", body)
		}
		if _, exists := got["document_id"]; exists {
			t.Fatalf("GET progress 响应含 document_id 字段（响应体 %s）", body)
		}
		if strings.Contains(string(body), "document_id") {
			t.Fatalf("GET progress 响应文本仍出现 document_id（响应体 %s）", body)
		}
		t.Logf("步骤3 实际值：%s", body)
	})

	t.Run("步骤4_批注创建与列举", func(t *testing.T) {
		if noteUID == "" {
			t.Fatalf("前序步骤未取得 note.org 的 uid")
		}
		payload, err := json.Marshal(map[string]string{
			"uid": noteUID, "location": "page:1", "text": "note",
		})
		if err != nil {
			t.Fatalf("构造批注请求体失败: %v", err)
		}
		resp, body := doRequest(t, http.MethodPost, srv.URL+"/api/annotations", payload, authBearer)
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("POST /api/annotations 状态码 = %d，期望 201（handler 用 StatusCreated）（响应体 %s）",
				resp.StatusCode, body)
		}
		var created batchBAnnotation
		if err := json.Unmarshal(body, &created); err != nil {
			t.Fatalf("解析 POST /api/annotations 响应失败: %v（响应体 %s）", err, body)
		}
		if created.UID != noteUID || created.Location != "page:1" || created.Text != "note" {
			t.Fatalf("创建响应 uid/location/text = %q/%q/%q，期望 %q/page:1/note（响应体 %s）",
				created.UID, created.Location, created.Text, noteUID, body)
		}
		if created.ID == 0 {
			t.Fatalf("创建响应的 id = 0，期望服务端生成的非零 id（响应体 %s）", body)
		}

		resp, body = doRequest(t, http.MethodGet, srv.URL+"/api/annotations?uid="+noteUID, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/annotations 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		var items []batchBAnnotation
		if err := json.Unmarshal(body, &items); err != nil {
			t.Fatalf("解析 GET /api/annotations 响应失败: %v（响应体 %s）", err, body)
		}
		if len(items) != 1 {
			t.Fatalf("批注条数 = %d，期望 1（响应体 %s）", len(items), body)
		}
		if items[0].ID != created.ID {
			t.Fatalf("列举到的批注 id = %d，期望与创建返回的 %d 一致（响应体 %s）",
				items[0].ID, created.ID, body)
		}
		t.Logf("步骤4 实际值：id=%d location=%s", items[0].ID, items[0].Location)
	})

	t.Run("步骤5_REST覆盖写_uid不变且op为update", func(t *testing.T) {
		if noteUID == "" {
			t.Fatalf("前序步骤未取得 note.org 的 uid")
		}
		resp, body := doRequest(t, http.MethodPut, srv.URL+"/api/files/note.org", []byte("hello-v2"), authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("覆盖 PUT 状态码 = %d，期望 200（已存在）（响应体 %s）", resp.StatusCode, body)
		}
		var wr batchBFileWrite
		if err := json.Unmarshal(body, &wr); err != nil {
			t.Fatalf("解析覆盖 PUT 响应失败: %v（响应体 %s）", err, body)
		}
		if wr.Created {
			t.Fatalf("覆盖 PUT 的 created = true，期望 false（响应体 %s）", body)
		}
		if wr.UID != noteUID {
			t.Fatalf("覆盖 PUT 的 uid = %q，期望与首次 %q 相同（uid 不随内容变化）", wr.UID, noteUID)
		}
	})

	t.Run("步骤6_按uid移动_产生rename且uid不变", func(t *testing.T) {
		if noteUID == "" {
			t.Fatalf("前序步骤未取得 note.org 的 uid")
		}
		payload, err := json.Marshal(map[string]string{"to": "renamed.org"})
		if err != nil {
			t.Fatalf("构造移动请求体失败: %v", err)
		}
		resp, body := doRequest(t, http.MethodPost,
			srv.URL+"/api/resources/"+noteUID+"/move", payload, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("POST /api/resources/%s/move 状态码 = %d，期望 200（响应体 %s）",
				noteUID, resp.StatusCode, body)
		}
		var mv struct {
			UID  string `json:"uid"`
			Root string `json:"root"`
			From string `json:"from"`
			To   string `json:"to"`
		}
		if err := json.Unmarshal(body, &mv); err != nil {
			t.Fatalf("解析 move 响应失败: %v（响应体 %s）", err, body)
		}
		if mv.UID != noteUID {
			t.Fatalf("move 后 uid = %q，期望 %q（改名不得改变身份）", mv.UID, noteUID)
		}
		if mv.From != "note.org" || mv.To != "renamed.org" {
			t.Fatalf("move 的 from/to = %q/%q，期望 %q/%q", mv.From, mv.To, "note.org", "renamed.org")
		}
		if _, statErr := os.Stat(filepath.Join(notesRoot, "renamed.org")); statErr != nil {
			t.Fatalf("move 后磁盘上不存在 renamed.org（stat 错误 = %v）", statErr)
		}
		if _, statErr := os.Stat(filepath.Join(notesRoot, "note.org")); !os.IsNotExist(statErr) {
			t.Fatalf("move 后磁盘上仍存在 note.org（stat 错误 = %v）", statErr)
		}
	})

	t.Run("步骤7_书库根只读_写403读200", func(t *testing.T) {
		// 书库根在 bootstrap 阶段已登记：先确认身份可用并取出 uid。
		resp, body := doRequest(t, http.MethodGet,
			srv.URL+"/api/resources?root="+testEbooksTag, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/resources?root=ebooks 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeResourceList(t, body)
		if len(list.Items) != 1 {
			t.Fatalf("书库根登记条数 = %d，期望 1（bootstrap 登记的 book.epub）（响应体 %s）",
				len(list.Items), body)
		}
		if list.Items[0].Path != "book.epub" || list.Items[0].Root != testEbooksTag {
			t.Fatalf("书库根条目 root/path = %q/%q，期望 %q/book.epub",
				list.Items[0].Root, list.Items[0].Path, testEbooksTag)
		}
		ebookUID = list.Items[0].UID

		// 写：ondemand 根一律 403 root_read_only（架构约束，不是暂时没权限）。
		resp, body = doRequest(t, http.MethodPut,
			srv.URL+"/api/files/book.epub?root="+testEbooksTag, []byte("overwrite-attempt"), authBearer)
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("PUT 书库根文件状态码 = %d，期望 403（响应体 %s）", resp.StatusCode, body)
		}
		if code := decodeErrorCode(t, body); code != "root_read_only" {
			t.Fatalf("PUT 书库根文件 error.code = %q，期望 %q（响应体 %s）", code, "root_read_only", body)
		}

		// 读：所有根开放，内容必须原样返回（写被拒后内容不得被改写）。
		resp, body = doRequest(t, http.MethodGet,
			srv.URL+"/api/files/book.epub?root="+testEbooksTag, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET 书库根文件状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		if string(body) != testEbookContent {
			t.Fatalf("GET 书库根文件内容 = %q，期望 %q（写被 403 拒绝后内容应保持原样）",
				body, testEbookContent)
		}
		// 磁盘侧同样不变（防止「接口报 403 但已经落盘」）。
		onDisk, err := os.ReadFile(filepath.Join(ebooksRoot, "book.epub"))
		if err != nil {
			t.Fatalf("读取书库根物理文件失败: %v", err)
		}
		if string(onDisk) != testEbookContent {
			t.Fatalf("书库根物理文件内容 = %q，期望 %q（写请求必须完全不落盘）", onDisk, testEbookContent)
		}
		t.Logf("步骤7 实际值：书库 uid=%s，读回 %d 字节", ebookUID, len(body))
	})

	t.Run("步骤8_rescan_写墓碑", func(t *testing.T) {
		if ebookUID == "" {
			t.Fatalf("前序步骤未取得 book.epub 的 uid")
		}
		// 模拟「外部工具直接删盘」：绕过所有写钩子移除文件，再触发全量重扫。
		if err := os.Remove(filepath.Join(ebooksRoot, "book.epub")); err != nil {
			t.Fatalf("删除书库根物理文件失败: %v", err)
		}

		resp, body := doRequest(t, http.MethodPost, srv.URL+"/api/resources/rescan", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("POST /api/resources/rescan 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		var st batchBRescan
		if err := json.Unmarshal(body, &st); err != nil {
			t.Fatalf("解析 rescan 响应失败: %v（响应体 %s）", err, body)
		}
		if st.Deleted != 1 {
			t.Fatalf("rescan deleted = %d，期望 1（仅 book.epub 消失）（响应体 %s）", st.Deleted, body)
		}
		if st.Failed != 0 {
			t.Fatalf("rescan failed = %d，期望 0（响应体 %s）", st.Failed, body)
		}

		// 墓碑可见性：include_deleted=true 时能查到，且 uid 保持删除前的身份。
		resp, body = doRequest(t, http.MethodGet,
			srv.URL+"/api/resources?root="+testEbooksTag+"&include_deleted=true", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET 书库根含墓碑清单状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeResourceList(t, body)
		if len(list.Items) != 1 {
			t.Fatalf("含墓碑清单条数 = %d，期望 1（响应体 %s）", len(list.Items), body)
		}
		if list.Items[0].DeletedAt == "" {
			t.Fatalf("墓碑的 deleted_at 为空串，期望 RFC3339 时间戳（响应体 %s）", body)
		}
		if list.Items[0].UID != ebookUID {
			t.Fatalf("墓碑 uid = %q，期望删除前的 %q", list.Items[0].UID, ebookUID)
		}

		// 默认视图不含墓碑。
		resp, body = doRequest(t, http.MethodGet,
			srv.URL+"/api/resources?root="+testEbooksTag, nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET 书库根默认清单状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		if live := decodeResourceList(t, body); len(live.Items) != 0 {
			t.Fatalf("默认视图条数 = %d，期望 0（墓碑不得出现在默认视图）（响应体 %s）",
				len(live.Items), body)
		}
		t.Logf("步骤8 实际值：deleted=%d scanned=%d unchanged=%d", st.Deleted, st.Scanned, st.Unchanged)
	})

	t.Run("步骤9_changes游标_连续且覆盖四类op", func(t *testing.T) {
		resp, body := doRequest(t, http.MethodGet, srv.URL+"/api/changes?since=0", nil, authBearer)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/changes 状态码 = %d，期望 200（响应体 %s）", resp.StatusCode, body)
		}
		list := decodeChangeList(t, body)
		if len(list.Changes) < 4 {
			t.Fatalf("changes 条数 = %d，期望至少 4（create/update/rename/delete）（响应体 %s）",
				len(list.Changes), body)
		}

		ops := make(map[string]int, 4)
		for i, c := range list.Changes {
			if c.Seq != int64(i+1) {
				t.Fatalf("第 %d 条变更 seq = %d，期望 %d（seq 必须从 1 起连续递增无空洞）",
					i, c.Seq, i+1)
			}
			ops[c.Op]++
			switch c.Op {
			case "rename":
				if c.UID != noteUID || c.OldPath != "note.org" || c.Path != "renamed.org" {
					t.Fatalf("rename 事件的 uid/old_path/path = %q/%q/%q，期望 %q/note.org/renamed.org",
						c.UID, c.OldPath, c.Path, noteUID)
				}
			case "delete":
				if c.UID != ebookUID || c.Root != testEbooksTag || c.Path != "book.epub" {
					t.Fatalf("delete 事件的 uid/root/path = %q/%q/%q，期望 %q/%q/book.epub",
						c.UID, c.Root, c.Path, ebookUID, testEbooksTag)
				}
			}
		}
		// 四类 op 全部出现（本场景确实产生了它们，故不放宽为「至少 3 类」）。
		for _, want := range []string{"create", "update", "rename", "delete"} {
			if ops[want] == 0 {
				t.Fatalf("changes 未包含 %q 事件，实测 op 计数 %v（响应体 %s）", want, ops, body)
			}
		}

		last := list.Changes[len(list.Changes)-1]
		if list.NextCursor != last.Seq {
			t.Fatalf("next_cursor = %d，期望等于最后一条 seq %d", list.NextCursor, last.Seq)
		}
		if list.HasMore {
			t.Fatalf("has_more = true，期望 false（事件总数未触及 limit）")
		}
		t.Logf("步骤9 实际值：%d 条事件，seq %d..%d，op 计数 %v，next_cursor=%d",
			len(list.Changes), list.Changes[0].Seq, last.Seq, ops, list.NextCursor)
	})
}
