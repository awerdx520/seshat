// 本文件是 internal/api 的**内部**测试（package api），专门覆盖未导出标识符：
// deleteListLimit（删除目录时的列举上限）与 truncationReached（截断判定纯函数）。
//
// 为什么不放 files_test.go：那里是 package api_test（黑盒），访问不到未导出的
// deleteListLimit，无法把上限临时调小以走到截断路径。Go 允许同一个目录下同时存在
// package api 与 package api_test 的测试文件，两者由同一次 go test 编译。
//
// 覆盖范围：
//  1. truncationReached 的表驱动断言（含 limit<=0 的边界）；
//  2. 端到端：deleteListLimit=1 时删除含 2 个登记行的目录仍返回 200 且目录已删
//     （截断只影响墓碑写入的完整度，不改变删除本身的行为）。截断的**可观测性**
//     由 1 承担——告警走包级 slog，没有可注入点，捕获 stderr 会让用例极其脆弱；
//  3. inlineContentTypes 静态白名单的不变量：17 项全部非空、且不得出现任何可执行
//     类型（html/svg/xml/javascript/x-shockwave）。
package api

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"seshat/internal/auth"
	"seshat/internal/gitver"
	"seshat/internal/registry"
	"seshat/internal/storage"
)

// internalTestToken 是本文件用例使用的访问令牌。
const internalTestToken = "internal-test-token"

// TestTruncationReached 验证截断判定：恰好撞到上限即视为「可能仍有未列举的行」，
// 上限非正时永不判截断（0/负数意味着「不限」，把它当成截断会误报）。
func TestTruncationReached(t *testing.T) {
	cases := []struct {
		returned int
		limit    int
		want     bool
	}{
		{returned: 0, limit: 1, want: false},
		{returned: 1, limit: 1, want: true},
		{returned: 2, limit: 1, want: true},
		{returned: 99999, limit: 100000, want: false},
		{returned: 100000, limit: 100000, want: true},
		{returned: 5, limit: 0, want: false},
	}
	for _, c := range cases {
		if got := truncationReached(c.returned, c.limit); got != c.want {
			t.Errorf("truncationReached(%d, %d) = %v, 期望 %v", c.returned, c.limit, got, c.want)
		}
	}
}

// newInternalFileHandler 组装一个最小的 mirror 根处理器（真实 gitver 仓库 + registry），
// 供删除用例走完整 HTTP 栈。刻意不复用 api_test 的 newFileEnv：跨包不可见，而把
// 它导出只为测试是不值得的（会扩大 api 包的公开面）。
func newInternalFileHandler(t *testing.T) (http.Handler, string) {
	t.Helper()

	notesDir := t.TempDir()
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
	}); err != nil {
		t.Fatalf("设置根清单失败: %v", err)
	}
	return NewHandlerFullWithRegistry(db, repo, nil, svc, auth.New(internalTestToken), nil), notesDir
}

// rawRequest 发送一次原始字节请求（文件端点不能用 JSON 序列化）。
func rawRequest(t *testing.T, h http.Handler, method, target string, body []byte) *httptest.ResponseRecorder {
	t.Helper()

	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req := httptest.NewRequest(method, target, reader)
	req.Header.Set("Authorization", "Bearer "+internalTestToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestInlineContentTypesAreStatic 把「白名单里绝不允许出现可执行类型」变成机械可查
// 的不变量：遍历全部 17 项，值必须非空且不含任何可执行类型的标志串。
//
// 为什么需要它：白名单从 mime.TypeByExtension 改为静态表后，「某个扩展名映射到什么
// 类型」不再由宿主 MIME 数据库兜底，而由这张表一次性决定。新增一项时若顺手抄了
// text/html 或 image/svg+xml，白名单立刻变成 XSS 通道（与服务端同源，内联即执行）。
func TestInlineContentTypesAreStatic(t *testing.T) {
	if len(inlineContentTypes) != 17 {
		t.Fatalf("白名单项数 = %d, 期望 17（新增项须同步本断言与 docs）", len(inlineContentTypes))
	}

	forbidden := []string{"html", "svg", "xml", "javascript", "x-shockwave"}
	for ext, ct := range inlineContentTypes {
		if ct == "" {
			t.Errorf("%s 的 Content-Type 为空", ext)
			continue
		}
		lower := strings.ToLower(ct)
		for _, bad := range forbidden {
			if strings.Contains(lower, bad) {
				t.Errorf("%s 的 Content-Type = %q 含可执行类型标志 %q（白名单只允许确定安全的类型）", ext, ct, bad)
			}
		}
	}
}

// TestDeleteDirectoryWithTruncatedList 验证「列举被上限截断」不改变删除本身的行为：
// 仍有 200、目录确实从磁盘消失。截断的后果是「可能有登记行没写墓碑」，那属于
// 后续批次（分批删除）要解决的事，本批只让它可见（slog 告警）。
func TestDeleteDirectoryWithTruncatedList(t *testing.T) {
	h, notesDir := newInternalFileHandler(t)

	for _, name := range []string{"dir/a.org", "dir/b.org"} {
		rec := rawRequest(t, h, http.MethodPut, "/api/files/"+name, []byte("content"))
		if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
			t.Fatalf("写入 %s 失败: %d %s", name, rec.Code, rec.Body.String())
		}
	}

	// 把列举上限调到 1：两个登记行的目录必然触发截断分支。
	prev := deleteListLimit
	deleteListLimit = 1
	t.Cleanup(func() { deleteListLimit = prev })

	rec := rawRequest(t, h, http.MethodDelete, "/api/files/dir", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("删除目录状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(notesDir, "dir")); !os.IsNotExist(err) {
		t.Fatalf("目录未被删除: stat err = %v", err)
	}
}
