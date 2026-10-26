import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/github_sync.dart';
import 'package:fl_clash/common/secure_storage.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/github_sync_strings.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class GitHubSyncSection extends StatefulWidget {
  const GitHubSyncSection({
    super.key,
    required this.onBackup,
    required this.onRestore,
    this.service = SnippetService.github,
    this.client,
    this.launchBrowser,
  });
  final SnippetService service;
  final GitHubSyncClient? client;
  final Future<bool> Function(Uri)? launchBrowser;
  final Future<void> Function(BackupDelivery, BackupFetch?) onBackup;
  final Future<void> Function(BackupFetch, RestoreStrategy) onRestore;

  @override
  State<GitHubSyncSection> createState() => _GitHubSyncSectionState();
}

class _GitHubSyncSectionState extends State<GitHubSyncSection> {
  String get _sessionKey => 'flclashx.${widget.service.name}.session.v1';
  final _storage = SessionStorage();
  late final _client =
      widget.client ?? GitHubSyncClient(service: widget.service);
  GitHubSession? _session;
  List<GitHubBackup> _backups = [];
  GitHubBackup? _selected;
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
    final stored = await _storage.read(key: _sessionKey);
    if (stored != null) {
      try {
        _session = GitHubSession.fromJson(
          jsonDecode(stored) as Map<String, dynamic>,
        );
      } catch (_) {
        await _storage.delete(key: _sessionKey);
      }
    }
    if (_session != null) await _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final strings = GitHubSyncStrings(context, widget.service);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = strings.error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final current = _session;
    if (current == null) return;
    final session = await _client.refreshSession(current);
    if (!mounted) return;
    if (!identical(session, current)) {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toJson()),
      );
      if (!mounted) return;
      _session = session;
    }
    final backups = await _client.list(session);
    if (!mounted) return;
    final previous = _selected?.id;
    _backups = backups;
    _selected =
        backups.where((item) => item.id == previous).firstOrNull ??
        backups.firstOrNull;
  }

  Future<void> _signIn() async {
    final result = await dialogs.showCommonDialog<Object>(
      context: context,
      child: _SnippetAuthorizationDialog(
        client: _client,
        launchBrowser: widget.launchBrowser,
      ),
    );
    if (!mounted) return;
    if (result == _SnippetSignInAction.token) {
      await _signInWithToken();
    } else if (result is GitHubSession) {
      await _run(() => _saveSession(result));
    }
  }

  Future<void> _signInWithToken() async {
    final token = await dialogs.showCommonDialog<String>(
      context: context,
      child: _SnippetTokenDialog(service: widget.service),
    );
    if (token == null || !mounted) return;
    await _run(() async {
      final session = await _client.signInWithToken(token);
      if (!mounted) return;
      await _saveSession(session);
    });
  }

  Future<void> _saveSession(GitHubSession session) async {
    final backups = await _client.list(session);
    if (!mounted) return;
    await _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));
    if (!mounted) return;
    _session = session;
    _backups = backups;
    _selected = backups.firstOrNull;
  }

  Future<void> _signOut() async {
    if (await dialogs.showMessage(
              title: GitHubSyncStrings(context, widget.service).signOut,
              message: TextSpan(
                text: GitHubSyncStrings(context, widget.service).logoutConfirm,
              ),
            ) !=
            true ||
        !mounted) {
      return;
    }
    await _storage.delete(key: _sessionKey);
    _session = null;
    _backups = [];
    _selected = null;
  }

  Future<RestoreStrategy?> _chooseMode({required bool upload}) {
    final strings = GitHubSyncStrings(context, widget.service);
    return dialogs.showCommonDialog<RestoreStrategy>(
      context: context,
      child: Builder(
        builder: (dialogContext) => CommonDialog(
          title: upload ? strings.upload : strings.download,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListItem(
                title: Text(strings.merge),
                subtitle: Text(
                  upload ? strings.mergeUpload : strings.mergeDownload,
                ),
                onTap: () =>
                    Navigator.of(dialogContext).pop(RestoreStrategy.compatible),
              ),
              ListItem(
                title: Text(strings.replace),
                subtitle: Text(
                  upload ? strings.replaceUpload : strings.replaceDownload,
                ),
                onTap: () =>
                    Navigator.of(dialogContext).pop(RestoreStrategy.override),
              ),
            ],
          ),
        ),
      ),
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
    final strings = GitHubSyncStrings(context, widget.service);
    final session = _session!;
    final target = _selected;
    final mode = target == null
        ? RestoreStrategy.override
        : await _chooseMode(upload: true);
    if (mode == null || !mounted) return;
    final merge = mode == RestoreStrategy.compatible;
    final password = await _password(
      creating: true,
      message: [
        if (target != null) _backupLabel(target),
        target == null
            ? strings.newBackup
            : (merge ? strings.mergeUpload : strings.replaceUpload),
        if (merge) strings.mergePassword,
        strings.disclosure,
      ].join('\n\n'),
    );
    if (password == null || !mounted) return;
    await widget.onBackup(
      (path) async {
        try {
          _selected = await _client.upload(
            session,
            path,
            target,
            password: password,
          );
          _backups = [
            _selected!,
            ..._backups.where((b) => b.id != _selected!.id),
          ];
          return true;
        } catch (error) {
          throw MessageException(strings.error(error));
        }
      },
      merge
          ? (path) async {
              try {
                await _client.download(
                  session,
                  target!,
                  path,
                  password: password,
                );
                return path;
              } catch (error) {
                throw MessageException(strings.error(error));
              }
            }
          : null,
    );
  }

  Future<void> _download() async {
    await _refresh();
    if (!mounted) return;
    final target = _selected;
    if (target == null) return;
    final session = _session!;
    final strings = GitHubSyncStrings(context, widget.service);
    final mode = await _chooseMode(upload: false);
    if (mode == null || !mounted) return;
    final password = await _password(
      creating: false,
      message:
          '${_backupLabel(target)}\n\n${mode == RestoreStrategy.compatible ? strings.mergeDownload : strings.replaceDownload}',
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
      child: Builder(
        builder: (dialogContext) => CommonDialog(
          title: GitHubSyncStrings(context, widget.service).choose,
          child: SizedBox(
            height: 260,
            width: 300,
            child: ListView(
              children: [
                for (final backup in _backups)
                  ListItem(
                    title: Text(_backupLabel(backup)),
                    onTap: () => Navigator.of(dialogContext).pop(backup),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (backup != null && mounted) setState(() => _selected = backup);
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context, widget.service);
    return AbsorbPointer(
      absorbing: _busy,
      child: generateSection(
        title: strings.title,
        items: [
          ListItem(
            leading: const GlyphIcon(AppGlyphs.account),
            title: Text(_session?.login ?? strings.title),
            subtitle: Text(
              _session == null
                  ? strings.signedOut
                  : (_selected == null
                        ? strings.noBackup
                        : _backupLabel(_selected!)),
            ),
            trailing: _busy
                ? const CommonCircleLoading(size: 20)
                : TonalButton(
                    label: _session == null ? strings.signIn : strings.signOut,
                    onPressed: _session == null
                        ? _signIn
                        : () => _run(_signOut),
                  ),
          ),
          if (_error != null)
            ListItem(
              title: Text(
                _error!,
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          if (_session != null) ...[
            ListItem(title: Text(strings.refresh), onTap: () => _run(_refresh)),
            if (_backups.length > 1)
              ListItem(title: Text(strings.choose), onTap: _choose),
            ListItem(title: Text(strings.upload), onTap: () => _run(_upload)),
            if (_selected != null)
              ListItem(
                title: Text(strings.download),
                onTap: () => _run(_download),
              ),
          ],
        ],
      ),
    );
  }
}

enum _SnippetSignInAction { token }

class _SnippetAuthorizationDialog extends StatefulWidget {
  const _SnippetAuthorizationDialog({required this.client, this.launchBrowser});
  final GitHubSyncClient client;
  final Future<bool> Function(Uri)? launchBrowser;

  @override
  State<_SnippetAuthorizationDialog> createState() =>
      _SnippetAuthorizationDialogState();
}

class _SnippetAuthorizationDialogState
    extends State<_SnippetAuthorizationDialog> {
  CancelToken? _cancel;
  GitHubDeviceCode? _code;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.client.browserAuthorizationAvailable) {
        unawaited(_authorize());
      }
    });
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _openBrowser(Uri uri) async {
    final opened =
        await (widget.launchBrowser?.call(uri) ??
            launchUrl(uri, mode: LaunchMode.externalApplication));
    if (!opened) {
      throw const GitHubSyncException(GitHubSyncFailure.browser);
    }
  }

  Future<void> _authorize() async {
    if (_working) return;
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      _working = true;
      _error = null;
      _code = null;
    });
    final strings = GitHubSyncStrings(context, widget.client.service);
    try {
      final session = await widget.client.authorize(
        widget.client.githubClientId,
        cancel: cancel,
        onCode: (code) async {
          if (!mounted || cancel.isCancelled) return;
          setState(() => _code = code);
          if (code.userCode.isNotEmpty) {
            await Clipboard.setData(ClipboardData(text: code.userCode));
          }
          if (!mounted || cancel.isCancelled) return;
          await _openBrowser(code.verificationUri);
        },
      );
      if (mounted && !cancel.isCancelled) Navigator.of(context).pop(session);
    } catch (error) {
      if (mounted && !cancel.isCancelled) {
        setState(() => _error = strings.error(error));
      }
    } finally {
      cancel.cancel();
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context, widget.client.service);
    final l = context.appLocalizations;
    final available = widget.client.browserAuthorizationAvailable;
    final code = _code;
    return CommonDialog(
      title: strings.signIn,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        if (available && !_working)
          TextButton(onPressed: _authorize, child: Text(l.retry)),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(available ? l.snippetBrowserHelp : l.snippetOAuthUnavailable),
          if (code != null && code.userCode.isNotEmpty) ...[
            const SizedBox(height: 16),
            SelectableText(code.userCode),
            Text(l.snippetDeviceCodeHelp),
          ],
          if (_working) ...[
            const SizedBox(height: 16),
            const CommonCircleLoading(size: 20),
          ],
          if (_error != null)
            Text(_error!, style: TextStyle(color: context.colorScheme.error)),
          if (code != null && _working)
            TextButton(
              onPressed: () async {
                try {
                  await _openBrowser(code.verificationUri);
                } catch (_) {
                  if (mounted) setState(() => _error = l.snippetBrowserError);
                }
              },
              child: Text(l.snippetOpenBrowser),
            ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_SnippetSignInAction.token),
            child: Text(l.snippetConnect),
          ),
        ],
      ),
    );
  }
}

class _SnippetTokenDialog extends StatefulWidget {
  const _SnippetTokenDialog({required this.service});
  final SnippetService service;

  @override
  State<_SnippetTokenDialog> createState() => _SnippetTokenDialogState();
}

class _SnippetTokenDialogState extends State<_SnippetTokenDialog> {
  final _token = TextEditingController();

  @override
  void dispose() {
    _token.clear();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context, widget.service);
    void submit() {
      if (_token.text.trim().isNotEmpty) {
        Navigator.of(context).pop(_token.text.trim());
      }
    }

    return CommonDialog(
      title: context.appLocalizations.snippetConnect,
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.appLocalizations.cancel),
        ),
        TextButton(
          onPressed: submit,
          child: Text(context.appLocalizations.confirm),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(strings.tokenHelp),
          SecretTextFormField(
            controller: _token,
            autofocus: true,
            decoration: InputDecoration(labelText: strings.tokenLabel),
            onFieldSubmitted: (_) => submit(),
          ),
          TextButton(
            onPressed: () async {
              await launchUrl(
                Uri.parse(
                  widget.service == SnippetService.github
                      ? 'https://github.com/settings/tokens'
                      : 'https://gitee.com/profile/personal_access_tokens',
                ),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(strings.tokenLabel),
          ),
        ],
      ),
    );
  }
}

class GitHubBackupPasswordDialog extends StatefulWidget {
  const GitHubBackupPasswordDialog({
    super.key,
    required this.creating,
    required this.message,
  });
  final bool creating;
  final String message;

  @override
  State<GitHubBackupPasswordDialog> createState() =>
      _GitHubBackupPasswordDialogState();
}

class _GitHubBackupPasswordDialogState
    extends State<GitHubBackupPasswordDialog> {
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
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = GitHubSyncStrings(context);
    final l = context.appLocalizations;
    return CommonDialog(
      title: widget.creating ? strings.encrypt : strings.decrypt,
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
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
                  decoration: InputDecoration(
                    labelText: strings.confirmPassword,
                  ),
                  validator: (value) =>
                      value == _password.text ? null : strings.passwordMismatch,
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
