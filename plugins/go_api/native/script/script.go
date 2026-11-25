package script

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/buke/quickjs-go"
)

const (
	timeout     = 10 * time.Second
	memoryLimit = 256 * 1024 * 1024
)

func Invoke(operation string, request json.RawMessage) (any, error) {
	if operation != "evaluate" {
		return nil, fmt.Errorf("unknown script operation %q", operation)
	}
	var input struct {
		Script string `json:"script"`
		Config string `json:"config"`
	}
	if err := json.Unmarshal(request, &input); err != nil {
		return nil, err
	}
	return evaluate(input.Script, input.Config, timeout)
}

func evaluate(script, config string, limit time.Duration) (string, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	vm := quickjs.NewRuntime(
		quickjs.WithMemoryLimit(memoryLimit),
		quickjs.WithMaxStackSize(1<<20),
		quickjs.WithCanBlock(false),
	)
	defer vm.Close()
	deadline := time.Now().Add(limit)
	vm.SetInterruptHandler(func() int {
		if !time.Now().Before(deadline) {
			return 1
		}
		return 0
	})
	ctx := vm.NewBareContext()
	if ctx == nil {
		return "", errors.New("cannot initialize script context")
	}
	defer ctx.Close()

	if !json.Valid([]byte(config)) {
		return "", errors.New("profile is not valid JSON")
	}
	initial := ctx.ParseJSON(config)
	defer initial.Free()
	if initial.IsException() {
		return "", ctx.Exception()
	}
	stringify := ctx.Eval("JSON.stringify")
	defer stringify.Free()
	if stringify.IsException() {
		return "", ctx.Exception()
	}
	noThis := ctx.Undefined()
	defer noThis.Free()
	setConsole(ctx, stringify, noThis)

	program := ctx.Eval(script, quickjs.EvalFileName("profile.js"))
	defer program.Free()
	if program.IsException() {
		return "", ctx.Exception()
	}
	entry := ctx.Eval("main")
	defer entry.Free()
	if !entry.IsFunction() {
		return "", errors.New("script does not define main()")
	}
	result := ctx.Invoke(entry, noThis, initial)
	defer result.Free()
	if result.IsException() {
		return "", ctx.Exception()
	}
	if result.IsPromise() {
		resolved, err := resolvePromise(ctx, result, deadline)
		if err != nil {
			return "", err
		}
		defer resolved.Free()
		result = resolved
	}
	if result.IsUndefined() || result.IsNull() {
		return config, nil
	}
	output := ctx.Invoke(stringify, noThis, result)
	defer output.Free()
	if output.IsException() {
		return "", ctx.Exception()
	}
	if output.IsUndefined() {
		return "", errors.New("main() returned a value that is not JSON")
	}
	return output.ToString(), nil
}

func resolvePromise(ctx *quickjs.Context, promise *quickjs.Value, deadline time.Time) (*quickjs.Value, error) {
	for promise.PromiseState() == quickjs.PromisePending {
		if !time.Now().Before(deadline) {
			return nil, errors.New("script execution timed out")
		}
		switch ctx.LoopOnce() {
		case -2:
			if err := ctx.Exception(); err != nil {
				return nil, err
			}
			return nil, errors.New("failed to execute script jobs")
		case -1:
			if promise.PromiseState() == quickjs.PromisePending {
				return nil, errors.New("main() returned a Promise that did not settle")
			}
		}
	}
	result := promise.PromiseResult()
	if promise.PromiseState() == quickjs.PromiseRejected {
		defer result.Free()
		if err := result.ToError(); err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("main() rejected: %s", result.ToString())
	}
	return result, nil
}

func setConsole(ctx *quickjs.Context, stringify, noThis *quickjs.Value) {
	console := ctx.NewObject()
	for _, level := range []string{"log", "info", "warn", "error", "debug", "trace"} {
		console.Set(level, ctx.NewFunction(func(ctx *quickjs.Context, _ *quickjs.Value, values []*quickjs.Value) *quickjs.Value {
			parts := make([]string, 0, len(values))
			for _, value := range values {
				if value.IsString() {
					parts = append(parts, value.ToString())
					continue
				}
				encoded := ctx.Invoke(stringify, noThis, value)
				switch {
				case encoded.IsException():
					_ = ctx.Exception()
					parts = append(parts, "[unprintable value]")
				case encoded.IsUndefined():
					parts = append(parts, "undefined")
				default:
					parts = append(parts, encoded.ToString())
				}
				encoded.Free()
			}
			fmt.Fprintf(os.Stderr, "[script:%s] %s\n", level, strings.Join(parts, " "))
			return ctx.Undefined()
		}))
	}
	ctx.Globals().Set("console", console)
}
