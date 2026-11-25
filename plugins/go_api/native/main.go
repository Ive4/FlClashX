package main

// #include "bridge.h"
import "C"

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"unsafe"

	"flclashx/go_api/editor"
	"flclashx/go_api/hotkey"
	"flclashx/go_api/ipc"
	"flclashx/go_api/script"
)

var subscriptions = struct {
	sync.RWMutex
	next      int64
	callbacks map[int64]C.EventCallback
}{callbacks: make(map[int64]C.EventCallback)}

//export FlClashGoInvoke
func FlClashGoInvoke(operation *C.char, request *C.uint8_t, requestLength C.intptr_t, data *C.uint8_t, dataLength C.intptr_t, responseLength *C.intptr_t, responseKind *C.uint8_t) *C.uint8_t {
	name := C.GoString(operation)
	input := json.RawMessage(C.GoBytes(unsafe.Pointer(request), C.int(requestLength)))
	bytes := C.GoBytes(unsafe.Pointer(data), C.int(dataLength))
	result, err := invoke(name, input, bytes)
	responseKindValue := 0
	var response []byte
	if value, ok := result.([]byte); ok && err == nil {
		response = value
		responseKindValue = 1
	} else if err == nil {
		response, err = json.Marshal(result)
	}
	if err != nil {
		response = []byte(err.Error())
		responseKindValue = 2
	}
	*responseLength = C.intptr_t(len(response))
	*responseKind = C.uint8_t(responseKindValue)
	return (*C.uint8_t)(C.CBytes(response))
}

func invoke(name string, request json.RawMessage, data []byte) (result any, err error) {
	defer func() {
		if failure := recover(); failure != nil {
			result = nil
			err = fmt.Errorf("%s: %v", name, failure)
		}
	}()
	section, operation, _ := strings.Cut(name, ".")
	switch section {
	case "bridge":
		if operation == "version" {
			return 1, nil
		}
	case "editor":
		return editor.Invoke(operation, request, data)
	case "hotkey":
		return hotkey.Invoke(operation, request, data, emit)
	case "ipc":
		return ipc.Invoke(operation, request, data, emit)
	case "script":
		return script.Invoke(operation, request)
	}
	return nil, fmt.Errorf("unknown native operation %q", name)
}

//export FlClashGoFree
func FlClashGoFree(data *C.uint8_t) {
	C.free(unsafe.Pointer(data))
}

//export FlClashGoOpenEvents
func FlClashGoOpenEvents(callback C.EventCallback) C.int64_t {
	subscriptions.Lock()
	defer subscriptions.Unlock()
	subscriptions.next++
	id := subscriptions.next
	subscriptions.callbacks[id] = callback
	return C.int64_t(id)
}

//export FlClashGoCloseEvents
func FlClashGoCloseEvents(id C.int64_t) {
	subscriptions.Lock()
	defer subscriptions.Unlock()
	delete(subscriptions.callbacks, int64(id))
}

func emit(id int64, kind int, data []byte) {
	subscriptions.RLock()
	defer subscriptions.RUnlock()
	if callback := subscriptions.callbacks[id]; callback != nil {
		address := (*C.uint8_t)(C.CBytes(data))
		C.deliver_event(callback, C.int64_t(id), C.int32_t(kind), address, C.intptr_t(len(data)))
	}
}

func main() {}
