//go:build openharmony

package core

import (
	"core/platform/ownerlookup"
	"core/tun"
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"net"
	"net/netip"
	"sync"
	"syscall"
	"time"
)

var embeddedMu sync.Mutex
var embeddedConnection net.Conn
var embeddedTun *sing_tun.Listener
var ohosOwners ownerlookup.Broker

func init() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		if metadata.RawSrcAddr == nil || metadata.RawDstAddr == nil {
			return "", ownerlookup.ErrUnavailable
		}
		local, err := netip.ParseAddrPort(metadata.RawSrcAddr.String())
		if err != nil {
			return "", err
		}
		remote, err := netip.ParseAddrPort(metadata.RawDstAddr.String())
		if err != nil {
			return "", err
		}
		owner, err := ohosOwners.Lookup(metadata.NetWork.String(), local, remote, 500*time.Millisecond)
		if err != nil {
			return "", err
		}
		metadata.Uid = uint32(owner.UID)
		return owner.Bundle, nil
	}
}

func TakeOhosOwners() string { return ohosOwners.Take() }

func ResolveOhosOwner(id uint32, uid int, bundle string) {
	ohosOwners.Resolve(id, ownerlookup.Result{UID: uid, Bundle: bundle})
}

func RunEmbedded(raw string) error {
	var settings struct {
		Address string `json:"address"`
		Token   string `json:"token"`
	}
	if err := json.Unmarshal([]byte(raw), &settings); err != nil {
		return err
	}
	host, _, err := net.SplitHostPort(settings.Address)
	if err != nil || host != "127.0.0.1" || len(settings.Token) != 64 {
		return fmt.Errorf("invalid Core control endpoint")
	}
	connection, err := net.DialTimeout("tcp", settings.Address, 10*time.Second)
	if err != nil {
		return err
	}
	embeddedMu.Lock()
	embeddedConnection = connection
	embeddedMu.Unlock()
	connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err = writeFrame(connection, []byte(settings.Token)); err != nil {
		connection.Close()
		return err
	}
	connection.SetWriteDeadline(time.Time{})
	serveWithCleanup(connection, func() {
		StopOhosTun()
		handleShutdown()
		embeddedMu.Lock()
		embeddedConnection = nil
		embeddedMu.Unlock()
	})
	return nil
}

func StartOhosTun(fd int, raw string) error {
	var settings struct {
		Stack   string `json:"stack"`
		Address string `json:"address"`
		DNS     string `json:"dns"`
	}
	if err := json.Unmarshal([]byte(raw), &settings); err != nil {
		return err
	}
	embeddedMu.Lock()
	defer embeddedMu.Unlock()
	if embeddedConnection == nil {
		return fmt.Errorf("Core is not connected")
	}
	if embeddedTun != nil {
		return fmt.Errorf("VPN tunnel already exists")
	}
	owned, err := syscall.Dup(fd)
	if err != nil {
		return err
	}
	embeddedTun = tun.Start(owned, settings.Stack, settings.Address, settings.DNS, raw)
	if embeddedTun == nil {
		return fmt.Errorf("TUN initialization failed")
	}
	return nil
}

func StopOhosTun() {
	embeddedMu.Lock()
	defer embeddedMu.Unlock()
	if embeddedTun != nil {
		embeddedTun.Close()
		embeddedTun = nil
	}
}

func StopEmbedded() {
	embeddedMu.Lock()
	defer embeddedMu.Unlock()
	if embeddedConnection != nil {
		embeddedConnection.Close()
	}
}
