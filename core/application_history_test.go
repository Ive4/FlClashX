package core

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type applicationHistoryTracker struct {
	statistic.Tracker
	info *statistic.TrackerInfo
}

func (t applicationHistoryTracker) Info() *statistic.TrackerInfo { return t.info }

func TestRequestUpdatesApplicationHistoryWithoutAnEventConsumer(t *testing.T) {
	path := filepath.Join(t.TempDir(), "application-history.json")
	history := &applicationHistoryStore{path: path}
	original := desktopApplicationHistory.Swap(history)
	defer desktopApplicationHistory.Store(original)
	recordDesktopApplication(applicationHistoryTracker{
		info: &statistic.TrackerInfo{
			Metadata: &constant.Metadata{Type: constant.TUN, Process: "background.exe"},
			Start:    time.Now(),
		},
	})
	if err := history.flush(); err != nil {
		t.Fatal(err)
	}
	reopened := applicationHistoryStore{path: path}
	reopened.load()
	if _, ok := reopened.entries["background.exe"]; !ok {
		t.Fatal("request with no attached UI was not recorded")
	}
}

func TestApplicationHistorySurvivesWithoutEventListener(t *testing.T) {
	path := filepath.Join(t.TempDir(), "application-history.json")
	first := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	last := first.Add(time.Minute)
	history := applicationHistoryStore{path: path}
	history.record("Browser.exe", `C:\Apps\Browser.exe`, true, first)
	history.record("BROWSER.EXE", `c:\apps\BROWSER.EXE`, true, last)
	history.record("Browser.exe", `D:\Portable\Browser.exe`, true, last)
	history.record("", "", true, last)
	if err := history.flush(); err != nil {
		t.Fatal(err)
	}
	reopened := applicationHistoryStore{path: path}
	reopened.load()
	if len(reopened.entries) != 2 {
		t.Fatalf("got %d saved identities, want two distinct paths", len(reopened.entries))
	}
	entry := reopened.entries[`c:\apps\browser.exe`]
	if !entry.First.Equal(first) || !entry.Last.Equal(last) || !entry.Path {
		t.Fatalf("stored request times = %+v", entry)
	}
}
