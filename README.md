FlClashX extends [FlClash](https://github.com/chen08209/FlClash) with additional features and experimental HarmonyOS support. Its public version follows the upstream base version; `pubspec.yaml` is the version source. The project is maintained in [Ive4/FlClashX](https://github.com/Ive4/FlClashX), with its Core fork in [Ive4/Clash.Meta](https://github.com/Ive4/Clash.Meta). See [upstream synchronization](UPSTREAM.md).

<div align="center">

<img src="assets/images/icon.png" alt="FlClashX" width="88">

# FlClashX

A multi-platform proxy client based on ClashMeta. Simple to use, open source and ad-free.

**English** · [简体中文](README_zh_CN.md)

[![Release](https://img.shields.io/github/v/release/Ive4/FlClashX?style=flat-square&label=release)](https://github.com/Ive4/FlClashX/releases)
[![Downloads](https://img.shields.io/github/downloads/Ive4/FlClashX/total?style=flat-square&logo=github)](https://github.com/Ive4/FlClashX/releases)
[![License](https://img.shields.io/github/license/Ive4/FlClashX?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-upstream_channel-26A5E4?style=flat-square&logo=telegram&logoColor=white)](https://t.me/FlClash)

[Repository](https://github.com/Ive4/FlClashX) · [Download](#download) · [HarmonyOS](#harmonyos-experimental) · [Changelog](CHANGELOG.md) · [Build from source](#build-from-source)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash dashboard on a MacBook and a phone" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## Features

- **One app for Android, Windows, macOS and Linux**, with x64 and ARM64 builds on the desktop.
- **Experimental HarmonyOS 7 support** for ARM64 devices, with a native HAP build and VPN integration. See the [current limitations](#harmonyos-experimental).
- **mihomo (Clash.Meta) core** with rule routing, proxy groups, latency tests, system proxy and TUN mode.
- **Profiles** from a subscription link or a file, with a built-in editor, override scripts, and custom rules,
  proxies and proxy groups.
- **Live views** of connections, requests, DNS queries and logs.
- **Material You design with Apple-style interaction**: dynamic color, light and dark themes, continuous corners,
  sheets that snap between heights, and layouts that adapt from phones to desktops.
- **Backup and restore** through WebDAV or a local file, plus password-encrypted backups in GitHub Gist and Gitee snippets.
- **Platform touches**: a Quick Settings tile, per-app proxy and Android TV support on Android; a tray menu and
  global hotkeys on the desktop.
- **Open source and ad-free**, licensed under GPL-3.0.

## Download

FlClashX packages are published through [this repository's Releases](https://github.com/Ive4/FlClashX/releases).
Available platforms and versions depend on the assets attached to each release. Pushing source code does not
by itself publish an installer. The table below describes build targets and package formats.

| Platform | Packages | Notes |
| --- | --- | --- |
| Android | APK for `arm64-v8a`, `armeabi-v7a` and `x86_64` | Most phones use `arm64-v8a`. |
| Windows 10 and later | Installer (`.exe`) or portable `.zip`, for x64 and ARM64 | Pick ARM64 on Snapdragon and other ARM laptops. |
| macOS 12 and later | DMG for Apple Silicon and Intel | Check the release assets for your architecture. |
| Linux | `.deb`, `.rpm` and AppImage, for x64 and ARM64 | See the tray note below. |
| HarmonyOS 7 / API 26 | ARM64 HAP | Experimental. Requires your own signing configuration; see [HarmonyOS](#harmonyos-experimental). |

<p>
  <a href="https://github.com/Ive4/FlClashX/releases"><img alt="Get FlClashX on GitHub" src="snapshots/get-it-on-github.svg" height="56"></a>
</p>

**Upstream distribution channels**

The F-Droid repository, Homebrew cask and [website](https://chen08209.github.io/FlClash) below distribute upstream FlClash.

<p>
  <a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" height="56"></a>
</p>

**Homebrew (upstream FlClash)**

```bash
brew tap chen08209/tap
brew install --cask flclash
```

**Linux tray icon**

The `.deb` package installs its own dependencies. With the AppImage or the `.rpm`, install the AyatanaAppIndicator
library so the tray icon can show:

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian and Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**Unattended desktop**

FlClashX starts the core only after the disclaimer is accepted. Where nobody can click it, such as a container, set
`FLCLASH_ACCEPT_DISCLAIMER=1` in the app's environment to accept it on first launch.

## Usage

**Import a profile from a link.** Opening a link in this form imports the subscription into FlClashX. The `clashmeta://`
and `flclash://` schemes work the same way.

```text
clash://install-config?url=<URL-encoded subscription link>
```

**Automate on Android.** Tasker, MacroDroid and similar apps can start, stop or toggle the proxy by starting an
activity with one of these actions:

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

From a computer, the same works over adb:

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## HarmonyOS (experimental)

The HarmonyOS port targets ARM64 phones and tablets running HarmonyOS 7 / API 26. A HAP has been built and
installed on an API 26 phone, and browser traffic through the VPN has been confirmed. Tablet behavior,
sustained background operation and the remaining native plugins still need validation and adaptation.

**Per-app VPN access control** accepts HarmonyOS bundle names without requiring a complete installed-app list:

- Allowlist mode: only the selected apps enter the VPN.
- Exclusion mode: selected apps bypass the VPN; other apps follow its routes.
- The two lists are mutually exclusive. Save changes and reconnect the VPN to apply them.

In Tools → Access control, enable the feature, choose a mode, then use the clipboard import action to add
one bundle name per line. Traffic entering FlClashX still follows the active Clash routing rules.
The allow/block fields are implemented, but their end-to-end behavior still needs device testing.
Automatic installed-app enumeration and UID-to-bundle lookup are restricted under the current normal signing.

**Application catalog:** [ohos_app_catalog.json](assets/data/ohos_app_catalog.json) stores application names
and HarmonyOS bundle names. It is a shared reference, not an inventory of apps installed on another device,
and is not yet connected to the app's selection screen.
With Python 3.9+ and `hdc` in `PATH`, update it from a USB-debugging device on Windows or macOS:

```sh
python3 tool/update_ohos_app_catalog.py
```

On Windows, `python` can be used instead of `python3`. Use `--hdc` to specify the executable, `--device` to
select a connected device, or `--csv` to export a spreadsheet. Updates merge by bundle name and retain
entries collected from other devices. See the [catalog guide](tool/ohos_app_catalog.md).

**Build:** the current build script runs on Windows and uses Harmony Flutter, Harmony Go, the DevEco API 26
SDK and the HarmonyOS Rust target. Prepare the local toolchains and signing files as described in the
[HarmonyOS build guide](ohos/README.md), then run from the repository root:

```powershell
powershell -File tool/build_ohos.ps1 -HarmonyHome "D:\Java\Huawei"
```

The signed output is `build/ohos/hap/entry-default-signed.hap`. Signing files and native build outputs
are excluded from Git. The Core submodule uses the `FlClash` branch of
[Ive4/Clash.Meta](https://github.com/Ive4/Clash.Meta/tree/FlClash); upstream update instructions are in the build guide.

## Build from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 (release builds use 3.47.6),
[Go](https://go.dev/dl/) 1.27 and [Rust](https://rustup.rs/) installed through rustup. Each platform builds on its own
host, except Android, which builds anywhere. HarmonyOS uses the separate toolchains and script described above.

```bash
git clone --recurse-submodules https://github.com/Ive4/FlClashX.git
cd FlClashX
flutter pub get
dart setup.dart android   # or windows, macos, linux
```

Packages land in `dist/`. The Go core and the Rust libraries are compiled as part of the Flutter build.

| Platform | Also needed |
| --- | --- |
| Android | Android SDK with the NDK. Add `--arch arm64` to build a single ABI. |
| Windows | GCC (MinGW-w64) for the core and [Inno Setup](https://jrsoftware.org/isinfo.php) 6 for the installer. |
| macOS | Xcode and Node.js. The script installs `appdmg` through npm. |
| Linux | Debian or Ubuntu. The script installs the build packages with apt and downloads `appimagetool`. |

Run `dart setup.dart --help` for the remaining options, such as `--targets` to build only some package formats.

## Support

Starring the repository is the easiest way to support the project. Report FlClashX bugs and feature requests
in [this repository's Issues](https://github.com/Ive4/FlClashX/issues). The
[FlClash Telegram channel](https://t.me/FlClash) belongs to the upstream project.

<a href="https://star-history.com/#Ive4/FlClashX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Ive4/FlClashX&type=Date&theme=dark">
    <img alt="Star history" src="https://api.star-history.com/svg?repos=Ive4/FlClashX&type=Date" width="640">
  </picture>
</a>

## License

FlClashX is released under the [GPL-3.0 license](LICENSE), retaining the upstream project's license and attribution.
