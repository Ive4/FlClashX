# FlClash direct outbound DNS

Based on crates.io meow-config 0.28.0, upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

`RawDns` retains `direct-nameserver` and `direct-nameserver-follow-policy` as typed fields, including reload
comparison. The candidate DNS builder constructs a dedicated direct resolver using the same bootstrap roots,
hosts, IPv6 setting and candidate proxy registry. Its cache is independent and it has no fallback tier or fake-IP
pool. Only an explicit follow-policy flag shares the main resolver's immutable nameserver policy. The direct
resolver is attached to the same main resolver generation before configuration can commit.

The direct-only URL parser maps encrypted Mihomo `#DIRECT` and declared proxy/group fragments to the selected
proxy while retaining the upstream hostname as default SNI. Explicit `?proxy=` and dotted SNI overrides keep
their existing interpretation. Unsupported fragment parameters fail instead of changing routing intent. Raw DNS
strings remain unchanged. `prefer-h3` is also retained as a typed comparison input so toggling it alone rebuilds
clients; FlClash's existing scoped preferred-DoH installation remains the transport policy owner.
