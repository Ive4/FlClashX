package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

const procThreadAttributeJobList = 0x0002000D

func isAllowedCoreAddress(address string) bool {
	suffix, ok := strings.CutPrefix(address, `\\.\pipe\FlClashCore_`)
	return ok && isLowerHex(suffix, 32)
}

func ensureOwnerAddress(string) error {
	return nil
}

func openCore(path string) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ, nil,
		windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		windows.CloseHandle(handle)
		return nil, err
	}
	if info.FileAttributes&(windows.FILE_ATTRIBUTE_DIRECTORY|windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		windows.CloseHandle(handle)
		return nil, errors.New("Core must be a regular file")
	}
	return os.NewFile(uintptr(handle), path), nil
}

func finalPath(file *os.File) (string, error) {
	buffer := make([]uint16, windows.MAX_PATH)
	for {
		size, err := windows.GetFinalPathNameByHandle(windows.Handle(file.Fd()), &buffer[0], uint32(len(buffer)), 0)
		if err != nil {
			return "", err
		}
		if size < uint32(len(buffer)) {
			return windows.UTF16ToString(buffer[:size]), nil
		}
		buffer = make([]uint16, size+1)
	}
}

func launchCore(path, address string, stdout, stderr *os.File) (*os.Process, func(), *helperError) {
	file, err := openVerifiedCore(path)
	if err != nil {
		return nil, nil, verificationError(err)
	}
	defer file.Close()
	lockedPath, err := finalPath(file)
	if err != nil {
		return nil, nil, verificationError(err)
	}
	process, release, err := createCoreProcess(lockedPath, address, stdout, stderr)
	if err != nil {
		var confinement *confinementError
		if errors.As(err, &confinement) {
			return nil, nil, &helperError{Code: "internalError", Message: err.Error()}
		}
		return nil, nil, launchError(err)
	}
	return process, release, nil
}

type confinementError struct{ error }

func (e *confinementError) Error() string { return "Core confinement failed: " + e.error.Error() }

func createCoreProcess(path, address string, stdout, stderr *os.File) (*os.Process, func(), error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, nil, &confinementError{err}
	}
	process, err := createAssignedProcess(job, path, address, stdout, stderr)
	if err != nil {
		windows.CloseHandle(job)
		return nil, nil, err
	}
	return process, func() { _ = windows.CloseHandle(job) }, nil
}

func createAssignedProcess(job windows.Handle, path, address string, stdout, stderr *os.File) (*os.Process, error) {
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return nil, &confinementError{err}
	}
	attributes, err := windows.NewProcThreadAttributeList(2)
	if err != nil {
		return nil, &confinementError{err}
	}
	defer attributes.Delete()
	// Creation and job assignment must be atomic if the Helper crashes at launch.
	if err := attributes.Update(procThreadAttributeJobList, unsafe.Pointer(&job), unsafe.Sizeof(job)); err != nil {
		return nil, &confinementError{err}
	}

	stdin, err := os.Open(os.DevNull)
	if err != nil {
		return nil, err
	}
	defer stdin.Close()
	var handles [3]windows.Handle
	for index, file := range [3]*os.File{stdin, stdout, stderr} {
		current := windows.CurrentProcess()
		if err := windows.DuplicateHandle(current, windows.Handle(file.Fd()), current, &handles[index], 0, true,
			windows.DUPLICATE_SAME_ACCESS); err != nil {
			return nil, err
		}
		defer windows.CloseHandle(handles[index])
	}
	if err := attributes.Update(windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, unsafe.Pointer(&handles[0]), unsafe.Sizeof(handles)); err != nil {
		return nil, err
	}
	startup := windows.StartupInfoEx{
		StartupInfo: windows.StartupInfo{
			Cb:        uint32(unsafe.Sizeof(windows.StartupInfoEx{})),
			Flags:     windows.STARTF_USESTDHANDLES,
			StdInput:  handles[0],
			StdOutput: handles[1],
			StdErr:    handles[2],
		},
		ProcThreadAttributeList: attributes.List(),
	}
	executable, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	command, err := windows.UTF16PtrFromString(windows.ComposeCommandLine([]string{path, address}))
	if err != nil {
		return nil, err
	}
	directory, err := windows.UTF16PtrFromString(filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	var info windows.ProcessInformation
	flags := uint32(windows.EXTENDED_STARTUPINFO_PRESENT | windows.CREATE_NO_WINDOW)
	if err := windows.CreateProcess(executable, command, nil, nil, true, flags, nil, directory, &startup.StartupInfo, &info); err != nil {
		return nil, err
	}
	defer windows.CloseHandle(info.Thread)
	defer windows.CloseHandle(info.Process)
	process, err := os.FindProcess(int(info.ProcessId))
	if err != nil {
		return nil, &confinementError{fmt.Errorf("adopt Core process: %w", err)}
	}
	return process, nil
}

func requestCoreExit(*os.Process) bool {
	return false
}
