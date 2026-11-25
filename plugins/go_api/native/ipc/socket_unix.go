//go:build (linux && !android && !flclash_ohos) || (darwin && !ios)

package ipc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

func listen(address string) (net.Listener, error) {
	if strings.HasPrefix(address, "@") || strings.IndexByte(address, 0) >= 0 {
		return nil, errors.New("IPC requires a filesystem socket")
	}
	config := net.ListenConfig{Control: restrictBeforeBind}
	original, _ := os.Lstat(address)
	listener, err := config.Listen(context.Background(), "unix", address)
	if errors.Is(err, syscall.EADDRINUSE) && canReclaimSocket(address, original) {
		if err := os.Remove(address); err != nil {
			return nil, err
		}
		listener, err = config.Listen(context.Background(), "unix", address)
	}
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(address, 0600); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

func canReclaimSocket(address string, original os.FileInfo) bool {
	if original == nil || original.Mode()&os.ModeSocket == 0 ||
		original.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid()) {
		return false
	}
	peer, err := net.DialTimeout("unix", address, time.Second)
	if err == nil {
		peer.Close()
		return false
	}
	if !errors.Is(err, syscall.ECONNREFUSED) {
		return false
	}
	current, err := os.Lstat(address)
	return err == nil && os.SameFile(original, current)
}

func admit(peer net.Conn) (uint32, error) {
	socket, err := peer.(*net.UnixConn).SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid, uid uint32
	var credErr error
	if err := socket.Control(func(fd uintptr) {
		pid, uid, credErr = peerCredentials(int(fd))
	}); err != nil {
		return 0, err
	}
	if credErr != nil {
		return 0, credErr
	}
	if ownUID := uint32(os.Geteuid()); uid != ownUID && uid != 0 {
		return 0, fmt.Errorf("peer uid %d is neither %d nor root", uid, ownUID)
	}
	return pid, nil
}

func isPlatformPeerGone(error) bool { return false }
