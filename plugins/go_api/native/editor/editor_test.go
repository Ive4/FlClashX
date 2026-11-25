package editor

import (
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func call(t *testing.T, op string, args map[string]any, data ...byte) any {
	t.Helper()
	request, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	result, err := Invoke(op, request, data)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestDocumentCoordinatesAndSnapshot(t *testing.T) {
	text := "a\u0301😀\r\nb\r\n\r"
	original := call(t, "create", map[string]any{"text": text})
	defer call(t, "dispose", map[string]any{"id": original})
	id := call(t, "snapshot", map[string]any{"id": original})
	args := map[string]any{"id": id}
	defer call(t, "dispose", args)
	if got := call(t, "length", args); got != 9 {
		t.Fatalf("scalar length is %v", got)
	}
	args["start"], args["end"] = 0, 4
	want := []string{"a\u0301😀", "b", "\r"}
	if got := call(t, "lines", args); !reflect.DeepEqual(got, want) {
		t.Fatalf("lines = %#v, want %#v", got, want)
	}
	args["index"] = 2
	if got := call(t, "lineToChar", args); got != 8 {
		t.Fatalf("final line starts at %v", got)
	}
	args["index"] = 4
	if got := call(t, "charToLine", args); got != 0 {
		t.Fatalf("line of LF is %v", got)
	}
	args["start"], args["end"] = 1, 3
	call(t, "remove", args)
	if got := string(call(t, "utf8Bytes", args).([]byte)); got != "a\r\nb\r\n\r" {
		t.Fatalf("edited text is %q", got)
	}
	if got := string(call(t, "utf8Bytes", map[string]any{"id": original}).([]byte)); got != text {
		t.Fatalf("snapshot changed to %q", got)
	}
	args["original"], args["start"], args["length"], args["text"] = original, 1, 0, "\u0301😀"
	if !call(t, "sameText", args).(bool) {
		t.Fatal("the buffered splice should restore the original")
	}
}

func TestOpenDocument(t *testing.T) {
	dir := t.TempDir()
	for _, test := range []struct {
		name string
		data string
		kind string
	}{
		{name: "missing", kind: "notFound"},
		{name: "binary", data: "a\xff", kind: "notUtf8"},
		{name: "text", data: "\ufeffa\rb\r\n名\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(dir, test.name)
			if test.data != "" {
				if err := os.WriteFile(path, []byte(test.data), 0600); err != nil {
					t.Fatal(err)
				}
			}
			result := call(t, "openFile", map[string]any{"path": path})
			encoded, err := json.Marshal(result)
			if err != nil {
				t.Fatal(err)
			}
			var opened struct {
				ID   uint64
				Kind string
			}
			if err := json.Unmarshal(encoded, &opened); err != nil {
				t.Fatal(err)
			}
			if opened.Kind != test.kind {
				t.Fatalf("open result = %s", encoded)
			}
			if test.kind == "" {
				args := map[string]any{"id": opened.ID}
				defer call(t, "dispose", args)
				got := string(call(t, "utf8Bytes", args).([]byte))
				if got != "\ufeffa\rb\n名\n" {
					t.Fatalf("read text = %q", got)
				}
			}
		})
	}
}

func TestUploadJoinsChunksBeforeDecoding(t *testing.T) {
	for _, test := range []struct {
		name   string
		chunks []string
		want   string
	}{
		{"splits a character and a line break", []string{"a\xe5", "\x90\x8d\r", "\nb"}, "a名\nb"},
		{"rejects a truncated character", []string{"a\xe5", "\x90"}, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			length := 0
			for _, chunk := range test.chunks {
				length += len(chunk)
			}
			id := call(t, "beginUpload", map[string]any{"length": length})
			args := map[string]any{"id": id}
			defer call(t, "discardUpload", args)
			for _, chunk := range test.chunks {
				call(t, "uploadChunk", args, []byte(chunk)...)
			}
			result := call(t, "finishUpload", args).(openResult)
			if test.want == "" {
				if result.Kind != "notUtf8" {
					t.Fatalf("invalid UTF-8 result = %#v", result)
				}
				return
			}
			args = map[string]any{"id": result.ID}
			defer call(t, "dispose", args)
			got := string(call(t, "utf8Bytes", args).([]byte))
			if got != test.want {
				t.Fatalf("decoded content = %q, want %q", got, test.want)
			}
		})
	}
}

func TestFoldBracketGuideAndWordResults(t *testing.T) {
	text := "x: [\n  a:\n    item1 名\n\n  other (\n    1abc\n  )\n]\n"
	id := call(t, "create", map[string]any{"text": text})
	args := map[string]any{"id": id, "tabSize": 2, "index": 3, "firstLine": 2, "lastLine": 4}
	defer call(t, "dispose", args)
	if got := call(t, "matchingBracket", args); got != len([]rune(text))-2 {
		t.Fatalf("closing bracket is at %v", got)
	}
	for _, test := range []struct {
		op   string
		want string
	}{
		{"folds", `[{"startLine":0,"endLine":7},{"startLine":1,"endLine":2},{"startLine":4,"endLine":6}]`},
		{"guides", `[{"startLine":0,"endLine":6,"indentLevel":0,"leadingSpaces":0},{"startLine":1,"endLine":3,"indentLevel":1,"leadingSpaces":2},{"startLine":4,"endLine":6,"indentLevel":1,"leadingSpaces":2}]`},
		{"words", `["a","item1","other","x","名"]`},
	} {
		got, err := json.Marshal(call(t, test.op, args))
		if err != nil || string(got) != test.want {
			t.Errorf("%s = %s, %v; want %s", test.op, got, err, test.want)
		}
	}
}

func TestLongLineEditsAgainstScalarModel(t *testing.T) {
	text := strings.Repeat("a😀c\r", 16384)
	runes := []rune(text)
	id := call(t, "create", map[string]any{"text": text})
	args := map[string]any{"id": id}
	defer call(t, "dispose", args)
	random := rand.New(rand.NewSource(11))
	for range 4000 {
		start := random.Intn(len(runes))
		end := min(start+random.Intn(10), len(runes))
		args["start"], args["end"] = start, end
		call(t, "remove", args)
		insert := []rune("a名\n😀")
		args["index"], args["text"] = start, string(insert)
		call(t, "insert", args)
		runes = append(runes[:start], append(insert, runes[end:]...)...)
	}
	got := string(call(t, "utf8Bytes", args).([]byte))
	if got != string(runes) {
		t.Fatal("long line edits diverged from the scalar model")
	}
	beginning := 0
	for index, line := range strings.Split(got, "\n") {
		args["index"] = index
		if got := call(t, "lineToChar", args); got != beginning {
			t.Fatalf("line %d starts at %v, want %d", index, got, beginning)
		}
		beginning += len([]rune(line)) + 1
	}
}
