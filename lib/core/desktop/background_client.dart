import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/l10n_labels.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:path/path.dart' as p;

import 'helper_client.dart';
import 'launcher.dart';
import 'model.dart';
import 'process_probe.dart';

class DesktopBackgroundClient {
  String? _url;
  String? _token;
  String? _sessionId;
  int? _pid;
  String? _runtimeDir;
  CoreResumeState? resumeState;
  bool showOnLaunch = false;
  bool restorePending = false;

  String get executablePath => p.join(
    _runtimeDir ?? appPath.executableDirPath,
    'FlClashDesktop${appPath.executableExtension}',
  );

  bool get available =>
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      File(executablePath).existsSync();

  Future<void> inspectExisting() async {
    if (!available) {
      return;
    }
    await _prepareRuntime();
    final state = File(p.join(await appPath.homeDirPath, '.desktop-host.json'));
    if (await _readState(state)) {
      restorePending = (await _request('/status'))['lightweight'] == true;
    }
  }

  Future<Map<String, Object?>> _request(
    String path, {
    Map<String, Object?>? body,
  }) async {
    final url = _url;
    final token = _token;
    if (url == null || token == null) {
      throw StateError('Desktop backend is not connected');
    }
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.openUrl(
        body == null ? 'GET' : 'POST',
        Uri.parse('$url$path'),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Desktop backend HTTP ${response.statusCode}: $text');
      }
      return Map<String, Object?>.from(jsonDecode(text) as Map);
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _readState(File file) async {
    if (!await file.exists()) {
      return false;
    }
    final data = jsonDecode(await file.readAsString()) as Map;
    final url = data['url'];
    final token = data['token'];
    final hostPid = data['pid'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        token is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
        hostPid is! int ||
        !await isProcessExecutableAlive(hostPid, executablePath)) {
      return false;
    }
    _url = url as String;
    _token = token;
    _pid = hostPid;
    await _request('/status');
    return true;
  }

  Future<void> _ensureStarted() async {
    await _prepareRuntime();
    final home = await appPath.homeDirPath;
    final state = File(p.join(home, '.desktop-host.json'));
    if (await _readState(state)) {
      return;
    }
    final config = File(p.join(home, '.desktop-host-config.json'));
    final localizations = currentAppLocalizations;
    await config.writeAsString(
      jsonEncode({
        'home': home,
        'app': _appImage ?? Platform.resolvedExecutable,
        'appImage': _appImage != null,
        'core': p.join(
          _runtimeDir ?? appPath.executableDirPath,
          p.basename(appPath.corePath),
        ),
        'icon': _runtimeDir == null
            ? p.join(
                Platform.isMacOS
                    ? p.join(
                        appPath.executableDirPath,
                        '..',
                        'Frameworks',
                        'App.framework',
                        'Resources',
                        'flutter_assets',
                      )
                    : p.join(
                        appPath.executableDirPath,
                        'data',
                        'flutter_assets',
                      ),
                'assets',
                'images',
                'tray',
                Platform.isWindows
                    ? 'windows'
                    : (Platform.isMacOS ? 'macos' : 'unix'),
                Platform.isWindows
                    ? 'status_2.ico'
                    : (Platform.isMacOS ? 'status_1.png' : 'status_2.png'),
              )
            : p.join(_runtimeDir!, 'tray.png'),
        'showLabel': localizations.show,
        'exitLabel': localizations.exit,
        'safeMode': safeModeBuild,
      }),
      flush: true,
    );
    await Process.start(
      executablePath,
      ['--config', config.path],
      mode: ProcessStartMode.detached,
      workingDirectory: home,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await _readState(state)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Desktop backend did not start');
  }

  String? get _appImage {
    final image = Platform.isLinux ? Platform.environment['APPIMAGE'] : null;
    return image != null && p.isAbsolute(image) && File(image).existsSync()
        ? image
        : null;
  }

  Future<void> _prepareRuntime() async {
    if (_appImage == null || _runtimeDir != null) {
      return;
    }
    final host = executablePath;
    final core = appPath.corePath;
    final home = await appPath.homeDirPath;
    final icon = p.join(
      appPath.executableDirPath,
      'data',
      'flutter_assets',
      'assets',
      'images',
      'tray',
      'unix',
      'status_2.png',
    );
    // AppImage unmounts its bundle when the Flutter process exits.
    _runtimeDir = await Isolate.run(() async {
      final hostHash = await sha256.bind(File(host).openRead()).first;
      final coreHash = await sha256.bind(File(core).openRead()).first;
      final directory = Directory(
        p.join(home, '.desktop-runtime', '$hostHash-$coreHash'),
      );
      await directory.create(recursive: true);
      for (final source in [host, core, icon]) {
        final destination = p.join(
          directory.path,
          source == icon ? 'tray.png' : p.basename(source),
        );
        if (!await File(destination).exists()) {
          final staged = await File(source).copy('$destination.staging-$pid');
          if (source != icon) {
            final result = await Process.run('chmod', ['700', staged.path]);
            if (result.exitCode != 0) {
              throw StateError(
                'Cannot stage desktop backend: ${result.stderr}',
              );
            }
          }
          await staged.rename(destination);
        }
      }
      return directory.path;
    });
  }

  Future<CoreProcessLease> attach({
    required String sessionId,
    required String address,
  }) async {
    await _ensureStarted();
    final helperReady =
        !safeModeBuild &&
        (Platform.isWindows || (Platform.isLinux && _appImage == null)) &&
        await helperClient.readiness() == HelperReadiness.ready;
    final response = await _request(
      '/attach',
      body: {
        'sessionId': sessionId,
        'address': address,
        'uiPid': pid,
        'helperUrl': helperReady ? helperClient.baseUrl : '',
      },
    );
    if (response['pid'] != _pid) {
      throw StateError('Desktop backend PID changed');
    }
    _sessionId = sessionId;
    resumeState = response['wasLightweight'] == true
        ? CoreResumeState(
            coreReused: response['coreReused'] == true,
            mode: response['mode'] as String?,
            profileId: response['profileId'] as String?,
            selectedMap: Map<String, String>.from(
              response['selectedMap'] as Map? ?? const {},
            ),
            runningSince: switch (response['runningSince']) {
              final int milliseconds => DateTime.fromMillisecondsSinceEpoch(
                milliseconds,
              ),
              _ => null,
            },
          )
        : null;
    return _BackgroundCoreLease(this, sessionId, _pid!);
  }

  Future<void> enter({
    required DateTime? runningSince,
    required bool cleanupProxy,
    required String mode,
    String? profileId,
    String testUrl = '',
    int delayTestTimeout = defaultDelayTestTimeout,
    bool closeConnections = false,
  }) async {
    await _request(
      '/lightweight',
      body: {
        'sessionId': _sessionId,
        'runningSince': runningSince?.millisecondsSinceEpoch,
        'cleanupProxy': cleanupProxy && !safeModeBuild,
        'showLabel': currentAppLocalizations.show,
        'exitLabel': currentAppLocalizations.exit,
        'mode': mode,
        'profileId': profileId ?? '',
        'testUrl': testUrl,
        'delayTestTimeout': delayTestTimeout,
        'closeConnections': closeConnections,
        'labels': {
          'lightweight': currentAppLocalizations.lightweightMode,
          'running': currentAppLocalizations.running,
          'notRunning': currentAppLocalizations.notRunning,
          'mode': currentAppLocalizations.mode,
          for (final mode in Mode.values) mode.name: mode.label,
          'closeConnections': currentAppLocalizations.closeConnections,
          'openHome': currentAppLocalizations.openConfigDirectory,
          'error': currentAppLocalizations.error,
          'proxies': currentAppLocalizations.proxies,
          'delayTest': currentAppLocalizations.delayTest,
          'timeout': currentAppLocalizations.timeout,
          'proxyGroupEmpty': currentAppLocalizations.proxyGroupEmpty,
        },
      },
    );
  }

  Future<void> cancelEnter() async {
    await _request('/cancel-lightweight', body: {'sessionId': _sessionId});
  }

  Future<CoreProcessStopResult> stop(
    String sessionId,
    int hostPid,
    Duration timeout,
  ) async {
    if (await isProcessExecutableAlive(hostPid, executablePath)) {
      await _request('/stop', body: {'sessionId': sessionId});
    }
    final deadline = DateTime.now().add(timeout);
    while (await isProcessExecutableAlive(hostPid, executablePath) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return CoreProcessStopResult(
      stopped: true,
      exitConfirmed: !await isProcessExecutableAlive(hostPid, executablePath),
    );
  }
}

class BackgroundLauncherResolver implements DesktopCoreLauncherResolver {
  const BackgroundLauncherResolver(this.fallback, this.client);

  final DesktopCoreLauncherResolver fallback;
  final DesktopBackgroundClient client;

  @override
  Future<CoreProcessLauncher> resolve() async {
    return client.available ? _BackgroundLauncher(client) : fallback.resolve();
  }
}

class _BackgroundLauncher implements CoreProcessLauncher {
  const _BackgroundLauncher(this.client);

  final DesktopBackgroundClient client;

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) => client.attach(sessionId: sessionId, address: address);
}

class _BackgroundCoreLease implements CoreProcessLease {
  const _BackgroundCoreLease(this.client, this.sessionId, this.pid);

  final DesktopBackgroundClient client;

  @override
  final String sessionId;

  @override
  final int pid;

  @override
  CoreProcessOwner get owner => CoreProcessOwner.background;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) =>
      client.stop(sessionId, pid, timeout);
}

final desktopBackground = DesktopBackgroundClient();
