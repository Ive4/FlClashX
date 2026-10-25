import 'package:fl_clash/common/context.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/common/github_sync.dart';
import 'package:material_ui/material_ui.dart';

class GitHubSyncStrings {
  GitHubSyncStrings(
    BuildContext context, [
    this.service = SnippetService.github,
  ]) : _l = context.appLocalizations,
       _zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool _zh;
  final AppLocalizations _l;
  final SnippetService service;
  String get tokenHelp => _l.snippetTokenHelp;
  String get tokenLabel => _l.snippetToken;
  String _text(String zh, String en) => _zh ? zh : en;

  String get title =>
      service == SnippetService.github ? 'GitHub Gist' : _l.snippetGitee;
  String get signIn => _l.snippetConnect;
  String get signOut => _text('退出登录', 'Sign out');
  String get signedOut => _l.snippetSignedOut;
  String get upload => _l.snippetUpload;
  String get download => _l.snippetDownload;
  String get refresh => _text('刷新云端备份', 'Refresh cloud backups');
  String get noBackup => _text('暂无云端备份', 'No cloud backup yet');
  String get choose => _text('选择云端备份', 'Choose a cloud backup');
  String get uploaded =>
      _text('上传将替换所选云端备份。', 'Uploading replaces the selected cloud backup.');
  String get newBackup => _l.snippetNewBackup;
  String get disclosure => _l.snippetEncryptionHelp;
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
  String get mergePassword => _text(
    '请输入所选云端备份的密码，合并后继续使用此密码加密。',
    'Enter the selected cloud backup’s password. The merged backup uses the same password.',
  );
  String get encrypt => _text('加密并上传', 'Encrypt and upload');
  String get decrypt => _text('解密并恢复', 'Decrypt and restore');
  String get passwordLabel => _text('备份密码', 'Backup password');
  String get confirmPassword => _text('再次输入密码', 'Confirm password');
  String get passwordLength => _text(
    '加密密码至少 12 个字符，最多 1024 个字符。',
    'Use a password of 12 to 1024 characters.',
  );
  String get passwordMismatch =>
      _text('两次输入的密码不一致。', 'The passwords do not match.');
  String get passwordHelp => _l.snippetPasswordHelp;
  String get logoutConfirm => _l.snippetLogout;
  String get storageFailed => _text(
    '操作失败，请检查系统安全存储和网络后重试。',
    'Operation failed. Check system secure storage and your connection, then retry.',
  );

  String error(Object error) {
    if (error is! GitHubSyncException) return storageFailed;
    return switch (error.failure) {
      GitHubSyncFailure.password => passwordLength,
      GitHubSyncFailure.decryption => _text(
        '密码错误或备份已损坏，未恢复任何数据。',
        'Wrong password or damaged backup. Nothing was restored.',
      ),
      GitHubSyncFailure.network => _l.snippetNetworkError,
      GitHubSyncFailure.unauthorized => _text(
        '登录已失效，请退出后重新登录。',
        'Session expired. Sign out and sign in again.',
      ),
      GitHubSyncFailure.forbidden => _l.snippetPermissionError,
      GitHubSyncFailure.expired => _text(
        '验证码已过期，请重新登录。',
        'The code expired. Sign in again.',
      ),
      GitHubSyncFailure.denied => _text(
        '你已取消 GitHub 授权。',
        'GitHub authorization was declined.',
      ),
      GitHubSyncFailure.clientId => _text(
        '请检查 Client ID，并在 OAuth App 中启用 Device Flow。',
        'Check the Client ID and enable Device Flow in your OAuth App.',
      ),
      GitHubSyncFailure.invalidBackup => _text(
        '云端备份无效或校验失败，未恢复任何数据。',
        'Invalid cloud backup or checksum mismatch. Nothing was restored.',
      ),
      GitHubSyncFailure.tooLarge => _text(
        '备份超过 5 MiB，请使用本地备份或 WebDAV。',
        'The backup exceeds 5 MiB. Use local backup or WebDAV.',
      ),
      GitHubSyncFailure.changed => _text(
        '云端备份已变化，请刷新后重新确认。',
        'The cloud backup changed. Refresh and confirm again.',
      ),
      GitHubSyncFailure.missing => _text(
        '云端备份不存在或无权访问，请刷新。',
        'The cloud backup is missing or inaccessible. Refresh the list.',
      ),
    };
  }
}
