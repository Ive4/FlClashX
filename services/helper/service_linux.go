package main

import (
	"context"
	json "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

var coreName = "FlClashCore"

const (
	protocolVersion  = "6"
	serviceName      = "flclash-helper"
	unitPath         = "/etc/systemd/system/" + serviceName + ".service"
	helperSocketPath = "/run/flclash/helper.sock"
	ownerUIDEnv      = "FLCLASH_HELPER_OWNER_UID"
	ownerGIDEnv      = "FLCLASH_HELPER_OWNER_GID"
	execCoreArgument = "--exec-core"
	coreStatusFD     = 3
)

type ownerIDs struct {
	uid uint32
	gid uint32
}

func run(args []string) error {
	if len(args) == 0 {
		return runService()
	}
	if len(args) == 1 {
		switch args[0] {
		case "install":
			return installService()
		case "uninstall":
			return uninstallService()
		}
	}
	if len(args) == 2 && args[0] == execCoreArgument {
		status := os.NewFile(coreStatusFD, "core launch status")
		if _, err := status.Stat(); err != nil {
			return fmt.Errorf("open Core launch channel: %w", err)
		}
		defer status.Close()
		unix.CloseOnExec(coreStatusFD)
		failure := execVerifiedCore(args[1])
		data, err := json.Marshal(failure)
		if err != nil {
			return err
		}
		_, err = status.Write(data)
		return err
	}
	return errors.New("expected no arguments, install, or uninstall")
}

func parseOwnerID(value string) (uint32, error) {
	id, err := strconv.ParseUint(strings.TrimSpace(value), 10, 32)
	if err != nil || id == 0 || id == uint64(^uint32(0)) {
		return 0, errors.New("expected a non-root user or group ID")
	}
	return uint32(id), nil
}

func serviceOwner() (ownerIDs, error) {
	uid, err := parseOwnerID(os.Getenv(ownerUIDEnv))
	if err != nil {
		return ownerIDs{}, fmt.Errorf("%s: %w", ownerUIDEnv, err)
	}
	gid, err := parseOwnerID(os.Getenv(ownerGIDEnv))
	if err != nil {
		return ownerIDs{}, fmt.Errorf("%s: %w", ownerGIDEnv, err)
	}
	return ownerIDs{uid: uid, gid: gid}, nil
}

func invokingOwner() (ownerIDs, error) {
	value, ok := os.LookupEnv("PKEXEC_UID")
	if !ok {
		value, ok = os.LookupEnv("SUDO_UID")
	}
	if !ok {
		return ownerIDs{}, errors.New("neither PKEXEC_UID nor SUDO_UID is set; run the installer through pkexec")
	}
	uid, err := parseOwnerID(value)
	if err != nil {
		return ownerIDs{}, fmt.Errorf("the invoking user ID is not usable: %w", err)
	}
	output, err := exec.Command("id", "-g", strconv.FormatUint(uint64(uid), 10)).Output()
	if err != nil {
		return ownerIDs{}, fmt.Errorf("query the invoking user: %w", err)
	}
	gid, err := parseOwnerID(string(output))
	if err != nil {
		return ownerIDs{}, fmt.Errorf("the invoking group is not usable: %w", err)
	}
	return ownerIDs{uid: uid, gid: gid}, nil
}

func unitContents(executable string, owner ownerIDs) string {
	return fmt.Sprintf(`[Unit]
Description=FlClash Helper starts the FlClash Core with the privileges TUN mode needs.
After=network-online.target nftables.service iptables.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=:%s
Group=%d
Environment=%s=%d
Environment=%s=%d
RuntimeDirectory=flclash
RuntimeDirectoryMode=0755
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
`, strconv.Quote(strings.ReplaceAll(executable, "%", "%%")), owner.gid,
		ownerUIDEnv, owner.uid, ownerGIDEnv, owner.gid)
}

func installedOwnerUID(unit string) (uint32, bool) {
	for line := range strings.SplitSeq(unit, "\n") {
		value, ok := strings.CutPrefix(line, "Environment="+ownerUIDEnv+"=")
		if ok {
			uid, err := strconv.ParseUint(strings.TrimSpace(value), 10, 32)
			return uint32(uid), err == nil
		}
	}
	return 0, false
}

func ensureRootOwned(executable string) error {
	for path := executable; ; path = filepath.Dir(path) {
		info, err := os.Lstat(path)
		if err != nil {
			return fmt.Errorf("inspect %s: %w", path, err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !rootProtected(info) {
			return fmt.Errorf("%s must be owned by root and protected against other writers; install the package instead of running an unpacked bundle", path)
		}
		if filepath.Dir(path) == path {
			return nil
		}
	}
}

func rootProtected(info os.FileInfo) bool {
	return info.Sys().(*syscall.Stat_t).Uid == 0 && info.Mode().Perm()&0o022 == 0
}

func lockUnitDirectory() (*os.File, error) {
	directory, err := os.Open(filepath.Dir(unitPath))
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(directory.Fd()), unix.LOCK_EX); err != nil {
		directory.Close()
		return nil, err
	}
	return directory, nil
}

func installService() error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := ensureRootOwned(executable); err != nil {
		return err
	}
	owner, err := invokingOwner()
	if err != nil {
		return err
	}
	directory, err := lockUnitDirectory()
	if err != nil {
		return err
	}
	defer directory.Close()
	existing, err := os.ReadFile(unitPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read %s: %w", unitPath, err)
	}
	if uid, ok := installedOwnerUID(string(existing)); ok && uid != owner.uid {
		return fmt.Errorf("the Helper is already installed for UID %d; run FlClashHelperService uninstall as that user first", uid)
	}

	unit, err := os.CreateTemp(filepath.Dir(unitPath), serviceName+"-")
	if err != nil {
		return err
	}
	defer os.Remove(unit.Name())
	_, writeErr := io.WriteString(unit, unitContents(executable, owner))
	if err := errors.Join(writeErr, unit.Chmod(0o644), unit.Close()); err != nil {
		return err
	}
	if err := os.Rename(unit.Name(), unitPath); err != nil {
		return fmt.Errorf("write %s: %w", unitPath, err)
	}
	if err := systemctl("daemon-reload"); err != nil {
		return err
	}
	if err := systemctl("enable", serviceName); err != nil {
		return err
	}
	return systemctl("restart", serviceName)
}

func uninstallService() error {
	directory, err := lockUnitDirectory()
	if err != nil {
		return err
	}
	defer directory.Close()
	_ = exec.Command("systemctl", "disable", "--now", serviceName).Run()
	if err := os.Remove(unitPath); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return fmt.Errorf("remove %s: %w", unitPath, err)
	}
	return systemctl("daemon-reload")
}

func systemctl(args ...string) error {
	cmd := exec.Command("systemctl", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("systemctl %s: %w", strings.Join(args, " "), err)
	}
	return nil
}

func runService() error {
	if err := coreHashConfigured(); err != nil {
		return err
	}
	owner, err := serviceOwner()
	if err != nil {
		return err
	}
	if os.Geteuid() != 0 {
		return errors.New("the Helper service must run as root")
	}
	path, err := os.Executable()
	if err != nil {
		return err
	}
	listener, err := listenOwnerSocket(helperSocketPath, owner.gid)
	if err != nil {
		return err
	}
	defer listener.Close()
	h := &helper{path: path}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return h.serve(ctx, ownerListener{
		Listener: listener,
		helper:   h,
		authorize: func(conn net.Conn) bool {
			return isOwnerConnection(conn.(*net.UnixConn), owner.uid)
		},
	})
}

func listenOwnerSocket(path string, gid uint32) (*net.UnixListener, error) {
	info, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || !rootProtected(info) {
		return nil, errors.New("the Helper socket directory must be owned by root and protected against other writers")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 || info.Sys().(*syscall.Stat_t).Uid != 0 {
			return nil, errors.New("the previous Helper socket is not owned by root")
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, err
	}
	if err := errors.Join(os.Chown(path, 0, int(gid)), os.Chmod(path, 0o660)); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

func isOwnerConnection(conn *net.UnixConn, uid uint32) bool {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	match := false
	err = rawConn.Control(func(fd uintptr) {
		credentials, err := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		match = err == nil && credentials.Uid == uid
	})
	return err == nil && match
}

func isAllowedCoreAddress(address string) bool {
	digits, ok := strings.CutPrefix(address, "/tmp/FlClashSocket_")
	if !ok {
		return false
	}
	digits, ok = strings.CutSuffix(digits, ".sock")
	if !ok || len(digits) == 0 || len(digits) > 10 {
		return false
	}
	for _, digit := range digits {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

func ensureOwnerAddress(address string) error {
	owner, err := serviceOwner()
	if err != nil {
		return err
	}
	info, err := os.Lstat(address)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 || info.Sys().(*syscall.Stat_t).Uid != owner.uid {
		return errors.New("Core address is not a socket owned by the Helper owner")
	}
	return nil
}

func openCore(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	if !info.Mode().IsRegular() || !rootProtected(info) {
		file.Close()
		return nil, errors.New("Core must be a regular file owned by root and protected against other writers")
	}
	return file, nil
}

func launchCore(path, address string, stdout, stderr *os.File) (*os.Process, func(), *helperError) {
	status, statusWriter, err := os.Pipe()
	if err != nil {
		return nil, nil, launchError(err)
	}
	defer status.Close()
	cmd := exec.Command("/proc/self/exe", execCoreArgument, address)
	cmd.Dir = filepath.Dir(path)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.ExtraFiles = []*os.File{statusWriter}
	err = cmd.Start()
	statusWriter.Close()
	if err != nil {
		return nil, nil, launchError(err)
	}

	// A successful exec closes the status pipe while keeping the process PID.
	data, err := io.ReadAll(io.LimitReader(status, maxBodyBytes+1))
	if err == nil && len(data) == 0 {
		return cmd.Process, nil, nil
	}
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
	var failure helperError
	if err == nil {
		err = json.Unmarshal(data, &failure)
	}
	if err != nil {
		return nil, nil, launchError(fmt.Errorf("read Core launch status: %w", err))
	}
	return nil, nil, &failure
}

func execVerifiedCore(address string) *helperError {
	if os.Geteuid() != 0 || !isAllowedCoreAddress(address) {
		return launchError(errors.New("invalid privileged Core launch"))
	}
	owner, err := serviceOwner()
	if err != nil {
		return launchError(err)
	}
	if err := ensureOwnerAddress(address); err != nil {
		return launchError(err)
	}
	executable, err := os.Executable()
	if err != nil {
		return verificationError(err)
	}
	path := filepath.Join(filepath.Dir(executable), coreName)
	file, err := openVerifiedCore(path)
	if err != nil {
		return verificationError(err)
	}
	defer file.Close()

	// The real owner tells the Core who should own the files it creates.
	if err := syscall.Setresgid(int(owner.gid), 0, 0); err != nil {
		return launchError(err)
	}
	if err := syscall.Setresuid(int(owner.uid), 0, 0); err != nil {
		return launchError(err)
	}
	// Execute the inode we hashed even if an update has replaced its path.
	return launchError(unix.Exec("/proc/self/fd/"+strconv.Itoa(int(file.Fd())),
		[]string{path, address}, os.Environ()))
}

func requestCoreExit(process *os.Process) bool {
	return process.Signal(syscall.SIGTERM) == nil
}
