package ipc

import (
	"context"
	"fmt"
	"net"
	"os"
	"testing"
	"time"

	"github.com/Microsoft/go-winio"
)

func testAddress(t *testing.T) string {
	return fmt.Sprintf(`\\.\pipe\FlClashTest_%d_%d`, os.Getpid(), testAddressID.Add(1))
}

func connectTestPeer(t *testing.T, address string) net.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	peer, err := winio.DialPipeContext(ctx, address)
	if err != nil {
		t.Fatal(err)
	}
	peer.SetDeadline(time.Now().Add(3 * time.Second))
	return peer
}
