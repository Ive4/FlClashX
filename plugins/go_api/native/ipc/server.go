//go:build (linux && !android && !flclash_ohos) || (darwin && !ios) || windows

package ipc

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
)

const (
	connectedEvent = iota + 1
	messageEvent
	disconnectedEvent
	failedEvent

	headerSize      = 4
	maxFrameSize    = 64 * 1024 * 1024
	maxPendingBytes = 16 * 1024 * 1024
)

var (
	nextID          atomic.Int64
	servers         sync.Map
	errNotConnected = errors.New("IPC peer is not connected")
	errQueueFull    = errors.New("IPC send queue is full")
)

func Invoke(operation string, request json.RawMessage, data []byte, emit func(int64, int, []byte)) (any, error) {
	var args struct {
		ID      int64  `json:"id"`
		Address string `json:"address"`
		Events  int64  `json:"events"`
	}
	if err := json.Unmarshal(request, &args); err != nil {
		return nil, err
	}
	switch operation {
	case "bind":
		if args.Address == "" || args.Events <= 0 {
			return nil, errors.New("IPC bind requires an address and event stream")
		}
		listener, err := listen(args.Address)
		if err != nil {
			return nil, err
		}
		id := nextID.Add(1)
		servers.Store(id, serve(listener, func(kind int, payload []byte) {
			emit(args.Events, kind, payload)
		}))
		return id, nil
	case "send":
		entry, ok := servers.Load(args.ID)
		if !ok {
			return nil, errNotConnected
		}
		return nil, entry.(*server).send(data)
	case "close":
		if entry, ok := servers.LoadAndDelete(args.ID); ok {
			entry.(*server).close()
		}
		return nil, nil
	default:
		return nil, fmt.Errorf("unknown IPC operation %q", operation)
	}
}

type server struct {
	listener net.Listener
	done     chan struct{}
	wake     chan struct{}
	once     sync.Once
	mu       sync.Mutex
	closed   bool
	peer     net.Conn
	queue    [][]byte
	pending  int
}

func serve(listener net.Listener, emit func(int, []byte)) *server {
	s := &server{listener: listener, done: make(chan struct{}), wake: make(chan struct{}, 1)}
	go s.accept(emit)
	return s
}

func (s *server) send(payload []byte) error {
	if len(payload) > maxFrameSize {
		return oversizedFrame()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.peer == nil {
		return errNotConnected
	}
	size := headerSize + len(payload)
	if s.pending > 0 && s.pending+size > maxPendingBytes {
		return errQueueFull
	}
	s.queue = append(s.queue, payload)
	s.pending += size
	select {
	case s.wake <- struct{}{}:
	default:
	}
	return nil
}

func (s *server) clearQueue() {
	s.queue = nil
	s.pending = 0
}

func (s *server) close() {
	s.once.Do(func() {
		s.mu.Lock()
		s.closed = true
		peer := s.peer
		s.mu.Unlock()
		s.listener.Close()
		if peer != nil {
			peer.Close()
		}
	})
	<-s.done
}

func (s *server) accept(emit func(int, []byte)) {
	defer close(s.done)
	defer s.listener.Close()
	for {
		peer, err := s.listener.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if !closed {
				emit(failedEvent, []byte("accept error: "+err.Error()))
			}
			return
		}
		pid, err := admit(peer)
		if err != nil {
			peer.Close()
			continue
		}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			peer.Close()
			return
		}
		s.peer = peer
		s.mu.Unlock()

		var identity [4]byte
		binary.LittleEndian.PutUint32(identity[:], pid)
		emit(connectedEvent, identity[:])
		err = s.exchange(peer, emit)

		s.mu.Lock()
		s.peer = nil
		s.clearQueue()
		closed := s.closed
		s.mu.Unlock()
		if closed {
			return
		}
		var failure []byte
		if !peerGone(err) {
			failure = []byte(err.Error())
		}
		emit(disconnectedEvent, failure)
	}
}

func (s *server) exchange(peer net.Conn, emit func(int, []byte)) error {
	stop := make(chan struct{})
	written := make(chan error, 1)
	go func() {
		err := s.transmit(peer, stop)
		peer.Close()
		written <- err
	}()
	reader := bufio.NewReader(peer)
	for {
		payload, err := readFrame(reader)
		if err == nil {
			emit(messageEvent, payload)
			continue
		}
		close(stop)
		peer.Close()
		writeErr := <-written
		if peerGone(err) && !peerGone(writeErr) {
			return writeErr
		}
		return err
	}
}

func (s *server) transmit(peer net.Conn, stop <-chan struct{}) error {
	for {
		select {
		case <-stop:
			return nil
		default:
		}
		s.mu.Lock()
		if len(s.queue) != 0 {
			payload := s.queue[0]
			s.queue[0] = nil
			s.queue = s.queue[1:]
			s.pending -= headerSize + len(payload)
			s.mu.Unlock()
			if err := writeFrame(peer, payload); err != nil {
				return err
			}
			continue
		}
		s.mu.Unlock()
		select {
		case <-stop:
			return nil
		case <-s.wake:
		}
	}
}

func peerGone(err error) bool {
	return err == nil || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, net.ErrClosed) || errors.Is(err, syscall.ECONNRESET) ||
		errors.Is(err, syscall.EPIPE) || isPlatformPeerGone(err)
}

func oversizedFrame() error {
	return fmt.Errorf("IPC frame exceeds %d bytes", maxFrameSize)
}

func readFrame(reader io.Reader) ([]byte, error) {
	var header [headerSize]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size > maxFrameSize {
		return nil, oversizedFrame()
	}
	payload := make([]byte, size)
	_, err := io.ReadFull(reader, payload)
	return payload, err
}

func writeFrame(writer io.Writer, payload []byte) error {
	var header [headerSize]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(payload)))
	for _, part := range [][]byte{header[:], payload} {
		for len(part) > 0 {
			written, err := writer.Write(part)
			if err != nil {
				return err
			}
			if written == 0 {
				return io.ErrShortWrite
			}
			part = part[written:]
		}
	}
	return nil
}
