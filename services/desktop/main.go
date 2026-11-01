package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"net"
	"net/http"
	"os"
	"os/exec"
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
	trayOnly := flag.Bool("tray", false, "native tray")
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
	statePath := filepath.Join(config.Home, ".desktop-host.json")
	if *trayOnly {
		runTray(config, statePath)
		return
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
	host := &host{config: config, token: randomID() + randomID(), controlURL: "http://" + listener.Addr().String(), trayReady: make(chan struct{}, 1)}
	defer os.Remove(statePath)
	finished := make(chan struct{})
	var quit sync.Once
	host.quit = func() { quit.Do(func() { close(finished) }) }
	var tray *exec.Cmd
	var trayDone chan struct{}
	host.setTrayVisible = func(visible bool) error {
		if !visible {
			if trayDone != nil {
				select {
				case <-trayDone:
				case <-time.After(3 * time.Second):
					return os.ErrDeadlineExceeded
				}
				tray, trayDone = nil, nil
			}
			return nil
		}
		if tray != nil && processAlive(tray.Process.Pid) {
			return nil
		}
		select {
		case <-host.trayReady:
		default:
		}
		if err := writeState(*configPath, host.config); err != nil {
			return err
		}
		command := exec.Command(executable, "--config", *configPath, "--tray")
		prepareCommand(command)
		if err := command.Start(); err != nil {
			return err
		}
		tray = command
		done := make(chan struct{})
		trayDone = done
		go func() { command.Wait(); close(done) }()
		select {
		case <-host.trayReady:
			return nil
		case <-done:
			return os.ErrProcessDone
		case <-time.After(5 * time.Second):
			return os.ErrDeadlineExceeded
		}
	}
	server := &http.Server{Handler: http.HandlerFunc(host.serveHTTP), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 4096}
	defer server.Close()
	if writeState(statePath, hostState{host.controlURL, host.token, os.Getpid()}) != nil {
		return
	}
	go server.Serve(listener)
	<-finished
	host.operation.Lock()
	host.closed = true
	host.lightweight = false
	host.trayVisible.Store(false)
	host.operation.Unlock()
	if trayDone != nil {
		select {
		case <-trayDone:
		case <-time.After(2 * time.Second):
		}
	}
}

func runTray(config launchConfig, statePath string) {
	data, err := os.ReadFile(statePath)
	if err != nil {
		return
	}
	var state hostState
	if json.Unmarshal(data, &state) != nil {
		return
	}
	client := &http.Client{Transport: &http.Transport{Proxy: nil}, Timeout: 10 * time.Second}
	request := func(method, path string, body any) (*http.Response, error) {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		request, err := http.NewRequest(method, state.URL+path, bytes.NewReader(data))
		if err != nil {
			return nil, err
		}
		request.Header.Set("Authorization", "Bearer "+state.Token)
		request.Header.Set("Content-Type", "application/json")
		return client.Do(request)
	}
	systray.Run(func() {
		icon, err := os.ReadFile(config.Icon)
		if err != nil {
			systray.Quit()
			return
		}
		if runtime.GOOS == "darwin" {
			systray.SetTemplateIcon(icon, icon)
		} else {
			systray.SetIcon(icon)
		}
		systray.SetTooltip("FlClashX")
		label := func(key string) string { return config.Labels[key] }
		status := systray.AddMenuItem(label("lightweight"), "")
		status.Disable()
		systray.AddSeparator()
		show := systray.AddMenuItem(config.ShowLabel, "")
		modes := systray.AddMenuItem(label("mode"), "")
		actions := make(chan string, 8)
		done := make(chan struct{})
		bind := func(item *systray.MenuItem, action string) {
			go func() {
				for {
					select {
					case _, ok := <-item.ClickedCh:
						if !ok {
							return
						}
						select {
						case actions <- action:
						case <-done:
							return
						}
					case <-done:
						return
					}
				}
			}()
		}
		modeItems := make(map[string]*systray.MenuItem)
		for _, mode := range []string{"rule", "global", "direct"} {
			item := modes.AddSubMenuItemCheckbox(label(mode), "", false)
			modeItems[mode] = item
			bind(item, mode)
		}
		closeConnections := systray.AddMenuItem(label("closeConnections"), "")
		bind(closeConnections, "closeConnections")
		openHome := systray.AddMenuItem(label("openHome"), "")
		bind(openHome, "openHome")
		systray.AddSeparator()
		quit := systray.AddMenuItem(config.ExitLabel, "")
		refresh := func() {
			response, err := request(http.MethodGet, "/tray-state", nil)
			if err != nil {
				return
			}
			defer response.Body.Close()
			var current struct {
				Mode    string `json:"mode"`
				Running bool   `json:"running"`
			}
			if response.StatusCode != http.StatusOK || json.NewDecoder(response.Body).Decode(&current) != nil {
				return
			}
			runningLabel := label("notRunning")
			if current.Running {
				runningLabel = label("running")
				closeConnections.Enable()
			} else {
				closeConnections.Disable()
			}
			status.SetTitle(label("lightweight") + " · " + runningLabel)
			for mode, item := range modeItems {
				if current.Mode == mode {
					item.Check()
				} else {
					item.Uncheck()
				}
			}
		}
		showUI := func() {
			if response, err := request(http.MethodPost, "/show", nil); err == nil {
				response.Body.Close()
			}
		}
		systray.SetOnTapped(showUI)
		if response, err := request(http.MethodPost, "/tray-ready", nil); err == nil {
			response.Body.Close()
		}
		go func() {
			defer close(done)
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			refresh()
			for {
				select {
				case _, ok := <-show.ClickedCh:
					if !ok {
						return
					}
					showUI()
				case _, ok := <-quit.ClickedCh:
					if !ok {
						return
					}
					if response, err := request(http.MethodPost, "/quit", nil); err == nil {
						response.Body.Close()
					}
				case action := <-actions:
					response, err := request(http.MethodPost, "/tray-action", map[string]string{"action": action})
					if err != nil {
						status.SetTitle(label("error"))
						continue
					}
					response.Body.Close()
					if response.StatusCode != http.StatusOK {
						status.SetTitle(label("error"))
						continue
					}
					refresh()
				case <-ticker.C:
					response, err := request(http.MethodGet, "/tray-status", nil)
					if err != nil {
						systray.Quit()
						return
					}
					var status struct {
						Visible bool `json:"visible"`
					}
					err = json.NewDecoder(response.Body).Decode(&status)
					response.Body.Close()
					if err != nil || !status.Visible {
						systray.Quit()
						return
					}
				}
			}
		}()
	}, func() {})
}
