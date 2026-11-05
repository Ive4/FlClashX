package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"
)

type trayTestCall struct {
	ID        string         `json:"id"`
	Method    string         `json:"method"`
	Arguments map[string]any `json:"arguments"`
}

func proxyFixture(now string, count int) map[string]any {
	proxies := map[string]any{"Reject": map[string]any{"type": "Reject"}}
	members := make([]string, count)
	for index := range members {
		members[index] = "Node " + strconv.Itoa(index)
		proxies[members[index]] = map[string]any{"type": "Shadowsocks"}
	}
	proxies["Japan: 🇯🇵"] = map[string]any{"type": "Selector", "all": members, "now": now, "testUrl": "https://group.invalid/test"}
	proxies["Other"] = map[string]any{"type": "URLTest", "all": append(append([]string{}, members...), "Reject"), "testUrl": "https://group.invalid/test"}
	proxies["GLOBAL"] = map[string]any{"type": "Selector", "all": members, "hidden": true}
	proxies["Hidden"] = map[string]any{"type": "Selector", "all": members, "hidden": true}
	return map[string]any{"all": []string{"GLOBAL", "Japan: 🇯🇵", "Hidden", "Other"}, "proxies": proxies}
}

func getTrayState(t *testing.T, h *host) trayMenuState {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, h.controlURL+"/tray-state", nil)
	request.Header.Set("Authorization", "Bearer "+h.token)
	response := httptest.NewRecorder()
	h.serveHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	var state trayMenuState
	if err := json.Unmarshal(response.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	return state
}

func TestTraySelectionsValidateMembershipAndOnlyResumeAcknowledgedChoices(t *testing.T) {
	now, reject, malformed := "Node 0", false, false
	var mu sync.Mutex
	var methods []string
	h, _ := testHostReply(t, func(frame []byte) []byte {
		mu.Lock()
		defer mu.Unlock()
		var call trayTestCall
		json.Unmarshal(frame, &call)
		methods = append(methods, call.Method)
		var result any
		switch call.Method {
		case "getProxies":
			result = proxyFixture(now, 2)
		case "changeProxy":
			if malformed {
				result = nil
			} else if reject {
				result = map[string]any{"message": "selection rejected", "changed": false}
			} else {
				now = call.Arguments["proxy-name"].(string)
				result = map[string]any{"message": "", "changed": true}
			}
		default:
			result = true
		}
		data, _ := json.Marshal(map[string]any{"id": call.ID, "result": result})
		return data
	})
	session := randomID()
	front, _ := attachFrontend(t, h, session)
	response := control(h, "/lightweight", h.token, `{"sessionId":"`+session+`","profileId":"42","mode":"rule","closeConnections":true}`)
	if response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	state := getTrayState(t, h)
	if len(state.Groups) != 2 || state.Groups[0].Name != "Japan: 🇯🇵" || !state.Groups[0].Selectable {
		t.Fatalf("groups: %+v", state.Groups)
	}
	requestState := func(etag string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, h.controlURL+"/tray-state", nil)
		request.Header.Set("Authorization", "Bearer "+h.token)
		request.Header.Set("If-None-Match", etag)
		result := httptest.NewRecorder()
		h.serveHTTP(result, request)
		return result
	}
	first := requestState("")
	if etag := first.Header().Get("ETag"); etag == "" {
		t.Fatal("no menu revision")
	} else if result := requestState(etag); result.Code != http.StatusNotModified || result.Body.Len() != 0 {
		t.Fatal("unchanged menu was retransmitted")
	}
	for _, body := range []string{
		`{"action":"select","group":"Japan: 🇯🇵","proxy":"missing"}`,
		`{"action":"select","group":"Hidden","proxy":"Node 1"}`,
	} {
		if result := control(h, "/tray-action", h.token, body); result.Code == http.StatusOK {
			t.Fatal("accepted a missing or hidden target")
		}
	}
	if result := control(h, "/tray-action", h.token, `{"action":"select","group":"Japan: 🇯🇵","proxy":"Node 1"}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	if result := requestState(first.Header().Get("ETag")); result.Code != http.StatusOK {
		t.Fatal("selection did not invalidate the menu revision")
	}
	mu.Lock()
	reject = true
	mu.Unlock()
	if result := control(h, "/tray-action", h.token, `{"action":"select","group":"Japan: 🇯🇵","proxy":"Node 0"}`); result.Code == http.StatusOK {
		t.Fatal("accepted a rejected selection")
	}
	mu.Lock()
	malformed = true
	mu.Unlock()
	if result := control(h, "/tray-action", h.token, `{"action":"select","group":"Japan: 🇯🇵","proxy":"Node 0"}`); result.Code == http.StatusOK {
		t.Fatal("accepted an unanswered selection")
	}
	mu.Lock()
	closed := false
	for _, method := range methods {
		closed = closed || method == "closeConnections"
	}
	mu.Unlock()
	if !closed {
		t.Fatal("did not honor connection cleanup setting")
	}
	front.Close()
	_, resumed := attachFrontend(t, h, randomID())
	selected := resumed["selectedMap"].(map[string]string)
	if resumed["profileId"] != "42" || selected["Japan: 🇯🇵"] != "Node 1" {
		t.Fatalf("resume state: %+v", resumed)
	}
	if result := control(h, "/tray-action", h.token, `{"action":"select","group":"Japan: 🇯🇵","proxy":"Node 0"}`); result.Code == http.StatusOK {
		t.Fatal("a stale tray changed the restored frontend")
	}
}

func asynchronousTrayCore(t *testing.T) (*host, <-chan trayTestCall, func(trayTestCall, any)) {
	t.Helper()
	core, peer := net.Pipe()
	h := &host{
		config: launchConfig{SafeMode: true}, token: "secret", controlURL: "http://127.0.0.1:12345",
		core: core, corePID: os.Getpid(), quit: func() {}, setTrayVisible: func(bool) error { return nil },
	}
	calls := make(chan trayTestCall, 32)
	var write sync.Mutex
	reply := func(call trayTestCall, result any) {
		data, _ := json.Marshal(map[string]any{"id": call.ID, "result": result})
		write.Lock()
		defer write.Unlock()
		writeFrame(peer, data)
	}
	go h.readCore(core)
	go func() {
		for {
			frame, err := readFrame(peer)
			if err != nil {
				return
			}
			var call trayTestCall
			json.Unmarshal(frame, &call)
			if call.Method == "asyncTestDelay" {
				calls <- call
			} else {
				reply(call, proxyFixture("Node 0", 12))
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
	return h, calls, func(call trayTestCall, delay any) {
		if delay == nil {
			reply(call, nil)
			return
		}
		reply(call, map[string]any{"name": call.Arguments["proxy-name"], "value": delay})
	}
}

func nextTrayProbe(t *testing.T, calls <-chan trayTestCall) trayTestCall {
	t.Helper()
	select {
	case call := <-calls:
		return call
	case <-time.After(2 * time.Second):
		t.Fatal("no delay probe")
		return trayTestCall{}
	}
}

func TestTrayTestsAreBoundedDeduplicatedAndDoNotBlockControl(t *testing.T) {
	h, calls, reply := asynchronousTrayCore(t)
	session := randomID()
	attachFrontend(t, h, session)
	if result := control(h, "/lightweight", h.token, `{"sessionId":"`+session+`","mode":"rule","delayTestTimeout":1250}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	if result := control(h, "/tray-action", h.token, `{"action":"test"}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	initial := make([]trayTestCall, 8)
	for index := range initial {
		initial[index] = nextTrayProbe(t, calls)
		if initial[index].Arguments["test-url"] != "https://group.invalid/test" || initial[index].Arguments["timeout"] != float64(1250) {
			t.Fatal(initial[index].Arguments)
		}
	}
	select {
	case <-calls:
		t.Fatal("more than eight concurrent probes")
	default:
	}
	if state := getTrayState(t, h); !state.Testing || !state.Groups[0].Proxies[0].Testing {
		t.Fatal("control did not report the pending batch")
	}
	for _, call := range initial {
		reply(call, 123)
	}
	for index := 0; index < 4; index++ {
		reply(nextTrayProbe(t, calls), -1)
	}
	for deadline := time.Now().Add(2 * time.Second); ; {
		state := getTrayState(t, h)
		if !state.Testing {
			for _, group := range state.Groups {
				for _, proxy := range group.Proxies {
					if proxy.Name != "Reject" && proxy.Delay == nil {
						t.Fatal("lost a group delay result")
					}
				}
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("batch did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	select {
	case <-calls:
		t.Fatal("duplicated group probes or tested Reject")
	default:
	}
	h.operation.Lock()
	h.mode = "global"
	h.operation.Unlock()
	if state := getTrayState(t, h); len(state.Groups) != 1 || state.Groups[0].Name != "GLOBAL" {
		t.Fatal("global mode did not expose GLOBAL")
	}
}

func TestTrayProbeResultsCannotOutliveTheirLightweightSession(t *testing.T) {
	h, calls, reply := asynchronousTrayCore(t)
	session := randomID()
	attachFrontend(t, h, session)
	control(h, "/lightweight", h.token, `{"sessionId":"`+session+`","mode":"rule"}`)
	control(h, "/tray-action", h.token, `{"action":"test","group":"Japan: 🇯🇵"}`)
	initial := make([]trayTestCall, 8)
	for index := range initial {
		initial[index] = nextTrayProbe(t, calls)
	}
	if result := control(h, "/cancel-lightweight", h.token, `{"sessionId":"`+session+`"}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	for _, call := range initial {
		reply(call, 99)
	}
	h.operation.Lock()
	defer h.operation.Unlock()
	if len(h.tray.delays) != 0 || len(h.tray.pending) != 0 {
		t.Fatal("cancelled results leaked into another session")
	}
}

func TestMissingTrayProbeResponsePreservesMeasurementsAndCancelsBatch(t *testing.T) {
	h, calls, reply := asynchronousTrayCore(t)
	session := randomID()
	attachFrontend(t, h, session)
	control(h, "/lightweight", h.token, `{"sessionId":"`+session+`","mode":"rule"}`)
	key := trayProbeKey{"Node 0", "https://group.invalid/test"}
	h.operation.Lock()
	h.tray.delays[key] = 73
	h.operation.Unlock()
	control(h, "/tray-action", h.token, `{"action":"test"}`)
	initial := make([]trayTestCall, 8)
	for index := range initial {
		initial[index] = nextTrayProbe(t, calls)
	}
	reply(initial[0], nil)
	for deadline := time.Now().Add(2 * time.Second); getTrayState(t, h).Testing; {
		if time.Now().After(deadline) {
			t.Fatal("missing response did not cancel the batch")
		}
		time.Sleep(time.Millisecond)
	}
	for _, call := range initial[1:] {
		reply(call, 999)
	}
	h.operation.Lock()
	defer h.operation.Unlock()
	if len(h.tray.delays) != 1 || h.tray.delays[key] != 73 {
		t.Fatal("missing or late responses replaced the prior measurement")
	}
	select {
	case <-calls:
		t.Fatal("queued probes continued after a missing response")
	default:
	}
}
