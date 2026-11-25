package script

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestEvaluate(t *testing.T) {
	const config = `{"mode":"rule"}`
	for _, test := range []struct {
		name, script, result, errorContains string
	}{
		{"transform", "function main(c) { c.mode = 'global'; return c }", `{"mode":"global"}`, ""},
		{"lexical entry", "const main = c => ({ ...c, mode: 'direct' })", `{"mode":"direct"}`, ""},
		{"unchanged", "function main() { console.log('testing', {ok:true}) }", config, ""},
		{"async", "async function main(c) { await Promise.resolve(); return c }", config, ""},
		{"rejected", "async function main() { throw new Error('bad profile') }", "", "bad profile"},
		{"never settles", "function main() { return new Promise(() => {}) }", "", "did not settle"},
		{"no host API", "function main() { return {load: typeof loadScript, os: typeof os, timer: typeof setTimeout} }", `{"load":"undefined","os":"undefined","timer":"undefined"}`, ""},
		{"module denied", "async function main() { await import('os'); return {} }", "", "module"},
		{"missing main", "const other = () => null", "", "does not define main()"},
		{"unserializable", "function main() { return () => ({}) }", "", "not JSON"},
		{"loop", "function main() { while (true) {} }", "", "interrupted"},
	} {
		t.Run(test.name, func(t *testing.T) {
			result, err := evaluate(test.script, config, 250*time.Millisecond)
			if test.errorContains != "" {
				if err == nil || !strings.Contains(err.Error(), test.errorContains) {
					t.Fatalf("expected %q, got %v", test.errorContains, err)
				}
				return
			}
			if err != nil || result != test.result {
				t.Fatalf("expected %s, got %q, %v", test.result, result, err)
			}
		})
	}
}

func TestProfileScriptFixture(t *testing.T) {
	code, err := os.ReadFile("testdata/profile_script.js")
	if err != nil {
		t.Fatal(err)
	}
	config, err := os.ReadFile("testdata/profile_config.json")
	if err != nil {
		t.Fatal(err)
	}
	result, err := evaluate(string(code), string(config), timeout)
	if err != nil || result == string(config) || !strings.Contains(result, `"proxy-groups"`) {
		t.Fatalf("unexpected profile output: %s %v", result, err)
	}
}
