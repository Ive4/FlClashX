# FlClash listener patches

Based on the crates.io meow-listener 0.28.0 package, corresponding to upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

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
