# FlClash listener lifetime patch

Based on the crates.io meow-listener 0.28.0 package, corresponding to upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

FlClash owns each listener generation separately from the process. Upstream's process-lifetime detached TCP and
UDP tasks can survive a listener stop, keep a UDP port bound and admit a new handshake using obsolete credentials.
The local patch adds an optional tracked task scope: FlClash cancels it and awaits its tasks after stopping accept
loops. Mixed, Shadowsocks and TProxy child tasks inherit that scope; standalone upstream users keep the existing
unscoped behavior. TProxy's UDP reply task gains an abort-on-drop guard for cancelled flows. No protocol or routing
semantics are changed by the patch.

Keep this patch limited to task ownership when updating the pinned backend. The wrapper's lifecycle regressions
are in core/rust/tests/engine_flow.rs.
