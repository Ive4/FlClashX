# FlClash Rust Core

This crate replaces the active Mihomo runtime with the MIT-licensed meow-rs 0.28.0 crates. Cargo.lock pins registry
checksums; the corresponding upstream source revision is `80816302e7ad8f868fdf1619a11bf3c8121696dd`.
`vendor/meow-listener` contains that release with the narrow task-ownership patch documented in
`FLCLASH-PATCHES.md`: listener stop cancels and joins accepted clients and UDP relays before rebinding.
`vendor/meow-common` and `vendor/meow-anytls` carry the documented TCP socket-policy hooks, including preservation
of supplied keepalive idle/interval/disable values through the AnyTLS connection setup.
`vendor/meow-dns` adds a scoped preferred DoH transport hook. With `dns.prefer-h3`, the wrapper attempts verified
HTTP/3 through the selected upstream proxy, then falls back to the original verified TLS DoH transport on failure.
An attempt is bounded to 1.2 seconds and failing endpoints back off for 30 seconds. UDP sockets retain platform
protection and outbound binding; the saved DNS preference is preserved.
`vendor/meow-transport` preserves Mihomo's REALITY client authentication version 1.8.2. Servers can enforce client
version bounds; the upstream 1.8.1 payload failed against a deployed server that accepted the otherwise identical
1.8.2 request. Certificate HMAC and TLS Finished verification remain enforced.
The upstream notice is bundled at `assets/data/meow-rs-license.txt` and registered in Flutter's license registry.
The old Go Core remains an inactive protocol reference. `services/desktop` remains the separate background owner.

## Runtime boundaries

| Surface | Implementation | Ownership |
| --- | --- | --- |
| Windows, macOS, Linux | `FlClashCore` executable, `ipc.rs`, `engine.rs` | Existing desktop lifecycle, process lease and Helper |
| Android | `mobile.rs` JNI and the authored `android/core` Java interfaces | Existing `ServiceState` and VPN service |
| HarmonyOS | `ohos.rs` exports consumed by `vpn_bridge.cpp` | Existing VPN extension and authenticated lightweight reattachment |
| Mobile TUN | `mobile_tun.rs`, shared lwIP TCP/UDP/DNS stack | Owned duplicate fd, cancellation and joined stack teardown |

Desktop requests and event batches retain the four-byte little-endian framing and structured JSON envelope.
Responses over 1 MiB spill into `<home>/responses`. Initialization registers the home without overwriting
`config.yaml`; configuration writes commit after runtime application succeeds, with rollback on failure.
Android socket protection and UID/package callbacks remain active through the Rust bridge, including the pre-29
procfs fallback. HarmonyOS owner resolution uses a bounded broker and retains the original flow tuple.
HarmonyOS may attach TUN before profile setup. Its initial Engine rejects all traffic and refuses DNS until the
profile commits; setup keeps the same Engine/Tunnel, and a failed setup retains the rejecting policy and saved file.
HarmonyOS route declarations are checked against the native VPN's installed CIDRs, including its mandatory DNS
host route. A mismatch rejects configuration before commit. Desktop include/exclude lists produce an exact route
plan with transactional installation and reverse teardown; the original scope behavior applies without a custom plan.

TCP keepalive settings apply to new outbound TCP sockets. The wrapper sets and reads back the requested OS idle,
probe interval and enable state; unsupported values fail before applying the profile. Reload rollback restores the
prior policy, and existing connections retain their original options. Protocol heartbeats and UDP/QUIC timers are
independent of these TCP settings.

## Builds and checks

The normal Flutter setup hook builds the desktop Rust executable and hashes it into the Helper. Android's
`:core` Gradle module builds and merges the three Rust JNI ABIs. `tool/build_rust_ohos.ps1` cross-builds the
HarmonyOS cdylib, and `tool/build_ohos.ps1` includes it in the app build. Native compiler, SDK, libclang,
CMake and NASM requirements are recorded in `.agents/project.md` and `.agents/commands.md`.

```text
cargo test --locked --all-targets -- --test-threads=1
cargo fmt --check
flutter pub get
flutter analyze --no-fatal-infos
flutter test test/core
```

`tests/` contains real loopback proxy/probe tests, a spawned executable IPC and response-spill test, raw IPv4/IPv6
TCP/UDP/DNS packet tests, provider reload/rollback tests and authenticated lightweight reconnection tests.
These tests never create a host TUN or change the system proxy. Starting the Flutter app on a developer host
still requires `SAFE_MODE=true`.
Independent Core fixtures run serially because each process owns one kernel home, resolver and socket policy.
Concurrency within a test, including overlapping configuration and lifecycle requests, remains enabled.

## Compatibility limits

The wrapper validates before applying and returns field-specific errors for unsupported effectful options. It does
not remove failed nodes or acknowledge an unsupported operation as successful. In particular, backend-unsupported
protocols, custom aliases that meow-rs renames to built-in nodes, nondefault unsupported socket settings, legacy
GEOIP `.dat`, NTP time changes and unsupported advanced DNS/TUN options fail explicitly. Unquoted numeric REALITY
short IDs must be quoted to preserve their literal text. The saved source profile is retained on rejection.

Serialized legacy defaults remain loadable without deleting their saved values: an unrestricted IPv4/IPv6 LAN
allow-list, settings for a disabled controller/TUIC server, empty TLS/Android blocks, Darwin-only packet hints on
other platforms, and the single-processor packet-pump default. ETag and QUIC-Go hints are accepted only when no
corresponding HTTP-provider or QUIC operation is active. Enabling those unsupported operations, restrictive LAN
filters or nondefault processor counts still fails explicitly. `tests/legacy_defaults.rs` covers both paths.

Mobile VPN stack selections use the meow-rs lwIP implementation. They do not select the old Go gvisor/system/mips
implementations. Supported default setting substitutions are logged by the wrapper.

Connection and DNS events are derived from the backend's active/recent connection and DNS snapshots. They retain
the Flutter JSON shape, but do not provide lossless per-query history, original query initiators/latencies, or every
short-lived connection under a large burst. Cache observations carry a neutral initiator and delay. Automatic
backend health-check delay notifications are not equivalent to Mihomo's hook; explicit delay tests return results.
Memory reporting provides RSS; the old Go heap/stack counters have no Rust equivalent and return zero.
Encrypted profile import currently supports age X25519 identities, rather than every identity type supported by Go.
Public external-controller configuration mutations (`PUT`/`PATCH /configs`) return an explicit unsupported response;
configuration changes must use FlClash's transaction owner. Other supported controller APIs remain available.

Compilation and portable packet tests do not establish real VPN routing, platform permission/revoke behavior,
screen-off survival, or an installed app's end-to-end traffic. Those require the corresponding platform/device run.
