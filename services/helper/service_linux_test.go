package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLinuxOwnerChecksUnixPeerCredentials(t *testing.T) {
	path := filepath.Join(t.TempDir(), "owner.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.DialUnix("unix", nil, listener.Addr().(*net.UnixAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	conn, err := listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	uid := uint32(os.Geteuid())
	if !isOwnerConnection(conn, uid) || isOwnerConnection(conn, uid+1) {
		t.Fatal("Unix peer must match the registered owner")
	}
}

func TestLinuxUnitEscapesThePathAndPreservesTheRegisteredOwner(t *testing.T) {
	unit := unitContents("/opt/Fl Clash%/a\"b\nc", ownerIDs{uid: 1001, gid: 1002})
	for _, line := range []string{
		`ExecStart=:"/opt/Fl Clash%%/a\"b\nc"`,
		"Group=1002",
		"Environment=FLCLASH_HELPER_OWNER_UID=1001",
		"Environment=FLCLASH_HELPER_OWNER_GID=1002",
		"RuntimeDirectory=flclash",
	} {
		if !strings.Contains(unit, "\n"+line+"\n") {
			t.Errorf("unit did not contain %q", line)
		}
	}
	legacyUnit := "[Service]\nExecStart=\"/opt/Fl Clash/FlClashHelperService\"\nEnvironment=FLCLASH_HELPER_OWNER_UID=1003\n"
	if uid, ok := installedOwnerUID(legacyUnit); !ok || uid != 1003 {
		t.Fatalf("legacy unit owner = %d, found %t", uid, ok)
	}
}
