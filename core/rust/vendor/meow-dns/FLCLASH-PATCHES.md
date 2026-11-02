# FlClash preferred DoH transport

Based on the crates.io meow-dns 0.28.0 package, corresponding to upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

An optional scoped transport is captured when a DoH client is constructed. FlClash uses it for actual HTTP/3
preference. Each attempt receives the same address, SNI, request path, wire query and selected proxy as the normal
DoH transport. Failed or timed-out attempts retain the existing authenticated TLS fallback within the query budget.
Responses undergo the original transaction, opcode and question checks. Other upstream transports are unchanged.
Scoped ownership restores the previous preference after failed configuration and cannot clear a successor's policy.

The resolver may own a dedicated direct resolver built in the same candidate generation. Immutable nameserver
policy can be shared explicitly while caches, fallback tiers and fake-IP pools remain independent. Cache and
connection resets also reach this direct resolver. Ordinary `resolve_ips` and proxy-server host resolution keep
their existing resolver selection.

Hostname DNS upstreams routed through a proxy also retain a bootstrap resolver made from the same candidate's
`default-nameserver` roots. TCP/TLS and preferred DoH proxy exchanges scope this resolver to the actual dial
hostname, independently of SNI. Direct adapters use it only when that DNS transport resolves locally; a remote
proxy still receives the original hostname and causes no local bootstrap query. Bootstrap failure propagates
without a system-resolver retry. DNS result snapshots merge direct records with main records before filtering,
sorting and limiting, so the existing observation path can see actual direct answers.

Ordinary and scoped bootstrap clients share the same transport constructor. IP-literal UDP, TCP, TLS and HTTPS
roots preserve their declared address, port, SNI, path, certificate checks and three-second query budget; rcode
roots remain local answers. Hostname roots are rejected to avoid recursive bootstrap. No encrypted root is
silently replaced by UDP.
