import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const updateRepository = String.fromEnvironment(
  'FLCLASHX_UPDATE_REPOSITORY',
  defaultValue: 'Ive4/FlClashX',
);

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.version,
    required this.build,
    required this.url,
    required this.sha256Hex,
    required this.size,
    required this.notes,
    this.androidVersionCode,
  });
  final String version;
  final int build;
  final Uri url;
  final String sha256Hex;
  final int size;
  final String notes;
  final int? androidVersionCode;
  bool get isAndroid => androidVersionCode != null;
  String get fullVersion => '$version+$build';

  bool isNewerThan(String currentVersion, int currentBuild) {
    final versionCode = androidVersionCode;
    return (versionCode == null || versionCode > currentBuild) &&
        compareVersions(
              '$version+${versionCode ?? build}',
              '$currentVersion+$currentBuild',
            ) >
            0;
  }

  static AppUpdateRelease parse(
    Map<String, dynamic> data,
    String repository,
    String target,
    String notes, {
    String? tag,
  }) {
    final version = data['version'];
    final build = data['build'];
    final assets = data['assets'];
    if (data['app'] != 'FlClashX' ||
        data['schema'] != 1 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build is! int ||
        build <= 0 ||
        assets is! Map) {
      throw const FormatException('Invalid FlClashX update manifest');
    }
    if (!assets.containsKey(target)) {
      throw UnsupportedError('No FlClashX update package for $target');
    }
    final asset = assets[target];
    if (asset is! Map) throw const FormatException('Invalid update asset');
    final rawUrl = asset['url'];
    final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    final digest = asset['sha256'];
    final size = asset['size'];
    if (url == null ||
        !validReleaseUrl(url, repository, tag: tag) ||
        size is! int ||
        size <= 0 ||
        size > 2 * 1024 * 1024 * 1024 ||
        digest is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid update asset');
    }
    final filename = url.pathSegments.last;
    int? androidVersionCode;
    if (target.startsWith('android-')) {
      final versionCode = asset['versionCode'];
      if (filename != 'FlClashX-$version-$target.apk' ||
          versionCode is! int ||
          versionCode < build ||
          versionCode > 0x7fffffff) {
        throw const FormatException('Invalid FlClashX Android update asset');
      }
      androidVersionCode = versionCode;
    } else if (!filename.startsWith('FlClashX-') ||
        !filename.endsWith('.exe')) {
      throw const FormatException('Invalid FlClashX Windows update asset');
    }
    return AppUpdateRelease(
      version: version,
      build: build,
      url: url,
      sha256Hex: digest.toLowerCase(),
      size: size,
      notes: notes,
      androidVersionCode: androidVersionCode,
    );
  }
}

bool validReleaseUrl(Uri url, String repository, {String? tag}) {
  final segments = url.pathSegments;
  return url.scheme == 'https' &&
      url.host == 'github.com' &&
      url.port == 443 &&
      url.userInfo.isEmpty &&
      !url.hasQuery &&
      !url.hasFragment &&
      segments.length == 6 &&
      '${segments[0]}/${segments[1]}' == repository &&
      segments[2] == 'releases' &&
      segments[3] == 'download' &&
      segments[4].isNotEmpty &&
      (tag == null || segments[4] == tag) &&
      segments[5].isNotEmpty &&
      !segments[5].contains('/') &&
      !segments[5].contains(r'\');
}

String? updateTargetForAbi(Abi abi) => switch (abi) {
  Abi.windowsX64 => 'windows-amd64',
  Abi.windowsArm64 => 'windows-arm64',
  Abi.androidArm => 'android-armeabi-v7a',
  Abi.androidArm64 => 'android-arm64-v8a',
  Abi.androidX64 => 'android-x86_64',
  _ => null,
};

class AppUpdater {
  AppUpdater({Dio? client}) : _dio = client ?? request.dio;
  final Dio _dio;
  Future<AppUpdateRelease?> check() async {
    if (!RegExp(
          r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
        ).hasMatch(updateRepository) ||
        updateRepository.toLowerCase() == 'chen08209/flclash') {
      throw StateError(currentAppLocalizations.updateSourceMissing);
    }
    final target = updateTargetForAbi(Abi.current());
    if (target == null ||
        (Platform.isAndroid && !await app!.supportsAppUpdates())) {
      throw UnsupportedError(currentAppLocalizations.updateUnavailable);
    }
    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$updateRepository/releases/latest',
      options: Options(receiveTimeout: const Duration(seconds: 30)),
    );
    final release = response.data;
    if (release == null) throw const FormatException('Invalid GitHub release');
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final tag = release['tag_name'];
    final assets = release['assets'];
    if (tag is! String || tag.isEmpty || assets is! List) {
      throw const FormatException('Invalid GitHub release');
    }
    final manifests = assets
        .whereType<Map>()
        .where((asset) => asset['name'] == 'flclashx-update.json')
        .toList();
    if (manifests.length != 1) {
      throw const FormatException(
        'Expected one flclashx-update.json in the latest release',
      );
    }
    final rawUrl = manifests.single['browser_download_url'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null ||
        !validReleaseUrl(uri, updateRepository, tag: tag) ||
        uri.pathSegments.last != 'flclashx-update.json') {
      throw const FormatException('Invalid manifest location');
    }
    final result = await _dio.getUri<String>(
      uri,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final manifest = jsonDecode(result.data ?? '');
    if (manifest is! Map<String, dynamic>) {
      throw const FormatException('Invalid FlClashX update manifest');
    }
    final update = AppUpdateRelease.parse(
      manifest,
      updateRepository,
      target,
      release['body'] as String? ?? '',
      tag: tag,
    );
    final current = globalState.packageInfo;
    return update.isNewerThan(
          current.version,
          int.tryParse(current.buildNumber) ?? 0,
        )
        ? update
        : null;
  }

  Future<File> download(
    AppUpdateRelease release,
    CancelToken cancel,
    void Function(double?) progress,
  ) async {
    final root = Platform.isAndroid
        ? await Directory(
            p.join(await appPath.tempPath, 'app-updates'),
          ).create(recursive: true)
        : Directory.systemTemp;
    final directory = await root.createTemp('FlClashX-update-');
    final extension = release.isAndroid ? 'apk' : 'exe';
    final file = File(p.join(directory.path, 'installer.$extension.part'));
    var oversized = false;
    try {
      await _dio.downloadUri(
        release.url,
        file.path,
        cancelToken: cancel,
        options: Options(receiveTimeout: const Duration(seconds: 60)),
        onReceiveProgress: (received, total) {
          if (received > release.size) {
            oversized = true;
            cancel.cancel('Update exceeds manifest size');
          }
          progress((received / release.size).clamp(0.0, 1.0));
        },
      );
      if (cancel.isCancelled) throw cancel.cancelError!;
      progress(null);
      if (await file.length() != release.size ||
          (await sha256.bind(file.openRead()).first).toString() !=
              release.sha256Hex) {
        throw StateError(currentAppLocalizations.updateVerificationFailed);
      }
      if (cancel.isCancelled) throw cancel.cancelError!;
      return await file.rename(
        p.join(directory.path, 'FlClashX-update.$extension'),
      );
    } catch (_) {
      await discardDownloadedUpdate(file);
      if (oversized) {
        throw StateError(currentAppLocalizations.updateVerificationFailed);
      }
      rethrow;
    }
  }

  Future<void> installAndroid(AppUpdateRelease release, File installer) async {
    try {
      await app!.installUpdateApk(
        installer.path,
        release.version,
        release.androidVersionCode!,
      );
    } on PlatformException catch (error) {
      final l = currentAppLocalizations;
      throw StateError(switch (error.code) {
        'UPDATE_UNSUPPORTED' => l.updateUnavailable,
        'UPDATE_INVALID_APK' => l.updateVerificationFailed,
        'UPDATE_SIGNER_MISMATCH' => l.updateAndroidSignatureMismatch,
        _ => l.updateAndroidInstallFailed,
      });
    } finally {
      await discardDownloadedUpdate(installer);
    }
  }

  Future<void> scheduleInstall(File installer) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final executable = Platform.resolvedExecutable;
    if (p.basename(executable).toLowerCase() != 'flclashx.exe') {
      throw StateError('Run an installed FlClashX build to update');
    }
    final ready = File(p.join(installer.parent.path, 'ready'));
    final script = windowsUpdateScript(
      installer: installer.path,
      executable: executable,
      parentPid: pid,
      readyPath: ready.path,
    );
    final encoded = base64Encode([
      for (final unit in script.codeUnits) ...[unit & 255, unit >> 8],
    ]);
    final command =
        'Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList '
        "'-NoProfile','-NonInteractive','-EncodedCommand','$encoded'";
    final launcher = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
    if (launcher.exitCode != 0) throw StateError('Cannot start update worker');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await ready.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Update worker did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

String _psLiteral(String value) => "'${value.replaceAll("'", "''")}'";

String windowsUpdateScript({
  required String installer,
  required String executable,
  required int parentPid,
  required String readyPath,
}) {
  final arguments =
      '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- '
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

Future<void> discardDownloadedUpdate(File file) async {
  try {
    if (await file.exists()) await file.delete();
    await file.parent.delete();
  } on FileSystemException {
    // Cleanup must preserve the original transfer or installation result.
  }
}
