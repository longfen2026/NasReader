package storage

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestWebdavBasicAuthPreemptive 验证：当服务器要求 Basic 认证时，
// newWebdavBackend 会预先带上 Authorization 头，从而通过 Connect()（OPTIONS 探测），
// 而不会因缺少挑战头协商失败而返回 401。
func TestWebdavBasicAuthPreemptive(t *testing.T) {
	const wantUser = "alice"
	const wantPass = "s3cr3t"
	wantHeader := "Basic " + base64.StdEncoding.EncodeToString([]byte(wantUser+":"+wantPass))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != wantHeader {
			// 模拟服务器：未认证时返回 401 并带挑战头
			w.Header().Set("WWW-Authenticate", `Basic realm="webdav"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		// 已认证：OPTIONS 探测放行
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	t.Setenv("WEBDAV_URL", srv.URL)
	t.Setenv("WEBDAV_USER", wantUser)
	t.Setenv("WEBDAV_PASSWORD", wantPass)
	t.Setenv("WEBDAV_BOOKS_PATH", "/books")
	t.Setenv("WEBDAV_UPLOADS_PATH", "/uploads")

	b, err := newWebdavBackend()
	if err != nil {
		t.Fatalf("预期预置 Basic 认证后连接成功，实际失败: %v", err)
	}
	if b == nil {
		t.Fatal("backend 不应为 nil")
	}
}

// TestWebdavBasicAuthWrongCredentials 验证：凭据错误时仍返回连接失败（401 透传）。
func TestWebdavBasicAuthWrongCredentials(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("WWW-Authenticate", `Basic realm="webdav"`)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	t.Setenv("WEBDAV_URL", srv.URL)
	t.Setenv("WEBDAV_USER", "alice")
	t.Setenv("WEBDAV_PASSWORD", "wrong")

	if _, err := newWebdavBackend(); err == nil {
		t.Fatal("预期凭据错误时连接失败，实际成功")
	} else if !strings.Contains(err.Error(), "连接 WebDAV 失败") {
		t.Fatalf("错误信息应包含连接失败提示，实际: %v", err)
	}
}
