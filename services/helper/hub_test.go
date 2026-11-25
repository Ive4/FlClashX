package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testSession = "0123456789abcdef0123456789abcdef"

func TestHelperHTTPBoundary(t *testing.T) {
	h := &helper{}
	tests := []struct {
		name     string
		method   string
		target   string
		body     string
		host     string
		origin   bool
		chunked  bool
		status   int
		response string
	}{
		{name: "ping mismatch", method: "GET", target: "/ping?coreSha256=wrong", status: 409, response: "coreSha256Mismatch"},
		{name: "duplicate ping query", method: "GET", target: "/ping?coreSha256=one&coreSha256=two", status: 400, response: "invalidRequest"},
		{name: "owner browser", method: "GET", target: "/logs", origin: true, status: 403, response: "invalidRequest"},
		{name: "rebound browser", method: "GET", target: "/logs", host: "external.example", status: 403, response: "invalidRequest"},
		{name: "local authority", method: "GET", target: "/logs", host: "FlClashHelperService", status: 200},
		{name: "no child", method: "POST", target: "/stop", body: `{"sessionId":"` + testSession + `"}`, status: 200, response: "notRunning"},
		{name: "duplicate session", method: "POST", target: "/stop", body: `{"sessionId":"` + testSession + `","sessionId":"` + testSession + `"}`, status: 400, response: "invalidRequest"},
		{name: "mis-cased session", method: "POST", target: "/stop", body: `{"SessionID":"` + testSession + `"}`, status: 400, response: "invalidRequest"},
		{name: "oversized body", method: "POST", target: "/stop", body: strings.Repeat(" ", 4097), status: 413, response: "invalidRequest"},
		{name: "missing content length", method: "POST", target: "/stop", chunked: true, status: 411, response: "invalidRequest"},
		{name: "unknown endpoint", method: "POST", target: "/absent", status: 404, response: "notFound"},
		{name: "wrong method", method: "POST", target: "/logs", status: 405, response: "invalidRequest"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest(tt.method, tt.target, strings.NewReader(tt.body))
			r.Host = "127.0.0.1:47890"
			if tt.host != "" {
				r.Host = tt.host
			}
			if tt.origin {
				r.Header.Set("Origin", "")
			}
			if tt.chunked {
				r.ContentLength = -1
				r.TransferEncoding = []string{"chunked"}
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tt.status || !strings.Contains(w.Body.String(), tt.response) {
				t.Fatalf("HTTP %d %q, want %d containing %q", w.Code, w.Body.String(), tt.status, tt.response)
			}
			if strings.HasPrefix(tt.target, "/ping") && w.Header().Get("X-Flclash-Helper-Protocol") == "" {
				t.Fatal("ping responses must publish the protocol version")
			}
		})
	}
}

func TestManagedSessionMismatchPreservesCore(t *testing.T) {
	h := &helper{core: &managedCore{sessionID: testSession, done: make(chan struct{})}}
	r := httptest.NewRequest(http.MethodPost, "/stop", strings.NewReader(`{"sessionId":"ffffffffffffffffffffffffffffffff"}`))
	r.Host = "localhost"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "sessionMismatch") || h.core == nil {
		t.Fatalf("HTTP %d %q, core = %v", w.Code, w.Body.String(), h.core)
	}
}
