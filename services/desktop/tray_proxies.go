package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

type trayActionRequest struct {
	Action string `json:"action"`
	Group  string `json:"group,omitempty"`
	Proxy  string `json:"proxy,omitempty"`
}

type trayProxy struct {
	Name      string `json:"name"`
	Delay     *int   `json:"delay,omitempty"`
	Testing   bool   `json:"testing,omitempty"`
	probeable bool
}

type trayGroup struct {
	Name       string      `json:"name"`
	Now        string      `json:"now"`
	Selectable bool        `json:"selectable"`
	Proxies    []trayProxy `json:"proxies"`
	url        string
	hidden     bool
}

type trayMenuState struct {
	Mode     string      `json:"mode"`
	Running  bool        `json:"running"`
	Testing  bool        `json:"testing"`
	Groups   []trayGroup `json:"groups"`
	revision string
}

type trayProbeKey struct{ name, url string }

type trayProxyState struct {
	groups           []trayGroup
	updated          time.Time
	profileID        string
	testURL          string
	timeout          int
	closeConnections bool
	selections       map[string]string
	delays           map[trayProbeKey]int
	pending          map[trayProbeKey]bool
	generation       uint64
	revision         uint64
}

func (s *trayProxyState) cancelTests() {
	s.generation++
	s.revision++
	s.pending = nil
}

func (h *host) refreshTrayGroups() error {
	data, err := h.trayInvoke("getProxies", nil)
	if err != nil {
		return err
	}
	var raw struct {
		All     []string `json:"all"`
		Proxies map[string]struct {
			Type    string   `json:"type"`
			All     []string `json:"all"`
			Now     string   `json:"now"`
			Hidden  bool     `json:"hidden"`
			TestURL string   `json:"testUrl"`
		} `json:"proxies"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.Proxies == nil || raw.All == nil {
		return errors.New("invalid proxy list response")
	}
	groups := make([]trayGroup, 0, len(raw.All))
	for _, name := range raw.All {
		proxy, exists := raw.Proxies[name]
		if !exists {
			continue
		}
		kind := strings.ReplaceAll(strings.ToLower(proxy.Type), "-", "")
		if kind != "selector" && kind != "urltest" && kind != "fallback" && kind != "loadbalance" {
			continue
		}
		group := trayGroup{Name: name, Now: proxy.Now, Selectable: kind != "loadbalance", url: proxy.TestURL, hidden: proxy.Hidden}
		if group.url == "" {
			group.url = h.tray.testURL
		}
		group.Proxies = make([]trayProxy, 0, len(proxy.All))
		for _, member := range proxy.All {
			node, exists := raw.Proxies[member]
			if !exists {
				continue
			}
			probeable := true
			switch strings.ToLower(node.Type) {
			case "reject", "rejectdrop", "pass", "passrule", "rematch", "compatible", "dns":
				probeable = false
			}
			group.Proxies = append(group.Proxies, trayProxy{Name: member, probeable: probeable})
		}
		groups = append(groups, group)
	}
	h.tray.groups, h.tray.updated = groups, time.Now()
	h.tray.revision++
	return nil
}

func (h *host) trayState(since string) (trayMenuState, error) {
	state := trayMenuState{Mode: h.mode, Running: h.runningSince != nil && h.core != nil, Groups: []trayGroup{}}
	if h.lightweight && h.core != nil && time.Since(h.tray.updated) >= 15*time.Second {
		if err := h.refreshTrayGroups(); err != nil {
			return state, err
		}
	}
	state.revision = fmt.Sprintf("\"%d:%s:%t:%t\"", h.tray.revision, h.mode, state.Running, h.lightweight)
	if since == state.revision || !h.lightweight || h.core == nil {
		return state, nil
	}
	state.Testing = len(h.tray.pending) != 0
	for _, group := range h.tray.groups {
		if h.mode == "direct" || (h.mode == "global" && group.Name != "GLOBAL") ||
			(h.mode != "global" && (group.Name == "GLOBAL" || group.hidden)) {
			continue
		}
		group.Proxies = append([]trayProxy{}, group.Proxies...)
		for index := range group.Proxies {
			node := &group.Proxies[index]
			key := trayProbeKey{node.Name, group.url}
			if delay, exists := h.tray.delays[key]; exists {
				node.Delay = &delay
			}
			node.Testing = h.tray.pending[key]
		}
		state.Groups = append(state.Groups, group)
	}
	return state, nil
}

func (h *host) trayProxyAction(request trayActionRequest) error {
	if h.closed || !h.lightweight || h.core == nil {
		return errors.New("inactive tray")
	}
	if err := h.refreshTrayGroups(); err != nil {
		return err
	}
	state, err := h.trayState("")
	if err != nil {
		return err
	}
	if request.Action == "test" {
		jobs := make([]trayProbeKey, 0)
		pending := make(map[trayProbeKey]bool)
		found := request.Group == ""
		for _, group := range state.Groups {
			if request.Group != "" && group.Name != request.Group {
				continue
			}
			found = true
			for _, proxy := range group.Proxies {
				key := trayProbeKey{proxy.Name, group.url}
				if proxy.probeable && !pending[key] {
					pending[key] = true
					jobs = append(jobs, key)
				}
			}
		}
		if !found {
			return errors.New("unknown proxy group")
		}
		if len(h.tray.pending) != 0 || len(jobs) == 0 {
			return nil
		}
		h.tray.pending = pending
		h.tray.revision++
		timeout := h.tray.timeout
		if timeout <= 0 || timeout > 180000 {
			timeout = 8000
		}
		for worker := 0; worker < min(8, len(jobs)); worker++ {
			go h.testTrayProxies(h.core, h.frontSession, h.tray.generation, jobs, worker, min(8, len(jobs)), timeout)
		}
		return nil
	}
	for _, group := range state.Groups {
		if group.Name != request.Group || !group.Selectable {
			continue
		}
		for _, proxy := range group.Proxies {
			if proxy.Name != request.Proxy {
				continue
			}
			data, err := h.trayInvoke("changeProxy", map[string]string{"group-name": group.Name, "proxy-name": proxy.Name})
			if err != nil {
				return err
			}
			var result struct {
				Message *string `json:"message"`
				Changed *bool   `json:"changed"`
			}
			if err := json.Unmarshal(data, &result); err != nil {
				return err
			}
			if result.Message == nil || result.Changed == nil {
				return errors.New("invalid proxy selection response")
			}
			if *result.Message != "" {
				return errors.New(*result.Message)
			}
			h.tray.selections[group.Name] = proxy.Name
			h.tray.updated = time.Time{}
			if *result.Changed {
				method := "resetConnections"
				if h.tray.closeConnections {
					method = "closeConnections"
				}
				_, err = h.trayInvoke(method, nil)
			}
			return err
		}
	}
	return errors.New("proxy is not a selectable group member")
}

func (h *host) testTrayProxies(core net.Conn, session string, generation uint64, jobs []trayProbeKey, first, stride, timeout int) {
	for index := first; index < len(jobs); index += stride {
		h.operation.Lock()
		active := !h.closed && h.lightweight && h.core == core && h.frontSession == session && h.tray.generation == generation
		h.operation.Unlock()
		if !active {
			return
		}
		key := jobs[index]
		data, err := h.coreInvokeOn(core, "asyncTestDelay", map[string]any{"proxy-name": key.name, "test-url": key.url, "timeout": timeout}, 2*time.Duration(timeout)*time.Millisecond+2*time.Second)
		var result struct {
			Name  string `json:"name"`
			Value *int   `json:"value"`
		}
		valid := err == nil && json.Unmarshal(data, &result) == nil && result.Name == key.name && result.Value != nil && *result.Value != 0
		h.operation.Lock()
		if !h.closed && h.lightweight && h.core == core && h.frontSession == session && h.tray.generation == generation {
			if !valid {
				h.tray.cancelTests()
				h.operation.Unlock()
				return
			}
			h.tray.delays[key] = *result.Value
			delete(h.tray.pending, key)
			h.tray.revision++
		}
		h.operation.Unlock()
	}
}
