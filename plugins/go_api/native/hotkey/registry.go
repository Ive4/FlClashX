//go:build (linux && !android && !flclash_ohos) || (darwin && !ios) || windows

package hotkey

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
)

type modifiers uint8

const (
	alt modifiers = 1 << iota
	control
	meta
	shift
)

type spec struct {
	ID        uint32   `json:"id"`
	Key       uint32   `json:"key"`
	Modifiers []string `json:"modifiers"`
}

type failure struct {
	ID     uint32 `json:"id"`
	Reason string `json:"reason"`
}

type eventSink struct {
	id   int64
	emit func(int64, int, []byte)
}

type backend interface {
	register(uint32, modifiers, uint32) (func(), error)
}

type registry struct {
	mu         sync.Mutex
	backend    backend
	unregister []func()
	nextID     uint32
	ids        atomic.Pointer[map[uint32]uint32]
	sink       atomic.Pointer[eventSink]
}

var active registry

func Invoke(operation string, request json.RawMessage, _ []byte, emit func(int64, int, []byte)) (any, error) {
	switch operation {
	case "listen", "unlisten":
		var args struct {
			Events int64 `json:"events"`
		}
		if err := json.Unmarshal(request, &args); err != nil {
			return nil, err
		}
		if args.Events <= 0 {
			return nil, errors.New("hotkeys require an event stream")
		}
		if operation == "listen" {
			active.sink.Store(&eventSink{args.Events, emit})
		} else if current := active.sink.Load(); current != nil && current.id == args.Events {
			active.sink.CompareAndSwap(current, nil)
		}
		return nil, nil
	case "set":
		var specs []spec
		if err := json.Unmarshal(request, &specs); err != nil {
			return nil, err
		}
		return active.replace(specs)
	default:
		return nil, fmt.Errorf("unknown hotkey operation %q", operation)
	}
}

func (r *registry) replace(specs []spec) ([]failure, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ids.Store(nil)
	for _, unregister := range r.unregister {
		unregister()
	}
	r.unregister = nil
	if r.backend == nil {
		platform, err := newBackend(r.pressed)
		if err != nil {
			return nil, err
		}
		r.backend = platform
	}

	ids := make(map[uint32]uint32, len(specs))
	failures := make([]failure, 0)
	for _, spec := range specs {
		mods, err := primaryModifiers(spec.Modifiers)
		if err == nil {
			// RegisterHotKey reserves IDs above 0xBFFF for shared libraries.
			r.nextID = r.nextID%0xBFFF + 1
			id := r.nextID
			var unregister func()
			unregister, err = r.backend.register(spec.Key, mods, id)
			if err == nil {
				ids[id] = spec.ID
				r.unregister = append(r.unregister, unregister)
			}
		}
		if err != nil {
			failures = append(failures, failure{spec.ID, err.Error()})
		}
	}
	r.ids.Store(&ids)
	return failures, nil
}

func (r *registry) pressed(nativeID uint32) {
	ids := r.ids.Load()
	sink := r.sink.Load()
	if ids == nil || sink == nil {
		return
	}
	if id, ok := (*ids)[nativeID]; ok {
		var data [4]byte
		binary.LittleEndian.PutUint32(data[:], id)
		sink.emit(sink.id, 1, data[:])
	}
}

func primaryModifiers(values []string) (modifiers, error) {
	var mods modifiers
	for _, value := range values {
		switch value {
		case "alt":
			mods |= alt
		case "control":
			mods |= control
		case "meta":
			mods |= meta
		case "shift":
			mods |= shift
		case "fn", "capsLock":
		default:
			return 0, fmt.Errorf("unknown hotkey modifier %q", value)
		}
	}
	if mods == 0 {
		return 0, errors.New("A global hotkey needs Shift, Control, Alt or Meta")
	}
	return mods, nil
}

func unsupportedKey(usage uint32) error {
	return fmt.Errorf("Key 0x%08x cannot be a global hotkey", usage)
}
