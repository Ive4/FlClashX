# FlClash TUN inbound rule compatibility

Source: the exact crates.io meow-rules 0.28.0 package, upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

`src/in_type.rs` accepts `IN-TYPE,TUN` and matches only `Metadata.conn_type == ConnType::Tun`.
Desktop TUN and the mobile packet bridge already produce this connection type. FlClash uses it in per-application
HTTP/SOCKS mode, the default TUN bypass, and follow-rule exceptions. Internal `Tunnel`, HTTP, SOCKS and TProxy
connections must remain distinct. Unknown inbound types still fail validation.

Regressions live in `core/rust/tests/application_proxy_rules.rs`, including nested AND/NOT, PASS continuation,
actual Core reload/persistence/rollback and route decisions for TUN, HTTP and SOCKS metadata. Check the same behavior
in the next upstream version before removing this override.
