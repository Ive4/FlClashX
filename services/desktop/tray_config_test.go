package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
)

func TestBothModesKeepTheSameMenuAndOrder(t *testing.T) {
	for _, macOS := range []bool{false, true} {
		state := trayMenuState{Mode: "rule", Running: true}
		normal := trayEntries(state, macOS)
		state.Lightweight = true
		light := trayEntries(state, macOS)
		if len(normal) != len(light) {
			t.Fatal("mode switch changed the menu length")
		}
		seen := map[string]bool{}
		for index, entry := range normal {
			if entry.action != light[index].action || entry.enabled != light[index].enabled {
				t.Fatalf("mode switch changed item %d", index)
			}
			seen[entry.action] = true
		}
		for _, action := range []string{"show", "lightweight", "running", "rule", "global", "direct", "proxies", "closeConnections", "tun", "systemProxy", "autoLaunch", "copyEnv", "openHome", "exit"} {
			if !seen[action] {
				t.Fatalf("missing %s", action)
			}
		}
		if seen["showTitle"] != macOS || seen["monochrome"] != macOS {
			t.Fatal("macOS menu controls changed platform")
		}
	}
}

func TestTrayActionsUseTheCurrentFrontendAndAreDeliveredOnce(t *testing.T) {
	h, _ := testHost(t)
	session := randomID()
	_, _ = attachFrontend(t, h, session)
	for _, action := range []string{"running", "tun", "systemProxy", "autoLaunch", "copyEnv", "showTitle", "monochrome", "lightweight", "exit"} {
		if result := control(h, "/tray-action", h.token, `{"action":"`+action+`"}`); result.Code != http.StatusOK {
			t.Fatal(result.Body.String())
		}
	}
	if result := control(h, "/tray-ui", h.token, `{"sessionId":"stale"}`); result.Code == http.StatusOK {
		t.Fatal("stale frontend drained commands")
	}
	var received []string
	for len(received) < 9 {
		result := control(h, "/tray-ui", h.token, `{"sessionId":"`+session+`","uiPid":`+strconv.Itoa(os.Getpid())+`,"ready":true}`)
		var response struct {
			Actions []trayActionRequest `json:"actions"`
		}
		if result.Code != http.StatusOK || json.Unmarshal(result.Body.Bytes(), &response) != nil || len(response.Actions) != 1 {
			t.Fatal(result.Body.String())
		}
		received = append(received, response.Actions[0].Action)
	}
	want := []string{"running", "tun", "systemProxy", "autoLaunch", "copyEnv", "showTitle", "monochrome", "lightweight", "exit"}
	if !reflect.DeepEqual(received, want) {
		t.Fatalf("commands = %v", received)
	}
	if result := control(h, "/tray-ui", h.token, `{"sessionId":"`+session+`","uiPid":`+strconv.Itoa(os.Getpid())+`,"ready":true}`); result.Body.String() != "{\"actions\":[]}\n" {
		t.Fatal("commands were delivered again")
	}
}

func TestTraySettingsCannotBeOverwrittenByAnOldOrDetachingUI(t *testing.T) {
	h, _ := testHost(t)
	session := randomID()
	_, _ = attachFrontend(t, h, session)
	root := t.TempDir()
	h.config.Icon = filepath.Join(root, "macos", "status_1.png")
	settings := traySettings{Mode: "global", Tun: true, Icon: filepath.Join(root, "unix", "status_3.png")}
	request := trayConfigRequest{SessionID: session, UIPID: os.Getpid(), Settings: settings}
	if err := h.configureTray(request); err != nil {
		t.Fatal(err)
	}
	request.SessionID = "stale"
	if err := h.configureTray(request); err == nil {
		t.Fatal("accepted stale configuration")
	}
	request.SessionID = session
	request.Settings.Icon = filepath.Join(filepath.Dir(root), "outside.png")
	if err := h.configureTray(request); err == nil {
		t.Fatal("accepted icon outside tray assets")
	}
	h.lightweight = true
	request.Settings = traySettings{Mode: "direct"}
	if err := h.configureTray(request); err != nil {
		t.Fatal(err)
	}
	if h.mode != "global" || !h.settings.Tun {
		t.Fatal("detaching UI overwrote background settings")
	}
}

func TestDeferredConfigurationSurvivesUIReattachment(t *testing.T) {
	h, _ := testHost(t)
	session := randomID()
	first, _ := attachFrontend(t, h, session)
	h.lightweight, h.launching = true, true
	if result := control(h, "/tray-action", h.token, `{"action":"tun"}`); result.Code != http.StatusOK {
		t.Fatal(result.Body.String())
	}
	if result := control(h, "/tray-ui", h.token, `{"sessionId":"`+session+`","uiPid":`+strconv.Itoa(os.Getpid())+`,"ready":true}`); result.Body.String() != "{\"actions\":[]}\n" {
		t.Fatal("detaching UI consumed configuration")
	}
	first.Close()
	newSession := randomID()
	_, _ = attachFrontend(t, h, newSession)
	result := control(h, "/tray-ui", h.token, `{"sessionId":"`+newSession+`","uiPid":`+strconv.Itoa(os.Getpid())+`,"ready":true}`)
	if result.Code != http.StatusOK || result.Body.String() != "{\"actions\":[{\"action\":\"tun\"}]}\n" {
		t.Fatal(result.Body.String())
	}
}

func TestTrayTrafficUsesTheOriginalUnits(t *testing.T) {
	if trayTraffic(1024) != "1 KB" || trayTraffic(0) != "0 B" || trayTraffic(1024*1024) != "1 MB" {
		t.Fatal("incorrect traffic units")
	}
}

func TestEarlyTrayExitCannotReleaseAnAttachedCoreOrAnotherUI(t *testing.T) {
	h, _ := testHost(t)
	h.uiPID = os.Getpid()
	body := `{"uiPid":` + strconv.Itoa(os.Getpid()) + `}`
	if response := control(h, "/close-tray", h.token, body); response.Body.String() != "{\"closed\":false}\n" {
		t.Fatal("closed an attached Core")
	}
	h.operation.Lock()
	h.core.Close()
	h.core, h.corePID = nil, 0
	h.operation.Unlock()
	if response := control(h, "/close-tray", h.token, `{"uiPid":0}`); response.Body.String() != "{\"closed\":false}\n" {
		t.Fatal("closed another UI tray")
	}
	if response := control(h, "/close-tray", h.token, body); response.Body.String() != "{\"closed\":true}\n" {
		t.Fatal(response.Body.String())
	}
}
