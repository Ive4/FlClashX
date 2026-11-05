# FlClash listener patches

Based on the crates.io meow-listener 0.28.0 package, corresponding to upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

UDP flows and the TProxy TCP path route through the tunnel's mutable metadata
entry so resolved application identity reaches connection statistics. Eager
UDP destination resolution still precedes routing and NAT key construction.

FlClash owns each listener generation separately from the process. Upstream's process-lifetime detached TCP and
UDP tasks can survive a listener stop, keep a UDP port bound and admit a new handshake using obsolete credentials.
The local patch adds an optional tracked task scope: FlClash cancels it and awaits its tasks after stopping accept
loops. Mixed, Shadowsocks and TProxy child tasks inherit that scope; standalone upstream users keep the existing
unscoped behavior. TProxy's UDP reply task gains an abort-on-drop guard for cancelled flows.

The optional TUN route plan carries FlClash's validated include-minus-exclude CIDRs into the listener. Explicit
plans replace scope defaults, bind outbound sockets to the physical interface before installing routes, and use
transactional main-table route installation: any failed add rolls back prior successful adds and fails startup.
The adapter, routes and outbound binding share an owner even if the blocking installer outlives cancelled startup.
Unspecified plans retain upstream global/fake-IP scopes, Linux policy routing and macOS split-default selection.
Explicit plans reject unsplit defaults, IPv6 without a device address, and macOS zero-key routes that would shadow
the physical default. The original physical defaults are never replaced.

Keep both changes isolated when updating the pinned backend. Lifecycle regressions are in
core/rust/tests/engine_flow.rs; route subtraction and listener handoff are in core/rust/tests/tun_routes.rs, and
transactional install/rollback tests use a recording route backend in src/tun/route.rs without changing host routes.

Windows TUN DNS is scoped to the owned virtual adapter through IP Helper. Physical adapters retain automatic or
manual DNS unchanged. The virtual adapter gets its peer as DNS server and a low IPv4 interface metric; its previous
values restore on normal teardown. There is no machine-wide backup/reset, loopback DNS listener or PowerShell DNS
worker. The peer's host route is mandatory when the route plan does not already include it. UDP and bounded TCP DNS
use the current resolver; TCP framing and reloads are covered in `core/rust/tests/windows_dns.rs`. That suite also
checks scoped rollback and offers an explicit isolated-adapter test without changing physical DNS or default routes.
