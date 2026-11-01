package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

type trayResponse struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
	File string `json:"file"`
}

func (h *host) handleTrayResponse(frame []byte) bool {
	if !bytes.Contains(frame, []byte("tray-")) {
		return false
	}
	var response trayResponse
	if json.Unmarshal(frame, &response) != nil || !strings.HasPrefix(response.ID, "tray-") {
		return false
	}
	h.pendingMu.Lock()
	if pending := h.pending[response.ID]; pending != nil {
		delete(h.pending, response.ID)
		pending <- response
	}
	h.pendingMu.Unlock()
	return true
}

func (h *host) trayInvoke(method string, arguments any) (json.RawMessage, error) {
	id := "tray-" + randomID()
	pending := make(chan trayResponse, 1)
	h.pendingMu.Lock()
	if h.pending == nil {
		h.pending = make(map[string]chan trayResponse)
	}
	h.pending[id] = pending
	h.pendingMu.Unlock()
	defer func() { h.pendingMu.Lock(); delete(h.pending, id); h.pendingMu.Unlock() }()
	data, err := json.Marshal(map[string]any{"id": id, "method": method, "arguments": arguments})
	if err != nil {
		return nil, err
	}
	h.coreWriteMu.Lock()
	h.core.SetWriteDeadline(time.Now().Add(2 * time.Second))
	err = writeFrame(h.core, data)
	h.core.SetWriteDeadline(time.Time{})
	if err != nil {
		h.core.Close()
	}
	h.coreWriteMu.Unlock()
	if err != nil {
		return nil, err
	}
	select {
	case response := <-pending:
		if response.Error != nil {
			return nil, errors.New(response.Error.Message)
		}
		if response.File != "" {
			return nil, errors.New("unexpected spilled tray response")
		}
		return response.Result, nil
	case <-time.After(5 * time.Second):
		return nil, errors.New("tray request timed out")
	}
}

// The caller holds operation, so a restored frontend supersedes old tray actions.
func (h *host) trayAction(action string) error {
	if h.closed || !h.lightweight {
		return errors.New("inactive tray")
	}
	if action == "openHome" {
		var command *exec.Cmd
		switch runtime.GOOS {
		case "windows":
			command = exec.Command("explorer.exe", h.config.Home)
		case "darwin":
			command = exec.Command("open", h.config.Home)
		default:
			command = exec.Command("xdg-open", h.config.Home)
		}
		prepareCommand(command)
		if err := command.Start(); err != nil {
			return err
		}
		go command.Wait()
		return nil
	}
	if h.core == nil {
		return net.ErrClosed
	}
	if action == "rule" || action == "global" || action == "direct" {
		result, err := h.trayInvoke("updateConfig", map[string]string{"mode": action})
		if err != nil {
			return err
		}
		var message string
		if json.Unmarshal(result, &message) != nil {
			return errors.New("invalid mode response")
		}
		if message != "" {
			return errors.New(message)
		}
		h.mode = action
		return nil
	}
	if action == "closeConnections" {
		result, err := h.trayInvoke("closeConnections", nil)
		if err != nil {
			return err
		}
		var closed bool
		if json.Unmarshal(result, &closed) != nil || !closed {
			return errors.New("connections could not be closed")
		}
		return nil
	}
	return errors.New("unsupported tray action")
}
