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
  bidirectional traffic. Sustained background operation is not yet validated. A continuous
  background task cannot simply be requested from VpnExtensionContext: the SDK
  restricts that API to UIAbility or FA ServiceAbility contexts.
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
- Secure storage, connectivity, app links and remaining native plugins still
  require adaptation. UI-process termination currently closes the control channel
  and stops the VPN; reconnecting a new UI to a surviving Core is not implemented.
- The separate Go Core probe is not the application Core integration.
