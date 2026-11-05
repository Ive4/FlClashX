package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTrayReadsLargeSpilledRepliesAndRejectsForeignFiles(t *testing.T) {
	home := t.TempDir()
	root := filepath.Join(home, "responses")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	h := &host{config: launchConfig{Home: home}}
	path := filepath.Join(root, "large.json")
	data, _ := json.Marshal(map[string]any{"id": "tray-owned", "result": map[string]any{"payload": strings.Repeat("x", 1024*1024)}})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	result, err := h.readTrayResponse(trayResponse{ID: "tray-owned", File: path})
	if err != nil || len(result.Result) < 1024*1024 {
		t.Fatalf("spilled result: %d bytes, %v", len(result.Result), err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("did not consume the response file")
	}
	foreign := filepath.Join(home, "private.json")
	if err := os.WriteFile(foreign, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := h.readTrayResponse(trayResponse{ID: "tray-owned", File: foreign}); err == nil {
		t.Fatal("read a path outside the response directory")
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Fatal("removed the foreign file")
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := h.readTrayResponse(trayResponse{ID: "tray-other", File: path}); err == nil {
		t.Fatal("accepted another request's response")
	}
}
