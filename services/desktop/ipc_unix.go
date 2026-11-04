//go:build !windows

package main

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func flushDNSCache() error { return nil }

func listenCore(_ string) (net.Listener, string, error) {
	number, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		return nil, "", err
	}
	address := fmt.Sprintf("/tmp/FlClashSocket_%s.sock", number)
	listener, err := net.Listen("unix", address)
	if err == nil {
		err = os.Chmod(address, 0600)
	}
	if err != nil && listener != nil {
		listener.Close()
	}
	return listener, address, err
}

func dialFrontend(address string) (net.Conn, error) {
	if filepath.Dir(address) != "/tmp" || !strings.HasPrefix(filepath.Base(address), "FlClashSocket_") || !strings.HasSuffix(address, ".sock") {
		return nil, fmt.Errorf("invalid frontend address")
	}
	return net.DialTimeout("unix", address, 5*time.Second)
}

func prepareCommand(_ *exec.Cmd) {}

func validateCorePeer(_ net.Conn, _ int) error { return nil }

func processAlive(pid int) bool {
	return pid > 0 && (syscall.Kill(pid, 0) == nil || syscall.Kill(pid, 0) == syscall.EPERM)
}

func lockHost(path string) (*os.File, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}
