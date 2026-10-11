// Package auth 提供 notes 服务的单用户令牌认证。
//
// 服务只有唯一的期望令牌（由配置从环境变量 NOTES_AUTH_TOKEN 注入），
// 认证即校验请求是否携带该令牌。支持两种 scheme：
//   - Bearer：Authorization: Bearer <token>（REST 接口）
//   - Basic：Authorization: Basic base64(user:token)（WebDAV 客户端）
//
// 令牌比较使用 crypto/subtle.ConstantTimeCompare，避免时序攻击；
// 未配置令牌（空字符串）时拒绝所有请求，保证安全默认。
package auth

import (
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"strings"
)

// Authenticator 校验请求是否携带正确的访问令牌。
// 使用 New 构造，零值不可用（token 为空会拒绝所有请求）。
type Authenticator struct {
	// token 是唯一的期望访问令牌，不导出，避免被外部包读取或修改。
	token string
}

// unauthorizedBody 是未认证请求的响应体：统一 JSON 错误格式
// {"error":{"code":"unauthorized","message":"Unauthorized"}}，与 internal/api
// 对外错误体（{"error":{"code","message"}}）保持一致，便于客户端统一解析。
const unauthorizedBody = `{"error":{"code":"unauthorized","message":"Unauthorized"}}` + "\n"

// New 构造 Authenticator。token 为空（未配置）时所有请求都会被拒绝。
func New(token string) *Authenticator {
	return &Authenticator{token: token}
}

// Authenticate 解析请求的 Authorization 头并校验令牌。
// 支持 Bearer 与 Basic 两种 scheme；未携带头部、scheme 不受支持、
// 格式非法、令牌不匹配，或未配置令牌（token 为空）时均返回 false。
func (a *Authenticator) Authenticate(r *http.Request) bool {
	// 未配置令牌：拒绝一切请求（安全默认）。
	if a.token == "" {
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
	return subtle.ConstantTimeCompare([]byte(presented), []byte(a.token)) == 1
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
			w.Header().Set("WWW-Authenticate", "Bearer")
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(unauthorizedBody))
			return
		}
		next.ServeHTTP(w, r)
	})
}
