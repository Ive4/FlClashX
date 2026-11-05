package main

import "testing"

func TestTrayProxyTitlesExposePendingSuccessTimeoutAndFailure(t *testing.T) {
	labels := map[string]string{"timeout": "Timed out", "error": "Failed"}
	success, timeout, failure := 42, -1, -2
	for _, test := range []struct {
		delay   *int
		pending bool
		title   string
	}{
		{nil, false, "Node: 🇯🇵"},
		{nil, true, "Node: 🇯🇵 · …"},
		{&success, false, "Node: 🇯🇵 · 42 ms"},
		{&timeout, false, "Node: 🇯🇵 · Timed out"},
		{&failure, false, "Node: 🇯🇵 · Failed"},
	} {
		if actual := trayProxyTitle(trayProxy{Name: "Node: 🇯🇵", Delay: test.delay, Testing: test.pending}, labels); actual != test.title {
			t.Fatalf("title = %q; want %q", actual, test.title)
		}
	}
}
