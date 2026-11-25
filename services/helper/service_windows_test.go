package main

import (
	"crypto/sha256"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

const coreTestChild = "--test-helper-core-child"

func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == coreTestChild {
		fmt.Fprintln(os.Stdout, "Core stdout")
		fmt.Fprintln(os.Stderr, "Core stderr")
		for {
			time.Sleep(time.Hour)
		}
	}
	os.Exit(m.Run())
}

func TestWindowsOwnerIsTheClientEndOfTheConnection(t *testing.T) {
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.DialTCP("tcp4", nil, listener.Addr().(*net.TCPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := listener.AcceptTCP()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	pid, err := clientPID(client.LocalAddr().(*net.TCPAddr).AddrPort(), server.LocalAddr().(*net.TCPAddr).AddrPort())
	if err != nil || pid != uint32(os.Getpid()) {
		t.Fatalf("client pid %d, error %v, want %d", pid, err, os.Getpid())
	}
	owner, err := processSID(pid)
	if err != nil {
		t.Fatal(err)
	}
	different, err := windows.StringToSid("S-1-5-21-1-2-3-1001")
	if err != nil {
		t.Fatal(err)
	}
	if !isOwnerConnection(server, owner) || isOwnerConnection(server, different) {
		t.Fatal("TCP peer must match the registered owner")
	}
}

func TestWindowsKeepsTheVerifiedCoreFileLocked(t *testing.T) {
	path := filepath.Join(t.TempDir(), coreName)
	contents := []byte("bundled core")
	if err := os.WriteFile(path, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	savedHash := expectedCoreSHA256
	expectedCoreSHA256 = fmt.Sprintf("%x", sha256.Sum256(contents))
	t.Cleanup(func() { expectedCoreSHA256 = savedHash })
	file, err := openVerifiedCore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := os.WriteFile(path, []byte("replacement"), 0o644); err == nil {
		t.Fatal("Core could be rewritten after verification")
	}
	if err := os.Rename(path, path+".renamed"); err == nil {
		t.Fatal("Core could be renamed after verification")
	}
}

func TestWindowsVerifiedCoreCapturesBothStreamsAndDiesWithItsJob(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), coreName)
	if err := os.WriteFile(path, contents, 0o644); err != nil {
		t.Fatal(err)
	}
	savedHash := expectedCoreSHA256
	expectedCoreSHA256 = fmt.Sprintf("%x", sha256.Sum256(contents))
	t.Cleanup(func() { expectedCoreSHA256 = savedHash })

	h := &helper{}
	process, release, failure := h.spawn(path, coreTestChild)
	if failure != nil {
		t.Fatalf("verified Core could not start: %+v", failure)
	}
	closed := false
	defer func() {
		if !closed {
			release()
			_, _ = process.Wait()
		}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		h.logMu.Lock()
		logs := strings.Join(h.logs, "\n")
		h.logMu.Unlock()
		if strings.Contains(logs, "Core stdout") && strings.Contains(logs, "Core stderr") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("wanted both Core output streams, got %q", logs)
		}
		time.Sleep(10 * time.Millisecond)
	}
	release()
	closed = true
	exited := make(chan error, 1)
	go func() {
		_, err := process.Wait()
		exited <- err
	}()
	select {
	case err := <-exited:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		_ = process.Kill()
		t.Fatal("Core outlived its job")
	}
}
