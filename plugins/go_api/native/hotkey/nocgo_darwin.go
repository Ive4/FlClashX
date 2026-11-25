//go:build !ios && !cgo

package hotkey

import "errors"

func newBackend(func(uint32)) (backend, error) {
	return nil, errors.New("macOS global hotkeys require cgo")
}
