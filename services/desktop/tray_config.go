package main

import (
	"errors"
	"maps"
	"os"
	"path/filepath"
	"time"
)

type traySettings struct {
	Mode             string            `json:"mode"`
	RunningSince     *int64            `json:"runningSince"`
	Tun              bool              `json:"tun"`
	SystemProxy      bool              `json:"systemProxy"`
	AutoLaunch       bool              `json:"autoLaunch"`
	ShowTitle        bool              `json:"showTitle"`
	Monochrome       bool              `json:"monochrome"`
	Icon             string            `json:"icon"`
	Template         bool              `json:"template"`
	Title            string            `json:"title"`
	ToolTip          string            `json:"toolTip"`
	Shortcuts        map[string]string `json:"shortcuts"`
	Labels           map[string]string `json:"labels"`
	ProfileID        string            `json:"profileId"`
	TestURL          string            `json:"testUrl"`
	Timeout          int               `json:"timeout"`
	CloseConnections bool              `json:"closeConnections"`
	SelectedMap      map[string]string `json:"selectedMap"`
	OnlyProxyTraffic bool              `json:"onlyProxyTraffic"`
}

type trayConfigRequest struct {
	SessionID string       `json:"sessionId"`
	UIPID     int          `json:"uiPid"`
	Settings  traySettings `json:"settings"`
}

func (h *host) configureTray(request trayConfigRequest) error {
	if h.lightweight {
		return nil
	}
	if request.UIPID <= 0 || (request.SessionID != "" && h.frontSession != "" && request.SessionID != h.frontSession) ||
		(h.uiPID != 0 && h.uiPID != request.UIPID && processAlive(h.uiPID)) {
		return errors.New("inactive frontend")
	}
	settings := request.Settings
	if settings.Icon != "" {
		root := filepath.Dir(filepath.Dir(h.config.Icon))
		relative, err := filepath.Rel(root, settings.Icon)
		if err != nil || !filepath.IsLocal(relative) {
			return errors.New("invalid tray icon")
		}
	}
	if settings.Mode != "rule" && settings.Mode != "global" && settings.Mode != "direct" {
		return errors.New("invalid tray mode")
	}
	h.tray.configure(settings.ProfileID, settings.TestURL, settings.Timeout, settings.CloseConnections)
	if !maps.Equal(h.settings.SelectedMap, settings.SelectedMap) {
		h.tray.updated = time.Time{}
	}
	h.uiPID = request.UIPID
	h.settings = settings
	h.config.Labels = settings.Labels
	h.config.ShowLabel, h.config.ExitLabel = settings.Labels["show"], settings.Labels["exit"]
	h.mode, h.runningSince = settings.Mode, settings.RunningSince
	h.tray.revision++
	return nil
}

func (h *host) queueTrayAction(request trayActionRequest) error {
	if len(h.uiActions) >= 32 {
		return errors.New("frontend action queue is full")
	}
	h.uiActions = append(h.uiActions, request)
	if h.lightweight || !processAlive(h.uiPID) {
		go h.showUI()
	}
	return nil
}

func (h *host) dispatchTrayAction(request trayActionRequest) error {
	if h.closed {
		return os.ErrClosed
	}
	switch request.Action {
	case "show":
		go h.showUI()
		return nil
	case "lightweight":
		if h.lightweight {
			go h.showUI()
			return nil
		}
	case "exit":
		if h.lightweight {
			go h.exitFromTray()
			return nil
		}
	case "test":
		return h.trayProxyAction(request)
	case "openHome", "closeConnections":
		return h.trayAction(request.Action)
	case "rule", "global", "direct":
		if h.lightweight {
			return h.trayAction(request.Action)
		}
	case "select":
		if h.lightweight {
			return h.trayProxyAction(request)
		}
	case "running", "tun", "systemProxy", "autoLaunch", "copyEnv", "showTitle", "monochrome":
	default:
		return errors.New("unsupported tray action")
	}
	return h.queueTrayAction(request)
}
