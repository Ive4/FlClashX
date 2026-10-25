package ownerlookup

import (
	"encoding/json"
	"errors"
	"net/netip"
	"sync"
	"time"
)

var ErrUnavailable = errors.New("connection owner unavailable")

type Request struct {
	ID       uint32 `json:"id"`
	Protocol string `json:"protocol"`
	Local    string `json:"local"`
	Remote   string `json:"remote"`
}

type Result struct {
	UID    int
	Bundle string
}

type Broker struct {
	mu      sync.Mutex
	next    uint32
	pending map[uint32]chan Result
	queue   []Request
}

func (b *Broker) Lookup(protocol string, local, remote netip.AddrPort, timeout time.Duration) (Result, error) {
	if (protocol != "tcp" && protocol != "udp") || !local.IsValid() || !remote.IsValid() || local.Port() == 0 || remote.Port() == 0 {
		return Result{}, ErrUnavailable
	}
	b.mu.Lock()
	if len(b.pending) >= 64 || len(b.queue) >= 64 {
		b.mu.Unlock()
		return Result{}, ErrUnavailable
	}
	if b.pending == nil {
		b.pending = make(map[uint32]chan Result)
	}
	b.next++
	id := b.next
	answer := make(chan Result, 1)
	b.pending[id] = answer
	b.queue = append(b.queue, Request{id, protocol, local.String(), remote.String()})
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.pending, id)
		b.mu.Unlock()
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case result := <-answer:
		if result.UID < 0 || result.Bundle == "" {
			return Result{}, ErrUnavailable
		}
		return result, nil
	case <-timer.C:
		return Result{}, ErrUnavailable
	}
}

func (b *Broker) Take() string {
	b.mu.Lock()
	requests := make([]Request, 0, len(b.queue))
	for _, request := range b.queue {
		if _, exists := b.pending[request.ID]; exists {
			requests = append(requests, request)
		}
	}
	b.queue = nil
	b.mu.Unlock()
	data, _ := json.Marshal(requests)
	return string(data)
}

func (b *Broker) Resolve(id uint32, result Result) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if answer := b.pending[id]; answer != nil {
		select {
		case answer <- result:
		default:
		}
	}
}
