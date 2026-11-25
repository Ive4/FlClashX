//go:build !ios

package ipc

import (
	"syscall"

	"golang.org/x/sys/unix"
)

func restrictBeforeBind(_, _ string, _ syscall.RawConn) error { return nil }

func peerCredentials(fd int) (uint32, uint32, error) {
	cred, err := unix.GetsockoptXucred(fd, unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	if err != nil {
		return 0, 0, err
	}
	pid, _ := unix.GetsockoptInt(fd, unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	return uint32(pid), cred.Uid, nil
}
