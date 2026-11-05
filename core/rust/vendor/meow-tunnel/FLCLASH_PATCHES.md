# FlClash application process metadata

Source: crates.io `meow-tunnel` 0.28.0, upstream revision
`80816302e7ad8f868fdf1619a11bf3c8121696dd`, under the included MIT license.

`src/tunnel.rs` adds a per-tunnel process lookup policy. `off` skips native
lookup while preserving inbound-supplied identity; `strict` keeps lazy rule
demand; `always` also identifies connections matched without a process rule
and in direct/global mode. Socket scans continue to use the existing async
blocking-pool lookup. Resolved identity remains in the mutable connection
metadata used by routing, connection statistics and FlClash request events.

`src/udp.rs` uses the same mutable routing entry after its existing eager DNS
resolution. FlClash's vendored listeners make the same change for their UDP
flows. Destination resolution and NAT keys retain their existing order.

`src/lib.rs` exports the policy for the FlClash engine adapter, which applies
the saved setting on creation and after successful reload. No process rules
are injected and saved profile rules retain their contents and precedence.

Regression coverage lives in `core/rust/tests/application_process.rs`: real
TCP/UDP socket ownership, all lookup policies, direct/global modes, process
rule matching, preserved inbound identity, rejected reloads, and a real local
HTTP proxy connection whose API metadata identifies its caller.
