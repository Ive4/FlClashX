# FlClash TCP socket policy patch

Source: the exact crates.io `meow-common` 0.28.0 package, upstream revision
`80816302e7ad8f868fdf1619a11bf3c8121696dd` (`crates/meow-common`). The included
MIT notice is the upstream workspace notice. Registry sources otherwise remain
unchanged outside the files listed below.

- `Cargo.toml` makes the existing socket2 0.5 dependency available on every
  target so the TCP policy callback has one portable socket type.
- `src/tcp_socket_policy.rs` adds a fallible pre-connect callback with owned
  installation guards. The newest live guard wins; dropping a rejected
  candidate restores its predecessor, and dropping an older owner cannot
  clear a newer owner's policy. Callbacks run outside the registry lock.
- `src/socket_protect.rs` applies the callback before connecting plain and
  Android-protected sockets. Hostname/address fallback still uses the same
  entry point. Protector errors and TCP policy errors abort the dial.
- `src/outbound_iface.rs` also invokes it for stream sockets before the
  interface lookup. This covers interface-bound TCP and meow-proxy's Linux
  `SO_MARK` DIRECT branch, which invokes this helper even with no interface
  installed. Datagram sockets never receive the TCP policy.
- `src/lib.rs` exports the callback module.

FlClash's policy sets and reads back `SO_KEEPALIVE`, idle and probe interval in
whole seconds. The OS must accept the exact requested values; there is no
fixed-value substitution. Existing connected sockets keep their creation-time
options; a successful reload affects new sockets. A failed staged installation
restores policy for subsequent dials. These settings control TCP's OS probes;
they do not change QUIC/UDP keepalives, HTTP reuse, protocol heartbeats, AnyTLS
session reaping, or other transport/session timers.

The matching `meow-anytls` patch avoids replacing the pre-connect policy with
that library's native 120/30 second defaults after the connection opens.
