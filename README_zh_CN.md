FlClashX 基于 [FlClash](https://github.com/chen08209/FlClash) 持续进行功能增强与优化，并提供实验性的鸿蒙适配。公开版本跟随所基于的上游版本，以 `pubspec.yaml` 为版本来源。主仓库为 [Ive4/FlClashX](https://github.com/Ive4/FlClashX)，内核仓库为 [Ive4/Clash.Meta](https://github.com/Ive4/Clash.Meta)。同步方式见 [上游同步约定](UPSTREAM.md)。

<div align="center">

<img src="assets/images/icon.png" alt="FlClashX" width="88">

# FlClashX

基于 ClashMeta 的多平台代理客户端，简单易用，开源无广告。

[English](README.md) · **简体中文**

[![Release](https://img.shields.io/github/v/release/Ive4/FlClashX?style=flat-square&label=release)](https://github.com/Ive4/FlClashX/releases)
[![Downloads](https://img.shields.io/github/downloads/Ive4/FlClashX/total?style=flat-square&logo=github)](https://github.com/Ive4/FlClashX/releases)
[![License](https://img.shields.io/github/license/Ive4/FlClashX?style=flat-square)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-upstream_channel-26A5E4?style=flat-square&logo=telegram&logoColor=white)](https://t.me/FlClash)

[项目仓库](https://github.com/Ive4/FlClashX) · [下载](#下载) · [鸿蒙适配](#鸿蒙适配实验性) · [更新日志](CHANGELOG.md) · [从源码构建](#从源码构建)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash 在 MacBook 与手机上的仪表盘" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## 功能

- **一个应用覆盖 Android、Windows、macOS 和 Linux**，桌面端同时提供 x64 与 ARM64 版本。
- **实验性的 HarmonyOS 7 适配**：面向 ARM64 设备，提供原生 HAP 构建和 VPN 集成，使用前请查看[当前限制](#鸿蒙适配实验性)。
- **mihomo（Clash.Meta）内核**：规则分流、代理组、延迟测试、系统代理与 TUN 模式。
- **配置管理**：通过订阅链接或文件导入配置，内置编辑器，支持覆写脚本以及自定义规则、代理和代理组。
- **实时查看**连接、请求、DNS 查询和日志。
- **Material You 设计，融合 Apple 式交互**：支持动态取色、浅色与深色主题，连续曲率圆角，弹出面板可在几档高度间吸附，布局随屏幕从手机到桌面自适应。
- **备份与恢复**：通过 WebDAV 或本地文件，也支持将密码加密后的备份同步到 GitHub Gist 和 Gitee 代码片段。
- **平台细节**：Android 上有快捷设置磁贴、分应用代理和 Android TV 支持；桌面端有托盘菜单和全局快捷键。
- **开源无广告**，以 GPL-3.0 协议发布。

## 下载

FlClashX 安装包通过[本仓库 Releases](https://github.com/Ive4/FlClashX/releases) 发布。
可下载的平台和版本以每次发布的实际附件为准；推送源码本身不会生成或发布安装包。下表列出构建目标和安装包格式。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| Android | `arm64-v8a`、`armeabi-v7a`、`x86_64` 三种 APK | 绝大多数手机选 `arm64-v8a`。 |
| Windows 10 及以上 | 安装版（`.exe`）或便携版（`.zip`），分 x64 与 ARM64 | 骁龙等 ARM 架构笔记本选 ARM64。 |
| macOS 12 及以上 | Apple Silicon 与 Intel 两种 DMG | 按发布附件选择对应架构。 |
| Linux | `.deb`、`.rpm` 和 AppImage，分 x64 与 ARM64 | 托盘依赖见下方说明。 |
| HarmonyOS 7 / API 26 | ARM64 HAP | 实验性支持，需要配置自己的签名，见[鸿蒙适配](#鸿蒙适配实验性)。 |

<p>
  <a href="https://github.com/Ive4/FlClashX/releases"><img alt="Get FlClashX on GitHub" src="snapshots/get-it-on-github.svg" height="56"></a>
</p>

**上游分发渠道**

下方的 F-Droid 仓库、Homebrew cask 和[上游官网](https://chen08209.github.io/FlClash/zh)分发的是上游 FlClash。

<p>
  <a href="https://chen08209.github.io/FlClash-fdroid-repo/repo?fingerprint=789D6D32668712EF7672F9E58DEEB15FBD6DCEEC5AE7A4371EA72F2AAE8A12FD"><img alt="Get it on F-Droid" src="snapshots/get-it-on-fdroid.svg" height="56"></a>
</p>

**Homebrew（上游 FlClash）**

```bash
brew tap chen08209/tap
brew install --cask flclash
```

**Linux 托盘图标**

`.deb` 安装包会自动安装所需依赖。使用 AppImage 或 `.rpm` 时，需要先安装 AyatanaAppIndicator 库，托盘图标才能显示：

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian 与 Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**无人值守的桌面环境**

FlClashX 要在免责声明被接受后才会启动核心。在容器等无人点击的环境里，可在应用的环境变量中设置
`FLCLASH_ACCEPT_DISCLAIMER=1`，首次启动时即视为接受。

## 使用

**通过链接导入配置。** 打开下面格式的链接，即可把订阅导入 FlClashX。`clashmeta://` 和 `flclash://` 开头的链接同样可用。

```text
clash://install-config?url=<经过 URL 编码的订阅链接>
```

**Android 自动化。** Tasker、MacroDroid 等应用可以用下面的 Action 启动 Activity，从而启动、停止或切换代理：

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

在电脑上也可以通过 adb 触发：

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## 鸿蒙适配（实验性）

鸿蒙版本面向 HarmonyOS 7 / API 26 的 ARM64 手机和平板。目前已在 API 26 手机上完成 HAP 构建、
安装及浏览器经 VPN 访问的验证；平板适配、长期后台运行和其余原生插件仍需验证与完善。

**分应用 VPN 访问控制**可以直接使用鸿蒙包名，不依赖获取完整的已安装应用列表：

- 白名单模式：只有选中的应用进入 VPN。
- 排除模式：选中的应用绕过 VPN，其余应用按 VPN 路由处理。
- 两种名单互斥，保存修改后重新连接 VPN 生效。

在“工具 → 应用访问控制”中开启功能、选择模式，再通过“剪贴板导入”添加包名，每行一个。
进入 FlClashX 的流量仍会执行当前 Clash 分流规则。允许／排除名单字段已接入，实际按应用分流效果仍需真机验证。
当前普通签名下，完整应用列表读取及 UID 到包名的查询受到限制。

**应用包名目录：**[ohos_app_catalog.json](assets/data/ohos_app_catalog.json) 保存应用名称和鸿蒙包名，
供查询与维护。它不代表其他设备实际安装了这些应用，目前也尚未接入应用选择界面。
安装 Python 3.9+、将 `hdc` 加入 `PATH` 后，可在 Windows 或 macOS 上连接开启 USB 调试的鸿蒙设备更新：

```sh
python3 tool/update_ohos_app_catalog.py
```

Windows 可以使用 `python` 替代 `python3`。通过 `--hdc` 指定工具路径、`--device` 选择连接的设备，
或通过 `--csv` 导出表格。脚本按包名合并更新，保留其他设备采集过的条目，详见[目录维护说明](tool/ohos_app_catalog.md)。

**构建：**当前构建脚本面向 Windows，需要鸿蒙 Flutter、鸿蒙 Go、DevEco API 26 SDK 及鸿蒙 Rust 目标。
按照[鸿蒙构建说明](ohos/README.md)准备本机工具链和签名文件后，在项目根目录执行：

```powershell
powershell -File tool/build_ohos.ps1 -HarmonyHome "D:\Java\Huawei"
```

签名后的产物为 `build/ohos/hap/entry-default-signed.hap`。签名文件与原生构建产物已从 Git 排除。
内核子模块使用 [Ive4/Clash.Meta](https://github.com/Ive4/Clash.Meta/tree/FlClash) 的 `FlClash` 分支，
内核上游同步步骤见鸿蒙构建说明。

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) 3.47（正式版构建使用 3.47.6）、[Go](https://go.dev/dl/) 1.27，
以及通过 rustup 安装的 [Rust](https://rustup.rs/)。桌面端需要在对应系统上构建，Android 在任意系统上都能构建。
鸿蒙版本使用上方单独说明的工具链与脚本。

```bash
git clone --recurse-submodules https://github.com/Ive4/FlClashX.git
cd FlClashX
flutter pub get
dart setup.dart android   # 或 windows、macos、linux
```

安装包输出到 `dist/`。Go 内核和 Rust 库会在 Flutter 构建过程中一并编译。

| 平台 | 额外依赖 |
| --- | --- |
| Android | 带 NDK 的 Android SDK。加上 `--arch arm64` 可以只构建单个 ABI。 |
| Windows | 编译内核用的 GCC（MinGW-w64），以及打包安装程序用的 [Inno Setup](https://jrsoftware.org/isinfo.php) 6。 |
| macOS | Xcode 与 Node.js。脚本会通过 npm 安装 `appdmg`。 |
| Linux | Debian 或 Ubuntu。脚本会用 apt 安装构建所需的软件包，并下载 `appimagetool`。 |

其余选项可以运行 `dart setup.dart --help` 查看，例如用 `--targets` 只构建部分安装包格式。

## 支持

给仓库点一个 Star 是支持项目最简单的方式。FlClashX 的 Bug 与功能建议请提交到
[本仓库 Issues](https://github.com/Ive4/FlClashX/issues)。[FlClash Telegram 频道](https://t.me/FlClash)属于上游项目。

<a href="https://star-history.com/#Ive4/FlClashX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Ive4/FlClashX&type=Date&theme=dark">
    <img alt="Star history" src="https://api.star-history.com/svg?repos=Ive4/FlClashX&type=Date" width="640">
  </picture>
</a>

## 许可证

FlClashX 以 [GPL-3.0 协议](LICENSE)发布，保留上游项目的许可证与署名。
