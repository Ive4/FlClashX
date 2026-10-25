# FlClashX 自动更新（Windows）

## 构建时指定自己的发布仓库

官方仓库仅用于同步源码，FlClashX 安装包必须发布到自己的公开 GitHub Releases。默认发布仓库为 `Ive4/FlClashX`，可用构建变量覆盖；不会回退到官方安装包。不在客户端保存 GitHub token。

```powershell
$env:FLCLASHX_UPDATE_REPOSITORY = 'Ive4/FlClashX'
dart setup.dart windows
```

直接调用 Flutter 构建时使用 `--dart-define=FLCLASHX_UPDATE_REPOSITORY=Ive4/FlClashX`。

## 发布更新

1. 在 `pubspec.yaml` 保持所基于的官方公开版本，如 `0.9.2`；每次增强版发布递增 `+` 后的构建号，例如 `0.9.2+2026102501`。
2. 构建目标架构的 Inno Setup EXE 安装包。不能将 ZIP、普通主程序 EXE 或官方安装包作为更新安装器。
3. 创建 GitHub Release；同一公开版本再次发布可使用不同标签，如 `v0.9.2-build2026102501`。界面版本仍显示 `0.9.2`。
4. 用实际安装包生成清单，标签需与 Release 完全一致：

```powershell
python tool/create_update_manifest.py --repository Ive4/FlClashX --tag v0.9.2-build2026102501 --windows-amd64 dist/FlClashX-0.9.2-windows-amd64-setup.exe
```

将示例路径替换为实际安装包路径。ARM64 包可同时通过 `--windows-arm64` 指定；只生成一份包含全部架构的清单。

5. 将安装包与 `dist/flclashx-update.json` 一起上传到同一个 Release，并将其设为 Latest。客户端只读取已发布的正式 Latest，不安装草稿或预发布版。原仓库 CI 的发布条件仍限定官方仓库，自有发布流水线需另外配置。

## 更新行为

- 自动检查与关于页手动检查共用专属更新源，比较公开版本和内部构建号。
- 确认“下载并安装更新”后流式下载，显示进度，可取消。成功下载后校验大小和 SHA-256；失败不退出当前应用。
- 保存配置与当前运行状态，启动隐藏的外部更新进程；应用正常退出并关闭核心后才执行安装器。
- 安装路径使用当前程序所在目录。Windows 可能弹出 UAC，不绕过系统授权。
- 安装结束后启动 FlClashX；更新前运行中的核心恢复运行，更新前已停止则保持停止，不修改长期自动启动偏好。
- 安装失败或 UAC 被取消时尝试重新启动原路径的应用。安装器日志保存在本次 `%TEMP%/FlClashX-update-*` 目录，失败详情为 `update-error.txt`。不承诺安装过程发生损坏后的自动回滚。
- 如果原应用 90 秒内没有退出，更新进程停止等待，不执行覆盖安装。
- 当前自动安装仅支持 Windows x64/ARM64；其他平台明确提示暂不支持。

清单 SHA-256 校验用于检测下载损坏和不匹配，发布仓库的访问权限仍需由维护者管理。
