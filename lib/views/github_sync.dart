import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/github_sync.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/github_sync_strings.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class GitHubSyncSection extends StatefulWidget {
  const GitHubSyncSection({
    super.key, required this.onBackup, required this.onRestore,
  });
  final Future<void> Function(BackupDelivery, BackupFetch?) onBackup;
  final Future<void> Function(BackupFetch, RestoreStrategy) onRestore;

  @override
  State<GitHubSyncSection> createState() => _GitHubSyncSectionState();
}

class _GitHubSyncSectionState extends State<GitHubSyncSection> {
  static const _sessionKey = 'flclashx.github.session.v1';
  static const _clientIdKey = 'flclashx.github.clientId';
  final _storage = Platform.isMacOS
      ? const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        )
      : const FlutterSecureStorage();
  final _client = GitHubSyncClient();
  GitHubSession? _session;
  List<GitHubBackup> _backups = [];
  GitHubBackup? _selected;
  String _clientId = githubOAuthClientId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_run(_load));
    });
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _clientId = prefs.getString(_clientIdKey) ?? githubOAuthClientId;
    final stored = await _storage.read(key: _sessionKey);
    if (stored != null) {
      try {
        _session = GitHubSession.fromJson(jsonDecode(stored) as Map<String, dynamic>);
      } catch (_) {
        await _storage.delete(key: _sessionKey);
      }
    }
    if (_session != null) await _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() { _busy = true; _error = null; });
    final strings = GitHubSyncStrings(context);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = strings.error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final session = _session;
    if (session == null) return;
    final backups = await _client.list(session);
    final previous = _selected?.id;
    _backups = backups;
    _selected = backups.where((item) => item.id == previous).firstOrNull ??
        backups.firstOrNull;
  }

  Future<void> _signIn() async {
    if (_clientId.trim().isEmpty) {
      await _showSetup();
      return;
    }
    final session = await dialogs.showCommonDialog<GitHubSession>(
      context: context,
      child: _GitHubLoginDialog(clientId: _clientId.trim()),
    );
    if (session == null || !mounted) return;
    await _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));
    _session = session;
    _selected = null;
    await _refresh();
  }

  Future<void> _showSetup() async {
    final strings = GitHubSyncStrings(context);
    await dialogs.showCommonDialog<void>(
      context: context,
      child: Builder(builder: (dialogContext) => CommonDialog(
        title: strings.setup,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.appLocalizations.confirm),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.setupHelp),
            TextButton(
              onPressed: () async {
                await launchUrl(
                  Uri.parse('https://github.com/settings/applications/new'),
                  mode: LaunchMode.externalApplication,
                );
              },
              child: Text(strings.register),
            ),
          ],
        ),
      )),
    );
  }

  Future<void> _signOut() async {
    if (await dialogs.showMessage(
      title: GitHubSyncStrings(context).signOut,
      message: TextSpan(text: GitHubSyncStrings(context).logoutConfirm),
    ) != true || !mounted) return;
    await _storage.delete(key: _sessionKey);
    _session = null;
    _backups = [];
    _selected = null;
  }

  Future<RestoreStrategy?> _chooseMode({required bool upload}) {
    final strings = GitHubSyncStrings(context);
    return dialogs.showCommonDialog<RestoreStrategy>(
      context: context,
      child: Builder(builder: (dialogContext) => CommonDialog(
        title: upload ? strings.upload : strings.download,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListItem(
              title: Text(strings.merge),
              subtitle: Text(upload ? strings.mergeUpload : strings.mergeDownload),
              onTap: () => Navigator.of(dialogContext).pop(RestoreStrategy.compatible),
            ),
            ListItem(
              title: Text(strings.replace),
              subtitle: Text(upload ? strings.replaceUpload : strings.replaceDownload),
              onTap: () => Navigator.of(dialogContext).pop(RestoreStrategy.override),
            ),
          ],
        ),
      )),
    );
  }

  Future<String?> _password({required bool creating, required String message}) {
    return dialogs.showCommonDialog<String>(
      context: context,
      child: GitHubBackupPasswordDialog(creating: creating, message: message),
    );
  }

  Future<void> _upload() async {
    await _refresh();
    if (!mounted) return;
    final strings = GitHubSyncStrings(context);
    final session = _session!;
    final target = _selected;
    final mode = target == null ? RestoreStrategy.override :
        await _chooseMode(upload: true);
    if (mode == null || !mounted) return;
    final merge = mode == RestoreStrategy.compatible;
    final password = await _password(
      creating: true,
      message: [
        if (target != null) _backupLabel(target),
        target == null ? strings.newBackup :
            (merge ? strings.mergeUpload : strings.replaceUpload),
        if (merge) strings.mergePassword,
        strings.disclosure,
      ].join('\n\n'),
    );
    if (password == null || !mounted) return;
    await widget.onBackup((path) async {
      try {
        _selected = await _client.upload(session, path, target, password: password);
        _backups = [_selected!, ..._backups.where((b) => b.id != _selected!.id)];
        return true;
      } catch (error) {
        throw MessageException(strings.error(error));
      }
    }, merge ? (path) async {
      try {
        await _client.download(session, target!, path, password: password);
        return path;
      } catch (error) {
        throw MessageException(strings.error(error));
      }
    } : null);
  }

  Future<void> _download() async {
    await _refresh();
    if (!mounted) return;
    final target = _selected;
    if (target == null) return;
    final session = _session!;
    final strings = GitHubSyncStrings(context);
    final mode = await _chooseMode(upload: false);
    if (mode == null || !mounted) return;
    final password = await _password(
      creating: false,
      message: '${_backupLabel(target)}\n\n${mode == RestoreStrategy.compatible ? strings.mergeDownload : strings.replaceDownload}',
    );
    if (password == null || !mounted) return;
    await widget.onRestore((path) async {
      try {
        await _client.download(session, target, path, password: password);
        return path;
      } catch (error) {
        throw MessageException(strings.error(error));
      }
    }, mode);
  }

  String _backupLabel(GitHubBackup backup) =>
      '${backup.updatedAt.toLocal().toString().split('.').first} · ${backup.id}';

  Future<void> _choose() async {
    final backup = await dialogs.showCommonDialog<GitHubBackup>(
      context: context,
      child: Builder(builder: (dialogContext) => CommonDialog(
        title: GitHubSyncStrings(context).choose,
        child: SizedBox(
          height: 260,
          width: 300,
          child: ListView(children: [
            for (final backup in _backups)
              ListItem(
                title: Text(_backupLabel(backup)),
                onTap: () => Navigator.of(dialogContext).pop(backup),
              ),
          ]),
        ),
      )),
    );
    if (backup != null && mounted) setState(() => _selected = backup);
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context);
    return AbsorbPointer(
      absorbing: _busy,
      child: generateSection(
        title: strings.title,
        items: [
          ListItem(
            leading: const GlyphIcon(AppGlyphs.account),
            title: Text(_session?.login ?? 'GitHub'),
            subtitle: Text(_session == null ? strings.signedOut :
                (_selected == null ? strings.noBackup : _backupLabel(_selected!))),
            trailing: _busy
                ? const CommonCircleLoading(size: 20)
                : TonalButton(
                    label: _session == null ? strings.signIn : strings.signOut,
                    onPressed: () => _run(_session == null ? _signIn : _signOut),
                  ),
          ),
          if (_error != null) ListItem(
            title: Text(_error!, style: TextStyle(color: context.colorScheme.error)),
          ),
          if (_session == null) ...[
            ListItem.input(
              title: const Text('OAuth Client ID'),
              subtitle: Text(_clientId.isEmpty ? strings.setupHelp : _clientId),
              dialogTitle: 'OAuth Client ID', value: _clientId,
              resetValue: githubOAuthClientId,
              onChanged: (value) async {
                if (value == null) return;
                await _run(() async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(_clientIdKey, value.trim());
                  _clientId = value.trim();
                });
              },
            ),
            ListItem(title: Text(strings.setup), onTap: _showSetup),
          ] else ...[
            ListItem(title: Text(strings.refresh), onTap: () => _run(_refresh)),
            if (_backups.length > 1)
              ListItem(title: Text(strings.choose), onTap: _choose),
            ListItem(title: Text(strings.upload), onTap: () => _run(_upload)),
            if (_selected != null)
              ListItem(title: Text(strings.download), onTap: () => _run(_download)),
          ],
        ],
      ),
    );
  }
}

class _GitHubLoginDialog extends StatefulWidget {
  const _GitHubLoginDialog({required this.clientId});
  final String clientId;

  @override
  State<_GitHubLoginDialog> createState() => _GitHubLoginDialogState();
}

class _GitHubLoginDialogState extends State<_GitHubLoginDialog> {
  final _client = GitHubSyncClient();
  final _cancel = CancelToken();
  GitHubDeviceCode? _code;
  String? _error;
  bool _browserFailed = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_authorize());
    });
  }

  @override
  void dispose() {
    _cancel.cancel();
    _client.close();
    super.dispose();
  }

  Future<void> _openBrowser() async {
    try {
      final opened = await launchUrl(
        _code!.verificationUri, mode: LaunchMode.externalApplication,
      );
      if (mounted) setState(() => _browserFailed = !opened);
    } catch (_) {
      if (mounted) setState(() => _browserFailed = true);
    }
  }

  Future<void> _authorize() async {
    final strings = GitHubSyncStrings(context);
    try {
      final session = await _client.authorize(
        widget.clientId, cancel: _cancel,
        onCode: (code) async {
          if (!mounted) return;
          setState(() => _code = code);
          await _openBrowser();
        },
      );
      if (mounted) Navigator.of(context).pop(session);
    } catch (error) {
      if (mounted && !_cancel.isCancelled) {
        setState(() { _error = strings.error(error); _finished = true; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context);
    final l = context.appLocalizations;
    return CommonDialog(
      title: strings.signIn,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.cancel)),
        if (_code != null && !_finished)
          TextButton(onPressed: _openBrowser, child: Text(strings.browser)),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_code == null && !_finished) const CommonCircleLoading(size: 24),
          if (_code != null) ...[
            Text(strings.waiting),
            const SizedBox(height: 12),
            SelectableText(_code!.userCode, style: AppTextStyle.title2.of(context)),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _code!.userCode));
              },
              child: Text(l.copy),
            ),
          ] else if (!_finished) Text(strings.opening),
          if (_browserFailed) Text(strings.browserFailed),
          if (_error != null) Text(_error!),
        ],
      ),
    );
  }
}

class GitHubBackupPasswordDialog extends StatefulWidget {
  const GitHubBackupPasswordDialog({
    super.key, required this.creating, required this.message,
  });
  final bool creating;
  final String message;

  @override
  State<GitHubBackupPasswordDialog> createState() => _GitHubBackupPasswordDialogState();
}

class _GitHubBackupPasswordDialogState extends State<GitHubBackupPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context);
    final l = context.appLocalizations;
    return CommonDialog(
      title: widget.creating ? strings.encrypt : strings.decrypt,
      hasFields: true,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.cancel)),
        TextButton(onPressed: _submit, child: Text(l.confirm)),
      ],
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.message),
              const SizedBox(height: 12),
              SecretTextFormField(
                controller: _password,
                autofocus: true,
                maxLength: 1024,
                decoration: InputDecoration(labelText: strings.passwordLabel),
                validator: (value) {
                  final length = (value ?? '').runes.length;
                  if (length < (widget.creating ? 12 : 1) || length > 1024) {
                    return strings.passwordLength;
                  }
                  return null;
                },
                onFieldSubmitted: widget.creating ? null : (_) => _submit(),
              ),
              if (widget.creating) ...[
                const SizedBox(height: 8),
                SecretTextFormField(
                  controller: _confirmation,
                  maxLength: 1024,
                  decoration: InputDecoration(labelText: strings.confirmPassword),
                  validator: (value) => value == _password.text ? null : strings.passwordMismatch,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              const SizedBox(height: 12),
              Text(strings.passwordHelp),
            ],
          ),
        ),
      ),
    );
  }
}
