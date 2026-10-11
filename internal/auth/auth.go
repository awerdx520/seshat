// Package auth 提供 notes 服务的单用户令牌认证。
//
// 服务主令牌（由配置从环境变量 NOTES_AUTH_TOKEN 注入）保护普通端点；此外可配置
// 独立的节点令牌（NOTES_NODE_TOKEN），仅用于本地处理节点端点
// （/api/llm/tasks/poll、/api/llm/tasks/{id}/result、/api/llm/nodes/register），
// 实现节点与客户端的最小权限隔离。认证即校验请求是否携带期望令牌。支持两种 scheme：
//   - Bearer：Authorization: Bearer <token>（REST 接口）
//   - Basic：Authorization: Basic base64(user:token)（WebDAV 客户端）
//
// 令牌比较使用 crypto/subtle.ConstantTimeCompare，避免时序攻击；
// 未配置令牌（空字符串）时拒绝所有请求，保证安全默认。节点令牌未配置时，
// 节点端点回退接受主令牌（向后兼容既有部署）。
package auth

import (
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"strings"
)

// Authenticator 校验请求是否携带正确的访问令牌。
// 使用 New 或 NewWithNodeToken 构造，零值不可用（token 为空会拒绝所有请求）。
type Authenticator struct {
	// token 是唯一的期望访问令牌，不导出，避免被外部包读取或修改。
	token string
	// nodeToken 是本地处理节点专用令牌，与主令牌分离。为空时节点端点回退
	// 接受主令牌（向后兼容）。
	nodeToken string
}

// unauthorizedBody 是未认证请求的响应体：统一 JSON 错误格式
// {"error":{"code":"unauthorized","message":"Unauthorized"}}，与 internal/api
// 对外错误体（{"error":{"code","message"}}）保持一致，便于客户端统一解析。
const unauthorizedBody = `{"error":{"code":"unauthorized","message":"Unauthorized"}}` + "\n"

// New 构造 Authenticator。token 为空（未配置）时所有请求都会被拒绝。
func New(token string) *Authenticator {
	return &Authenticator{token: token}
}

// NewWithNodeToken 构造同时支持主令牌与节点令牌的 Authenticator。
// nodeToken 用于节点端点（NodeMiddleware），mainToken 用于其余端点（Middleware）。
// nodeToken 为空时节点端点回退接受 mainToken（向后兼容既有部署）。
func NewWithNodeToken(mainToken, nodeToken string) *Authenticator {
	return &Authenticator{token: mainToken, nodeToken: nodeToken}
}

// Authenticate 解析请求的 Authorization 头并校验主令牌。
// 支持 Bearer 与 Basic 两种 scheme；未携带头部、scheme 不受支持、
// 格式非法、令牌不匹配，或未配置令牌（token 为空）时均返回 false。
func (a *Authenticator) Authenticate(r *http.Request) bool {
	return a.authenticateAgainst(r, a.token)
}

// AuthenticateNode 解析请求的 Authorization 头并校验节点令牌。
// 未配置节点令牌（nodeToken 为空）时回退校验主令牌，保证向后兼容；
// 两者皆空时拒绝（安全默认）。
func (a *Authenticator) AuthenticateNode(r *http.Request) bool {
	return a.authenticateAgainst(r, a.nodeExpectedToken())
}

// nodeExpectedToken 返回节点端点应校验的令牌：优先节点令牌，未配置时回退主令牌。
func (a *Authenticator) nodeExpectedToken() string {
	if a.nodeToken != "" {
		return a.nodeToken
	}
	return a.token
}

// authenticateAgainst 校验请求是否携带 expected 令牌；expected 为空时拒绝。
// 支持 Bearer（REST）与 Basic（WebDAV 客户端）两种 scheme。
func (a *Authenticator) authenticateAgainst(r *http.Request, expected string) bool {
	// 未配置期望令牌：拒绝一切请求（安全默认）。
	if expected == "" {
		return false
	}

	header := r.Header.Get("Authorization")
	if header == "" {
		return false
	}

	// 按首个空格切分 scheme 与凭证，缺失分隔符视为非法。
	scheme, credential, ok := strings.Cut(header, " ")
	if !ok {
		return false
	}
	credential = strings.TrimSpace(credential)

	var presented string
	switch {
	case strings.EqualFold(scheme, "Bearer"):
		presented = credential
	case strings.EqualFold(scheme, "Basic"):
		// Basic 凭证为 base64(user:token)，取其中的 token（密码）部分。
		presented = basicPassword(credential)
	default:
		return false
	}

	if presented == "" {
		return false
	}

	// 恒定时间比较，避免按字符提前返回泄露令牌信息。
	return subtle.ConstantTimeCompare([]byte(presented), []byte(expected)) == 1
}

// basicPassword 解码 Basic 凭证 base64(user:token)，返回其中的 token（密码）部分。
// 解码失败或缺少 "user:token" 分隔符时返回空字符串。
func basicPassword(encoded string) string {
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return ""
	}
	_, password, ok := strings.Cut(string(decoded), ":")
	if !ok {
		return ""
	}
	return password
}

// Middleware 包装 handler：未通过认证的请求返回 401，响应体为统一 JSON 错误体
// （Content-Type: application/json）并附带 WWW-Authenticate: Bearer 响应头，
// 认证通过则透传到 next。
func (a *Authenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.Authenticate(r) {
			writeUnauthorized(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// NodeMiddleware 包装节点端点 handler：未通过节点令牌认证的请求返回 401
// （错误体与 Middleware 一致），认证通过则透传到 next。
// 用于将本地处理节点端点（任务轮询/回传、节点注册）与普通端点的主令牌认证
// 隔离，实现最小权限。
func (a *Authenticator) NodeMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.AuthenticateNode(r) {
			writeUnauthorized(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// writeUnauthorized 写出统一的 401 响应（JSON 错误体 + WWW-Authenticate 头）。
func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(unauthorizedBody))
}
