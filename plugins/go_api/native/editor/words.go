package editor

import (
	"slices"
	"unicode/utf8"
)

const maxWords = 5000

// These ranges match the prefix matcher in CodeForge's word_chars.dart.
func isWordChar(ch rune) bool {
	switch {
	case ch >= '0' && ch <= '9', ch >= 'A' && ch <= 'Z', ch == '_', ch >= 'a' && ch <= 'z':
		return true
	case ch >= 0x0590 && ch <= 0x05ff, ch >= 0x0600 && ch <= 0x06ff, ch >= 0x08a0 && ch <= 0x08ff:
		return true
	case ch >= 0x3040 && ch <= 0x309f, ch >= 0x30a0 && ch <= 0x30ff:
		return true
	case ch >= 0x3400 && ch <= 0x4dbf, ch >= 0x4e00 && ch <= 0x9fff, ch >= 0xac00 && ch <= 0xd7af, ch >= 0xf900 && ch <= 0xfaff:
		return true
	default:
		return false
	}
}

func extractWords(root *node) []string {
	words := make([]string, 0)
	seen := make(map[string]struct{})
	var word []byte
	flush := func() {
		if len(word) == 0 {
			return
		}
		if first := word[0]; first < '0' || first > '9' {
			if _, exists := seen[string(word)]; !exists {
				text := string(word)
				seen[text] = struct{}{}
				words = append(words, text)
			}
		}
		word = word[:0]
	}
	root.visit(0, root.size(), 0, false, visitAll, func(_ int, chunk string) bool {
		for _, ch := range chunk {
			if isWordChar(ch) {
				word = utf8.AppendRune(word, ch)
			} else {
				flush()
				if len(words) >= maxWords {
					return false
				}
			}
		}
		return true
	})
	flush()
	slices.Sort(words)
	return words
}
