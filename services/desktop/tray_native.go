package main

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"time"

	"fyne.io/systray"
)

type trayEntry struct {
	action  string
	checked bool
	enabled bool
}

func trayEntries(state trayMenuState, macOS bool) []trayEntry {
	entries := []trayEntry{{"show", false, true}, {"lightweight", state.Lightweight, true}, {"running", false, true}}
	if macOS {
		entries = append(entries, trayEntry{"showTitle", state.Settings.ShowTitle, true}, trayEntry{"monochrome", state.Settings.Monochrome, true})
	}
	entries = append(entries,
		trayEntry{},
		trayEntry{"rule", state.Mode == "rule", true},
		trayEntry{"global", state.Mode == "global", true},
		trayEntry{"direct", state.Mode == "direct", true},
		trayEntry{},
		trayEntry{"proxies", false, true},
		trayEntry{"closeConnections", false, state.Running},
		trayEntry{},
		trayEntry{"tun", state.Settings.Tun, true},
		trayEntry{"systemProxy", state.Settings.SystemProxy, true},
		trayEntry{"autoLaunch", state.Settings.AutoLaunch, true},
		trayEntry{"copyEnv", false, true},
		trayEntry{"openHome", false, true},
		trayEntry{},
		trayEntry{"exit", false, true},
	)
	return entries
}

func (h *host) runTray(labels map[string]string, done <-chan struct{}, onReady func()) {
	actions := make(chan trayActionRequest, 32)
	bind := func(item *systray.MenuItem, action trayActionRequest) {
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
	items := make(map[string]*systray.MenuItem)
	titles := make(map[string]string)
	var proxies *trayProxyMenu
	for _, entry := range trayEntries(trayMenuState{}, runtime.GOOS == "darwin") {
		if entry.action == "" {
			systray.AddSeparator()
			continue
		}
		if entry.action == "proxies" {
			proxies = newTrayProxyMenu(labels, bind)
			continue
		}
		item := systray.AddMenuItemCheckbox(labels[entry.action], "", false)
		items[entry.action] = item
		titles[entry.action] = labels[entry.action]
		bind(item, trayActionRequest{Action: entry.action})
	}
	systray.SetOnTapped(func() {
		select {
		case actions <- trayActionRequest{Action: "show"}:
		case <-done:
		}
	})
	onReady()
	var iconPath, title, tooltip string
	var template bool
	failed := false
	refresh := func() {
		h.operation.Lock()
		state, err := h.trayState("")
		if state.Lightweight && state.Settings.ShowTitle && h.core != nil {
			if data, trafficError := h.trayInvoke("getTraffic", state.Settings.OnlyProxyTraffic); trafficError == nil {
				var traffic struct{ Up, Down float64 }
				if json.Unmarshal(data, &traffic) == nil {
					state.Settings.Title = trayTraffic(traffic.Up) + "/s\n" + trayTraffic(traffic.Down) + "/s"
				}
			}
		}
		h.operation.Unlock()
		if err != nil {
			failed = true
		}
		settings := state.Settings
		for _, entry := range trayEntries(state, runtime.GOOS == "darwin") {
			item := items[entry.action]
			if item == nil {
				continue
			}
			key := entry.action
			if key == "running" {
				key = "start"
				if state.Running {
					key = "stop"
				}
			}
			text := settings.Labels[key]
			if shortcut := settings.Shortcuts[entry.action]; shortcut != "" {
				text += "\t" + shortcut
			}
			if titles[entry.action] != text {
				item.SetTitle(text)
				titles[entry.action] = text
			}
			setTrayChecked(item, entry.checked)
			setTrayEnabled(item, entry.enabled)
		}
		proxies.updateLabels(settings.Labels)
		proxies.update(state)
		if settings.Icon != "" && (iconPath != settings.Icon || template != settings.Template) {
			if data, err := os.ReadFile(settings.Icon); err == nil {
				if settings.Template {
					systray.SetTemplateIcon(data, data)
				} else {
					systray.SetIcon(data)
				}
				iconPath, template = settings.Icon, settings.Template
			}
		}
		if runtime.GOOS == "darwin" && title != settings.Title {
			systray.SetTitle(settings.Title)
			title = settings.Title
		}
		currentTooltip := settings.ToolTip
		if failed {
			currentTooltip += " · " + settings.Labels["error"]
		}
		if tooltip != currentTooltip {
			systray.SetTooltip(currentTooltip)
			tooltip = currentTooltip
		}
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	refresh()
	for {
		select {
		case action := <-actions:
			h.operation.Lock()
			err := h.dispatchTrayAction(action)
			h.operation.Unlock()
			failed = err != nil
			refresh()
		case <-ticker.C:
			refresh()
		case <-done:
			return
		}
	}
}

func trayTraffic(value float64) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	index := 0
	for value >= 1024 && index < len(units)-1 {
		value /= 1024
		index++
	}
	return fmt.Sprintf("%.0f %s", value, units[index])
}
