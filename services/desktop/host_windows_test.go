package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestStopWaitsForCoreShutdownBeforeHelperTermination(t *testing.T) {
	shutdownDone := make(chan struct{})
	h, _ := testHostReply(t, func(frame []byte) []byte {
		var call map[string]any
		if json.Unmarshal(frame, &call) != nil || call["method"] != "shutdown" {
			t.Error("expected Core shutdown")
		}
		time.Sleep(30 * time.Millisecond)
		close(shutdownDone)
		response, _ := json.Marshal(map[string]any{"id": call["id"], "result": true})
		return response
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-shutdownDone:
		default:
			t.Error("Helper termination preceded DNS shutdown")
		}
		fmt.Fprint(w, `{"sessionId":"owned","stopped":true}`)
	}))
	defer server.Close()
	h.helperURL, h.coreSession = server.URL, "owned"
	if err := h.stopCore(); err != nil {
		t.Fatal(err)
	}
}
