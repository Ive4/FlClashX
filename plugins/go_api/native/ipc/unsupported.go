//go:build android || flclash_ohos || ios || (!linux && !darwin && !windows)

package ipc

import (
	"encoding/json"
	"errors"
)

func Invoke(string, json.RawMessage, []byte, func(int64, int, []byte)) (any, error) {
	return nil, errors.New("desktop IPC is unavailable on this platform")
}
