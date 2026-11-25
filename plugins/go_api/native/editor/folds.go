package editor

import (
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

const scanBackLimit = 500

type foldRange struct {
	StartLine int `json:"startLine"`
	EndLine   int `json:"endLine"`
}

func bracketKind(ch rune) (kind int, opening bool) {
	switch ch {
	case '{', '}':
		return 0, ch == '{'
	case '[', ']':
		return 1, ch == '['
	case '(', ')':
		return 2, ch == '('
	default:
		return -1, false
	}
}

func nextIndent(col int, ch rune, tabSize int) (int, bool) {
	switch {
	case ch == ' ':
		return col + 1, true
	case ch == '\t' && tabSize > 0:
		return col + tabSize - col%tabSize, true
	case ch == '\t':
		return col + 1, true
	default:
		return col, false
	}
}

func computeFolds(root *node, tabSize int) []foldRange {
	type indentStart struct{ line, columns int }
	ends := make(map[int]int)
	var bracketEnds [3][]int
	var colons []indentStart
	line, columns, lastContent := 0, 0, 0
	inIndent := true
	var last rune
	var hasContent bool
	closeIndent := func(start int) {
		if lastContent <= start {
			return
		}
		if end, seen := ends[start]; !seen || lastContent < end {
			ends[start] = lastContent
		}
	}
	finishLine := func() {
		if hasContent {
			for len(colons) > 0 && columns <= colons[len(colons)-1].columns {
				closeIndent(colons[len(colons)-1].line)
				colons = colons[:len(colons)-1]
			}
			if last == ':' {
				colons = append(colons, indentStart{line, columns})
			}
			lastContent = line
		}
		line++
		columns, inIndent, hasContent = 0, true, false
	}
	root.visit(0, root.size(), 0, false, visitAll, func(_ int, chunk string) bool {
		for _, ch := range chunk {
			if ch == '\n' {
				finishLine()
				continue
			}
			if inIndent {
				columns, inIndent = nextIndent(columns, ch, tabSize)
			}
			if !unicode.IsSpace(ch) && ch != '\ufeff' {
				last, hasContent = ch, true
			}
			kind, opening := bracketKind(ch)
			if kind == -1 {
				continue
			}
			stack := bracketEnds[kind]
			if opening {
				bracketEnds[kind] = append(stack, line)
			} else if len(stack) > 0 {
				start := stack[len(stack)-1]
				bracketEnds[kind] = stack[:len(stack)-1]
				if start < line {
					if end, seen := ends[start]; !seen || line < end {
						ends[start] = line
					}
				}
			}
		}
		return true
	})
	finishLine()
	for _, colon := range colons {
		closeIndent(colon.line)
	}
	folds := make([]foldRange, 0, len(ends))
	for start, end := range ends {
		folds = append(folds, foldRange{start, end})
	}
	slices.SortFunc(folds, func(a, b foldRange) int {
		return a.StartLine - b.StartLine
	})
	return folds
}

func matchingBracket(root *node, offset, limit int) int {
	start := root.textRange(offset, offset+1)[0]
	kind, opening := bracketKind(rune(start))
	if kind == -1 {
		return -1
	}
	mate := "{}[]()"[kind*2]
	if opening {
		mate = "{}[]()"[kind*2+1]
	}
	pair := string([]byte{start, mate})
	depth, match := 1, -1
	first, end := 0, offset
	if opening {
		first, end = offset+1, limit
	}
	root.visit(first, end, 0, !opening, visitBrackets, func(base int, chunk string) bool {
		for len(chunk) > 0 {
			var at int
			if opening {
				at = strings.IndexAny(chunk, pair)
			} else {
				at = strings.LastIndexAny(chunk, pair)
			}
			if at < 0 {
				break
			}
			if chunk[at] == start {
				depth++
			} else {
				depth--
				if depth == 0 {
					match = base + at
					return false
				}
			}
			if opening {
				base += at + 1
				chunk = chunk[at+1:]
			} else {
				chunk = chunk[:at]
			}
		}
		return true
	})
	return match
}

type guideBlock struct {
	StartLine     int `json:"startLine"`
	EndLine       int `json:"endLine"`
	IndentLevel   int `json:"indentLevel"`
	LeadingSpaces int `json:"leadingSpaces"`
}

type guideLine struct {
	last       rune
	lastByte   int
	columns    int
	hasContent bool
}

func readGuideLine(root *node, start, end, tabSize int) guideLine {
	var line guideLine
	root.visit(start, end, 0, true, visitNonBlank, func(offset int, chunk string) bool {
		for len(chunk) > 0 {
			ch, count := utf8.DecodeLastRuneInString(chunk)
			chunk = chunk[:len(chunk)-count]
			if !unicode.IsSpace(ch) {
				line.last = ch
				line.lastByte = offset + len(chunk)
				line.hasContent = true
				return false
			}
		}
		return true
	})
	if !line.hasContent {
		return line
	}
	line.columns, _ = root.leadingIndent(start, end, 0, tabSize)
	return line
}

func (n *node) leadingIndent(start, end, columns, tabSize int) (int, bool) {
	if start >= end {
		return columns, true
	}
	if n.spacing == spaces {
		return columns + end - start, true
	}
	if n.height == 1 {
		for _, ch := range n.text[start:end] {
			var indented bool
			columns, indented = nextIndent(columns, ch, tabSize)
			if !indented {
				return columns, false
			}
		}
		return columns, true
	}
	split := n.left.bytes
	columns, indented := n.left.leadingIndent(start, min(end, split), columns, tabSize)
	if !indented {
		return columns, false
	}
	return n.right.leadingIndent(max(0, start-split), end-split, columns, tabSize)
}

func computeGuides(root *node, firstVisible, lastVisible, tabSize int) []guideBlock {
	first := min(max(firstVisible, 0), root.lineBreaks())
	last := min(max(lastVisible, 0), root.lineBreaks())
	scanStart := max(first-scanBackLimit, 0)
	blocks := make([]guideBlock, 0)
	if scanStart > last {
		return blocks
	}
	total := root.lineBreaks() + 1
	horizon := min(last+2, total)
	lines := make([]guideLine, horizon-scanStart)
	lineStart := root.lineByte(scanStart)
	for i := range lines {
		lineEnd := root.lineByte(scanStart + i + 1)
		lines[i] = readGuideLine(root, lineStart, lineEnd, tabSize)
		lineStart = lineEnd
	}

	for index, line := range lines[:last-scanStart+1] {
		if line.last != '{' && line.last != '(' && line.last != '[' && line.last != ':' {
			continue
		}
		end := index + 1
		if line.last != ':' {
			if matched := matchingBracket(root, line.lastByte, lineStart); matched >= 0 {
				end = root.byteLine(matched) - scanStart + 1
			}
		}
		if end <= index+1 {
			scan := index + 1
			for ; scan < len(lines); scan++ {
				next := lines[scan]
				if !next.hasContent {
					continue
				}
				if next.columns <= line.columns {
					break
				}
				end = scan + 1
			}
			if scan == len(lines) && horizon < total {
				end = scan
			}
		}
		if end <= index+1 {
			continue
		}
		if slices.ContainsFunc(lines[index+1:end-1], func(next guideLine) bool {
			return next.hasContent && next.columns <= line.columns
		}) {
			continue
		}

		indentLevel := 0
		if tabSize > 0 {
			indentLevel = line.columns / tabSize
		}
		blocks = append(blocks, guideBlock{scanStart + index, scanStart + end, indentLevel, line.columns})
	}
	return blocks
}
