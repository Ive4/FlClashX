//go:build openharmony

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"core"
	"core/backupcodec"
	"fmt"
	"unsafe"
)

//export FlClashRun
func FlClashRun(path *C.char) (result *C.char) {
	defer func() {
		if value := recover(); value != nil {
			result = C.CString(fmt.Sprint(value))
		}
	}()
	if err := core.RunEmbedded(C.GoString(path)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export FlClashFree
func FlClashFree(value *C.char) {
	C.free(unsafe.Pointer(value))
}

//export FlClashBackupCodec
func FlClashBackupCodec(input *C.char, length C.int) *C.char {
	if input == nil || length <= 0 || int64(length) > backupcodec.MaxWireBytes {
		return C.CString(`{"error":"tooLarge"}`)
	}
	return C.CString(string(backupcodec.Handle(C.GoBytes(unsafe.Pointer(input), length))))
}

func main() {}

//export FlClashStartTun
func FlClashStartTun(fd C.int, options *C.char) *C.char {
	if err := core.StartOhosTun(int(fd), C.GoString(options)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export FlClashStopTun
func FlClashStopTun() { core.StopOhosTun() }

//export FlClashStopCore
func FlClashStopCore() { core.StopEmbedded() }

//export FlClashTakeOwners
func FlClashTakeOwners() *C.char { return C.CString(core.TakeOhosOwners()) }

//export FlClashResolveOwner
func FlClashResolveOwner(id C.uint, uid C.int, bundle *C.char) {
	core.ResolveOhosOwner(uint32(id), int(uid), C.GoString(bundle))
}
