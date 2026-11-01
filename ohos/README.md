# HarmonyOS build

This platform is under development. A successful HAP build does not establish Core or VPN support.

On Windows, run `powershell -File tool/build_ohos.ps1` from the repository root.
The script uses `D:\Java\Huawei\Enable-Harmony.ps1`, prepares isolated Material,
Cupertino and SQLite package copies, then restores ordinary dependency resolution.
Do not run IDE dependency resolution concurrently with this build.

Toolchains used: Harmony Flutter `3.47.7+ohos-0.0.1-pre`, DevEco Studio
`26.0.0.851`, SDK `26.0.0.105`, Rust `1.99.0` with
`aarch64-unknown-linux-ohos`. `OHOS_NDK_HOME` must point to the SDK native folder.
SQLite 3.54.1 amalgamation is downloaded from sqlite.org and checked against its
published SHA3-256 before compilation with the HarmonyOS NDK.

Copy `build-profile.template.json5` to `build-profile.json5` if absent, open this
directory in DevEco Studio, and generate the debug signature for
`com.follow.fl_clash`. The local signing configuration is ignored by Git.
Signed output is `entry/build/default/outputs/default/entry-default-signed.hap`.

The installed Harmony Flutter Hvigor source has a local compatibility fix in
`findFlutterPlugins`: `JSON.parse(fileContent).plugins?.ohos ?? []`. Without it,
IDE sync after stock Flutter `pub get` fails with `undefined.filter`.

Current boundaries:

- Rust and SQLite build for HarmonyOS ARM64; desktop IPC and hotkeys are excluded.
- Directory, package and device metadata channels are implemented in EntryAbility.
- Preferences use the existing atomic file store on HarmonyOS.
- The build script cross-compiles the existing Go Core. The VPN extension owns
  both the Core and system TUN descriptor. Flutter controls the Core through a
  loopback TCP connection authenticated with a fresh 256-bit token. No TUN
  descriptor crosses the VPN process boundary.
- VPN authorization is currently requested when initializing the Core. Starting
  the listener creates the virtual interface; stopping it destroys that interface.
  Extension teardown and control-connection loss shut down the Core and tunnel.
  The virtual DNS address has an explicit /32 route even when private networks
  are excluded. An authenticated Core disconnect allows teardown without waiting
  for a dead extension to write its status file.
  On the API 26 device, Core initialization and TUN creation have been observed,
  but LowMemoryKill reclaimed the VPN process in earlier runs. After the DNS
  route correction, the user confirmed browser access and TUN counters showed
  bidirectional traffic. A later capture confirmed `LowMemoryKill` of the VPN
  process while the UI survived. The Core releases reclaimable memory when the
  UI goes into the background or the VPN process receives a memory-pressure
  callback. After an unexpected disconnect, a VPN that was running is restored
  as soon as the UI process receives the disconnect, including in the background.
  If a background attempt fails, returning to the foreground permits one retry.
  At most two automatic attempts are allowed in two minutes. User stop and safe
  mode cancel recovery. This mitigates process loss.
  VPN status polling discards results across Core state transitions and does not
  convert an unfinished native session into a stop request during recovery.
  `EntryAbility` requests a `dataTransfer` continuous task while the VPN is
  running; the SDK requires a UIAbility context. It releases the task on an
  explicit stop or clean teardown, and retains it across unexpected Core loss
  so background recovery can run. The notification uses actual traffic totals;
  it does not invent a completion percentage for an open-ended VPN stream.
  Task cancellation and notification failures are recorded in diagnostics.
  Continuous tasks prevent suspension, but are still subject to resource and
  data-transfer activity checks. VPN process priority changes, notification
  renewal beyond ten minutes, and sustained background operation still need
  device validation.
- Per-application VPN allow/block lists use bundle names. The tools page exposes
  access control on HarmonyOS, and selected bundle names survive incomplete
  enumeration. On the API 26 device, the legacy launcher query returns no apps;
  it does not provide an unrestricted installed-app inventory with normal signing.
  The list combines query-visible apps, configured names, and names observed via
  the VPN-only `getConnectOwnerUid` API. Observed names are stored locally.
- A one-line HarmonyOS branch in `core/Clash.Meta/tunnel/tunnel.go` routes process
  lookup to the existing package-name hook. The HarmonyOS bridge resolves raw
  connection tuples through NetworkKit, with at most 64 pending lookups and a
  500 ms timeout; unknown owners remain unknown. Real-device owner resolution
  and per-app routing still require validation.
- Backup compression and encryption use the existing Go codec through its C ABI
  from a Dart worker isolate. Snippet sessions use Asset Store Kit, and local
  backup import/export uses the system document picker. These paths have been
  checked on the API 26 device, including WebDAV backup and restore.
- Connectivity, app links and remaining native plugins still
  require adaptation. UI-process termination currently closes the control channel
  and stops the VPN; reconnecting a new UI to a surviving Core is not implemented.
- The separate Go Core probe is not the application Core integration.

## Core disconnect diagnostics

The existing Logs page's export includes persistent HarmonyOS lifecycle logs,
even when the Core is disconnected. They record UI foreground/background,
Core/TUN starts and stops, automatic recovery outcomes, memory-pressure callbacks,
and asynchronous memory samples once per minute in the VPN process. Samples also
record system available memory and the process's `oom_score_adj` when readable,
including a sample 15 seconds after startup. System
`APP_KILLED`, `APP_CRASH`, `APP_FREEZE` and `RESOURCE_OVERLIMIT` events are
subscribed through HiAppEvent; delivery may occur after the next process start.

The UI and VPN each keep a current and previous 128 KiB JSONL file under the app's
`files/diagnostics/` directory. A separate session marker detects a prior session
that ended without teardown; it does not assert a cause. Endpoint tokens,
subscriptions and traffic destinations are not recorded. Diagnostic error
messages redact URLs and common credential fields. Export logs after a recurrence
and note whether it followed background use, lockscreen or a network change.

## Core fork and upstream updates

The submodule uses `https://github.com/Ive4/Clash.Meta.git`, branch `FlClash`.
The original upstream is `https://github.com/chen08209/Clash.Meta.git`.
The local submodule keeps that original address as the `upstream` remote.
After a fresh clone, add it once before fetching updates:

```sh
git -C core/Clash.Meta remote add upstream https://github.com/chen08209/Clash.Meta.git
git -C core/Clash.Meta fetch upstream
git -C core/Clash.Meta switch FlClash
git -C core/Clash.Meta merge upstream/FlClash
```

Resolve conflicts, run the relevant Core checks, push the updated `FlClash` branch
to `origin`, and commit the new submodule revision in this repository. Keep the
HarmonyOS package-owner hook when merging upstream changes.
