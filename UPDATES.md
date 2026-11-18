# FlClashX 自动更新

## 构建时指定自己的发布仓库

官方仓库仅用于同步源码，FlClashX 安装包必须发布到自己的公开 GitHub Releases。默认发布仓库为 `Ive4/FlClashX`，可用构建变量覆盖；不会回退到官方安装包。不在客户端保存 GitHub token。

```powershell
$env:FLCLASHX_UPDATE_REPOSITORY = 'Ive4/FlClashX'
dart setup.dart windows
```

直接调用 Flutter 构建时使用 `--dart-define=FLCLASHX_UPDATE_REPOSITORY=Ive4/FlClashX`。

## 准备正式发布包

在 `Ive4/FlClashX` 的 Actions 页面手动运行 **FlClashX stable artifacts**，选择包含要发布代码的分支或标签，再输入对应的 `vX.Y.Z` 或 `vX.Y.Z-buildN`。工作流验证 `pubspec.yaml` 的版本与构建号，生成 Windows x64/ARM64 安装包、三个 Android ABI 的已签名 APK 和一份 schema 1 清单。下载 `flclashx-stable-release-assets` 即可取得全部文件。工作流只生成 Actions 构件，正式 GitHub Release 由维护者另行创建。

Android 构建使用仓库的 `KEYSTORE`、`KEY_ALIAS`、`STORE_PASSWORD` 和 `KEY_PASSWORD` secrets，缺少任一项会停止构建。请沿用已发布 FlClashX Android 包的签名密钥，包名保持为 `com.follow.clash`。在本地配好 `android/app/keystore.jks` 和 `android/local.properties` 的现有签名配置后，可以设置 `FLCLASHX_ANDROID_UPDATER=true` 并运行 `dart setup.dart android --env stable --targets apk`。该开关只为已签名的 release 包加入安装权限与文件提供器，上游工作流仍使用自己的发布流程。

## 发布更新

1. 在 `pubspec.yaml` 保持所基于的官方公开版本，如 `0.9.3`，每次增强版发布递增 `+` 后的构建号，例如 `0.9.3+2026111801`。
2. 使用 Windows Inno Setup 安装包和按 ABI 拆分的已签名 Android APK。Android 文件名采用 `FlClashX-<版本>-android-<ABI>.apk`，支持 `armeabi-v7a`、`arm64-v8a` 和 `x86_64`。
3. 创建 GitHub Release。同一公开版本再次发布可使用不同标签，如 `v0.9.3-build2026111801`。界面版本仍显示 `0.9.3`。
4. 如需在本地生成清单，用实际安装包运行下列命令。标签需与 Release 完全一致。

```powershell
python tool/create_update_manifest.py --repository Ive4/FlClashX --tag v0.9.3-build2026111801 --windows-amd64 dist/FlClashX-0.9.3-windows-amd64-setup.exe --android-arm64-v8a dist/FlClashX-0.9.3-android-arm64-v8a.apk
```

将示例路径替换为实际安装包路径。还可以指定 `--windows-arm64`、`--android-armeabi-v7a` 和 `--android-x86_64`。清单为每个 Android APK 记录 Flutter 拆包生成的 `versionCode`，因此手动构建也应沿用 Flutter 的默认 ABI 偏移量与原有签名。

5. 将安装包与 `dist/flclashx-update.json` 一起上传到同一个 Release，并将其设为 Latest。客户端只读取已发布的正式 Latest。

## 更新行为

- 自动检查与关于页手动检查共用专属更新源，比较公开版本和内部构建号。
- 确认“下载并安装更新”后流式下载，显示进度，可取消。成功下载后校验大小和 SHA-256；失败不退出当前应用。

### Windows

- 保存配置与当前运行状态，启动隐藏的外部更新进程；应用正常退出并关闭核心后才执行安装器。
- 安装路径使用当前程序所在目录。Windows 可能弹出 UAC，不绕过系统授权。
- 安装结束后启动 FlClashX；更新前运行中的核心恢复运行，更新前已停止则保持停止，不修改长期自动启动偏好。
- 安装失败或 UAC 被取消时尝试重新启动原路径的应用。安装器日志保存在本次 `%TEMP%/FlClashX-update-*` 目录，失败详情为 `update-error.txt`。不承诺安装过程发生损坏后的自动回滚。
- 如果原应用 90 秒内没有退出，更新进程停止等待，不执行覆盖安装。

### Android

- 按当前应用进程的 ABI 选择 APK。交接前检查 APK 的包名、版本号和签名证书，要求与已安装的 FlClashX 签名一致。
- 校验通过后打开 Android 系统安装器。系统可能要求允许 FlClashX 安装未知应用，随后需要在安装器中确认更新。取消下载或安装会保留当前应用。
- 调试版、使用回退签名的开发版和没有启用更新权限的 Android 构建不提供应用内安装。

清单 SHA-256 校验用于检测下载损坏和不匹配，发布仓库的访问权限仍需由维护者管理。
