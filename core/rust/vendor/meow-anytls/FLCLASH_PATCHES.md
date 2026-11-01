# FlClash TCP socket policy patch

Source: the exact crates.io `meow-anytls` 0.28.0 package. Its original MIT
notice, README and source files are included.

Only `src/util/net.rs` changes. When a meow-common outbound TCP policy is
installed, `configure_tcp_stream` keeps `TCP_NODELAY` tuning and skips its
native 120-second idle / 30-second interval rewrite. The host's DialBridge
already connects through meow-common's fallible pre-connect policy callback.
With no host policy installed, the upstream keepalive behavior is retained.
This also preserves `disable-keep-alive` instead of enabling probes again.

This changes only OS TCP keepalive. AnyTLS's protocol keepalive, idle-session
checks and TLS behavior retain their upstream semantics.
