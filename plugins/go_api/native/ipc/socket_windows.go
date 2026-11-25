package ipc

import (
	"errors"
	"net"
	"unsafe"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

var getClientPID = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetNamedPipeClientProcessId")

func listen(address string) (net.Listener, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	return winio.ListenPipe(address, &winio.PipeConfig{
		SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;" + user.User.Sid.String() + ")",
	})
}

func admit(peer net.Conn) (uint32, error) {
	pipe, ok := peer.(interface{ Fd() uintptr })
	if !ok {
		return 0, errors.New("core pipe has no native handle")
	}
	var pid uint32
	result, _, err := getClientPID.Call(pipe.Fd(), uintptr(unsafe.Pointer(&pid)))
	if result == 0 {
		return 0, err
	}
	return pid, nil
}

func isPlatformPeerGone(err error) bool {
	return errors.Is(err, winio.ErrFileClosed) || errors.Is(err, windows.ERROR_NO_DATA) ||
		errors.Is(err, windows.ERROR_PIPE_NOT_CONNECTED) || errors.Is(err, windows.ERROR_BROKEN_PIPE)
}
