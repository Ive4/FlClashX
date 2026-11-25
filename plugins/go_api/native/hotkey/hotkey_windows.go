package hotkey

import (
	"errors"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	wmHotkey = 0x0312
	wmJob    = 0x8000
)

var (
	user32            = windows.NewLazySystemDLL("user32.dll")
	registerHotKey    = user32.NewProc("RegisterHotKey")
	unregisterHotKey  = user32.NewProc("UnregisterHotKey")
	getMessage        = user32.NewProc("GetMessageW")
	peekMessage       = user32.NewProc("PeekMessageW")
	postThreadMessage = user32.NewProc("PostThreadMessageW")
	errThreadStopped  = errors.New("Windows hotkey thread has stopped")
)

type winMessage struct {
	window  uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	x, y    int32
	private uint32
}

type winBackend struct {
	thread uint32
	jobs   chan func()
	done   chan struct{}
}

func newBackend(pressed func(uint32)) (backend, error) {
	b := &winBackend{jobs: make(chan func(), 1), done: make(chan struct{})}
	ready := make(chan struct{})
	go b.run(ready, pressed)
	<-ready
	return b, nil
}

func (b *winBackend) run(ready chan<- struct{}, pressed func(uint32)) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(b.done)
	var message winMessage
	// Windows only allocates the queue after this thread asks for messages.
	peekMessage.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0, 0)
	b.thread = windows.GetCurrentThreadId()
	close(ready)
	for {
		result, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) <= 0 {
			return
		}
		switch message.message {
		case wmJob:
			select {
			case job := <-b.jobs:
				job()
			default:
			}
		case wmHotkey:
			pressed(uint32(message.wParam))
		}
	}
}

func (b *winBackend) call(job func() error) error {
	reply := make(chan error, 1)
	select {
	case <-b.done:
		return errThreadStopped
	case b.jobs <- func() { reply <- job() }:
	}
	ok, _, err := postThreadMessage.Call(uintptr(b.thread), wmJob, 0, 0)
	if ok == 0 {
		select {
		case <-b.jobs:
			return err
		default:
		}
	}
	select {
	case err := <-reply:
		return err
	case <-b.done:
		return errThreadStopped
	}
}

func (b *winBackend) register(key uint32, modifiers modifiers, id uint32) (func(), error) {
	vk := virtualKey(key)
	if vk == 0 {
		return nil, unsupportedKey(key)
	}
	// MOD_NOREPEAT makes holding a shortcut trigger one press.
	flags := uintptr(0x4000)
	if modifiers&alt != 0 {
		flags |= 0x1
	}
	if modifiers&control != 0 {
		flags |= 0x2
	}
	if modifiers&shift != 0 {
		flags |= 0x4
	}
	if modifiers&meta != 0 {
		flags |= 0x8
	}
	if err := b.call(func() error {
		ok, _, err := registerHotKey.Call(0, uintptr(id), flags, uintptr(vk))
		if ok == 0 {
			return err
		}
		return nil
	}); err != nil {
		return nil, err
	}
	return func() {
		_ = b.call(func() error {
			unregisterHotKey.Call(0, uintptr(id))
			return nil
		})
	}, nil
}

func virtualKey(usage uint32) uint32 {
	switch {
	case usage >= 0x00070004 && usage <= 0x0007001d:
		return 'A' + usage - 0x00070004
	case usage >= 0x0007001e && usage <= 0x00070026:
		return '1' + usage - 0x0007001e
	case usage >= 0x0007003a && usage <= 0x00070045:
		return 0x70 + usage - 0x0007003a // F1–F12
	case usage >= 0x00070068 && usage <= 0x00070073:
		return 0x7c + usage - 0x00070068 // F13–F24
	case usage >= 0x00070059 && usage <= 0x00070061:
		return 0x61 + usage - 0x00070059 // Numpad1–Numpad9
	}
	return windowsKeys[usage]
}

var windowsKeys = map[uint32]uint32{
	0x00070027: '0',
	0x00070028: 0x0d, // Enter
	0x00070029: 0x1b, // Escape
	0x0007002a: 0x08, // Backspace
	0x0007002b: 0x09, // Tab
	0x0007002c: 0x20, // Space
	0x0007002d: 0xbd, // Minus
	0x0007002e: 0xbb, // Equal
	0x0007002f: 0xdb, // Left bracket
	0x00070030: 0xdd, // Right bracket
	0x00070031: 0xdc, // Backslash
	0x00070033: 0xba, // Semicolon
	0x00070034: 0xde, // Quote
	0x00070035: 0xc0, // Backquote
	0x00070036: 0xbc, // Comma
	0x00070037: 0xbe, // Period
	0x00070038: 0xbf, // Slash
	0x00070039: 0x14, // Caps Lock
	0x00070046: 0x2c, // Print Screen
	0x00070047: 0x91, // Scroll Lock
	0x00070048: 0x13, // Pause
	0x00070049: 0x2d, // Insert
	0x0007004a: 0x24, // Home
	0x0007004b: 0x21, // Page Up
	0x0007004c: 0x2e, // Delete
	0x0007004d: 0x23, // End
	0x0007004e: 0x22, // Page Down
	0x0007004f: 0x27, // Right
	0x00070050: 0x25, // Left
	0x00070051: 0x28, // Down
	0x00070052: 0x26, // Up
	0x00070053: 0x90, // Num Lock
	0x00070054: 0x6f, // Numpad divide
	0x00070055: 0x6a, // Numpad multiply
	0x00070056: 0x6d, // Numpad subtract
	0x00070057: 0x6b, // Numpad add
	0x00070058: 0x0d, // Numpad enter
	0x00070062: 0x60, // Numpad 0
	0x00070063: 0x6e, // Numpad decimal
	0x00070067: 'E',  // Numpad equal
	0x000c00b5: 0xb0, // Next track
	0x000c00b6: 0xb1, // Previous track
	0x000c00b7: 0xb2, // Media stop
	0x000c00cd: 0xb3, // Play/pause
	0x000c00e2: 0xad, // Mute
	0x000c00e9: 0xaf, // Volume up
	0x000c00ea: 0xae, // Volume down
}
