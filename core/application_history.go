package core

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const applicationHistoryLimit = 1024

var desktopApplicationHistory atomic.Pointer[applicationHistoryStore]

type applicationHistoryEntry struct {
	Content string    `json:"content"`
	Path    bool      `json:"path"`
	Windows bool      `json:"windows"`
	First   time.Time `json:"first"`
	Last    time.Time `json:"last"`
}

func (e applicationHistoryEntry) key() string {
	if e.Windows {
		return strings.ToLower(e.Content)
	}
	return e.Content
}

type applicationHistoryStore struct {
	path    string
	mu      sync.Mutex
	entries map[string]applicationHistoryEntry
	timer   *time.Timer
	dirty   bool
	writeMu sync.Mutex
}

func initApplicationHistory(home string) {
	if home == "" || (runtime.GOOS != "windows" && runtime.GOOS != "darwin") {
		return
	}
	path := filepath.Join(home, "application-history.json")
	if old := desktopApplicationHistory.Load(); old != nil && old.path == path {
		return
	}
	flushDesktopApplicationHistory()
	history := &applicationHistoryStore{path: path}
	history.load()
	desktopApplicationHistory.Store(history)
}

func recordDesktopApplication(c statistic.Tracker) {
	history := desktopApplicationHistory.Load()
	if history == nil {
		return
	}
	info := c.Info()
	if meta := info.Metadata; meta != nil && meta.Type != constant.INNER {
		history.record(meta.Process, meta.ProcessPath, runtime.GOOS == "windows", info.Start)
	}
}

func flushDesktopApplicationHistory() {
	if history := desktopApplicationHistory.Load(); history != nil {
		history.flushWithLog()
	}
}

func (s *applicationHistoryStore) load() {
	file, err := os.Open(s.path)
	if err != nil {
		return
	}
	defer file.Close()
	var snapshot struct {
		Entries []applicationHistoryEntry `json:"entries"`
	}
	if err := json.NewDecoder(io.LimitReader(file, 8<<20)).Decode(&snapshot); err != nil {
		return
	}
	s.entries = make(map[string]applicationHistoryEntry)
	for _, entry := range snapshot.Entries {
		if entry.Content != "" && !entry.Last.IsZero() {
			s.entries[entry.key()] = entry
		}
		if len(s.entries) == applicationHistoryLimit {
			break
		}
	}
}

func (s *applicationHistoryStore) record(process, path string, windows bool, at time.Time) {
	path = strings.TrimSpace(path)
	content := path
	if path == "" {
		content = strings.TrimSpace(process)
	} else if i := strings.Index(path, ".app/Contents/"); !windows && i >= 0 {
		content = path[:i+4]
	}
	if content == "" || strings.HasPrefix(content, ":") || strings.ContainsAny(content, "\x00\r\n") {
		return
	}
	entry := applicationHistoryEntry{Content: content, Path: path != "", Windows: windows, First: at, Last: at}
	key := entry.key()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.entries == nil {
		s.entries = make(map[string]applicationHistoryEntry)
	}
	if old, ok := s.entries[key]; ok {
		if at.Sub(old.Last) < 15*time.Second {
			return
		}
		entry.First = old.First
	} else if len(s.entries) >= applicationHistoryLimit {
		var oldest string
		for key, item := range s.entries {
			if oldest == "" || item.Last.Before(s.entries[oldest].Last) {
				oldest = key
			}
		}
		delete(s.entries, oldest)
	}
	s.entries[key] = entry
	s.dirty = true
	if s.timer == nil {
		s.timer = time.AfterFunc(time.Second, s.flushWithLog)
	}
}

func (s *applicationHistoryStore) flushWithLog() {
	if err := s.flush(); err != nil {
		log.Debugln("[APP] application history: %v", err)
	}
}

func (s *applicationHistoryStore) flush() error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if !s.dirty {
		s.mu.Unlock()
		return nil
	}
	s.dirty = false
	entries := make([]applicationHistoryEntry, 0, len(s.entries))
	for _, entry := range s.entries {
		entries = append(entries, entry)
	}
	s.mu.Unlock()

	if err := s.write(entries); err != nil {
		s.mu.Lock()
		s.dirty = true
		s.mu.Unlock()
		return err
	}
	return nil
}

func (s *applicationHistoryStore) write(entries []applicationHistoryEntry) error {
	file, err := os.CreateTemp(filepath.Dir(s.path), ".application-history-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	snapshot := struct {
		Entries []applicationHistoryEntry `json:"entries"`
	}{entries}
	err = json.NewEncoder(file).Encode(snapshot)
	if err == nil && runtime.GOOS == "darwin" && os.Geteuid() == 0 && os.Getuid() > 0 {
		err = file.Chown(os.Getuid(), os.Getgid())
	}
	if err = errors.Join(err, file.Close()); err != nil {
		return err
	}
	return os.Rename(file.Name(), s.path)
}
