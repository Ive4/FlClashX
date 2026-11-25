package main

import (
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const portKey = `SYSTEM\CurrentControlSet\Services\FlClashHelperService\Runtime`

var (
	getExtendedTCPTable = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")
	regCreateKeyEx      = windows.NewLazySystemDLL("advapi32.dll").NewProc("RegCreateKeyExW")
)

func processSID(pid uint32) (*windows.SID, error) {
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(handle)
	var token windows.Token
	if err := windows.OpenProcessToken(handle, windows.TOKEN_QUERY, &token); err != nil {
		return nil, err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, err
	}
	return user.User.Sid.Copy()
}

func isOwnerConnection(conn *net.TCPConn, owner *windows.SID) bool {
	client := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	server := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	pid, err := clientPID(client, server)
	if err != nil || pid == 0 {
		return false
	}
	sid, err := processSID(pid)
	return err == nil && sid.Equals(owner)
}

func clientPID(client, server netip.AddrPort) (uint32, error) {
	const tableClassTCP4OwnerPIDAll = 5
	var size uint32
	buffer := make([]byte, 16*1024)
	for range 5 {
		size = uint32(len(buffer))
		status, _, _ := getExtendedTCPTable.Call(uintptr(unsafe.Pointer(&buffer[0])),
			uintptr(unsafe.Pointer(&size)), 0, windows.AF_INET, tableClassTCP4OwnerPIDAll, 0)
		switch syscall.Errno(status) {
		case 0:
			pid := findTCPClient(buffer, client, server)
			return pid, nil
		case windows.ERROR_INSUFFICIENT_BUFFER:
			buffer = make([]byte, size)
		default:
			return 0, syscall.Errno(status)
		}
	}
	return 0, errors.New("the TCP table kept growing")
}

func findTCPClient(table []byte, client, server netip.AddrPort) uint32 {
	// The table starts with a row count. Each IPv4 owner row has six DWORDs.
	const rowSize = 24
	if len(table) < 4 {
		return 0
	}
	count := binary.LittleEndian.Uint32(table[:4])
	for offset := 4; count > 0 && offset+rowSize <= len(table); offset, count = offset+rowSize, count-1 {
		row := table[offset : offset+rowSize]
		local := netip.AddrPortFrom(netip.AddrFrom4([4]byte(row[4:8])), binary.BigEndian.Uint16(row[8:10]))
		remote := netip.AddrPortFrom(netip.AddrFrom4([4]byte(row[12:16])), binary.BigEndian.Uint16(row[16:18]))
		if local == client && remote == server {
			return binary.LittleEndian.Uint32(row[20:24])
		}
	}
	return 0
}

func publishPort(port int) (func(), error) {
	const registryOptionVolatile = 1
	path, err := windows.UTF16PtrFromString(portKey)
	if err != nil {
		return nil, err
	}
	var key registry.Key
	status, _, _ := regCreateKeyEx.Call(uintptr(registry.LOCAL_MACHINE), uintptr(unsafe.Pointer(path)), 0, 0,
		registryOptionVolatile, registry.SET_VALUE, 0, uintptr(unsafe.Pointer(&key)), 0)
	if status != 0 {
		return nil, syscall.Errno(status)
	}
	defer key.Close()
	cleanup := func() { _ = registry.DeleteKey(registry.LOCAL_MACHINE, portKey) }
	if err := key.SetDWordValue("Port", uint32(port)); err != nil {
		cleanup()
		return nil, err
	}
	return cleanup, nil
}
