package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

func listenCore(id string) (net.Listener, string, error) {
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		return nil, "", err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, "", err
	}
	address := `\\.\pipe\FlClashCore_` + id
	listener, err := winio.ListenPipe(address, &winio.PipeConfig{
		SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;" + user.User.Sid.String() + ")",
	})
	return listener, address, err
}

func dialFrontend(address string) (net.Conn, error) {
	if !strings.HasPrefix(address, `\\.\pipe\FlClashCore_`) || len(address) != len(`\\.\pipe\FlClashCore_`)+32 {
		return nil, fmt.Errorf("invalid frontend address")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return winio.DialPipeContext(ctx, address)
}

func validateCorePeer(connection net.Conn, pid int) error {
	file, ok := connection.(interface{ Fd() uintptr })
	if !ok {
		return fmt.Errorf("core pipe has no native handle")
	}
	var actual uint32
	result, _, err := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetNamedPipeClientProcessId").Call(file.Fd(), uintptr(unsafe.Pointer(&actual)))
	if result == 0 {
		return err
	}
	if actual != uint32(pid) {
		return fmt.Errorf("unexpected core peer PID %d", actual)
	}
	return nil
}

func prepareCommand(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return err == windows.ERROR_ACCESS_DENIED
	}
	defer windows.CloseHandle(handle)
	state, err := windows.WaitForSingleObject(handle, 0)
	return err == nil && state == uint32(windows.WAIT_TIMEOUT)
}

func lockHost(path string) (*os.File, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	err = windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &windows.Overlapped{})
	if err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}
