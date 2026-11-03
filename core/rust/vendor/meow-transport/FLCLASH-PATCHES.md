# FlClash transport patch

Baseline: exact meow-transport 0.28.0 package from upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd.

The REALITY authentication payload now advertises client version 1.8.2, matching
Mihomo's existing FlClash client. The upstream 1.8.1 value was rejected by a real
deployed server that accepted the same request with only the version changed.
REALITY servers can enforce minimum and maximum client versions before accepting
the authenticated session. Keys, short ID, timestamp, certificate HMAC, TLS
Finished verification and failure behavior remain unchanged.

The root integration test `tests/reality_contract.rs` reads a real transport
ClientHello and independently derives/decrypts its authentication payload with
BoringSSL and AES-GCM. It checks the version, timestamp and short ID and failed
with the unpatched dependency. The upstream payload-decryption regression also
expects the updated version. Keep real-node verification when changing this
patch; a self-consistent local TLS fixture alone does not establish server
interoperability.

References: Mihomo `component/tls/reality.go` in the retained contract source and
[XTLS REALITY server version checks](https://github.com/XTLS/REALITY/blob/main/tls.go).
