package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestFrameBoundsAndPartialWrites(t *testing.T) {
	payload := []byte("a framed response")
	writer := &shortWriter{}
	if err := writeFrame(writer, payload); err != nil {
		t.Fatal(err)
	}
	actual, err := readFrame(bytes.NewReader(writer.Bytes()))
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("frame = %q, %v", actual, err)
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], maxFrameSize+1)
	if _, err := readFrame(bytes.NewReader(header[:])); err == nil {
		t.Fatal("accepted an oversized frame")
	}
	if _, err := readFrame(bytes.NewReader([]byte{1, 0})); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("truncated frame: %v", err)
	}
}

type shortWriter struct{ bytes.Buffer }

func (writer *shortWriter) Write(data []byte) (int, error) {
	if len(data) > 2 {
		data = data[:2]
	}
	return writer.Buffer.Write(data)
}

func testHost(t *testing.T) (*host, net.Conn) {
	return testHostReply(t, func(frame []byte) []byte { return frame })
}

func testHostReply(t *testing.T, reply func([]byte) []byte) (*host, net.Conn) {
	t.Helper()
	core, peer := net.Pipe()
	h := &host{
		config: launchConfig{SafeMode: true}, token: "secret", controlURL: "http://127.0.0.1:12345",
		core: core, corePID: os.Getpid(), quit: func() {}, setTrayVisible: func(bool) error { return nil },
	}
	go h.readCore(core)
	go func() {
		for {
			frame, err := readFrame(peer)
			if err != nil {
				return
			}
			if writeFrame(peer, reply(frame)) != nil {
				return
			}
		}
	}()
	t.Cleanup(func() {
		h.operation.Lock()
		h.closed = true
		h.closeFrontend()
		core.Close()
		peer.Close()
		h.operation.Unlock()
	})
	return h, peer
}

func TestTrayActionsUseCoreAcknowledgementsAndResumeMode(t *testing.T) {
	var requests []map[string]any
	failure := false
	h, _ := testHostReply(t, func(frame []byte) []byte {
		var call map[string]any
		if err := json.Unmarshal(frame, &call); err != nil {
			t.Error(err)
		}
		requests = append(requests, call)
		result := any("")
		if call["method"] == "closeConnections" {
			result = true
		}
		response := map[string]any{"id": call["id"], "result": result}
		if failure {
			response["error"] = map[string]string{"code": "core_error", "message": "rejected"}
		}
		encoded, _ := json.Marshal(response)
		return encoded
	})
	session := randomID()
	front, _ := attachFrontend(t, h, session)
	response := control(h, "/lightweight", h.token, `{"sessionId":"`+session+`","mode":"rule","runningSince":123}`)
	if response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	if response := control(h, "/tray-action", h.token, `{"action":"global"}`); response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	if len(requests) != 1 || requests[0]["method"] != "updateConfig" || requests[0]["arguments"].(map[string]any)["mode"] != "global" {
		t.Fatalf("requests: %v", requests)
	}
	if response := control(h, "/tray-action", h.token, `{"action":"closeConnections"}`); response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	failure = true
	if response := control(h, "/tray-action", h.token, `{"action":"direct"}`); response.Code == http.StatusOK {
		t.Fatal("accepted a rejected mode change")
	}
	if response := control(h, "/tray-action", h.token, `{"action":"shutdown"}`); response.Code == http.StatusOK {
		t.Fatal("accepted an unsupported action")
	}
	front.Close()
	_, state := attachFrontend(t, h, randomID())
	if state["mode"] != "global" || state["wasLightweight"] != true {
		t.Fatalf("resume: %v", state)
	}
	if response := control(h, "/tray-action", h.token, `{"action":"direct"}`); response.Code == http.StatusOK {
		t.Fatal("a stale tray changed the foreground mode")
	}
}

func TestCancelLightweightKeepsFrontendAndRejectsStaleSessions(t *testing.T) {
	h, _ := testHost(t)
	session := randomID()
	front, _ := attachFrontend(t, h, session)
	if result := control(h, "/lightweight", h.token, `{"sessionId":"`+session+`"}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	if result := control(h, "/cancel-lightweight", h.token, `{"sessionId":"stale"}`); result.Code == http.StatusOK {
		t.Fatal("stale session cancelled handoff")
	}
	if result := control(h, "/cancel-lightweight", h.token, `{"sessionId":"`+session+`"}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	if h.lightweight || h.trayVisible.Load() {
		t.Fatal("handoff was not cancelled")
	}
	if err := writeFrame(front, []byte("still running")); err != nil {
		t.Fatal(err)
	}
	if data, err := readFrame(front); err != nil || string(data) != "still running" {
		t.Fatalf("response = %q, %v", data, err)
	}
}

func attachFrontend(t *testing.T, h *host, session string) (net.Conn, map[string]any) {
	t.Helper()
	listener, address, err := listenCore(randomID())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	accepted := make(chan net.Conn, 1)
	go func() { connection, _ := listener.Accept(); accepted <- connection }()
	h.operation.Lock()
	response, err := h.attach(attachRequest{SessionID: session, Address: address, UIPID: os.Getpid()})
	h.operation.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	select {
	case connection := <-accepted:
		if connection == nil {
			t.Fatal("no frontend connection")
		}
		t.Cleanup(func() { connection.Close() })
		return connection, response.(map[string]any)
	case <-time.After(3 * time.Second):
		t.Fatal("frontend connection timed out")
	}
	return nil, nil
}

func control(h *host, path, token, body string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, h.controlURL+path, bytes.NewBufferString(body))
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	h.serveHTTP(response, request)
	return response
}

func TestLightweightReattachesToTheSameCore(t *testing.T) {
	h, _ := testHost(t)
	firstSession := randomID()
	first, _ := attachFrontend(t, h, firstSession)
	if err := writeFrame(first, []byte("before")); err != nil {
		t.Fatal(err)
	}
	if data, err := readFrame(first); err != nil || string(data) != "before" {
		t.Fatalf("first response %q, %v", data, err)
	}
	response := control(h, "/lightweight", h.token, `{"sessionId":"`+firstSession+`","runningSince":12345,"cleanupProxy":true}`)
	if response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	first.Close()
	deadline := time.Now().Add(3 * time.Second)
	for {
		h.frontMu.Lock()
		detached := h.front == nil
		h.frontMu.Unlock()
		if detached {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("frontend did not detach")
		}
		time.Sleep(time.Millisecond)
	}
	second, state := attachFrontend(t, h, randomID())
	if state["wasLightweight"] != true || state["coreReused"] != true || state["corePid"] != os.Getpid() {
		t.Fatalf("resume state: %v", state)
	}
	if value := state["runningSince"].(*int64); value == nil || *value != 12345 {
		t.Fatal("lost the running time")
	}
	if err := writeFrame(second, []byte("after")); err != nil {
		t.Fatal(err)
	}
	if data, err := readFrame(second); err != nil || string(data) != "after" {
		t.Fatalf("resumed response %q, %v", data, err)
	}
	if response := control(h, "/stop", h.token, `{"sessionId":"`+firstSession+`"}`); response.Code == http.StatusOK {
		t.Fatal("a superseded session stopped the core")
	}
	h.operation.Lock()
	active := h.corePID == os.Getpid()
	h.operation.Unlock()
	if !active {
		t.Fatal("core stopped during UI reconstruction")
	}
}

func TestControlRequiresTokenAndRejectsBrowserRequests(t *testing.T) {
	h, _ := testHost(t)
	if result := control(h, "/quit", "wrong", "{}"); result.Code != http.StatusForbidden {
		t.Fatal("accepted wrong token")
	}
	request := httptest.NewRequest(http.MethodGet, h.controlURL+"/status", nil)
	request.Header.Set("Authorization", "Bearer "+h.token)
	request.Header.Set("Origin", "https://example.com")
	response := httptest.NewRecorder()
	h.serveHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatal("accepted browser origin")
	}
}

func TestTrayFailureKeepsTheFrontendActive(t *testing.T) {
	h, _ := testHost(t)
	session := randomID()
	front, _ := attachFrontend(t, h, session)
	h.setTrayVisible = func(bool) error { return errors.New("tray unavailable") }
	response := control(h, "/lightweight", h.token, `{"sessionId":"`+session+`"}`)
	if response.Code == http.StatusOK {
		t.Fatal("accepted handoff without a tray")
	}
	h.operation.Lock()
	lightweight := h.lightweight
	h.operation.Unlock()
	if lightweight || h.trayVisible.Load() {
		t.Fatal("failed handoff changed mode")
	}
	if err := writeFrame(front, []byte("still connected")); err != nil {
		t.Fatal(err)
	}
	if data, err := readFrame(front); err != nil || string(data) != "still connected" {
		t.Fatalf("response = %q, %v", data, err)
	}
}

func TestHelperStopDoesNotReleaseAnUnconfirmedLease(t *testing.T) {
	for _, response := range []string{
		`{"sessionId":"wrong","stopped":true}`,
		`{"sessionId":"owned","stopped":false,"reason":"notRunning"}`,
		`{"sessionId":"owned","stopped":true,"reason":"sessionMismatch"}`,
	} {
		t.Run(response, func(t *testing.T) {
			h, _ := testHost(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprint(w, response)
			}))
			defer server.Close()
			h.helperURL, h.coreSession = server.URL, "owned"
			if err := h.stopCore(); err == nil {
				t.Fatal("released a live Core without confirmed termination")
			}
			if h.core == nil || h.corePID != os.Getpid() {
				t.Fatal("lost the unconfirmed lease")
			}
		})
	}
}

func TestStaleTrayExitCannotStopTheRestoredFrontend(t *testing.T) {
	h, _ := testHost(t)
	h.exitFromTray()
	h.operation.Lock()
	defer h.operation.Unlock()
	if h.closed || h.core == nil || h.corePID != os.Getpid() {
		t.Fatal("a stale tray request stopped the foreground Core")
	}
}
