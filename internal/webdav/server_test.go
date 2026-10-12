package webdav

import (
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"seshat/internal/auth"
)

// testToken 是测试用的访问令牌（用户名任意，密码为该令牌）。
const testToken = "s3cret"

// basicAuthHeader 返回 Basic 认证头取值 base64(user:token)。
func basicAuthHeader(token string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte("alice:"+token))
}

// newTestServer 以 root 为挂载根启动测试服务器，返回 base URL。
func newTestServer(t *testing.T, root string) string {
	t.Helper()
	srv := httptest.NewServer(NewHandler(root, auth.New(testToken), SourceInternal))
	t.Cleanup(srv.Close)
	return srv.URL
}

// mustWriteFile 在 root 下写入测试文件，失败即终止测试。
func mustWriteFile(t *testing.T, root, name, content string) string {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("写入测试文件 %s 失败: %v", name, err)
	}
	return path
}

// doRequest 发送请求；authorization 为空表示不带 Authorization 头。
func doRequest(t *testing.T, method, url, body, authorization string) *http.Response {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatalf("构造 %s 请求失败: %v", method, err)
	}
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s 请求失败: %v", method, url, err)
	}
	return resp
}

// TestGetFile 验证 GET 读取挂载根下的文件。
func TestGetFile(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 标题\n")
	base := newTestServer(t, root)

	resp := doRequest(t, http.MethodGet, base+davPrefix+"/note.org", "", basicAuthHeader(testToken))
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 %d", resp.StatusCode, http.StatusOK)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取响应体失败: %v", err)
	}
	if string(body) != "* 标题\n" {
		t.Errorf("响应体 = %q, 期望 %q", string(body), "* 标题\n")
	}
}

// TestPutThenGet 验证 PUT 写入后磁盘文件与再 GET 的内容一致。
func TestPutThenGet(t *testing.T) {
	const content = "* 由 PUT 写入\n"
	root := t.TempDir()
	base := newTestServer(t, root)

	resp := doRequest(t, http.MethodPut, base+davPrefix+"/put.org", content, basicAuthHeader(testToken))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusCreated)
	}

	disk, err := os.ReadFile(filepath.Join(root, "put.org"))
	if err != nil {
		t.Fatalf("读取磁盘文件失败: %v", err)
	}
	if string(disk) != content {
		t.Errorf("磁盘内容 = %q, 期望 %q", string(disk), content)
	}

	resp = doRequest(t, http.MethodGet, base+davPrefix+"/put.org", "", basicAuthHeader(testToken))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusOK)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取响应体失败: %v", err)
	}
	if string(body) != content {
		t.Errorf("GET 内容 = %q, 期望 %q", string(body), content)
	}
}

// TestDeleteFile 验证 DELETE 删除文件且磁盘上已不存在。
func TestDeleteFile(t *testing.T) {
	root := t.TempDir()
	target := mustWriteFile(t, root, "del.org", "* 待删除\n")
	base := newTestServer(t, root)

	resp := doRequest(t, http.MethodDelete, base+davPrefix+"/del.org", "", basicAuthHeader(testToken))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE 状态码 = %d, 期望 %d", resp.StatusCode, http.StatusNoContent)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Errorf("文件仍存在或 stat 出错: %v", err)
	}
}

// TestPropfindDepthZero 验证 Depth: 0 的 PROPFIND 返回 207 Multi-Status。
func TestPropfindDepthZero(t *testing.T) {
	const propfindBody = `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>`
	root := t.TempDir()
	mustWriteFile(t, root, "a.org", "* a\n")
	base := newTestServer(t, root)

	req, err := http.NewRequest("PROPFIND", base+davPrefix+"/", strings.NewReader(propfindBody))
	if err != nil {
		t.Fatalf("构造 PROPFIND 请求失败: %v", err)
	}
	req.Header.Set("Authorization", basicAuthHeader(testToken))
	req.Header.Set("Depth", "0")
	req.Header.Set("Content-Type", "application/xml")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PROPFIND 请求失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMultiStatus {
		t.Fatalf("状态码 = %d, 期望 %d", resp.StatusCode, http.StatusMultiStatus)
	}
}

// TestUnauthorized 验证缺失或错误的 Basic 凭证返回 401。
func TestUnauthorized(t *testing.T) {
	root := t.TempDir()
	mustWriteFile(t, root, "note.org", "* 标题\n")
	base := newTestServer(t, root)

	cases := map[string]string{
		"无认证头":      "",
		"错误 Basic":  basicAuthHeader("wrong"),
		"非法 Base64": "Basic !!!not-base64!!!",
	}
	for name, header := range cases {
		resp := doRequest(t, http.MethodGet, base+davPrefix+"/note.org", "", header)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: 状态码 = %d, 期望 %d", name, resp.StatusCode, http.StatusUnauthorized)
		}
	}
}

// TestSourceFromContextEmpty 验证 context 中无来源标记时返回空串。
func TestSourceFromContextEmpty(t *testing.T) {
	if got := SourceFromContext(context.Background()); got != "" {
		t.Errorf("SourceFromContext(context.Background()) = %q, 期望空串", got)
	}
	// 类型不符的值不应被误判为来源标记。
	ctx := context.WithValue(context.Background(), sourceKey, "internal")
	if got := SourceFromContext(ctx); got != "" {
		t.Errorf("类型不符时 = %q, 期望空串", got)
	}
}

// TestSourceInjection 验证认证通过后 handler 能从 context 读到对应来源标记。
func TestSourceInjection(t *testing.T) {
	cases := []struct {
		name   string
		source Source
	}{
		{"内部端点", SourceInternal},
		{"对外端点", SourceExternal},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got Source
			reached := false

			// 测试 handler 模拟 webdav.Handler：读取 context 中的来源标记。
			inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				reached = true
				got = SourceFromContext(r.Context())
			})

			// 与 NewHandler 相同的链路：认证中间件 → 注入来源标记 → 内层 handler。
			srv := httptest.NewServer(auth.New(testToken).Middleware(injectSource(tc.source, inner)))
			defer srv.Close()

			resp := doRequest(t, http.MethodGet, srv.URL+"/", "", basicAuthHeader(testToken))
			resp.Body.Close()

			if !reached {
				t.Fatalf("请求未到达内层 handler（状态码 %d）", resp.StatusCode)
			}
			if got != tc.source {
				t.Errorf("SourceFromContext = %q, 期望 %q", got, tc.source)
			}
		})
	}
}
