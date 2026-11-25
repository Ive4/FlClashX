package editor

import (
	"strings"
	"unicode/utf8"
)

const chunkSize = 2048

// Nodes are immutable so document snapshots share untouched text across edits.
type node struct {
	left, right  *node
	text         string
	height       int
	bytes, chars int
	breaks       int
	brackets     bool
	spacing      spacing
}

type spacing uint8

const (
	content spacing = iota
	whitespace
	spaces
)

func leaf(text string) *node {
	if text == "" {
		return nil
	}
	kind := content
	if strings.TrimSpace(text) == "" {
		kind = whitespace
		if strings.Count(text, " ") == len(text) {
			kind = spaces
		}
	}
	return &node{
		text: text, height: 1, bytes: len(text), chars: utf8.RuneCountInString(text),
		breaks: strings.Count(text, "\n"), brackets: strings.ContainsAny(text, "()[]{}"),
		spacing: kind,
	}
}

func build(text string) *node {
	return buildChunks(text, strings.Clone)
}

func buildChunks[T string | []byte](text T, own func(T) string) *node {
	if len(text) <= chunkSize {
		return leaf(own(text))
	}
	middle := len(text) / 2
	for !utf8.RuneStart(text[middle]) {
		middle++
	}
	return branch(buildChunks(text[:middle], own), buildChunks(text[middle:], own))
}

func (n *node) size() int {
	if n == nil {
		return 0
	}
	return n.bytes
}

func (n *node) length() int {
	if n == nil {
		return 0
	}
	return n.chars
}

func (n *node) lineBreaks() int {
	if n == nil {
		return 0
	}
	return n.breaks
}

func branch(left, right *node) *node {
	return &node{
		left: left, right: right, height: max(left.height, right.height) + 1,
		bytes: left.bytes + right.bytes, chars: left.chars + right.chars,
		breaks: left.breaks + right.breaks, brackets: left.brackets || right.brackets,
		spacing: min(left.spacing, right.spacing),
	}
}

func balance(left, right *node) *node {
	if left.height > right.height+1 {
		a, b := left.left, left.right
		if a.height >= b.height {
			return branch(a, branch(b, right))
		}
		return branch(branch(a, b.left), branch(b.right, right))
	}
	if right.height > left.height+1 {
		a, b := right.left, right.right
		if b.height >= a.height {
			return branch(branch(left, a), b)
		}
		return branch(branch(left, a.left), branch(a.right, b))
	}
	return branch(left, right)
}

func join(left, right *node) *node {
	if left == nil {
		return right
	}
	if right == nil {
		return left
	}
	if left.height > right.height+1 {
		return balance(left.left, join(left.right, right))
	}
	if right.height > left.height+1 {
		return balance(join(left, right.left), right.right)
	}
	if left.height == 1 && right.height == 1 && left.bytes+right.bytes <= chunkSize {
		return leaf(left.text + right.text)
	}
	return branch(left, right)
}

func (n *node) split(offset int) (*node, *node) {
	if offset == 0 {
		return nil, n
	}
	if offset == n.bytes {
		return n, nil
	}
	if n.height == 1 {
		return leaf(n.text[:offset]), leaf(n.text[offset:])
	}
	if offset < n.left.bytes {
		before, after := n.left.split(offset)
		return before, join(after, n.right)
	}
	before, after := n.right.split(offset - n.left.bytes)
	return join(n.left, before), after
}

func (n *node) splice(start, end int, text string) *node {
	if start == end && text == "" {
		return n
	}
	before, rest := n.split(start)
	_, after := rest.split(end - start)
	return join(join(before, build(text)), after)
}

func (n *node) charByte(index int) int {
	if index <= 0 {
		return 0
	}
	if index >= n.length() {
		return n.size()
	}
	if n.height != 1 {
		if index < n.left.chars {
			return n.left.charByte(index)
		}
		return n.left.bytes + n.right.charByte(index-n.left.chars)
	}
	if n.chars == n.bytes {
		return index
	}
	for offset := range n.text {
		if index == 0 {
			return offset
		}
		index--
	}
	return n.bytes
}

func (n *node) byteChar(offset int) int {
	if offset <= 0 {
		return 0
	}
	if offset >= n.size() {
		return n.length()
	}
	if n.height != 1 {
		if offset < n.left.bytes {
			return n.left.byteChar(offset)
		}
		return n.left.chars + n.right.byteChar(offset-n.left.bytes)
	}
	if n.chars == n.bytes {
		return offset
	}
	return utf8.RuneCountInString(n.text[:offset])
}

func (n *node) byteLine(offset int) int {
	if offset <= 0 {
		return 0
	}
	if offset >= n.size() {
		return n.lineBreaks()
	}
	if n.height == 1 {
		return strings.Count(n.text[:offset], "\n")
	}
	if offset < n.left.bytes {
		return n.left.byteLine(offset)
	}
	return n.left.breaks + n.right.byteLine(offset-n.left.bytes)
}

// Line indices beyond the last LF address the end of the document.
func (n *node) lineByte(line int) int {
	if line <= 0 {
		return 0
	}
	if line > n.lineBreaks() {
		return n.size()
	}
	if n.height != 1 {
		if line <= n.left.breaks {
			return n.left.lineByte(line)
		}
		return n.left.bytes + n.right.lineByte(line-n.left.breaks)
	}
	offset := 0
	for range line {
		offset += strings.IndexByte(n.text[offset:], '\n') + 1
	}
	return offset
}

func (n *node) bytesRange(start, end int) []byte {
	result := make([]byte, 0, end-start)
	n.visit(start, end, 0, false, visitAll, func(_ int, chunk string) bool {
		result = append(result, chunk...)
		return true
	})
	return result
}

func (n *node) textRange(start, end int) string {
	if start >= end {
		return ""
	}
	for n.height != 1 {
		split := n.left.bytes
		if end <= split {
			n = n.left
		} else if start >= split {
			n, start, end = n.right, start-split, end-split
		} else {
			break
		}
	}
	if n.height == 1 {
		return n.text[start:end]
	}
	var text strings.Builder
	text.Grow(end - start)
	n.visit(start, end, 0, false, visitAll, func(_ int, chunk string) bool {
		text.WriteString(chunk)
		return true
	})
	return text.String()
}

type chunkFilter uint8

const (
	visitAll chunkFilter = iota
	visitBrackets
	visitNonBlank
)

func (n *node) visit(start, end, base int, reverse bool, filter chunkFilter, yield func(int, string) bool) bool {
	if start >= end || (filter == visitBrackets && !n.brackets) || (filter == visitNonBlank && n.spacing != content) {
		return true
	}
	if n.height == 1 {
		return yield(base+start, n.text[start:end])
	}
	split := n.left.bytes
	left := func() bool {
		return n.left.visit(start, min(end, split), base, reverse, filter, yield)
	}
	right := func() bool {
		return n.right.visit(max(0, start-split), end-split, base+split, reverse, filter, yield)
	}
	if reverse {
		return right() && left()
	}
	return left() && right()
}

func equalRange(left *node, leftStart int, right *node, rightStart, length int) bool {
	if length == 0 || (left == right && leftStart == rightStart) {
		return true
	}
	for left.height != 1 {
		split := left.left.bytes
		if leftStart+length <= split {
			left = left.left
		} else if leftStart >= split {
			left, leftStart = left.right, leftStart-split
		} else {
			break
		}
	}
	for right.height != 1 {
		split := right.left.bytes
		if rightStart+length <= split {
			right = right.left
		} else if rightStart >= split {
			right, rightStart = right.right, rightStart-split
		} else {
			break
		}
	}
	if left == right && leftStart == rightStart {
		return true
	}
	if left.height == 1 && right.height == 1 {
		return left.text[leftStart:leftStart+length] == right.text[rightStart:rightStart+length]
	}
	first := 0
	if left.height != 1 {
		first = left.left.bytes - leftStart
	} else {
		first = right.left.bytes - rightStart
	}
	return equalRange(left, leftStart, right, rightStart, first) &&
		equalRange(left, leftStart+first, right, rightStart+first, length-first)
}
