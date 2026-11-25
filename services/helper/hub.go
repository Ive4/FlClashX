package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	json "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	protocolHeader = "X-Flclash-Helper-Protocol"
	maxBodyBytes   = 4096
	maxLogLines    = 100
	forceExitWait  = 1500 * time.Millisecond
)

type startParams struct {
	Address   string `json:"address"`
	SessionID string `json:"sessionId"`
}

type stopParams struct {
	SessionID string `json:"sessionId"`
}

type startResponse struct {
	SessionID string `json:"sessionId"`
	PID       int    `json:"pid"`
}

type stopResponse struct {
	SessionID string `json:"sessionId"`
	Stopped   bool   `json:"stopped"`
	Reason    string `json:"reason,omitempty"`
}

type helperError struct {
	Code    string        `json:"code"`
	Message string        `json:"message"`
	Details *errorDetails `json:"details,omitempty"`
}

type errorDetails struct {
	OSError int `json:"osError"`
}

func launchError(err error) *helperError {
	result := &helperError{Code: "processLaunchFailed", Message: err.Error()}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		result.Details = &errorDetails{OSError: int(errno)}
	}
	return result
}

func verificationError(err error) *helperError {
	return &helperError{Code: "coreVerificationFailed", Message: err.Error()}
}

type helper struct {
	path string

	mu     sync.Mutex
	core   *managedCore
	closed bool

	logMu sync.Mutex
	logs  []string
}

type managedCore struct {
	sessionID string
	process   *os.Process
	done      chan struct{}
	waitErr   error
}

func (core *managedCore) wait(timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-core.done:
		return true
	case <-timer.C:
		return false
	}
}

func (h *helper) releaseCore() error {
	core := h.core
	if core == nil {
		return nil
	}
	if !requestCoreExit(core.process) || !core.wait(3*time.Second) {
		_ = core.process.Kill()
		if !core.wait(forceExitWait) {
			return errors.New("Core did not exit after termination")
		}
	}
	if core.waitErr != nil {
		return core.waitErr
	}
	h.core = nil
	return nil
}

func (h *helper) waitForCore(core *managedCore, release func()) {
	state, err := core.process.Wait()
	if release != nil {
		release()
	}
	core.waitErr = err
	close(core.done)

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.core != core {
		return
	}
	if err != nil {
		h.log(fmt.Sprintf("Helper could not wait for the Core: %v", err))
		return
	}
	h.log(fmt.Sprintf("Core exited on its own: %v", state))
	h.core = nil
}

func (h *helper) log(message string) {
	h.logMu.Lock()
	defer h.logMu.Unlock()
	if len(h.logs) == maxLogLines {
		copy(h.logs, h.logs[1:])
		h.logs = h.logs[:maxLogLines-1]
	}
	h.logs = append(h.logs, message)
}

func (h *helper) captureOutput(input *os.File) {
	defer input.Close()
	reader := bufio.NewReader(input)
	skip := false
	for {
		line, hasMore, err := reader.ReadLine()
		if err != nil {
			return
		}
		if !skip {
			h.log(strings.ToValidUTF8(string(line), "\ufffd"))
		}
		skip = hasMore
	}
}

func isLowerHex(value string, length int) bool {
	if len(value) != length {
		return false
	}
	for _, ch := range value {
		if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') {
			return false
		}
	}
	return true
}

func openVerifiedCore(path string) (*os.File, error) {
	if err := coreHashConfigured(); err != nil {
		return nil, err
	}
	file, err := openCore(path)
	if err != nil {
		return nil, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		file.Close()
		return nil, err
	}
	if hex.EncodeToString(hash.Sum(nil)) != expectedCoreSHA256 {
		file.Close()
		return nil, errors.New("Core executable SHA256 mismatch")
	}
	return file, nil
}

func isLocalHost(host string) bool {
	if host == "" {
		return true
	}
	if strings.Contains(host, ":") {
		domain, port, err := net.SplitHostPort(host)
		if err != nil {
			return false
		}
		if _, err := strconv.ParseUint(port, 10, 16); err != nil {
			return false
		}
		host = domain
	}
	switch strings.ToLower(host) {
	case "127.0.0.1", "localhost", "flclashhelperservice":
		return true
	}
	return false
}

func (h *helper) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if _, origin := r.Header["Origin"]; origin || !isLocalHost(r.Host) || r.URL.IsAbs() {
		w.Header().Set("Connection", "close")
		writeError(w, http.StatusForbidden, "invalidRequest", "browser origins and non-local hosts are not allowed")
		return
	}
	var method string
	switch r.URL.EscapedPath() {
	case "/ping", "/logs":
		method = http.MethodGet
	case "/start", "/stop":
		method = http.MethodPost
	default:
		writeError(w, http.StatusNotFound, "notFound", "Helper endpoint not found")
		return
	}
	if r.Method != method {
		writeError(w, http.StatusMethodNotAllowed, "invalidRequest", "Helper endpoint does not accept this method")
		return
	}
	switch r.URL.Path {
	case "/ping":
		h.ping(w, r)
	case "/start":
		var params startParams
		if readParams(w, r, &params) {
			h.start(w, params)
		}
	case "/stop":
		var params stopParams
		if readParams(w, r, &params) {
			h.stop(w, params)
		}
	case "/logs":
		w.Header().Set("Cache-Control", "no-store")
		h.logMu.Lock()
		logs := strings.Join(h.logs, "\n")
		h.logMu.Unlock()
		writeText(w, http.StatusOK, logs)
	}
}

func readParams(w http.ResponseWriter, r *http.Request, value any) bool {
	if r.ContentLength <= 0 && len(r.Header.Values("Content-Length")) == 0 {
		writeError(w, http.StatusLengthRequired, "invalidRequest", "request body length is required")
		return false
	}
	if r.ContentLength > maxBodyBytes {
		w.Header().Set("Connection", "close")
		writeError(w, http.StatusRequestEntityTooLarge, "invalidRequest", "request body exceeds 4096 bytes")
		return false
	}
	if contentType := r.Header.Get("Content-Type"); contentType != "" {
		mediaType, _, err := mime.ParseMediaType(contentType)
		if err != nil || mediaType != "application/json" {
			writeError(w, http.StatusUnsupportedMediaType, "invalidRequest", "request body must be JSON")
			return false
		}
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil || json.Unmarshal(body, value, json.RejectUnknownMembers(true)) != nil {
		writeError(w, http.StatusBadRequest, "invalidRequest", "invalid JSON request body")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, helperError{Code: code, Message: message})
}

func writeText(w http.ResponseWriter, status int, value string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, value)
}

func (h *helper) ping(w http.ResponseWriter, r *http.Request) {
	w.Header().Set(protocolHeader, protocolVersion)
	params, err := url.ParseQuery(r.URL.RawQuery)
	values := params["coreSha256"]
	if err != nil || len(params) != 1 || len(values) != 1 {
		writeError(w, http.StatusBadRequest, "invalidRequest", "invalid ping query")
		return
	}
	if values[0] != expectedCoreSHA256 {
		h.log("Helper ping rejected a Core SHA256 mismatch")
		writeError(w, http.StatusConflict, "coreSha256Mismatch", "Core SHA256 mismatch")
		return
	}
	file, err := openCore(filepath.Join(filepath.Dir(h.path), coreName))
	if err != nil {
		h.log(fmt.Sprintf("Helper ping failed: %v", err))
		writeText(w, http.StatusConflict, err.Error())
		return
	}
	file.Close()
	writeText(w, http.StatusOK, h.path)
}

func (h *helper) start(w http.ResponseWriter, params startParams) {
	if !isAllowedCoreAddress(params.Address) {
		writeError(w, http.StatusBadRequest, "invalidRequest", "invalid Core address")
		return
	}
	if !isLowerHex(params.SessionID, 32) {
		writeError(w, http.StatusBadRequest, "invalidRequest", "invalid Core session ID")
		return
	}
	if err := ensureOwnerAddress(params.Address); err != nil {
		writeError(w, http.StatusBadRequest, "invalidRequest", err.Error())
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		writeError(w, http.StatusServiceUnavailable, "internalError", "Helper is stopping")
		return
	}
	if err := h.releaseCore(); err != nil {
		h.reportStopFailure(w, err)
		return
	}
	path := filepath.Join(filepath.Dir(h.path), coreName)
	process, release, failure := h.spawn(path, params.Address)
	if failure != nil {
		h.log(failure.Message)
		status := http.StatusInternalServerError
		if failure.Code == "coreVerificationFailed" {
			status = http.StatusConflict
		}
		writeJSON(w, status, failure)
		return
	}
	core := &managedCore{sessionID: params.SessionID, process: process, done: make(chan struct{})}
	h.core = core
	go h.waitForCore(core, release)
	writeJSON(w, http.StatusOK, startResponse{SessionID: params.SessionID, PID: process.Pid})
}

func (h *helper) spawn(path, address string) (*os.Process, func(), *helperError) {
	stdout, outWriter, err := os.Pipe()
	if err != nil {
		return nil, nil, launchError(err)
	}
	defer outWriter.Close()
	stderr, errWriter, err := os.Pipe()
	if err != nil {
		stdout.Close()
		return nil, nil, launchError(err)
	}
	defer errWriter.Close()
	process, release, failure := launchCore(path, address, outWriter, errWriter)
	if failure != nil {
		stdout.Close()
		stderr.Close()
		return nil, nil, failure
	}
	go h.captureOutput(stdout)
	go h.captureOutput(stderr)
	return process, release, nil
}

func (h *helper) stop(w http.ResponseWriter, params stopParams) {
	if !isLowerHex(params.SessionID, 32) {
		writeError(w, http.StatusBadRequest, "invalidRequest", "invalid Core session ID")
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	response := stopResponse{SessionID: params.SessionID}
	switch {
	case h.core == nil:
		response.Reason = "notRunning"
	case h.core.sessionID != params.SessionID:
		response.Reason = "sessionMismatch"
		writeJSON(w, http.StatusConflict, response)
		return
	default:
		if err := h.releaseCore(); err != nil {
			h.reportStopFailure(w, err)
			return
		}
		response.Stopped = true
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *helper) reportStopFailure(w http.ResponseWriter, err error) {
	h.log(fmt.Sprintf("Helper could not stop the managed Core: %v", err))
	writeError(w, http.StatusInternalServerError, "coreStopFailed", err.Error())
}

func (h *helper) serve(ctx context.Context, listener net.Listener) error {
	server := &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    64 * 1024,
	}
	serveDone := make(chan struct{})
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		select {
		case <-ctx.Done():
			shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := server.Shutdown(shutdownContext); err != nil {
				_ = server.Close()
			}
		case <-serveDone:
		}
	}()
	err := server.Serve(listener)
	close(serveDone)
	<-shutdownDone

	h.mu.Lock()
	h.closed = true
	stopErr := h.releaseCore()
	h.mu.Unlock()
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	return errors.Join(err, stopErr)
}

type ownerListener struct {
	net.Listener
	authorize func(net.Conn) bool
	helper    *helper
}

func (l ownerListener) Accept() (net.Conn, error) {
	rejectionLogged := false
	for {
		conn, err := l.Listener.Accept()
		if errors.Is(err, net.ErrClosed) {
			return nil, err
		}
		if err != nil {
			l.helper.log(fmt.Sprintf("Helper could not accept a connection: %v", err))
			time.Sleep(time.Second)
			continue
		}
		if l.authorize(conn) {
			return conn, nil
		}
		conn.Close()
		if !rejectionLogged {
			l.helper.log("Helper refused a connection from an account other than its owner")
			rejectionLogged = true
		}
	}
}
