//go:build !android && !flclash_ohos

package hotkey

import (
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

const primaryMask = xproto.ModMask1 | xproto.ModMask4 | xproto.ModMaskControl | xproto.ModMaskShift

var lockMasks = [...]uint16{0, xproto.ModMask2, xproto.ModMaskLock, xproto.ModMask2 | xproto.ModMaskLock}

type combination struct {
	key  xproto.Keycode
	mask uint16
}

type grabState struct {
	id          uint32
	down        bool
	released    bool
	lastRelease xproto.Timestamp
}

type x11Backend struct {
	connection *xgb.Conn
	root       xproto.Window
	mu         sync.Mutex
	grabs      map[combination]*grabState
}

func newBackend(pressed func(uint32)) (backend, error) {
	if os.Getenv("DISPLAY") == "" {
		return nil, errors.New("Global hotkeys need an X11 display; DISPLAY is not set")
	}
	connection, err := xgb.NewConn()
	if err != nil {
		return nil, fmt.Errorf("unable to open the X11 display: %w", err)
	}
	b := &x11Backend{
		connection: connection,
		root:       xproto.Setup(connection).DefaultScreen(connection).Root,
		grabs:      make(map[combination]*grabState),
	}
	go b.run(pressed)
	return b, nil
}

func (b *x11Backend) run(pressed func(uint32)) {
	for {
		event, err := b.connection.WaitForEvent()
		if event == nil && err == nil {
			return
		}
		switch event := event.(type) {
		case xproto.KeyPressEvent:
			combo := combination{event.Detail, event.State & primaryMask}
			b.mu.Lock()
			grab := b.grabs[combo]
			var id uint32
			// X11 core auto-repeat sends a release and press with the same timestamp.
			if grab != nil && !grab.down && (!grab.released || grab.lastRelease != event.Time) {
				grab.down = true
				id = grab.id
			}
			b.mu.Unlock()
			if id != 0 {
				pressed(id)
			}
		case xproto.KeyReleaseEvent:
			b.mu.Lock()
			for combo, grab := range b.grabs {
				if combo.key == event.Detail {
					grab.down = false
					grab.released = true
					grab.lastRelease = event.Time
				}
			}
			b.mu.Unlock()
		}
	}
}

func (b *x11Backend) register(usage uint32, modifiers modifiers, id uint32) (func(), error) {
	symbol := keySymbol(usage)
	if symbol == 0 {
		return nil, unsupportedKey(usage)
	}
	key, err := b.keycode(symbol)
	if err != nil {
		return nil, err
	}
	var mask uint16
	if modifiers&alt != 0 {
		mask |= xproto.ModMask1
	}
	if modifiers&control != 0 {
		mask |= xproto.ModMaskControl
	}
	if modifiers&meta != 0 {
		mask |= xproto.ModMask4
	}
	if modifiers&shift != 0 {
		mask |= xproto.ModMaskShift
	}
	combo := combination{key, mask}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.grabs[combo] != nil {
		return nil, errors.New("hotkey is already registered")
	}
	for i, locks := range lockMasks {
		err := xproto.GrabKeyChecked(b.connection, false, b.root, mask|locks, key,
			xproto.GrabModeAsync, xproto.GrabModeAsync).Check()
		if err != nil {
			b.release(combo, lockMasks[:i])
			return nil, fmt.Errorf("unable to register X11 hotkey: %w", err)
		}
	}
	b.grabs[combo] = &grabState{id: id}
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		delete(b.grabs, combo)
		b.release(combo, lockMasks[:])
	}, nil
}

func (b *x11Backend) release(combo combination, locks []uint16) {
	for _, mask := range locks {
		_ = xproto.UngrabKeyChecked(b.connection, combo.key, b.root, combo.mask|mask).Check()
	}
}

func (b *x11Backend) keycode(symbol xproto.Keysym) (xproto.Keycode, error) {
	setup := xproto.Setup(b.connection)
	count := int(setup.MaxKeycode) - int(setup.MinKeycode) + 1
	mapping, err := xproto.GetKeyboardMapping(b.connection, setup.MinKeycode, byte(count)).Reply()
	if err != nil {
		return 0, err
	}
	if mapping == nil {
		return 0, errors.New("X11 keyboard mapping is unavailable")
	}
	for i, key := range mapping.Keysyms {
		if key == symbol {
			return setup.MinKeycode + xproto.Keycode(i/int(mapping.KeysymsPerKeycode)), nil
		}
	}
	return 0, fmt.Errorf("no X11 keycode for keysym 0x%x", symbol)
}

func keySymbol(usage uint32) xproto.Keysym {
	switch {
	case usage >= 0x00070004 && usage <= 0x0007001d:
		return xproto.Keysym('A' + usage - 0x00070004)
	case usage >= 0x0007001e && usage <= 0x00070026:
		return xproto.Keysym('1' + usage - 0x0007001e)
	case usage >= 0x0007003a && usage <= 0x00070045:
		return xproto.Keysym(0xffbe + usage - 0x0007003a) // F1–F12
	case usage >= 0x00070068 && usage <= 0x00070073:
		return xproto.Keysym(0xffca + usage - 0x00070068) // F13–F24
	case usage >= 0x00070059 && usage <= 0x00070061:
		return xproto.Keysym(0xffb1 + usage - 0x00070059) // Numpad1–Numpad9
	}
	return x11Keys[usage]
}

var x11Keys = map[uint32]xproto.Keysym{
	0x00070027: '0',
	0x00070028: 0xff0d, // Enter
	0x00070029: 0xff1b, // Escape
	0x0007002a: 0xff08, // Backspace
	0x0007002b: 0xff09, // Tab
	0x0007002c: ' ',
	0x0007002d: '-',
	0x0007002e: '=',
	0x0007002f: '[',
	0x00070030: ']',
	0x00070031: '\\',
	0x00070033: ';',
	0x00070034: 0x0ad0, // Left single quotation mark
	0x00070035: 0x0060, // Grave accent
	0x00070036: ',',
	0x00070037: '.',
	0x00070038: '/',
	0x00070039: 0xffe5,     // Caps Lock
	0x00070046: 0xff61,     // Print Screen
	0x00070047: 0xff14,     // Scroll Lock
	0x00070048: 0xff13,     // Pause
	0x00070049: 0xff63,     // Insert
	0x0007004a: 0xff50,     // Home
	0x0007004b: 0xff55,     // Page Up
	0x0007004c: 0xffff,     // Delete
	0x0007004d: 0xff57,     // End
	0x0007004e: 0xff56,     // Page Down
	0x0007004f: 0xff53,     // Right
	0x00070050: 0xff51,     // Left
	0x00070051: 0xff54,     // Down
	0x00070052: 0xff52,     // Up
	0x00070053: 0xffbe,     // Num Lock (F1 in the original X11 mapping)
	0x00070054: 0xffaf,     // Numpad divide
	0x00070055: 0xffaa,     // Numpad multiply
	0x00070056: 0xffad,     // Numpad subtract
	0x00070057: 0xffab,     // Numpad add
	0x00070062: 0xffb0,     // Numpad 0
	0x00070063: 0xffae,     // Numpad decimal
	0x000c00b5: 0x1008ff17, // Next track
	0x000c00b6: 0x1008ff16, // Previous track
	0x000c00b7: 0x1008ff15, // Media stop
	0x000c00e2: 0x1008ff12, // Mute
	0x000c00e9: 0x1008ff13, // Volume up
	0x000c00ea: 0x1008ff11, // Volume down
}
