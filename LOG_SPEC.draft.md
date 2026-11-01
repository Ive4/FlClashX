---
status: draft
project: "FlClash HarmonyOS Core disconnect"
confirmed_by: ""
confirmed_at: ""
---

# Project Log Troubleshooting Specification

## Scope

### Included

| Service or process | Reason | Environments | Source | Confidence |
|---|---|---|---|---|
| com.follow.fl_clash UI and OhosCoreTransport | Reports Core disconnection | Connected HarmonyOS device only | lib/core/ohos/core.dart; lib/core/ohos/transport.dart | High |
| FlClashVpnAbility and embedded Go Core | Owns the Core and TUN | Same device and application | ohos/entry/src/main/module.json5; ohos/entry/src/main/ets/vpn/FlClashVpnAbility.ets; core/embedded_ohos.go | High |
| System termination records naming the application or its established PID | Distinguish process termination from transport failure | Same incident window | ohos/README.md documents earlier LowMemoryKill observations; current incident unverified | Medium |

### Excluded

| Service or process | Reason | Source | Confidence |
|---|---|---|---|
| Windows/Android instances, other applications, remote proxy providers | Outside reported incident | User reports HarmonyOS Core disconnect while UI remains | High |
| Credentials, subscriptions, browsing history and full VPN configurations | Not required to classify process exit | Diagnostic scope decision | High |

### Uncertain

| Service or process | Missing information | Source | Confidence |
|---|---|---|---|
| Native crash reports | Shell cannot access /data/log/faultlog/faultlogger; use an available authorized app export if needed | Read-only directory probe, 2026-10-27 | High |
| Historical incidents | Exact time, foreground/background state and retained log coverage | User symptom only | Low |

## Log Map

Use the single connected target; if multiple targets appear, identify the intended device before querying. Discover its identifier locally and never publish it. Each command has a 15-second timeout. Save bounded evidence only under a newly created `%TEMP%/flclash-ohos-core-<timestamp>/` directory, never upload it. Cap each text result at 2 MiB. Summaries redact tokens, URLs, device identifiers and unrelated application data.

| Service | Log location or access command | Format/timezone | Sensitive fields | Source | Confidence |
|---|---|---|---|---|---|
| Application and extension | `hdc -t <target> shell "hilog -x -z 2000 -e 'com[.]follow[.]fl_clash\|FlClash\|fl_clash\|libflclash'"`; Markdown table escapes represent literal regex alternation characters | Device timestamps; compare device time with host, do not assume timezone | URLs, paths, error payloads | Device `hilog --help` verifies -x, -z, -e; native console messages in FlClashVpnAbility.ets | Medium: filter usefulness not yet tested |
| Application process inventory | `hdc -t <target> shell ps -A`; filter locally to the application/extension | Point-in-time state, not proof of historical death | Unrelated process names must not be reported | HDC read-only capability; module.json5 | Medium: process-name truncation possible |
| System exit reason | Query bounded hilog for established application PID plus `LowMemoryKill`, `AppExit`, `SIGSEGV`, `SIGABRT`, `panic`, `fatal` within the same incident window | Device timestamps | Unrelated process data excluded | Candidate evidence path; current accessibility and retention unverified | Low |
| Native crash report | `/data/log/faultlog/faultlogger` currently denied | Unknown until accessible | Stack paths, process metadata | Directory probe | High: unavailable; do not root or bypass |

## Correlation Model

| Priority | Field or strategy | Origin | Propagation and scope | Failure mode | Source | Confidence |
|---|---|---|---|---|---|---|
| 1 | Bundle plus PID plus process lifetime | Device process inventory and system records | UI and VPN processes tracked separately | PID reuse; process names can be truncated | module.json5 and device metadata | Medium |
| 2 | Control-session basename | `core-<microseconds>-<revision>.control` generated in OhosCore | Passed through VpnPlugin to VPN extension | Not necessarily emitted into hilog | lib/core/ohos/core.dart; VpnPlugin.ets | High for code, low for log availability |
| 3 | Incident time plus exact error signature | User time and device log timestamps | Same application only | Temporal proximity alone does not prove causation | User symptom and OhosCore crash-event mapping | Medium |

## Troubleshooting Scenarios

### UI remains visible but Core disconnects

- **Symptom:** User reports App remains running and displays Core disconnected.
- **Required incident inputs:** Target application and device. A unique connected device exists as of the preflight. Ask for an incident time when retained evidence cannot establish one; do not invent a time.
- **Start service and query:** Read device time and application process inventory, then the bounded matching hilog buffer above. Without an incident time, treat this solely as discovery of retained application events, not as attribution to every reported occurrence.
- **Extract for next hop:** Timestamp, process identity, native error or termination reason, and control session if present.
- **Next query:** Only records matching the established process/lifetime in a five-minute window around the candidate event; preserve the smaller relevant excerpt. Do not widen the device/application/time boundary silently.
- **Branches:** A native fatal stack establishes native failure; a system LowMemoryKill record matching the VPN PID establishes system reclamation; connection EOF alone establishes only disconnection. A requested stop or extension teardown must be distinguished from an unexpected exit. Absence of a record proves neither memory exhaustion nor a Go crash.
- **Stop condition:** Cause linked to the correct process and event, or retained evidence cannot distinguish the branches. Report that limitation and arrange bounded capture at the next occurrence.
- **Fallback:** If protected crash reports remain inaccessible, use a user-exported application/system report or a bounded future capture. Do not clear logs, restart the VPN, reinstall, root, or change device settings as part of initial evidence collection.

## Evidence and Root-Cause Rules

- The same UI message currently represents TransportDisconnected and TransportFailed; it is a symptom, not a diagnosis (lib/core/ohos/core.dart).
- The prior LowMemoryKill note in ohos/README.md is historical evidence only, not confirmation of this incident.
- Cite timestamps, process identity and the earliest causal event; state correlation confidence and missing coverage.
- Keep raw evidence local; report only necessary redacted excerpts. No configuration or credential collection.
- No production code change, package replacement or automatic restart solely on a speculative diagnosis.

## Developer Confirmation Required

- [ ] Confirm this application's UI, VPN extension and directly related system exit records as the boundary.
- [ ] Confirm bounded read-only device evidence collection and local temporary storage as described above.
- [ ] Confirm the correlation limits and stop conditions; protected crash files remain unavailable.
- [ ] Provide the last incident time and whether it happened in foreground, background/lockscreen, or while changing networks if known.
