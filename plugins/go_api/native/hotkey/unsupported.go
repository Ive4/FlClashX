//go:build android || flclash_ohos || ios || (!linux && !darwin && !windows)

package hotkey

import (
	"encoding/json"
	"errors"
)

func Invoke(string, json.RawMessage, []byte, func(int64, int, []byte)) (any, error) {
	return nil, errors.New("global hotkeys are unavailable on this platform")
}
