package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

var coreName = "FlClashCore.exe"

const (
	protocolVersion      = "8"
	serviceName          = "FlClashHelperService"
	serviceOperationWait = 10 * time.Second
	servicePollInterval  = 100 * time.Millisecond
)

type serviceCommand struct {
	ownerSID *windows.SID
	ownerPID uint32
}

func parseServiceCommand(args []string) (serviceCommand, error) {
	switch {
	case len(args) == 0:
		return serviceCommand{}, errors.New("the Helper service was registered without an owner; reinstall it")
	case len(args) == 2 && args[0] == "--owner-sid":
		sid, err := windows.StringToSid(args[1])
		if !strings.HasPrefix(args[1], "S-1-") || err != nil || sid.String() != args[1] {
			return serviceCommand{}, errors.New("--owner-sid is not a SID")
		}
		return serviceCommand{ownerSID: sid}, nil
	case len(args) == 3 && args[0] == "install" && args[1] == "--owner-pid":
		pid, err := strconv.ParseUint(args[2], 10, 32)
		if err != nil || pid == 0 {
			return serviceCommand{}, errors.New("--owner-pid is not a process ID")
		}
		return serviceCommand{ownerPID: uint32(pid)}, nil
	case len(args) == 1 && args[0] == "uninstall":
		return serviceCommand{}, nil
	}
	return serviceCommand{}, errors.New("expected --owner-sid <SID>, install --owner-pid <pid>, or uninstall")
}

func run(args []string) error {
	command, err := parseServiceCommand(args)
	if err != nil {
		return err
	}
	switch {
	case command.ownerSID != nil:
		return svc.Run(serviceName, windowsService{owner: command.ownerSID})
	case command.ownerPID != 0:
		return installService(command.ownerPID)
	default:
		return uninstallService()
	}
}

type windowsService struct {
	owner *windows.SID
}

func (s windowsService) Execute(_ []string, changes <-chan svc.ChangeRequest, reports chan<- svc.Status) (bool, uint32) {
	pending := svc.Status{State: svc.StartPending, CheckPoint: 1, WaitHint: uint32(serviceOperationWait.Milliseconds())}
	reports <- pending
	if err := s.serve(changes, reports, pending); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return false, 1
	}
	return false, 0
}

func (s windowsService) serve(changes <-chan svc.ChangeRequest, reports chan<- svc.Status, pending svc.Status) error {
	if err := coreHashConfigured(); err != nil {
		return err
	}
	path, err := os.Executable()
	if err != nil {
		return err
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return fmt.Errorf("bind Helper server: %w", err)
	}
	defer listener.Close()
	cleanup, err := publishPort(listener.Addr().(*net.TCPAddr).Port)
	if err != nil {
		return fmt.Errorf("publish Helper server port: %w", err)
	}
	defer cleanup()

	h := &helper{path: path}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		finished <- h.serve(ctx, ownerListener{
			Listener: listener,
			helper:   h,
			authorize: func(conn net.Conn) bool {
				return isOwnerConnection(conn.(*net.TCPConn), s.owner)
			},
		})
	}()
	reports <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop}
	for {
		select {
		case err := <-finished:
			return err
		case change, ok := <-changes:
			if !ok || change.Cmd == svc.Stop {
				pending.State = svc.StopPending
				reports <- pending
				cancel()
				return <-finished
			}
			if change.Cmd == svc.Interrogate {
				reports <- change.CurrentStatus
			}
		}
	}
}

func openServiceManager(access uint32) (*mgr.Mgr, error) {
	handle, err := windows.OpenSCManager(nil, nil, access)
	if err != nil {
		return nil, fmt.Errorf("open Windows service manager: %w", err)
	}
	return &mgr.Mgr{Handle: handle}, nil
}

func openService(manager *mgr.Mgr, access uint32) (*mgr.Service, error) {
	name, err := windows.UTF16PtrFromString(serviceName)
	if err != nil {
		return nil, err
	}
	handle, err := windows.OpenService(manager.Handle, name, access)
	if err != nil {
		return nil, err
	}
	return &mgr.Service{Name: serviceName, Handle: handle}, nil
}

func installService(ownerPID uint32) error {
	ownerSID, err := processSID(ownerPID)
	if err != nil {
		return fmt.Errorf("read the account of process %d: %w", ownerPID, err)
	}
	manager, err := openServiceManager(windows.SC_MANAGER_CONNECT | windows.SC_MANAGER_CREATE_SERVICE)
	if err != nil {
		return err
	}
	defer manager.Disconnect()
	path, err := os.Executable()
	if err != nil {
		return err
	}
	if err := removeExistingService(manager); err != nil {
		return err
	}
	service, err := manager.CreateService(serviceName, path, mgr.Config{
		StartType:    mgr.StartAutomatic,
		ErrorControl: mgr.ErrorNormal,
		DisplayName:  serviceName,
	}, "--owner-sid", ownerSID.String())
	if err != nil {
		return fmt.Errorf("create Helper service: %w", err)
	}
	defer service.Close()
	restart := mgr.RecoveryAction{Type: mgr.ServiceRestart, Delay: 5 * time.Second}
	if err := service.SetRecoveryActions([]mgr.RecoveryAction{restart, restart, restart}, 24*60*60); err != nil {
		return fmt.Errorf("configure Helper service recovery: %w", err)
	}
	if err := service.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
		return fmt.Errorf("start Helper service: %w", err)
	}
	return waitForServiceState(service, svc.Running)
}

func uninstallService() error {
	manager, err := openServiceManager(windows.SC_MANAGER_CONNECT)
	if err != nil {
		return err
	}
	defer manager.Disconnect()
	return removeExistingService(manager)
}

func removeExistingService(manager *mgr.Mgr) error {
	service, err := openService(manager, windows.SERVICE_QUERY_STATUS|windows.SERVICE_STOP|windows.DELETE)
	switch {
	case errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST):
		return nil
	case errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE):
		return waitForServiceDeletion(manager)
	case err != nil:
		return fmt.Errorf("open existing Helper service: %w", err)
	}
	if err := waitForServiceState(service, svc.Stopped); err != nil {
		service.Close()
		return err
	}
	err = service.Delete()
	service.Close()
	if err != nil && !errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) && !errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		return fmt.Errorf("delete Helper service: %w", err)
	}
	return waitForServiceDeletion(manager)
}

func waitForServiceState(service *mgr.Service, target svc.State) error {
	deadline := time.Now().Add(serviceOperationWait)
	for {
		status, err := service.Query()
		if err != nil {
			return fmt.Errorf("query Helper service: %w", err)
		}
		if status.State == target {
			return nil
		}
		if target == svc.Running && status.State == svc.Stopped {
			return fmt.Errorf("Helper service stopped during startup (exit code %d)", status.Win32ExitCode)
		}
		if target == svc.Stopped && status.State != svc.StopPending {
			_, err := service.Control(svc.Stop)
			switch {
			case errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE):
				return nil
			case err != nil && !errors.Is(err, windows.ERROR_SERVICE_CANNOT_ACCEPT_CTRL):
				return fmt.Errorf("stop Helper service: %w", err)
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for Helper service to reach state %d from %d", target, status.State)
		}
		time.Sleep(servicePollInterval)
	}
}

func waitForServiceDeletion(manager *mgr.Mgr) error {
	deadline := time.Now().Add(serviceOperationWait)
	for {
		service, err := openService(manager, windows.SERVICE_QUERY_STATUS)
		switch {
		case errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST):
			return nil
		case err == nil:
			service.Close()
		case !errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE):
			return fmt.Errorf("check Helper service deletion: %w", err)
		}
		if time.Now().After(deadline) {
			return errors.New("timed out waiting for Helper service deletion")
		}
		time.Sleep(servicePollInterval)
	}
}
