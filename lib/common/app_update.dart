import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/macos_update.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const updateRepository = String.fromEnvironment(
  'FLCLASHX_UPDATE_REPOSITORY',
  defaultValue: 'Ive4/FlClashX',
);
const _installedTag = String.fromEnvironment('FLCLASHX_UPDATE_TAG');

typedef _ReleaseTag = ({String version, int? prerelease, int build});

final _releaseTagPattern = RegExp(
  r'^v(\d+\.\d+\.\d+)(?:-pre\.([1-9]\d*)(?:\+(\d+))?|(?:-build|\+)(\d+))?$',
);

_ReleaseTag? _parseReleaseTag(String? tag) {
  final match = tag == null ? null : _releaseTagPattern.firstMatch(tag);
  if (match == null) return null;
  return (
    version: match[1]!,
    prerelease: int.tryParse(match[2] ?? ''),
    build: int.tryParse(match[3] ?? match[4] ?? '') ?? 0,
  );
}

int _compareReleaseTags(_ReleaseTag left, _ReleaseTag right) {
  final version = compareVersions(left.version, right.version);
  if (version != 0) return version;
  final lhs = left.prerelease;
  final rhs = right.prerelease;
  if (lhs != rhs) {
    if (lhs == null) return 1;
    if (rhs == null) return -1;
    return lhs.compareTo(rhs);
  }
  return left.build.compareTo(right.build);
}

String installedUpdateVersionLabel(String version) =>
    _parseReleaseTag(_installedTag)?.prerelease == null
    ? 'v$version'
    : _installedTag;

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.version,
    required this.build,
    required this.url,
    required this.sha256Hex,
    required this.size,
    required this.notes,
    this.androidVersionCode,
    this.tag,
    this.canInstall = true,
  });
  final String version;
  final int build;
  final Uri url;
  final String sha256Hex;
  final int size;
  final String notes;
  final int? androidVersionCode;
  final String? tag;
  final bool canInstall;
  bool get isAndroid => androidVersionCode != null;
  bool get isMacOS => url.pathSegments.lastOrNull?.endsWith('.dmg') == true;
  String get fullVersion {
    final prerelease = _parseReleaseTag(tag)?.prerelease;
    return prerelease == null
        ? '$version+$build'
        : '$version-pre.$prerelease+$build';
  }

  Uri get releasePage => Uri.https(
    'github.com',
    '/$updateRepository/releases${tag == null ? '' : '/tag/$tag'}',
  );

  bool isNewerThan(
    String currentVersion,
    int currentBuild, {
    String currentTag = _installedTag,
  }) {
    final versionCode = androidVersionCode;
    final releaseTag = _parseReleaseTag(tag);
    final installedTag = _parseReleaseTag(currentTag);
    return (versionCode == null || versionCode > currentBuild) &&
        _compareReleaseTags(
              (
                version: version,
                prerelease: releaseTag?.prerelease,
                build: versionCode ?? build,
              ),
              (
                version: currentVersion,
                prerelease: installedTag?.version == currentVersion
                    ? installedTag?.prerelease
                    : null,
                build: currentBuild,
              ),
            ) >
            0;
  }

  static AppUpdateRelease parse(
    Map<String, dynamic> data,
    String repository,
    String target,
    String notes, {
    String? tag,
    bool canInstall = true,
  }) {
    final version = data['version'];
    final build = data['build'];
    final assets = data['assets'];
    if (data['app'] != 'FlClashX' ||
        data['schema'] != 1 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        (tag != null && _parseReleaseTag(tag)?.version != version) ||
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
    } else if (target.startsWith('macos-')) {
      if (filename != 'FlClashX-$version-$target.dmg') {
        throw const FormatException('Invalid FlClashX macOS update asset');
      }
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
      tag: tag,
      canInstall: canInstall,
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
  Abi.macosX64 => 'macos-amd64',
  Abi.macosArm64 => 'macos-arm64',
  _ => null,
};

class AppUpdater {
  AppUpdater({Dio? client}) : _dio = client ?? request.dio;
  final Dio _dio;
  late final MacosAppUpdate? macos = _macosUpdater();

  MacosAppUpdate? _macosUpdater() {
    if (!Platform.isMacOS ||
        globalState.packageInfo.packageName != 'com.follow.clash') {
      return null;
    }
    final bundle = appBundleOf(Platform.resolvedExecutable);
    return bundle == null ? null : MacosAppUpdate(bundle);
  }

  Future<String> get macosFailureMarker async =>
      p.join(await appPath.homeDirPath, 'macos-update-error.txt');

  Future<AppUpdateRelease?> check({
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    if (!RegExp(
          r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
        ).hasMatch(updateRepository) ||
        updateRepository.toLowerCase() == 'chen08209/flclash') {
      throw StateError(currentAppLocalizations.updateSourceMissing);
    }
    final target = updateTargetForAbi(Abi.current());
    final release = await _release(channel);
    if (release == null) return null;
    final tag = release['tag_name'];
    final assets = release['assets'];
    final releaseTag = tag is String ? _parseReleaseTag(tag) : null;
    if (tag is! String ||
        releaseTag == null ||
        (releaseTag.prerelease != null) != (release['prerelease'] == true) ||
        assets is! List) {
      throw const FormatException('Invalid GitHub release');
    }
    final notes = release['body'] is String ? release['body'] as String : '';
    final canInstall =
        target != null &&
        (!Platform.isAndroid || await app!.supportsAppUpdates()) &&
        (!Platform.isMacOS || (macos?.canReplace ?? false));
    final manifests = assets
        .whereType<Map>()
        .where((asset) => asset['name'] == 'flclashx-update.json')
        .toList();
    if (manifests.length > 1) {
      throw const FormatException(
        'Expected one flclashx-update.json in the release',
      );
    }
    final manualUpdate = AppUpdateRelease(
      version: releaseTag.version,
      build: releaseTag.build,
      url: Uri.https('github.com', '/$updateRepository/releases/tag/$tag'),
      sha256Hex: '',
      size: 0,
      notes: notes,
      tag: tag,
      canInstall: false,
    );
    if (target == null || manifests.isEmpty) return _newer(manualUpdate);
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
    try {
      return _newer(
        AppUpdateRelease.parse(
          manifest,
          updateRepository,
          target,
          notes,
          tag: tag,
          canInstall: canInstall,
        ),
      );
    } on UnsupportedError {
      return _newer(manualUpdate);
    }
  }

  AppUpdateRelease? _newer(AppUpdateRelease update) {
    final current = globalState.packageInfo;
    return update.isNewerThan(
          current.version,
          int.tryParse(current.buildNumber) ?? 0,
        )
        ? update
        : null;
  }

  Future<Map<String, dynamic>?> _release(UpdateChannel channel) async {
    const base = 'https://api.github.com/repos/$updateRepository/releases';
    final options = Options(receiveTimeout: const Duration(seconds: 30));
    if (channel == UpdateChannel.stable) {
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/latest',
        options: options,
      );
      final value = response.data;
      if (value == null) throw const FormatException('Invalid GitHub release');
      return value['draft'] == true || value['prerelease'] == true
          ? null
          : value;
    }
    _ReleaseTag? newest;
    Map<String, dynamic>? selected;
    for (var page = 1; page <= 5; page++) {
      final response = await _dio.get<List<dynamic>>(
        base,
        queryParameters: {'per_page': 100, 'page': page},
        options: options,
      );
      final releases = response.data;
      if (releases == null) {
        throw const FormatException('Invalid GitHub releases');
      }
      for (final release in releases.whereType<Map<String, dynamic>>()) {
        final tag = release['tag_name'];
        final version = tag is String ? _parseReleaseTag(tag) : null;
        if (release['draft'] == true ||
            version == null ||
            (version.prerelease != null) != (release['prerelease'] == true)) {
          continue;
        }
        if (newest == null || _compareReleaseTags(version, newest) > 0) {
          newest = version;
          selected = release;
        }
      }
      if (releases.length < 100) break;
    }
    return selected;
  }

  Future<File> download(
    AppUpdateRelease release,
    CancelToken cancel,
    void Function(double?) progress,
  ) async {
    if (!release.canInstall) {
      throw UnsupportedError(currentAppLocalizations.updateUnavailable);
    }
    final root = Platform.isAndroid
        ? await Directory(
            p.join(await appPath.tempPath, 'app-updates'),
          ).create(recursive: true)
        : Directory.systemTemp;
    final directory = await root.createTemp('FlClashX-update-');
    final extension = release.isAndroid
        ? 'apk'
        : release.isMacOS
        ? 'dmg'
        : 'exe';
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

Future<void> discardDownloadedUpdate(File file, {String? staged}) async {
  try {
    if (staged != null) {
      final app = Directory(staged);
      if (await app.exists()) await app.delete(recursive: true);
    }
    if (await file.exists()) await file.delete();
    await file.parent.delete();
  } on FileSystemException {
    // Cleanup must preserve the original transfer or installation result.
  }
}
