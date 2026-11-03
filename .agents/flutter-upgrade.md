# Flutter Upgrade Checklist

Read this before changing `FLUTTER_VERSION` in `.github/workflows/build.yaml` or `.fvmrc`. This file records the
user-selected renderer policy and SDK-specific workarounds. Remove a workaround entry together with its workaround;
the global renderer policy requires a new user decision before changing it.

## Stable cadence

Flutter ships a stable release about once a quarter, three minor versions apart (3.41, 3.44, 3.47). The two minors in
between are beta only, so a fix that lands on `main` reaches the next stable minor, three above the current one.
Hotfix releases (3.47.x) carry only cherry-picks listed in the SDK's `CHANGELOG.md`.

## Skia on every supported platform

On 2026-11-03 the user explicitly requested Impeller disabled globally. All supported platforms use Skia; the
Windows runner has no Impeller opt-in. Keep these native settings for debug, profile and release builds:

| Platform | Native owner | Setting |
| --- | --- | --- |
| Windows | `windows/runner/main.cpp` | `flutter::ImpellerSwitch::Disabled` |
| Linux | `linux/runner/my_application.cc` | `fl_dart_project_set_enable_impeller(project, FALSE)` |
| macOS, both architectures | `macos/Runner/Info.plist` | `FLTEnableImpeller` is false |
| Android, every ABI | `android/app/src/main/AndroidManifest.xml` | `io.flutter.embedding.android.EnableImpeller` is false |
| HarmonyOS | `ohos/entry/src/main/resources/rawfile/buildinfo.json5` | `enable_impeller` is `"false"` |

IntelliJ and Zed run/debug configurations pass `--no-enable-impeller`, including safe mode. Use that flag with
`flutter run`; the pinned SDK's `flutter build` subcommands do not accept it, so release builds use the native
settings above. HarmonyOS's `flutter run` can rewrite buildinfo; keep its flag false. The checked-in buildinfo
was updated with the HM-Flutter SDK's `setImpellerEnableFlag` writer.

Do not re-enable Impeller as part of a Flutter or meow-rs upgrade. Check that a candidate SDK retains the Skia paths;
loss of a supported Skia path is an upgrade blocker under this policy. The upstream native controls are documented
in [Flutter's renderer guide](https://docs.flutter.dev/perf/impeller). Skia uses the existing Liquid Glass fallback:
frost, tint, blur and rim remain, with no shader-based refraction.

### Intel macOS SDK history

- **Bug:** [flutter/flutter#191538](https://github.com/flutter/flutter/issues/191538). From 3.47, when Impeller
  became the default desktop renderer, Intel (x86_64) Macs flicker across the whole window while scrolling or
  animating, and text can render garbled. Apple Silicon is not affected.
- **Fix upstream:** landed on `main` before 2026-08-25 and verified on `3.48.0-1.0.pre-404`; it is not in any
  3.47.x hotfix (checked through 3.47.6).
- **Current policy:** the checked-in `Info.plist` disables Impeller on both Intel and Apple Silicon in every build
  mode. The earlier Intel-only CI mutation is removed. Fixing the SDK issue does not change the global Skia policy.

### Windows memory and SDK history

- **Bug:** [flutter/flutter#193504](https://github.com/flutter/flutter/issues/193504), reported here as #2423. From
  3.47 the Windows embedder enables Impeller by default (`flutter_windows_engine.cc`). On some machines (seen on
  Windows 11 26200 with an Intel Arc integrated GPU) dragging a window edge freezes the window on its last frame:
  the EGL context is lost, no frame of the new size is ever produced, and every later frame is dropped while Dart
  keeps running. A dump shows no thread blocked; hiding and showing the window leaves it white until the app is
  restarted. Upstream could not reproduce it and closed the issue on 2026-10-29 for lack of additional information;
  that closure does not confirm a fix.
- **Memory regression:** On 2026-11-03, the same Windows Release frontend with the same private profile and window
  reproduced Impeller startup working-set peaks of 650–930 MiB and settled working sets around 420–460 MiB, versus
  around 210 MiB with Skia. The Flutter engine DLL is identical to the installed old version; that version forced
  Skia. These process measurements exclude the separate Rust Core and do not establish a Dart heap leak.
- **Selection:** the Windows project unconditionally selects Skia. Passing the former Impeller arguments must not
  enable Impeller or change the selected backend.
- **Verification:** check normal startup and startup with the former enable argument in safe mode; neither may log
  the Impeller startup message. Check redraw while resizing, scrolling, minimizing and restoring. Compare frontend
  working set and private bytes with the same data, dimensions and elapsed startup time, including cold peaks and
  repeated runs. Keep these checks when updating Flutter; do not infer that another platform shares the same
  measured Windows memory regression.

## Wrong-size back buffer on macOS

- **Bug:** [flutter/flutter#185394](https://github.com/flutter/flutter/issues/185394). `removeSurfaceForSize:` in
  the macOS engine's `FlutterSurfaceManager.mm` hands out the youngest idle cached surface without checking its size.
  When the window flips between sizes while the window server still holds the previous surface, which dragging a
  window edge back and forth does, a request for one size gets a surface of another. Impeller's Metal texture then
  disagrees with its descriptor, the render target drops it, and `Canvas::SetupRenderPass` dereferences a null
  texture on the raster thread. Debug builds log `The texture and its descriptor disagree about its size` and
  `Store action needs resolve but no valid resolve texture specified` first; release builds just crash.
- **Fix upstream:** [flutter/flutter#192522](https://github.com/flutter/flutter/pull/192522), still open; 3.47.6
  ships the same `FlutterSurfaceManager.mm` as 3.47.4.
- **Workaround:** `BackBufferCacheGuard` in the `window` plugin's
  `macos/window/Sources/window/BackBufferCacheGuard.swift`, installed from `WindowPlugin.register`, replaces
  `-[FlutterBackBufferCache removeSurfaceForSize:]` at runtime and answers nil when the cached surface is not the
  requested size, so the engine allocates a new one. It does nothing if the engine no longer has that class or
  selector.
- **Remove when:** `FLUTTER_VERSION` moves to a stable that contains #192522 (check the SDK `CHANGELOG.md` for a
  3.47.x cherry-pick). Before dropping it, run a debug build without the guard on that SDK and drag a window edge
  back and forth for a minute; neither validation line may appear.

## Windows view visibility forwarded by the runner

- **Bug:** the Windows embedder's `WindowsLifecycleManager` counts the Flutter view as a window of its own and keeps
  it visible until the view is sized to zero. Hiding the top-level window never resizes the view, and the `window`
  plugin keeps it sized while minimized, so the app was never told `hidden`: animations kept rendering in the tray
  and `appVisibleProvider` stayed true.
- **Workaround:** `WindowPluginForwardVisibility` in the `window` plugin's
  `windows/include/window/window_plugin_runner.h` hands the top-level window's `WM_SHOWWINDOW` and `WM_SIZE` to
  `ProcessExternalWindowMessage` for the view's HWND, so the view shows and hides with its window.
  `FlutterWindow::MessageHandler` in `windows/runner/flutter_window.cpp` calls it before `HandleTopLevelWindowProc`;
  the Flutter runner template has no such call, so keep it when regenerating the runner.
- **Remove when:** the engine hides the view together with its top-level window. Check with the proxy running and
  the window focused: hiding it to the tray and minimizing it must each log `AppLifecycleState.hidden`.

## macOS activation resumes a hidden window

- **Bug:** `handleWillBecomeActive` in the macOS engine's `FlutterEngine.mm` resumes when any window in
  `NSApp.windows` is visible, and the tray's `NSStatusBarWindow` always is. Activating the app while its window was
  minimized or hidden, such as Cmd-Tab back to a minimized window, reported `resumed`, and the next deactivation
  `inactive`, so frames ran until the window was shown again.
- **Workaround:** the `window` plugin observes will-become-active and will-resign-active and, once the engine has
  answered, sends `AppLifecycleState.hidden` on `flutter/lifecycle` while its window is not visible
  (`applicationActivityChanged` in `WindowPlugin.swift`). A window brought back without another activation change
  would then wait on an occlusion notification macOS does not always post, keeping its last frame, so `show` and a
  deminiaturize hand the state back (`windowBecameVisible`).
- **Remove when:** the engine ignores status item windows on activation. Check without the workaround: minimize the
  window, switch to another app, then Cmd-Tab back without restoring it; the log must stay at
  `AppLifecycleState.hidden`.

## Linux minimize on Wayland reads as inactive

- **Bug:** the Linux engine reports `hidden` for `GDK_WINDOW_STATE_ICONIFIED`, but xdg-shell has no minimized state,
  so GTK 3 never sets it on Wayland. A minimized window reported only its focus loss, as `inactive`, and kept
  rendering at the display rate (GNOME 46).
- **Workaround:** the `window` plugin's Linux `minimize` records the time, and a focus loss within 500 ms of it sends
  `AppLifecycleState.hidden`. Its `window-state-event` handler is connected after the engine's, so that message
  follows the engine's `inactive`; the compositor focuses the window when it restores it, which the engine reports as
  `resumed`. A minimize the compositor starts itself (Super+H, the dock) is not covered.
- **Remove when:** the Linux engine reports minimized windows on Wayland, which needs GTK 4 or xdg-shell's
  `suspended` state. Check in a GNOME Wayland session without the workaround: minimizing from the caption button
  must log `AppLifecycleState.hidden`.

## Liquid glass saves around the transform of a blurring layer

- **Bug:** not filed upstream. On 3.47 Impeller scales a `saveLayer`'s image filter by a transform set inside the
  layer that is still in effect when the layer is restored. A host's capture shrinks each pane's slot inside the
  layer that blurs it, so its blur vanished at a quarter scale and spread half again as far at 1.5.
- **Workaround:** `_LiquidGlassHostLayer._snapshot` sets each slot's transform inside a `save` of its own, and each
  band's offset, restored before the layer is.
- **Verification:** retain the slot's transform ownership and the frosted-pane regression in
  `test/widgets/liquid_glass_host_test.dart` under the normal Skia test suite. The earlier Impeller measurements
  record the origin of this workaround; they are not an instruction to enable that backend.
