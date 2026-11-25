// The editor backend derives from code_forge 10.14.0 by Athul A S.
// See plugins/code_forge/LICENSE for its MIT license.
package editor

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
	"unicode/utf8"
)

type document struct {
	mu   sync.RWMutex
	root *node
}

func (doc *document) snapshot() *node {
	doc.mu.RLock()
	defer doc.mu.RUnlock()
	return doc.root
}

var documents = struct {
	sync.RWMutex
	next  uint64
	items map[uint64]*document
}{items: make(map[uint64]*document)}

var uploads = struct {
	sync.Mutex
	next  uint64
	items map[uint64][]byte
}{items: make(map[uint64][]byte)}

func register(root *node) uint64 {
	documents.Lock()
	defer documents.Unlock()
	documents.next++
	documents.items[documents.next] = &document{root: root}
	return documents.next
}

func lookup(id uint64) (*document, error) {
	documents.RLock()
	doc := documents.items[id]
	documents.RUnlock()
	if doc == nil {
		return nil, errors.New("editor document is disposed")
	}
	return doc, nil
}

type openResult struct {
	ID      uint64 `json:"id,omitempty"`
	Kind    string `json:"kind,omitempty"`
	Message string `json:"message,omitempty"`
}

func fromUTF8(data []byte) openResult {
	if !utf8.Valid(data) {
		return openResult{Kind: "notUtf8", Message: "document is not valid UTF-8"}
	}
	if bytes.Contains(data, []byte("\r\n")) {
		data = bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))
	}
	root := buildChunks(data, func(chunk []byte) string { return string(chunk) })
	return openResult{ID: register(root)}
}

type arguments struct {
	ID        uint64
	Original  uint64
	Path      string
	Text      string
	Start     int
	End       int
	Index     int
	Length    int
	TabSize   int
	FirstLine int
	LastLine  int
}

func Invoke(operation string, request json.RawMessage, data []byte) (any, error) {
	var args arguments
	if err := json.Unmarshal(request, &args); err != nil {
		return nil, err
	}
	switch operation {
	case "create":
		return register(build(args.Text)), nil
	case "openFile":
		data, err := os.ReadFile(args.Path)
		if err != nil {
			kind := "unreadable"
			if errors.Is(err, fs.ErrNotExist) {
				kind = "notFound"
			}
			return openResult{Kind: kind, Message: err.Error()}, nil
		}
		return fromUTF8(data), nil
	case "fromUtf8":
		return fromUTF8(data), nil
	case "beginUpload":
		if args.Length < 0 {
			return nil, errors.New("invalid editor upload length")
		}
		data = make([]byte, 0, args.Length)
		uploads.Lock()
		uploads.next++
		id := uploads.next
		uploads.items[id] = data
		uploads.Unlock()
		return id, nil
	case "uploadChunk":
		uploads.Lock()
		defer uploads.Unlock()
		buffer, ok := uploads.items[args.ID]
		if !ok || len(data) > cap(buffer)-len(buffer) {
			return nil, errors.New("unexpected editor upload chunk")
		}
		uploads.items[args.ID] = append(buffer, data...)
		return nil, nil
	case "finishUpload", "discardUpload":
		uploads.Lock()
		buffer, ok := uploads.items[args.ID]
		delete(uploads.items, args.ID)
		uploads.Unlock()
		if operation == "discardUpload" {
			return nil, nil
		}
		if !ok || len(buffer) != cap(buffer) {
			return nil, errors.New("incomplete editor upload")
		}
		return fromUTF8(buffer), nil
	case "dispose":
		documents.Lock()
		delete(documents.items, args.ID)
		documents.Unlock()
		return nil, nil
	}

	doc, err := lookup(args.ID)
	if err != nil {
		return nil, err
	}
	switch operation {
	case "insert":
		doc.mu.Lock()
		at := doc.root.charByte(args.Index)
		doc.root = doc.root.splice(at, at, args.Text)
		doc.mu.Unlock()
		return nil, nil
	case "remove":
		doc.mu.Lock()
		start := doc.root.charByte(args.Start)
		end := doc.root.charByte(max(args.Start, args.End))
		doc.root = doc.root.splice(start, end, "")
		doc.mu.Unlock()
		return nil, nil
	}

	root := doc.snapshot()
	return readDocument(operation, root, args)
}

func readDocument(operation string, root *node, args arguments) (any, error) {
	switch operation {
	case "snapshot":
		return register(root), nil
	case "length":
		return root.length(), nil
	case "lineCount":
		return root.lineBreaks() + 1, nil
	case "text", "utf8Bytes":
		return root.bytesRange(0, root.size()), nil
	case "slice":
		start := root.charByte(args.Start)
		end := root.charByte(max(args.Start, args.End))
		return root.bytesRange(start, end), nil
	case "charToLine":
		return root.byteLine(root.charByte(args.Index)), nil
	case "lineToChar":
		return root.byteChar(root.lineByte(min(args.Index, root.lineBreaks()))), nil
	case "line":
		index := min(max(args.Index, 0), root.lineBreaks())
		return []byte(stripLineBreak(root.textRange(root.lineByte(index), root.lineByte(index+1)))), nil
	case "lines":
		return readLines(root, args.Start, args.End), nil
	case "sameText":
		original, err := lookup(args.Original)
		if err != nil {
			return nil, err
		}
		return sameText(root, original.snapshot(), args), nil
	case "folds":
		return computeFolds(root, args.TabSize), nil
	case "matchingBracket":
		if args.Index < 0 || args.Index >= root.length() {
			return nil, nil
		}
		if match := matchingBracket(root, root.charByte(args.Index), root.size()); match >= 0 {
			return root.byteChar(match), nil
		}
		return nil, nil
	case "guides":
		return computeGuides(root, args.FirstLine, args.LastLine, args.TabSize), nil
	case "words":
		return extractWords(root), nil
	default:
		return nil, fmt.Errorf("unknown editor operation %q", operation)
	}
}

func stripLineBreak(line string) string {
	if without, hasLF := strings.CutSuffix(line, "\n"); hasLF {
		return strings.TrimSuffix(without, "\r")
	}
	return line
}

func readLines(root *node, start, end int) []string {
	start = max(start, 0)
	end = min(end, root.lineBreaks()+1)
	if start >= end {
		return []string{}
	}
	lines := make([]string, 0, end-start)
	text := root.textRange(root.lineByte(start), root.lineByte(end))
	for line := range strings.SplitAfterSeq(text, "\n") {
		if len(lines) == end-start {
			break
		}
		lines = append(lines, stripLineBreak(line))
	}
	return lines
}

func sameText(root, original *node, args arguments) bool {
	start := min(max(args.Start, 0), root.length())
	removed := min(max(args.Length, 0), root.length()-start)
	first := root.charByte(start)
	last := root.charByte(start + removed)
	insertedEnd := first + len(args.Text)
	if insertedEnd+root.size()-last != original.size() {
		return false
	}
	return equalRange(root, 0, original, 0, first) &&
		original.textRange(first, insertedEnd) == args.Text &&
		equalRange(root, last, original, insertedEnd, root.size()-last)
}
