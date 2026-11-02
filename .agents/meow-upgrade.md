# meow-rs Compatibility And Upgrade Checks

Review this ledger whenever changing the meow-rs version. Check whether the candidate upstream release meets each
requirement before carrying, replacing or removing the corresponding local patch. Update the status and evidence in
the same upgrade change.

## Recorded Baseline

- Baseline: meow-rs crates `0.28.0`, upstream revision `80816302e7ad8f868fdf1619a11bf3c8121696dd`.
- Recorded: 2026-11-02. No later upstream release has been evaluated by this ledger.
- Exact versions, active local overrides and resolved checksums live in
  [Cargo.toml](../core/rust/Cargo.toml) and [Cargo.lock](../core/rust/Cargo.lock).
- Seven vendor crates are tracked below. The direct-resolver work in `meow-config`, `meow-proxy` and `meow-api`
  and its bootstrap hooks passed final merged host verification. Device acceptance remains separate.
- Final merged host verification: 93 tests across 16 test binaries, zero failed/ignored, with serial independent
  fixtures. The route recording-backend harness previously passed eight cases. The last installed HarmonyOS package
  exposed `dns.direct-nameserver`; rebuilding and phone validation of the completed fix are pending. End-to-end phone
  traffic has not passed. Compilation and portable tests do not close the device validation requirement.

These are compatibility requirements of the FlClash integration. Some require upstream lifecycle or resolver hooks;
FlClash-specific IPC, platform ownership and configuration transactions remain integration responsibilities.

## Vendored Requirements

### V1: Listener Generation Ownership

Status: implemented and covered by host flow tests.

Process-lifetime detached clients and UDP tasks can outlive a listener stop, retain ports and accept obsolete
credentials. The local `meow-listener` scope cancels and joins generation-owned Mixed, Shadowsocks and TProxy tasks;
TProxy UDP replies have an abort-on-drop guard.

- Patch: [meow-listener/FLCLASH-PATCHES.md](../core/rust/vendor/meow-listener/FLCLASH-PATCHES.md).
- Regression: [engine_flow.rs](../core/rust/tests/engine_flow.rs), especially pending authentication close and real
  encrypted Shadowsocks UDP stop, port release and restart.
- Upstream replacement condition: stopping a generation must close accepted idle/authenticating clients and UDP
  relays, await ownership release and permit immediate rebind with fresh credentials. A cancelled accept loop alone
  is insufficient. Keep the FlClash scope adapter until the replacement passes the same tests.

### V2: TCP Keepalive Policy Before Connect

Status: implemented; real Windows socket option tests passed.

Saved `keep-alive-idle`, `keep-alive-interval` and `disable-keep-alive` must control actual OS TCP probes, including
the observed 60-second interval. `meow-common` adds a fallible pre-connect policy hook for ordinary, protected and
interface-bound stream sockets. Owned guards restore the prior policy after failure and preserve a newer owner.

- Patch: [meow-common/FLCLASH_PATCHES.md](../core/rust/vendor/meow-common/FLCLASH_PATCHES.md).
- Adapter/tests: [socket_policy.rs](../core/rust/src/socket_policy.rs),
  [tests/socket_policy.rs](../core/rust/tests/socket_policy.rs).
- Upstream replacement condition: exact requested enable/idle/interval options must be set and read back for new
  sockets through every dial path; errors must abort the dial. Reload failure must restore policy, existing sockets
  must retain their options, and UDP must remain unaffected. Repeat native tests on each supported desktop OS.

### V3: AnyTLS Must Retain The Host TCP Policy

Status: implemented; included in the real socket tests.

`meow-anytls` previously rewrote OS keepalive to its own idle/interval defaults after the common dial path. Its local
`configure_tcp_stream` preserves an installed host policy while retaining upstream defaults when no policy exists.

- Patch: [meow-anytls/FLCLASH_PATCHES.md](../core/rust/vendor/meow-anytls/FLCLASH_PATCHES.md).
- Regression: [tests/socket_policy.rs](../core/rust/tests/socket_policy.rs), including disabled probes and the
  no-host-policy default case.
- Upstream replacement condition: AnyTLS setup must preserve custom and disabled OS probes without changing its
  protocol heartbeat, TLS behavior or session timers. Removing V2 does not automatically resolve this separate row.

### V4: Exact TUN Include/Exclude Routes And Transactional Installation

Status: implemented; host route-plan and isolated recording-backend tests passed; device traffic remains unverified.

`tun.route-address` and `tun.route-exclude-address` require canonical include-minus-exclude CIDRs. Desktop listeners
receive that exact plan; installation failure rolls back successful additions, and teardown preserves original
physical defaults. Mobile declarations are checked against the native VPN owner's installed routes, including its
mandatory DNS host route, before applying the profile.

- Patch: [meow-listener/FLCLASH-PATCHES.md](../core/rust/vendor/meow-listener/FLCLASH-PATCHES.md).
- Adapter/tests: [tun_routes.rs](../core/rust/src/tun_routes.rs),
  [tests/tun_routes.rs](../core/rust/tests/tun_routes.rs), and the recording backend tests in
  [vendor route.rs](../core/rust/vendor/meow-listener/src/tun/route.rs).
- Upstream replacement condition: preserve IPv4/IPv6 subtraction, explicit empty selections, split default routes,
  physical outbound binding, rollback and cancellation ownership. Mobile acceptance must correspond to routes
  actually installed by its platform owner. Do not merely ignore profile route fields.
- The root crate suite does not automatically execute a dependency's unit tests. Re-run the actual vendored
  `route.rs` recording-backend tests through an isolated harness and record its command; these checks must not
  install routes on the developer host.

### V5: Preferred HTTP/3 DoH With Verified TLS Fallback

Status: host verified in the final 93-test merge, including DIRECT/bootstrap, protocol-fidelity and preference-only
hot reload. Phone acceptance is pending.

`dns.prefer-h3` now drives a real bounded HTTP/3 attempt. A scoped `meow-dns` hook retains the selected proxy,
hostname/SNI, path and DNS wire query. Failure falls back to the original verified TLS DoH path and uses backoff.
Rejected configuration restores the previous preference without clearing a successor's ownership.

- Patch: [meow-dns/FLCLASH-PATCHES.md](../core/rust/vendor/meow-dns/FLCLASH-PATCHES.md).
- The [meow-config patch](../core/rust/vendor/meow-config/FLCLASH-PATCHES.md) also retains `prefer-h3` in the typed
  `RawDns` comparison so changing only this flag rebuilds captured DNS clients. The wrapper remains the preference
  policy owner.
- Adapter/tests: [dns_http3.rs](../core/rust/src/dns_http3.rs),
  [dns_http3/tests.rs](../core/rust/src/dns_http3/tests.rs).
- Upstream replacement condition: preserve certificate chain and hostname verification, selected proxy and protected
  socket paths, DNS transaction/question validation, bounded fallback and reload rollback. Acceptance of the YAML
  key or successful UDP transmission alone does not satisfy this requirement.
- Toggle only `prefer-h3` with identical upstreams and verify actual H3/TLS request counts change in both directions.
  Typed config diffing and resolver/client reconstruction must preserve this hot-reload behavior; changing a policy
  flag while reusing clients that captured the previous transport is insufficient. The current host merge passes.

### V6: Direct Resolver Configuration And DIRECT Dial Semantics

Status: host verified in the final 93-test merge, including actual H3/DIRECT/bootstrap exchanges, protocol fidelity
and rollback. Phone acceptance is pending.

The previously installed phone package rejects `dns.direct-nameserver`; its resolver addresses are intentionally
not recorded here. Local patches to exact `meow-config` and `meow-proxy` 0.28.0 packages provide a candidate direct
resolver that participates in configuration commit and rollback.

- Patch notes: [meow-config](../core/rust/vendor/meow-config/FLCLASH-PATCHES.md),
  [meow-proxy](../core/rust/vendor/meow-proxy/FLCLASH-PATCHES.md),
  [meow-common](../core/rust/vendor/meow-common/FLCLASH_PATCHES.md), and
  [meow-dns](../core/rust/vendor/meow-dns/FLCLASH-PATCHES.md).
- Adapter/tests: [direct_dns.rs](../core/rust/src/direct_dns.rs),
  [tests/direct_dns.rs](../core/rust/tests/direct_dns.rs), plus the DIRECT/H3 cases in
  [dns_http3/tests.rs](../core/rust/src/dns_http3/tests.rs).
- Required regression coverage includes DIRECT versus proxied destination resolution, empty/default behavior,
  valid resolver proxy tags and failed reload rollback.
- Candidate bootstrap resolution must use the same candidate `default-nameserver` through a task-scoped context
  for DIRECT and proxy/group upstream hostnames, including H3 and TLS paths. Test recursion prevention, concurrent
  candidate isolation and rejection rollback. A bootstrap failure must fail explicitly without falling back to libc
  or selecting the system resolver, and this context must not introduce another global DNS owner. This behavior is
  covered by the final host merge; retain it when replacing the hooks.
- Bootstrap roots must retain their declared UDP, TCP, TLS, HTTPS or refusal transport, certificate checks and
  routing selection. Converting an IP-based encrypted/TCP root into UDP port 53 does not honor the declaration.
  Require actual TCP/encrypted-root exchanges and a negative assertion that no UDP fallback occurred. This final
  protocol-fidelity requirement passes the final host merge.
- Upstream replacement condition: equivalent direct-resolver semantics must actually reach the DIRECT dial path,
  preserve legitimate resolver transport/proxy selection and participate in the same transaction. Do not remove the
  setting or replace it with the ordinary resolver to make validation pass.
- Domain destinations must use the dedicated resolver even when routing already populated an IP; literal IPs keep
  their normal path. Verify both TCP and UDP destination selection, stale UDP write-address handling and original
  reply/NAT address preservation. Dedicated caches must stay separate from main fallback/fake-IP behavior, and
  nameserver policy must be shared only when explicitly requested. Direct DNS records must participate in the
  existing merged snapshot/filter/limit path.
- Legacy encrypted resolver URL proxy/group tags and mobile system-DNS sentinel expansion must remain compatible.
  Perform normalization on runtime clones so the raw/source profile retains its supplied values.

### V7: Direct Resolver References Follow The Current Proxy Generation

Status: host verified in the final 93-test merge; phone acceptance is pending.

The `meow-api` runtime-reference scan must include direct-resolver lists. Reloading proxy objects while retaining
the same direct resolver URL must rebind to the new generation rather than retain obsolete objects.

- Patch notes: [meow-api/FLCLASH-PATCHES.md](../core/rust/vendor/meow-api/FLCLASH-PATCHES.md), covering
  `dns_uses_runtime_refs` and direct-list scanning. Reload coverage is in
  [tests/direct_dns.rs](../core/rust/tests/direct_dns.rs).
- Retain the changed-proxy-generation case with an unchanged direct resolver URL/tag.
- Upstream replacement condition: all resolver reference lists must track the current generation on successful
  reload and retain the old generation on rejected reload. Keep the FlClash public controller mutation guard.

## Integration Regressions To Retain

- HarmonyOS can attach TUN before profile setup. Its bootstrap policy must reject traffic/refuse DNS, preserve the
  saved profile and reuse the same Engine/Tunnel when real setup commits. Keep
  [mobile_contract.rs](../core/rust/tests/mobile_contract.rs) coverage if upstream construction APIs change.
- FlClash owns configuration transactions and rollback. Public controller configuration writes must not bypass the
  socket, DNS or route transaction. Keep [engine_flow.rs](../core/rust/tests/engine_flow.rs) controller coverage.
- Unsupported effectful options must remain explicit failures. A path-only aggregate diagnostic is implemented to
  expose remaining unsupported keys without exporting the user's configuration;
  [validation_summary.rs](../core/rust/tests/validation_summary.rs) has two focused checks and passes the final merged
  host suite. Device diagnostics remain to be checked.
- IPC framing, method/event envelopes, JNI/C ABI, process ownership and native VPN lifecycle are FlClash contracts.
  Replacing upstream hooks must preserve them. Current support limits are in
  [core/rust/README.md](../core/rust/README.md).

## Next Version Review Procedure

1. Record the candidate version, upstream revision, review date and upstream issue/commit evidence for every row.
   Compare the candidate source with the exact baseline package and the local patch notes, including fixes omitted
   from release notes. Mark each row as still required, upstream equivalent, or replaced by another explicit adapter.
2. Work in an isolated copy under the repository's worktree rules. Remove or replace one local override at a time
   only when the corresponding behavior is covered. Update all exact meow crate pins and Cargo.lock together. Do not
   reuse staged binaries as evidence for the candidate.
3. With the native environment from [commands.md](commands.md), run the checks below from `core/rust`, plus each
   row's focused cases and the separate route recording-backend harness:

   ```bash
   cargo fmt --check
   cargo test --locked --all-targets -- --test-threads=1
   ```

   Independent Core fixtures share process-level home, DNS and socket-policy state. Serial test scheduling keeps
   those fixtures isolated; concurrency inside each Tokio test remains exercised.

4. Rebuild the executable/cdylibs for supported targets. Check real Core/Helper hashes and package contents after a
   successful build. Verify native socket options on available OSes, use safe mode for any host Flutter launch, and
   preserve user profiles/data during upgrade installation. Report unavailable SDK/ABI/device coverage explicitly.
5. Exercise real configuration, VPN/TUN and browser or HTTP traffic on the affected platforms. A build, `ready`
   state or bootstrap indicator is insufficient. Record behavior before and after failure/reload/stop where relevant.
6. Remove a vendor override, its obsolete workaround and its exact vendor-gate exception only after equivalent
   upstream behavior passes these checks. Retain behavioral regressions and update the vendor-gate fixtures. Update
   this ledger, patch notes, build inputs and support limits with the evidence and remaining gaps; leave unresolved
   rows open.
