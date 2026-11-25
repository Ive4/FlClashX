//go:build (linux && !android && !flclash_ohos) || (darwin && !ios)

package ipc

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testAddress(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "flclash-ipc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "core.sock")
}

func connectTestPeer(t *testing.T, address string) net.Conn {
	t.Helper()
	peer, err := net.DialTimeout("unix", address, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	peer.SetDeadline(time.Now().Add(3 * time.Second))
	return peer
}

func TestListenReclaimsOnlyStaleSockets(t *testing.T) {
	address := testAddress(t)
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: address, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	listener, err := listen(address)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	info, err := os.Stat(address)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0600 {
		t.Fatalf("socket mode = %o", mode)
	}
	if extra, err := listen(address); err == nil {
		extra.Close()
		t.Fatal("bound over a live socket")
	}
}
