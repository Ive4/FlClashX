package hotkey

import (
	"testing"
	"time"
)

func TestWindowsThreadExecutesJobsAndForwardsHotkeyMessages(t *testing.T) {
	presses := make(chan uint32, 1)
	platform, err := newBackend(func(id uint32) { presses <- id })
	if err != nil {
		t.Fatal(err)
	}
	b := platform.(*winBackend)
	t.Cleanup(func() { postThreadMessage.Call(uintptr(b.thread), 0x0012, 0, 0) })

	if err := b.call(func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	const id = 123
	if ok, _, err := postThreadMessage.Call(uintptr(b.thread), wmHotkey, id, 0); ok == 0 {
		t.Fatal(err)
	}
	select {
	case got := <-presses:
		if got != id {
			t.Fatalf("event id = %d, want %d", got, id)
		}
	case <-time.After(time.Second):
		t.Fatal("hotkey message was not delivered")
	}
}
