# GitHub / Gitee 配置同步

入口：设置 → 备份与恢复 → GitHub Gist / Gitee 代码片段。

## 首次配置 OAuth App

在 https://github.com/settings/applications/new 注册一个属于你的 OAuth App：

- Application name：`FlClashX`
- Homepage URL：`https://github.com/Ive4/FlClashX`
- Authorization callback URL：`https://github.com/Ive4/FlClashX`（设备授权流程不使用回调）
- 勾选 **Enable Device Flow**。

由项目维护者复制 **Client ID** 并配置到构建环境，不需要普通用户注册应用或填写 Client ID。不需要创建或填写 GitHub Client Secret，也不要将 Client Secret 放进客户端。

发布版本可以预置这个公开的 Client ID，让用户直接登录：

```powershell
$env:FLCLASHX_GITHUB_CLIENT_ID = '你的 Client ID'
dart setup.dart windows
```

直接 Flutter 构建时使用：

```powershell
flutter build windows --release --dart-define=FLCLASHX_GITHUB_CLIENT_ID=你的ClientID
```

GitHub Actions 发布构建读取同名仓库变量 `FLCLASHX_GITHUB_CLIENT_ID`。此设备授权接入使用默认的不过期令牌；若在 GitHub 应用设置中开启令牌过期，到期后需要重新授权。

## Gitee 浏览器授权

由项目维护者注册 Gitee OAuth 应用并部署授权服务，应用密钥仅保留在服务端。将服务的 HTTPS 地址配置到构建环境或 Actions 仓库变量 `FLCLASHX_GITEE_OAUTH_URL`，普通用户即可点击“浏览器授权登录”，在 Gitee 页面确认后自动连接。OAuth 令牌到期时使用安全存储中的刷新令牌续期。

完整的服务启动、回调地址、HTTPS 代理和发布配置见 [Gitee 授权服务说明](services/gitee_oauth/README.md)。未配置 OAuth 的构建会显示提示，仍可使用手动 Token 连接。

## 登录与同步

1. 点击“浏览器授权登录”，在默认浏览器中确认授权。GitHub 需输入窗口显示并已复制的短验证码，只请求 `gist` 权限；Gitee 请求 `gists` 和 `user_info` 权限。授权成功后自动保存会话，支持取消、重试和手动 Token 备用入口。
2. 上传前设置独立的备份密码并再次确认（至少 12 个字符）。不是 GitHub 登录密码。
3. 首次上传创建非公开 Gist；再次上传可选择覆盖或合并。
4. 其他设备登录同一 GitHub 账户后，可选择备份，选择覆盖或合并，再输入备份密码恢复。

| 操作 | 行为 | 冲突规则 |
| --- | --- | --- |
| 覆盖上传 | 用本地完整备份替换云端当前版本 | 本地为准，云端独有数据不保留 |
| 合并上传 | 在临时目录合并两份备份后上传，不改变本地运行数据 | 保留两边独有记录；同一内部 ID 的记录和文件以本地为准；使用本机应用设置 |
| 覆盖恢复 | 用备份替换本地配置、规则和设置，沿用现有恢复逻辑的设备兼容处理 | 云端为准，删除本地独有记录 |
| 合并恢复 | 导入云端数据，保留本地独有记录和本机应用设置 | 同一内部 ID 的记录和文件以云端为准 |

合并按内部 ID（关系记录按其复合键）处理，不按显示名称去重；同名不同 ID 的记录会同时保留。关系集合取并集，不同步删除。单个 YAML 文件整体替换，不自动合并其文本。合并上传使用云端现有密码，结果继续使用相同密码；若需换密码，可使用覆盖上传设置新密码。

这是手动上传/恢复，不在后台自动覆盖配置。写入前检查云端更新时间，但 Gist 不提供本功能可依赖的原子写锁，避免两台设备同时上传。首次并发上传可能生成多个备份，列表中可以选择。

## 压缩与加密

数据先打包为 TAR，再进行真正的 LZMA2 压缩并封装为标准 XZ，最后使用 AES-256-GCM 加密上传。不是对 ZIP 二次压缩。LZMA2 使用 16 MiB 字典，XZ 使用 CRC64 校验（读取兼容既有 CRC32 XZ 备份）。所有备份入口统一写入 `.tar.xz`；不再提供 ZIP 或 Zstandard 路径，也不读取旧 ZIP。请重新生成备份。已有 WebDAV 自定义文件名会保留，建议手动改为 `.tar.xz`。

加密格式为 `flclashx-backup.json` 的 schema 2：

- `compression: tar+xz`、`cipher: AES-256-GCM`。
- PBKDF2-HMAC-SHA256，600,000 次迭代，派生 256 位密钥。
- 每次加密生成新的 16 字节随机盐和 12 字节随机 nonce，使用 16 字节认证标签。
- 格式版本和算法声明作为认证附加数据；先通过认证解密，再解压导入。密码错误或内容损坏不写入本地配置。
- GitHub 仅接收密文和公开的加密参数，密码不上传、不持久化；每次操作需输入。忘记密码无法恢复。
- 非公开 Gist 的链接仍不应公开。新上传版本已加密，但覆盖不会清除 Gist 的历史版本；若以前上传过明文敏感信息，需要自行删除旧 Gist 并更换已暴露的凭据。
- XZ 压缩/解压、PBKDF2 密钥派生和 AES-GCM 加解密由 Go 统一实现；TAR 打包、JSON 编解码和上传合并在 Flutter 后台 isolate 执行。桌面端使用现有 Core 可执行文件的独立 `--backup-codec` 模式，经 stdin/stdout 传递数据和密码，不启动代理服务、不传递文件路径、不把密码放入命令行。Android 使用独立后台 MethodChannel 调用 Go 绑定，不依赖 VPN 服务启动。
- 压缩后备份上限 5 MiB，解压后的 TAR 上限 128 MiB。超过 GitHub 传输上限可使用本地备份或 WebDAV；这两种方式使用 XZ，但不添加 GitHub 同步层的密码加密。

GitHub OAuth 凭据继续保存在系统安全存储，不包含在备份中；退出登录只清除此设备的登录凭据，云端备份保留。撤销授权请打开 https://github.com/settings/applications 。令牌失效后重新登录。

## 开发与验证

`archive` 用于 TAR 打包；XZ 复用 Go 模块中的 `github.com/ulikunitz/xz`，加密使用 Go 标准库，不再依赖 Dart 的 `cryptography` 或 `koni_codecs`。

Windows 的 `flutter_secure_storage_windows` 通过本地 `plugins/secure_storage_windows` 覆盖：保留上游 4.2.2 的 Dart FFI/DPAPI 实现，去掉旧 C++ 插件注册和兼容读取，因此不再需要 ATL。`flutter pub get` 必须执行，以重新生成插件注册和 CMake 清单；不要手工修改 generated 文件或 pub cache。如果构建目录仍缓存旧插件，可执行 `flutter clean` 后重新 `flutter pub get`。

这不会免除 Flutter Windows 对 Visual Studio C++ Build Tools 和 Windows SDK 的要求。其他平台继续使用原安全存储：Android Keystore、macOS Keychain、Linux libsecret（Linux 需要可用的密钥环及 libsecret 开发库）。已有 DPAPI 记录继续可读；使用旧 Windows 原生存储的安装需要重新登录。

Go 编解码不依赖 CGO，四个平台使用相同的 XZ 和 schema 2 加密格式；手机与桌面可以互相恢复。仅支持单个 XZ 流中的 LZMA2 块，字典上限 16 MiB，展开大小上限 128 MiB，先预检块/分块大小，再进行校验解压。

```powershell
flutter pub get
go -C core test ./backupcodec
flutter analyze --no-fatal-infos
flutter test test/common/github_sync_test.dart test/common/backup_xz_test.dart test/common/backup_merge_test.dart test/common/backup_task_test.dart test/providers/backup_action_test.dart
```

测试覆盖 XZ 参考样本与真实压缩、加密往返/错误密码/篡改、合并冲突与覆盖策略、授权轮询/降频、取消/拒绝/过期、备份发现过滤、非公开上传、云端变化检查，以及 raw 下载的令牌隔离与地址限制。真实浏览器授权、系统安全存储和跨设备恢复仍需使用注册的 OAuth App 联调。

Flutter 测试会构建一个临时 Go 编解码程序，需要 `go` 在 PATH 上；使用 mise 时先进入项目的 Go 环境，也可通过 `FLCLASHX_TEST_GO` 指定 Go 可执行文件。测试不启动代理、不接触实际配置或系统凭据。

协议参考：
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
- https://docs.github.com/en/rest/gists/gists
- https://pub.dev/packages/flutter_secure_storage

- https://tukaani.org/xz/xz-file-format.txt
- https://pkg.go.dev/github.com/ulikunitz/xz
- https://pkg.go.dev/crypto/cipher
- https://pkg.go.dev/crypto/pbkdf2
