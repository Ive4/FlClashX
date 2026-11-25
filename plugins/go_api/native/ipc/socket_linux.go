//go:build !android && !flclash_ohos

package ipc

import (
	"syscall"

	"golang.org/x/sys/unix"
)

func restrictBeforeBind(_, _ string, raw syscall.RawConn) error {
	var modeErr error
	if err := raw.Control(func(fd uintptr) {
		modeErr = unix.Fchmod(int(fd), 0600)
	}); err != nil {
		return err
	}
	return modeErr
}

func peerCredentials(fd int) (uint32, uint32, error) {
	cred, err := unix.GetsockoptUcred(fd, unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil {
		return 0, 0, err
	}
	return uint32(cred.Pid), cred.Uid, nil
}
