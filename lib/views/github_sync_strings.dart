import 'package:fl_clash/common/github_sync.dart';
import 'package:material_ui/material_ui.dart';

class GitHubSyncStrings {
  GitHubSyncStrings(BuildContext context)
    : _zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool _zh;
  String _text(String zh, String en) => _zh ? zh : en;

  String get title => _text('GitHub 同步', 'GitHub sync');
  String get signIn => _text('使用浏览器登录', 'Sign in with browser');
  String get signOut => _text('退出登录', 'Sign out');
  String get signedOut => _text('登录 GitHub，在设备之间同步配置', 'Sign in to sync settings between devices');
  String get upload => _text('上传到 GitHub', 'Upload to GitHub');
  String get download => _text('从 GitHub 恢复', 'Restore from GitHub');
  String get refresh => _text('刷新云端备份', 'Refresh cloud backups');
  String get noBackup => _text('暂无云端备份', 'No cloud backup yet');
  String get choose => _text('选择云端备份', 'Choose a cloud backup');
  String get uploaded => _text('上传将替换所选云端备份。', 'Uploading replaces the selected cloud backup.');
  String get newBackup => _text('将在你的 GitHub 账户中创建非公开 Gist。', 'A secret Gist will be created in your GitHub account.');
  String get disclosure => _text(
    '备份会先整体压缩为 XZ，再使用密码加密上传。密码不会上传到 GitHub，也不会保存在本机；忘记密码将无法恢复。',
    'The backup is compressed as XZ, then password-encrypted before upload. Your password is not uploaded or saved on this device. It cannot be recovered if forgotten.',
  );
  String get merge => _text('合并', 'Merge');
  String get replace => _text('覆盖', 'Replace');
  String get mergeUpload => _text(
    '保留云端独有记录，同一 ID 的记录和文件以本地为准。本机设置上传到云端，本地数据不变。',
    'Keep cloud-only records. Local records and files win for the same ID. Upload local settings; local data stays unchanged.',
  );
  String get replaceUpload => _text(
    '用本地完整备份替换云端当前版本，云端独有记录不保留。',
    'Replace the current cloud backup with the complete local backup. Cloud-only records are not retained.',
  );
  String get mergeDownload => _text(
    '保留本地独有记录，同一 ID 的记录和文件以云端为准。保留本机应用设置，不拼接同一份 YAML 文件。',
    'Keep local-only records. Cloud records and files win for the same ID. Keep this device’s app settings; individual YAML files are not combined.',
  );
  String get replaceDownload => _text(
    '用云端备份覆盖本地配置、规则和应用设置，本地独有记录将被移除。建议先导出本地备份。',
    'Replace local profiles, rules and app settings with the cloud backup. Local-only records are removed. Export a local backup first.',
  );
  String get mergePassword => _text('请输入所选云端备份的密码，合并后继续使用此密码加密。', 'Enter the selected cloud backup’s password. The merged backup uses the same password.');
  String get encrypt => _text('加密并上传', 'Encrypt and upload');
  String get decrypt => _text('解密并恢复', 'Decrypt and restore');
  String get passwordLabel => _text('备份密码', 'Backup password');
  String get confirmPassword => _text('再次输入密码', 'Confirm password');
  String get passwordLength => _text('加密密码至少 12 个字符，最多 1024 个字符。', 'Use a password of 12 to 1024 characters.');
  String get passwordMismatch => _text('两次输入的密码不一致。', 'The passwords do not match.');
  String get passwordHelp => _text('这是独立的备份密码，不是 GitHub 密码。请使用密码管理器妥善保存。', 'This is a separate backup password, not your GitHub password. Keep it in your password manager.');
  String get logoutConfirm => _text(
    '清除此设备的登录凭据，云端备份将保留。如需撤销授权，可在 GitHub 的 Authorized OAuth Apps 中操作。',
    'Remove the credentials from this device? Cloud backups are kept. You can revoke access in GitHub’s Authorized OAuth Apps settings.',
  );
  String get setup => _text('配置 GitHub 登录', 'Configure GitHub sign-in');
  String get setupHelp => _text(
    '首次使用需注册 GitHub OAuth App，启用 Enable Device Flow，然后填入 Client ID。无需 Client Secret。',
    'Register a GitHub OAuth App, enable Device Flow and enter its Client ID. No Client Secret is needed.',
  );
  String get register => _text('打开 GitHub 注册页面', 'Open GitHub app registration');
  String get waiting => _text('在浏览器中输入以下验证码并授权，完成后此窗口将自动关闭。', 'Enter this code in your browser and authorize. This window closes when sign-in completes.');
  String get opening => _text('正在请求 GitHub 授权…', 'Requesting GitHub authorization…');
  String get browser => _text('打开浏览器', 'Open browser');
  String get browserFailed => _text('无法自动打开浏览器，请手动访问 https://github.com/login/device。', 'Could not open the browser. Visit https://github.com/login/device manually.');
  String get storageFailed => _text('操作失败，请检查系统安全存储和网络后重试。', 'Operation failed. Check system secure storage and your connection, then retry.');

  String error(Object error) {
    if (error is! GitHubSyncException) return storageFailed;
    return switch (error.failure) {
      GitHubSyncFailure.password => passwordLength,
      GitHubSyncFailure.decryption => _text('密码错误或备份已损坏，未恢复任何数据。', 'Wrong password or damaged backup. Nothing was restored.'),
      GitHubSyncFailure.network => _text('无法连接 GitHub，请检查网络或代理后重试。', 'Cannot reach GitHub. Check your connection or proxy and retry.'),
      GitHubSyncFailure.unauthorized => _text('登录已失效，请退出后重新登录。', 'Session expired. Sign out and sign in again.'),
      GitHubSyncFailure.forbidden => _text('GitHub 权限不足或请求过于频繁，请检查 gist 授权或稍后重试。', 'GitHub denied access or rate limited the request. Check gist permission or retry later.'),
      GitHubSyncFailure.expired => _text('验证码已过期，请重新登录。', 'The code expired. Sign in again.'),
      GitHubSyncFailure.denied => _text('你已取消 GitHub 授权。', 'GitHub authorization was declined.'),
      GitHubSyncFailure.clientId => _text('请检查 Client ID，并在 OAuth App 中启用 Device Flow。', 'Check the Client ID and enable Device Flow in your OAuth App.'),
      GitHubSyncFailure.invalidBackup => _text('云端备份无效或校验失败，未恢复任何数据。', 'Invalid cloud backup or checksum mismatch. Nothing was restored.'),
      GitHubSyncFailure.tooLarge => _text('备份超过 5 MiB，请使用本地备份或 WebDAV。', 'The backup exceeds 5 MiB. Use local backup or WebDAV.'),
      GitHubSyncFailure.changed => _text('云端备份已变化，请刷新后重新确认。', 'The cloud backup changed. Refresh and confirm again.'),
      GitHubSyncFailure.missing => _text('云端备份不存在或无权访问，请刷新。', 'The cloud backup is missing or inaccessible. Refresh the list.'),
    };
  }
}
