//go:build (linux && !android && !flclash_ohos) || (darwin && !ios) || windows

package hotkey

import (
	"encoding/binary"
	"errors"
	"reflect"
	"testing"
)

type testBackend struct {
	nativeIDs []uint32
	released  int
}

func (b *testBackend) register(key uint32, mods modifiers, id uint32) (func(), error) {
	if key != 0x00070004 || mods != control|shift {
		return nil, errors.New("shortcut already taken")
	}
	b.nativeIDs = append(b.nativeIDs, id)
	return func() { b.released++ }, nil
}

func TestReplaceReportsIndividualFailuresAndEmitsCurrentIDs(t *testing.T) {
	backend := &testBackend{}
	r := registry{backend: backend}
	var events []uint32
	r.sink.Store(&eventSink{1, func(id int64, kind int, data []byte) {
		events = append(events, binary.LittleEndian.Uint32(data))
	}})
	failures, err := r.replace([]spec{
		{6, 0x00070004, []string{"control", "shift", "capsLock"}},
		{7, 0x00070005, []string{"control"}},
		{8, 0x00070004, []string{"fn"}},
	})
	if err != nil || len(failures) != 2 || failures[0].ID != 7 || failures[1].ID != 8 {
		t.Fatalf("failures = %+v, error = %v", failures, err)
	}
	nativeID := backend.nativeIDs[0]
	r.pressed(nativeID)
	failures, err = r.replace(nil)
	if err != nil || len(failures) != 0 || backend.released != 1 {
		t.Fatalf("failures = %+v, error = %v, released = %d", failures, err, backend.released)
	}
	r.pressed(nativeID)
	if !reflect.DeepEqual(events, []uint32{6}) {
		t.Fatalf("events = %v", events)
	}
}
