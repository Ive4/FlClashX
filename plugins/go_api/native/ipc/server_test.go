//go:build (linux && !android && !flclash_ohos) || (darwin && !ios) || windows

package ipc

import (
	"bytes"
	"encoding/binary"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

type testEvent struct {
	kind int
	data []byte
}

func TestServerExchangesFramesAndCanRebind(t *testing.T) {
	address := testAddress(t)
	listener, err := listen(address)
	if err != nil {
		t.Fatal(err)
	}
	events := make(chan testEvent, 20)
	server := serve(listener, func(kind int, data []byte) { events <- testEvent{kind, data} })
	defer server.close()
	if err := server.send([]byte("early")); err != errNotConnected {
		t.Fatalf("send without peer: %v", err)
	}

	peer := connectTestPeer(t, address)
	defer peer.Close()
	connected := expectEvent(t, events, connectedEvent)
	if pid := binary.LittleEndian.Uint32(connected); pid != uint32(os.Getpid()) {
		t.Fatalf("peer pid = %d, want %d", pid, os.Getpid())
	}

	if err := writeFrame(peer, []byte("ping")); err != nil {
		t.Fatal(err)
	}
	if payload := expectEvent(t, events, messageEvent); string(payload) != "ping" {
		t.Fatalf("incoming payload = %q", payload)
	}
	for _, payload := range [][]byte{nil, []byte("first"), []byte("second")} {
		if err := server.send(payload); err != nil {
			t.Fatal(err)
		}
	}
	for _, payload := range [][]byte{nil, []byte("first"), []byte("second")} {
		if got, err := readFrame(peer); err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("read frame = %q, %v, want %q", got, err, payload)
		}
	}
	if err := peer.Close(); err != nil {
		t.Fatal(err)
	}
	if data := expectEvent(t, events, disconnectedEvent); len(data) != 0 {
		t.Fatalf("disconnect error = %q", data)
	}
	peer = connectTestPeer(t, address)
	defer peer.Close()
	expectEvent(t, events, connectedEvent)
	server.close()
	if _, err := peer.Read(make([]byte, 1)); err == nil {
		t.Fatal("peer remained connected after close")
	}
	listener, err = listen(address)
	if err != nil {
		t.Fatal(err)
	}
	listener.Close()
}

func TestOutboxByteBudget(t *testing.T) {
	server := &server{peer: &net.UnixConn{}, wake: make(chan struct{}, 1)}
	if err := server.send(make([]byte, maxPendingBytes)); err != nil {
		t.Fatal(err)
	}
	if err := server.send(nil); err != errQueueFull {
		t.Fatalf("send over budget: %v", err)
	}
	if err := server.send(make([]byte, maxFrameSize+1)); err == nil {
		t.Fatal("accepted oversized frame")
	}
	server.clearQueue()
	if err := server.send(nil); err != nil {
		t.Fatal(err)
	}
}

func TestOversizedFrameHeaderIsRejected(t *testing.T) {
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(maxFrameSize+1))
	if _, err := readFrame(bytes.NewReader(header[:])); err == nil {
		t.Fatal("accepted oversized frame")
	}
}

var testAddressID atomic.Uint64

func expectEvent(t *testing.T, events <-chan testEvent, kind int) []byte {
	t.Helper()
	select {
	case event := <-events:
		if event.kind != kind {
			t.Fatalf("event = %d (%q), want %d", event.kind, event.data, kind)
		}
		return event.data
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for event %d", kind)
		return nil
	}
}
