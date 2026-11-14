package main

import (
	"encoding/json"
	"flag"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"fyne.io/systray"
)

type hostState struct {
	URL   string `json:"url"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

func main() {
	configPath := flag.String("config", "", "desktop host configuration")
	flag.Parse()
	data, err := os.ReadFile(*configPath)
	if err != nil {
		os.Exit(1)
	}
	var config launchConfig
	if json.Unmarshal(data, &config) != nil || !filepath.IsAbs(config.Home) || !filepath.IsAbs(config.App) || !filepath.IsAbs(config.Core) {
		os.Exit(1)
	}
	executable, err := os.Executable()
	if err != nil || (filepath.Dir(config.App) != filepath.Dir(executable) && !(runtime.GOOS == "linux" && config.AppImage)) || filepath.Dir(config.Core) != filepath.Dir(executable) {
		os.Exit(1)
	}
	lock, err := lockHost(filepath.Join(config.Home, ".desktop-host.lock"))
	if err != nil {
		os.Exit(1)
	}
	defer lock.Close()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		os.Exit(1)
	}
	defer listener.Close()
	h := &host{config: config, uiPID: config.UIPID, token: randomID() + randomID(), controlURL: "http://" + listener.Addr().String()}
	h.settings = traySettings{Icon: config.Icon, Template: runtime.GOOS == "darwin", ToolTip: "FlClashX", Labels: config.Labels}
	ready, done := make(chan struct{}), make(chan struct{})
	var quit sync.Once
	h.quit = func() { quit.Do(func() { close(done); systray.Quit() }) }
	h.waitTray = func() error {
		select {
		case <-ready:
			return nil
		case <-done:
			return os.ErrProcessDone
		case <-time.After(5 * time.Second):
			return os.ErrDeadlineExceeded
		}
	}
	server := &http.Server{Handler: http.HandlerFunc(h.serveHTTP), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 4096}
	defer server.Close()
	statePath := filepath.Join(config.Home, ".desktop-host.json")
	if writeState(statePath, hostState{h.controlURL, h.token, os.Getpid()}) != nil {
		return
	}
	defer os.Remove(statePath)
	go server.Serve(listener)
	go h.watchFrontend(done)
	configureTrayApplication()
	systray.Run(func() {
		icon, err := os.ReadFile(config.Icon)
		if err != nil {
			h.quit()
			return
		}
		if runtime.GOOS == "darwin" {
			systray.SetTemplateIcon(icon, icon)
		} else {
			systray.SetIcon(icon)
		}
		go h.runTray(config.Labels, done, func() { close(ready) })
	}, func() {})
	h.operation.Lock()
	h.closed = true
	h.closeFrontend()
	_ = h.stopCore()
	h.operation.Unlock()
}
