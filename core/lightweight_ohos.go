//go:build openharmony

package core

import (
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

type embeddedController struct {
	listener  net.Listener
	token     string
	control   string
	keepAlive bool
	closed    bool
}

var activeEmbeddedController *embeddedController

func serveEmbeddedController(initial net.Conn, token, control string) error {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	controller := &embeddedController{listener: listener, token: token, control: control}
	embeddedMu.Lock()
	activeEmbeddedController = controller
	embeddedMu.Unlock()
	defer func() {
		listener.Close()
		StopOhosTun()
		handleShutdown()
		embeddedMu.Lock()
		embeddedConnection = nil
		activeEmbeddedController = nil
		embeddedMu.Unlock()
		if control != "" {
			_ = os.Remove(filepath.Join(filepath.Dir(control), ".ohos-core-host.json"))
		}
	}()
	connection := initial
	for {
		embeddedMu.Lock()
		embeddedConnection = connection
		embeddedMu.Unlock()
		serveWithCleanup(connection, func() {})
		embeddedMu.Lock()
		embeddedConnection = nil
		keepAlive := controller.keepAlive && !controller.closed
		embeddedMu.Unlock()
		if !keepAlive {
			return nil
		}
		for {
			candidate, err := listener.Accept()
			if err != nil {
				return nil
			}
			candidate.SetDeadline(time.Now().Add(3 * time.Second))
			var header [4]byte
			_, err = io.ReadFull(candidate, header[:])
			if err != nil || binary.LittleEndian.Uint32(header[:]) != 64 {
				candidate.Close()
				continue
			}
			frame := make([]byte, 64)
			_, err = io.ReadFull(candidate, frame)
			if err != nil || subtle.ConstantTimeCompare(frame, []byte(token)) != 1 {
				candidate.Close()
				continue
			}
			if _, err := writeFrame(candidate, []byte(token)); err != nil {
				candidate.Close()
				continue
			}
			candidate.SetDeadline(time.Time{})
			embeddedMu.Lock()
			controller.keepAlive = false
			embeddedMu.Unlock()
			_ = os.Remove(filepath.Join(filepath.Dir(control), ".ohos-core-host.json"))
			connection = candidate
			break
		}
	}
}

func EnableEmbeddedLightweight(raw string) error {
	var request struct {
		RunningSince *int64 `json:"runningSince"`
		TunnelStatus string `json:"tunnelStatus"`
	}
	if err := json.Unmarshal([]byte(raw), &request); err != nil {
		return err
	}
	embeddedMu.Lock()
	defer embeddedMu.Unlock()
	controller := activeEmbeddedController
	if controller == nil || controller.closed || controller.control == "" || embeddedConnection == nil {
		return fmt.Errorf("Core cannot enter lightweight mode")
	}
	data, err := json.Marshal(map[string]any{
		"address": controller.listener.Addr().String(), "token": controller.token,
		"control": controller.control, "runningSince": request.RunningSince,
		"tunnelStatus": request.TunnelStatus,
	})
	if err != nil {
		return err
	}
	path := filepath.Join(filepath.Dir(controller.control), ".ohos-core-host.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		return err
	}
	controller.keepAlive = true
	return nil
}
