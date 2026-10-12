// 本文件覆盖 LLM 节点端点的独立令牌认证（技术债 #8）：节点令牌可访问节点端点、
// 主令牌访问节点端点 401、节点令牌不能访问普通端点、未配置节点令牌时回退主令牌。
// 测试复用 server_test.go / llm_test.go 中的 do / decodeJSON / assertErrorCode 辅助函数。
package api_test

import (
	"net/http"
	"path/filepath"
	"testing"

	"seshat/internal/api"
	"seshat/internal/auth"
	"seshat/internal/storage"
)

// 节点端点测试用的主令牌与节点令牌。
const (
	testMainToken = "main-token"
	testNodeToken = "node-token"
)

// newNodeAuthHandler 构造「主令牌 + 节点令牌」双认证的处理器：主认证器只接受
// 主令牌（保护普通端点），节点认证器接受节点令牌（保护节点端点）；nodeToken
// 为空表示未配置节点令牌，节点端点回退接受主令牌（向后兼容）。
func newNodeAuthHandler(t *testing.T, nodeToken string) http.Handler {
	t.Helper()
	db, err := storage.Open(filepath.Join(t.TempDir(), "seshat.db"), "")
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return api.NewHandlerFullWithNodeAuth(db, nil, nil,
		auth.New(testMainToken), auth.NewWithNodeToken(testMainToken, nodeToken))
}

// TestNodeEndpointsAcceptNodeToken 验证节点令牌可访问全部节点端点。
func TestNodeEndpointsAcceptNodeToken(t *testing.T) {
	h := newNodeAuthHandler(t, testNodeToken)

	// 轮询：空队列返回 204（认证已通过）。
	if rec := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testNodeToken, nil, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("节点令牌轮询状态码 = %d, 期望 204 (body=%q)", rec.Code, rec.Body.String())
	}
	// 注册：返回 200。
	if rec := do(t, h, http.MethodPost, "/api/llm/nodes/register", testNodeToken,
		map[string]string{"node_name": "home-nas"}, nil); rec.Code != http.StatusOK {
		t.Fatalf("节点令牌注册状态码 = %d, 期望 200 (body=%q)", rec.Code, rec.Body.String())
	}
	// 结果回传：认证已通过，任务不存在故返回 404（而非 401）。
	rec := do(t, h, http.MethodPost, "/api/llm/tasks/999/result", testNodeToken,
		map[string]string{"result": "r"}, nil)
	assertErrorCode(t, rec, http.StatusNotFound, "not_found")
}

// TestNodeEndpointsRejectMainToken 验证配置了节点令牌时，主令牌访问节点端点返回 401。
func TestNodeEndpointsRejectMainToken(t *testing.T) {
	h := newNodeAuthHandler(t, testNodeToken)

	cases := []struct {
		method string
		target string
		body   any
	}{
		{http.MethodGet, "/api/llm/tasks/poll", nil},
		{http.MethodPost, "/api/llm/tasks/1/result", map[string]string{"result": "r"}},
		{http.MethodPost, "/api/llm/nodes/register", map[string]string{"node_name": "n"}},
	}
	for _, tc := range cases {
		t.Run(tc.method+" "+tc.target, func(t *testing.T) {
			rec := do(t, h, tc.method, tc.target, testMainToken, tc.body, nil)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("主令牌访问节点端点状态码 = %d, 期望 401 (body=%q)", rec.Code, rec.Body.String())
			}
		})
	}
}

// TestNodeTokenRejectedOnRegularEndpoints 验证节点令牌不能访问普通端点（反向隔离）。
func TestNodeTokenRejectedOnRegularEndpoints(t *testing.T) {
	h := newNodeAuthHandler(t, testNodeToken)

	// 普通进度端点。
	if rec := do(t, h, http.MethodGet, "/api/progress/doc-1", testNodeToken, nil, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("节点令牌访问普通端点状态码 = %d, 期望 401", rec.Code)
	}
	// 任务创建端点（普通端点，由主令牌保护）。
	rec := do(t, h, http.MethodPost, "/api/llm/tasks", testNodeToken,
		map[string]string{"kind": "k", "payload": "{}", "route": "local"}, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("节点令牌创建任务状态码 = %d, 期望 401", rec.Code)
	}
}

// TestNodeEndpointsFallBackToMainToken 验证未配置节点令牌时节点端点回退接受主令牌。
func TestNodeEndpointsFallBackToMainToken(t *testing.T) {
	h := newNodeAuthHandler(t, "") // 未配置节点令牌。

	if rec := do(t, h, http.MethodGet, "/api/llm/tasks/poll", testMainToken, nil, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("未配置节点令牌时主令牌轮询状态码 = %d, 期望 204 (body=%q)", rec.Code, rec.Body.String())
	}
}

// TestNodeEndpointsRequireAnyToken 验证节点端点无令牌时返回 401。
func TestNodeEndpointsRequireAnyToken(t *testing.T) {
	h := newNodeAuthHandler(t, testNodeToken)

	if rec := do(t, h, http.MethodGet, "/api/llm/tasks/poll", "", nil, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("无令牌轮询状态码 = %d, 期望 401", rec.Code)
	}
}
