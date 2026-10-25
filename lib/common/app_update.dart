import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/state.dart';
import 'package:path/path.dart' as p;

const updateRepository = String.fromEnvironment(
  'FLCLASHX_UPDATE_REPOSITORY', defaultValue: 'Ive4/FlClashX');

class AppUpdateRelease {
  const AppUpdateRelease({required this.version, required this.build,
    required this.url, required this.sha256Hex, required this.size, required this.notes});
  final String version;
  final int build;
  final Uri url;
  final String sha256Hex;
  final int size;
  final String notes;
  String get fullVersion => '$version+$build';

  static AppUpdateRelease parse(Map<String, dynamic> data, String repository,
      String target, String notes) {
    if (data['app'] != 'FlClashX' || data['schema'] != 1 ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(data['version'] as String? ?? '') ||
        data['build'] is! int || (data['build'] as int) <= 0) {
      throw const FormatException('Invalid FlClashX update manifest');
    }
    final asset = (data['assets'] as Map)[target] as Map?;
    if (asset == null) throw UnsupportedError('No update package for $target');
    final url = Uri.parse(asset['url'] as String);
    final digest = asset['sha256'] as String;
    final size = asset['size'] as int;
    if (!validReleaseUrl(url, repository) ||
        !url.pathSegments.last.startsWith('FlClashX-') ||
        !url.path.endsWith('.exe') || size <= 0 || size > 2 * 1024 * 1024 * 1024 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid update asset');
    }
    return AppUpdateRelease(version: data['version'] as String,
      build: data['build'] as int, url: url, sha256Hex: digest.toLowerCase(),
      size: size, notes: notes);
  }
}

bool validReleaseUrl(Uri url, String repository) =>
    url.scheme == 'https' && url.host == 'github.com' &&
    url.userInfo.isEmpty && !url.hasQuery && !url.hasFragment &&
    url.path.startsWith('/$repository/releases/download/');

class AppUpdater {
  AppUpdater({Dio? client}) : _dio = client ?? request.dio;
  final Dio _dio;
  Future<AppUpdateRelease?> check() async {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(updateRepository) ||
        updateRepository.toLowerCase() == 'chen08209/flclash') {
      throw StateError(currentAppLocalizations.updateSourceMissing);
    }
    if (!Platform.isWindows) throw UnsupportedError(currentAppLocalizations.updateWindowsOnly);
    final target = switch (Abi.current()) {
      Abi.windowsX64 => 'windows-amd64',
      Abi.windowsArm64 => 'windows-arm64',
      _ => throw UnsupportedError('Unsupported Windows architecture'),
    };
    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$updateRepository/releases/latest',
      options: Options(receiveTimeout: const Duration(seconds: 30)));
    final release = response.data!;
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final manifest = (release['assets'] as List).cast<Map>().where(
      (asset) => asset['name'] == 'flclashx-update.json').single;
    final uri = Uri.parse(manifest['browser_download_url'] as String);
    if (!validReleaseUrl(uri, updateRepository)) throw const FormatException('Invalid manifest location');
    final result = await _dio.getUri<String>(uri,
      options: Options(responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30)));
    final update = AppUpdateRelease.parse(jsonDecode(result.data!) as Map<String, dynamic>,
      updateRepository, target, release['body'] as String? ?? '');
    final current = globalState.packageInfo;
    return compareVersions(update.fullVersion,
      '${current.version}+${int.tryParse(current.buildNumber) ?? 0}') > 0 ? update : null;
  }

  Future<File> download(AppUpdateRelease release, CancelToken cancel,
      void Function(double?) progress) async {
    final directory = await Directory.systemTemp.createTemp('FlClashX-update-');
    final file = File(p.join(directory.path, 'installer.exe.part'));
    try {
      await _dio.downloadUri(release.url, file.path,
        cancelToken: cancel,
        options: Options(receiveTimeout: const Duration(seconds: 60)),
        onReceiveProgress: (received, total) {
          if (received > release.size) cancel.cancel('Update exceeds manifest size');
          progress((received / release.size).clamp(0.0, 1.0));
        });
      if (cancel.isCancelled) throw cancel.cancelError!;
      progress(null);
      if (await file.length() != release.size ||
          (await sha256.bind(file.openRead()).first).toString() != release.sha256Hex) {
        throw StateError(currentAppLocalizations.updateVerificationFailed);
      }
      if (cancel.isCancelled) throw cancel.cancelError!;
      return await file.rename(p.join(directory.path, 'FlClashX-update.exe'));
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> scheduleInstall(File installer) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final executable = Platform.resolvedExecutable;
    if (p.basename(executable).toLowerCase() != 'flclashx.exe') {
      throw StateError('Run an installed FlClashX build to update');
    }
    final ready = File(p.join(installer.parent.path, 'ready'));
    final script = windowsUpdateScript(installer: installer.path,
      executable: executable, parentPid: pid, readyPath: ready.path);
    final encoded = base64Encode([
      for (final unit in script.codeUnits) ...[unit & 255, unit >> 8],
    ]);
    final launcher = await Process.run('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      "Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList "
      "'-NoProfile','-NonInteractive','-EncodedCommand','$encoded'",
    ]);
    if (launcher.exitCode != 0) throw StateError('Cannot start update worker');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await ready.exists()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Update worker did not start');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

String _psLiteral(String value) => "'${value.replaceAll("'", "''")}'";

String windowsUpdateScript({required String installer, required String executable,
  required int parentPid, required String readyPath}) {
  final arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- '
      '/DIR="${p.windows.dirname(executable)}" /LOG="${p.windows.join(p.windows.dirname(installer), 'install.log')}"';
  return """
\$ErrorActionPreference = 'Stop'
\$parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
if (\$null -eq \$parent) { exit 1 }
[IO.File]::WriteAllText(${_psLiteral(readyPath)}, 'ready')
if (-not \$parent.WaitForExit(90000)) { exit 2 }
try {
  \$install = Start-Process -FilePath ${_psLiteral(installer)} -Verb RunAs -WindowStyle Hidden -ArgumentList ${_psLiteral(arguments)} -Wait -PassThru
  if (\$install.ExitCode -ne 0) { throw "Installer exit code: \$(\$install.ExitCode)" }
} catch {
  [IO.File]::WriteAllText(${_psLiteral(p.windows.join(p.windows.dirname(installer), 'update-error.txt'))}, \$_.ToString())
} finally {
  Start-Process -FilePath ${_psLiteral(executable)} -WorkingDirectory ${_psLiteral(p.windows.dirname(executable))}
}
""";
}

final appUpdater = AppUpdater();
