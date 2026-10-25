package ownerlookup

import (
	"encoding/json"
	"errors"
	"net/netip"
	"testing"
	"time"
)

func TestLookupCorrelatesOwnerAndRejectsLateReply(t *testing.T) {
	var broker Broker
	local := netip.MustParseAddrPort("172.19.0.1:12345")
	remote := netip.MustParseAddrPort("1.1.1.1:443")
	finished := make(chan Result, 1)
	go func() {
		result, _ := broker.Lookup("tcp", local, remote, time.Second)
		finished <- result
	}()
	var requests []Request
	deadline := time.After(time.Second)
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for len(requests) == 0 {
		select {
		case <-deadline:
			t.Fatal("lookup was not queued")
		case <-ticker.C:
			if err := json.Unmarshal([]byte(broker.Take()), &requests); err != nil {
				t.Fatal(err)
			}
		}
	}
	request := requests[0]
	if request.Local != local.String() || request.Remote != remote.String() || request.Protocol != "tcp" {
		t.Fatalf("wrong connection tuple: %+v", request)
	}
	broker.Resolve(request.ID, Result{42, "com.example.browser"})
	if result := <-finished; result.UID != 42 || result.Bundle != "com.example.browser" {
		t.Fatalf("wrong owner: %+v", result)
	}
	broker.Resolve(request.ID, Result{99, "late.reply"})
	if _, err := broker.Lookup("udp", local, remote, time.Millisecond); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("expected bounded timeout: %v", err)
	}
	if pending := broker.Take(); pending != "[]" {
		t.Fatalf("expired lookup survived: %s", pending)
	}
}

func TestLookupRejectsIncompleteTuple(t *testing.T) {
	var broker Broker
	if _, err := broker.Lookup("tcp", netip.MustParseAddrPort("172.19.0.1:0"), netip.MustParseAddrPort("1.1.1.1:443"), time.Second); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("zero port must not match an arbitrary application: %v", err)
	}
}
