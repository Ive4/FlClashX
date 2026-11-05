package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

const maxFrameSize = 64 << 20

type launchConfig struct {
	Home      string            `json:"home"`
	App       string            `json:"app"`
	Core      string            `json:"core"`
	Icon      string            `json:"icon"`
	ShowLabel string            `json:"showLabel"`
	ExitLabel string            `json:"exitLabel"`
	Labels    map[string]string `json:"labels,omitempty"`
	SafeMode  bool              `json:"safeMode"`
	AppImage  bool              `json:"appImage"`
}

type attachRequest struct {
	SessionID  string `json:"sessionId"`
	Address    string `json:"address"`
	UIPID      int    `json:"uiPid"`
	HelperURL  string `json:"helperUrl"`
	CoreSHA256 string `json:"coreSha256"`
}

type lightweightRequest struct {
	SessionID        string            `json:"sessionId"`
	RunningSince     *int64            `json:"runningSince"`
	CleanupProxy     bool              `json:"cleanupProxy"`
	ShowLabel        string            `json:"showLabel"`
	ExitLabel        string            `json:"exitLabel"`
	Mode             string            `json:"mode"`
	Labels           map[string]string `json:"labels"`
	ProfileID        string            `json:"profileId"`
	TestURL          string            `json:"testUrl"`
	DelayTimeout     int               `json:"delayTestTimeout"`
	CloseConnections bool              `json:"closeConnections"`
}

type host struct {
	config         launchConfig
	token          string
	controlURL     string
	operation      sync.Mutex
	frontMu        sync.Mutex
	coreWriteMu    sync.Mutex
	front          net.Conn
	frontSession   string
	uiPID          int
	core           net.Conn
	coreListener   net.Listener
	coreProcess    *exec.Cmd
	coreDone       chan struct{}
	coreSession    string
	corePID        int
	helperURL      string
	lightweight    bool
	runningSince   *int64
	cleanupProxy   bool
	closed         bool
	quit           func()
	setTrayVisible func(bool) error
	trayReady      chan struct{}
	trayVisible    atomic.Bool
	launching      bool
	mode           string
	pendingMu      sync.Mutex
	pending        map[string]chan trayResponse
	tray           trayProxyState
}

func randomID() string {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data)
}

func (h *host) serveHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" || r.Host != h.controlURL[len("http://"):] || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+h.token)) != 1 {
		http.Error(w, "unauthorized", http.StatusForbidden)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodPost && r.URL.Path == "/tray-ready" {
		select {
		case h.trayReady <- struct{}{}:
		default:
		}
		json.NewEncoder(w).Encode(map[string]bool{"ready": true})
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/tray-status" {
		// Visibility must stay lock-free while attach waits for the tray to exit.
		json.NewEncoder(w).Encode(map[string]bool{"visible": h.trayVisible.Load()})
		return
	}
	h.operation.Lock()
	defer h.operation.Unlock()
	if h.closed {
		http.Error(w, "closed", http.StatusGone)
		return
	}
	var response any
	var err error
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/status":
		response = map[string]any{"pid": os.Getpid(), "corePid": h.corePID, "lightweight": h.lightweight, "runningSince": h.runningSince}
	case r.Method == http.MethodPost && r.URL.Path == "/show":
		go h.showUI()
		response = map[string]bool{"accepted": true}
	case r.Method == http.MethodGet && r.URL.Path == "/tray-state":
		var state trayMenuState
		state, err = h.trayState(r.Header.Get("If-None-Match"))
		if err == nil {
			w.Header().Set("ETag", state.revision)
			if state.revision == r.Header.Get("If-None-Match") {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
		response = state
	case r.Method == http.MethodPost && r.URL.Path == "/tray-action":
		var request trayActionRequest
		if err = decodeRequest(r, &request); err == nil {
			if request.Action == "select" || request.Action == "test" {
				err = h.trayProxyAction(request)
			} else {
				err = h.trayAction(request.Action)
			}
			response = map[string]bool{"applied": err == nil}
		}
	case r.Method == http.MethodPost && r.URL.Path == "/cancel-lightweight":
		var request struct {
			SessionID string `json:"sessionId"`
		}
		if err = decodeRequest(r, &request); err == nil {
			if request.SessionID != h.frontSession {
				err = errors.New("superseded session")
			} else {
				h.lightweight = false
				h.tray.cancelTests()
				h.trayVisible.Store(false)
				err = h.setTrayVisible(false)
				response = map[string]bool{"cancelled": err == nil}
			}
		}
	case r.Method == http.MethodPost && r.URL.Path == "/quit":
		go h.exitFromTray()
		response = map[string]bool{"accepted": true}
	case r.Method == http.MethodPost && r.URL.Path == "/attach":
		var request attachRequest
		if err = decodeRequest(r, &request); err == nil {
			response, err = h.attach(request)
		}
	case r.Method == http.MethodPost && r.URL.Path == "/lightweight":
		var request lightweightRequest
		if err = decodeRequest(r, &request); err == nil {
			if request.SessionID != h.frontSession || h.core == nil {
				err = errors.New("inactive session")
			} else {
				if request.ShowLabel != "" && request.ExitLabel != "" {
					h.config.ShowLabel, h.config.ExitLabel = request.ShowLabel, request.ExitLabel
				}
				h.config.Labels = request.Labels
				h.mode = request.Mode
				h.tray = trayProxyState{
					profileID: request.ProfileID, testURL: request.TestURL,
					timeout: request.DelayTimeout, closeConnections: request.CloseConnections,
					generation: h.tray.generation + 1,
					revision:   h.tray.revision + 1,
					selections: make(map[string]string), delays: make(map[trayProbeKey]int),
				}
				h.lightweight = true
				h.runningSince = request.RunningSince
				h.cleanupProxy = request.CleanupProxy && !h.config.SafeMode
				h.trayVisible.Store(true)
				if err = h.setTrayVisible(true); err != nil {
					h.lightweight = false
					h.trayVisible.Store(false)
				} else {
					response = map[string]any{"ready": true}
				}
			}
		}
	case r.Method == http.MethodPost && r.URL.Path == "/stop":
		var request struct {
			SessionID string `json:"sessionId"`
		}
		if err = decodeRequest(r, &request); err == nil {
			if request.SessionID != h.frontSession {
				err = errors.New("superseded session")
			} else {
				err = h.stopCore()
				if err == nil {
					response = map[string]any{"stopped": true}
					h.closed = true
					h.closeFrontend()
					go func() { time.Sleep(100 * time.Millisecond); h.quit() }()
				}
			}
		}
	default:
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		w.WriteHeader(http.StatusConflict)
		response = map[string]string{"error": err.Error()}
	}
	json.NewEncoder(w).Encode(response)
}

func decodeRequest(r *http.Request, value any) error {
	reader := http.MaxBytesReader(nil, r.Body, 16<<10)
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("unexpected trailing data")
	}
	return nil
}

func (h *host) attach(request attachRequest) (any, error) {
	if value, err := hex.DecodeString(request.SessionID); err != nil || len(value) != 16 || request.UIPID <= 0 {
		return nil, errors.New("invalid session")
	}
	if h.frontSession != "" && h.frontSession != request.SessionID && !h.lightweight && processAlive(h.uiPID) {
		return nil, errors.New("another frontend owns the session")
	}
	wasLightweight, runningSince := h.lightweight, h.runningSince
	reused := h.core != nil && processAlive(h.corePID)
	if !reused {
		if h.core != nil {
			return nil, errors.New("core exit is not confirmed")
		}
		if err := h.startCore(request); err != nil {
			return nil, err
		}
	}
	front, err := dialFrontend(request.Address)
	if err != nil {
		if !reused {
			_ = h.stopCore()
		}
		return nil, err
	}
	h.closeFrontend()
	h.frontMu.Lock()
	h.front = front
	h.frontMu.Unlock()
	h.frontSession, h.uiPID = request.SessionID, request.UIPID
	h.tray.cancelTests()
	h.lightweight = false
	h.trayVisible.Store(false)
	_ = h.setTrayVisible(false)
	core := h.core
	go h.readFrontend(front, core, request.SessionID)
	return map[string]any{"pid": os.Getpid(), "corePid": h.corePID, "wasLightweight": wasLightweight, "coreReused": reused, "runningSince": runningSince, "mode": h.mode, "profileId": h.tray.profileID, "selectedMap": h.tray.selections}, nil
}

func (h *host) startCore(request attachRequest) error {
	coreSession := randomID()
	listener, address, err := listenCore(coreSession)
	if err != nil {
		return err
	}
	h.coreSession, h.coreListener = coreSession, listener
	h.helperURL = ""
	if request.HelperURL != "" && !h.config.SafeMode {
		h.helperURL = request.HelperURL
		var response struct {
			PID       int    `json:"pid"`
			SessionID string `json:"sessionId"`
		}
		err = h.helperRequest("/start", map[string]string{"address": address, "sessionId": coreSession}, &response)
		if err == nil && (response.PID <= 0 || response.SessionID != coreSession) {
			err = errors.New("invalid helper lease")
		}
		h.corePID = response.PID
	}
	var helperFailure *helperError
	if errors.As(err, &helperFailure) && (helperFailure.Code == "coreVerificationFailed" || helperFailure.Code == "processLaunchFailed") {
		h.helperURL = ""
		err = nil
	}
	if h.helperURL == "" && err == nil {
		h.helperURL = ""
		command := exec.Command(h.config.Core, address)
		prepareCommand(command)
		command.Stdout, command.Stderr = io.Discard, io.Discard
		err = command.Start()
		if err == nil {
			h.coreProcess, h.corePID = command, command.Process.Pid
			done := make(chan struct{})
			h.coreDone = done
			go func() { command.Wait(); close(done) }()
		}
	}
	if err != nil {
		listener.Close()
		return err
	}
	type accepted struct {
		connection net.Conn
		err        error
	}
	ready := make(chan accepted, 1)
	go func() { connection, err := listener.Accept(); ready <- accepted{connection, err} }()
	select {
	case result := <-ready:
		err = result.err
		if err == nil {
			err = validateCorePeer(result.connection, h.corePID)
		}
		if err != nil && result.connection != nil {
			result.connection.Close()
		}
		if err == nil {
			h.core = result.connection
			go h.readCore(result.connection)
		}
	case <-time.After(10 * time.Second):
		err = errors.New("core connection timed out")
	}
	if err != nil {
		listener.Close()
		_ = h.stopCore()
		return err
	}
	return nil
}

func (h *host) helperRequest(path string, body, response any) error {
	base, err := url.Parse(h.helperURL)
	if err != nil || base.Scheme != "http" || base.User != nil || base.RawQuery != "" || base.Fragment != "" {
		return errors.New("invalid helper endpoint")
	}
	transport := &http.Transport{Proxy: nil}
	if runtime.GOOS == "linux" {
		if base.Host != "FlClashHelperService" {
			return errors.New("invalid helper authority")
		}
		transport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", "/run/flclash/helper.sock")
		}
	} else if base.Hostname() != "127.0.0.1" || base.Port() == "" {
		return errors.New("invalid helper host")
	}
	defer transport.CloseIdleConnections()
	data, _ := json.Marshal(body)
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	result, err := client.Post(h.helperURL+path, "application/json", bytes.NewReader(data))
	if err != nil {
		return err
	}
	defer result.Body.Close()
	if result.StatusCode != http.StatusOK {
		var failure helperError
		if json.NewDecoder(io.LimitReader(result.Body, 16<<10)).Decode(&failure) == nil && failure.Code != "" {
			return &failure
		}
		return fmt.Errorf("helper %s returned HTTP %d", path, result.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(result.Body, 16<<10)).Decode(response)
}

type helperError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *helperError) Error() string { return e.Code + ": " + e.Message }

func (h *host) readFrontend(front, core net.Conn, session string) {
	for {
		frame, err := readFrame(front)
		if err != nil {
			break
		}
		h.coreWriteMu.Lock()
		h.frontMu.Lock()
		current := h.front == front
		h.frontMu.Unlock()
		if current {
			err = writeFrame(core, frame)
		}
		h.coreWriteMu.Unlock()
		if err != nil || !current {
			break
		}
	}
	h.operation.Lock()
	defer h.operation.Unlock()
	if h.frontSession != session {
		return
	}
	h.closeFrontend()
	if !h.lightweight && !h.closed {
		if h.stopCore() == nil {
			h.closed = true
			go h.quit()
		}
	}
}

func (h *host) readCore(core net.Conn) {
	for {
		frame, err := readFrame(core)
		if err != nil {
			break
		}
		if h.handleTrayResponse(frame) {
			continue
		}
		h.frontMu.Lock()
		if h.front != nil {
			h.front.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := writeFrame(h.front, frame); err != nil {
				h.front.Close()
				h.front = nil
			}
		}
		h.frontMu.Unlock()
	}
	h.operation.Lock()
	defer h.operation.Unlock()
	if h.core != core {
		return
	}
	h.closeFrontend()
	_ = h.stopCore()
	if h.lightweight && !h.closed {
		go h.showUI()
	}
}

func (h *host) closeFrontend() {
	h.frontMu.Lock()
	defer h.frontMu.Unlock()
	if h.front != nil {
		h.front.Close()
		h.front = nil
	}
}

func (h *host) stopCore() error {
	if h.corePID != 0 {
		if h.core != nil && processAlive(h.corePID) {
			_, _ = h.coreInvoke("shutdown", nil, 30*time.Second)
		}
		if h.helperURL != "" {
			var response struct {
				SessionID string  `json:"sessionId"`
				Stopped   *bool   `json:"stopped"`
				Reason    *string `json:"reason"`
			}
			err := h.helperRequest("/stop", map[string]string{"sessionId": h.coreSession}, &response)
			if err == nil && (response.SessionID != h.coreSession || response.Stopped == nil || (*response.Stopped && response.Reason != nil) || (!*response.Stopped && (response.Reason == nil || *response.Reason != "notRunning"))) {
				err = errors.New("invalid helper stop response")
			}
			if err == nil && !*response.Stopped && processAlive(h.corePID) {
				err = errors.New("core exit is not confirmed")
			}
			if err != nil && processAlive(h.corePID) {
				return err
			}
		} else if h.coreProcess != nil {
			_ = h.coreProcess.Process.Kill()
			select {
			case <-h.coreDone:
			case <-time.After(10 * time.Second):
				return errors.New("core exit is not confirmed")
			}
		}
	}
	if !h.config.SafeMode && h.corePID != 0 {
		if err := flushDNSCache(); err != nil {
			return err
		}
	}
	if h.core != nil {
		h.core.Close()
		h.core = nil
	}
	if h.coreListener != nil {
		h.coreListener.Close()
		h.coreListener = nil
	}
	h.corePID = 0
	return nil
}

func (h *host) showUI() {
	h.operation.Lock()
	if h.closed || h.launching {
		h.operation.Unlock()
		return
	}
	h.launching = true
	previousPID := h.uiPID
	h.operation.Unlock()
	defer func() { h.operation.Lock(); h.launching = false; h.operation.Unlock() }()
	for deadline := time.Now().Add(5 * time.Second); processAlive(previousPID) && time.Now().Before(deadline); {
		time.Sleep(100 * time.Millisecond)
	}
	arguments := []string{"--show"}
	if h.config.SafeMode {
		arguments = append(arguments, "--safe-instance")
	}
	command := exec.Command(h.config.App, arguments...)
	command.Dir = h.config.Home
	prepareCommand(command)
	if command.Start() == nil {
		go command.Wait()
	}
}

func (h *host) exitFromTray() {
	h.operation.Lock()
	defer h.operation.Unlock()
	if h.closed || !h.lightweight {
		return
	}
	if h.stopCore() != nil {
		go h.showUI()
		return
	}
	if !h.config.SafeMode && (h.cleanupProxy || runtime.GOOS == "darwin") {
		arguments := []string{"--lightweight-cleanup"}
		if h.cleanupProxy {
			arguments = append(arguments, "--proxy")
		}
		if runtime.GOOS == "windows" {
			arguments = []string{"--clear-stale-proxy"}
		}
		command := exec.Command(h.config.App, arguments...)
		command.Dir = h.config.Home
		prepareCommand(command)
		if err := command.Run(); err != nil {
			go h.showUI()
			return
		}
	}
	h.closed = true
	go h.quit()
}

func readFrame(reader io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	length := binary.LittleEndian.Uint32(header[:])
	if length > maxFrameSize {
		return nil, errors.New("oversized IPC frame")
	}
	data := make([]byte, length)
	_, err := io.ReadFull(reader, data)
	return data, err
}

func writeFrame(writer io.Writer, data []byte) error {
	if len(data) > maxFrameSize {
		return errors.New("oversized IPC frame")
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(data)))
	for _, part := range [][]byte{header[:], data} {
		for len(part) > 0 {
			written, err := writer.Write(part)
			if err != nil {
				return err
			}
			if written == 0 {
				return io.ErrShortWrite
			}
			part = part[written:]
		}
	}
	return nil
}

func writeState(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	temp := filepath.Join(filepath.Dir(path), ".desktop-state-"+randomID())
	if err = os.WriteFile(temp, data, 0600); err != nil {
		return err
	}
	defer os.Remove(temp)
	return os.Rename(temp, path)
}
