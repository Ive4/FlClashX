import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'dart:ffi' show Abi;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/package.dart';
import 'package:flutter_test/flutter_test.dart';

class _DownloadAdapter implements HttpClientAdapter {
  final List<int> bytes;
  _DownloadAdapter(this.bytes);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    bytes,
    200,
    headers: {
      Headers.contentLengthHeader: ['${bytes.length}'],
    },
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  Map<String, dynamic> manifest({String app = 'FlClashX', String? url}) => {
    'schema': 1,
    'app': app,
    'version': '0.9.2',
    'build': 2026102501,
    'assets': {
      'windows-amd64': {
        'url':
            url ??
            'https://github.com/owner/FlClashX/releases/download/v0.9.2/FlClashX-windows.exe',
        'size': 1024,
        'sha256': 'a' * 64,
      },
    },
  };
  test('downloads and verifies bytes before returning an installer', () async {
    final bytes = [1, 2, 3, 4];
    final dio = Dio()..httpClientAdapter = _DownloadAdapter(bytes);
    final updater = AppUpdater(client: dio);
    final release = AppUpdateRelease(
      version: '0.9.2',
      build: 2,
      url: Uri.parse(
        'https://github.com/owner/FlClashX/releases/download/v1/FlClashX-test.exe',
      ),
      sha256Hex: sha256.convert(bytes).toString(),
      size: bytes.length,
      notes: '',
    );
    final file = await updater.download(release, CancelToken(), (_) {});
    expect(await file.readAsBytes(), bytes);
    await file.delete();
    await file.parent.delete();
    dio.close();
  });
  test('checksum mismatch never yields an installer', () async {
    final dio = Dio()..httpClientAdapter = _DownloadAdapter([1, 2]);
    final release = AppUpdateRelease(
      version: '0.9.2',
      build: 2,
      url: Uri.parse(
        'https://github.com/owner/FlClashX/releases/download/v1/FlClashX-test.exe',
      ),
      sha256Hex: '0' * 64,
      size: 2,
      notes: '',
    );
    // Load localization because verification errors are user-facing.
    await AppLocalizations.load(const Locale('en'));
    await expectLater(
      AppUpdater(client: dio).download(release, CancelToken(), (_) {}),
      throwsStateError,
    );
    dio.close();
  });
  test('same public version uses build numbers to detect updates', () {
    final release = AppUpdateRelease.parse(
      manifest(),
      'owner/FlClashX',
      'windows-amd64',
      '',
    );
    expect(
      compareVersions(release.fullVersion, '0.9.2+2026102401'),
      greaterThan(0),
    );
    expect(compareVersions(release.fullVersion, '0.9.2+2026102501'), 0);
    expect(compareVersions(release.fullVersion, '0.9.3+1'), lessThan(0));
  });
  test('selects the Android APK for the installed Dart ABI', () {
    expect(updateTargetForAbi(Abi.androidArm), 'android-armeabi-v7a');
    expect(updateTargetForAbi(Abi.androidArm64), 'android-arm64-v8a');
    expect(updateTargetForAbi(Abi.androidX64), 'android-x86_64');
    expect(updateTargetForAbi(Abi.androidIA32), isNull);
    final payload = manifest();
    final android = {
      'url':
          'https://github.com/owner/FlClashX/releases/download/v0.9.2/FlClashX-0.9.2-android-arm64-v8a.apk',
      'size': 1024,
      'sha256': 'A' * 64,
      'versionCode': 2026104501,
    };
    (payload['assets'] as Map)['android-arm64-v8a'] = android;
    final release = AppUpdateRelease.parse(
      payload,
      'owner/FlClashX',
      'android-arm64-v8a',
      '',
    );
    expect(release.androidVersionCode, 2026104501);
    expect(release.isNewerThan('0.9.2', 2026104500), isTrue);
    expect(release.isNewerThan('0.9.2', 2026104501), isFalse);
    expect(release.isNewerThan('0.9.1', 2026104501), isFalse);
    expect(
      () => AppUpdateRelease.parse(
        payload,
        'owner/FlClashX',
        'android-x86_64',
        '',
      ),
      throwsUnsupportedError,
    );
    for (final invalid in [
      {...android, 'versionCode': 0},
      {
        ...android,
        'url': (android['url'] as String).replaceFirst(
          'arm64-v8a.apk',
          'x86_64.apk',
        ),
      },
      {
        ...android,
        'url': (android['url'] as String).replaceFirst('/v0.9.2/', '/other/'),
      },
      {...android, 'sha256': 123},
    ]) {
      (payload['assets'] as Map)['android-arm64-v8a'] = invalid;
      expect(
        () => AppUpdateRelease.parse(
          payload,
          'owner/FlClashX',
          'android-arm64-v8a',
          '',
          tag: 'v0.9.2',
        ),
        throwsFormatException,
      );
    }
  });
  test('returns an APK only after download verification', () async {
    final bytes = [1, 2, 3, 4];
    final dio = Dio()..httpClientAdapter = _DownloadAdapter(bytes);
    addTearDown(dio.close);
    final release = AppUpdateRelease(
      version: '0.9.2',
      build: 2,
      url: Uri.parse(
        'https://github.com/owner/FlClashX/releases/download/v1/FlClashX-0.9.2-android-arm64-v8a.apk',
      ),
      sha256Hex: sha256.convert(bytes).toString(),
      size: bytes.length,
      notes: '',
      androidVersionCode: 2002,
    );
    final updater = AppUpdater(client: dio);
    final cancel = CancelToken();
    await expectLater(
      updater.download(release, cancel, (_) => cancel.cancel()),
      throwsA(isA<DioException>()),
    );
    final file = await updater.download(release, CancelToken(), (_) {});
    addTearDown(() => discardDownloadedUpdate(file));
    expect(file.path, endsWith('FlClashX-update.apk'));
    expect(await file.readAsBytes(), bytes);
  });
  test(
    'rejects upstream packages, mismatched origin, and missing architecture',
    () {
      expect(
        () => AppUpdateRelease.parse(
          manifest(app: 'FlClash'),
          'owner/FlClashX',
          'windows-amd64',
          '',
        ),
        throwsFormatException,
      );
      expect(
        () => AppUpdateRelease.parse(
          manifest(
            url:
                'https://github.com/chen08209/FlClash/releases/download/v0.9.2/FlClashX.exe',
          ),
          'owner/FlClashX',
          'windows-amd64',
          '',
        ),
        throwsFormatException,
      );
      expect(
        () => AppUpdateRelease.parse(
          manifest(),
          'owner/FlClashX',
          'windows-arm64',
          '',
        ),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'worker quotes paths and waits for the exact parent before installing',
    () {
      final script = windowsUpdateScript(
        installer: r"C:\Users\O'Brien\FlClashX-update.exe",
        executable: r'C:\Program Files\FlClashX\FlClashX.exe',
        parentPid: 123,
        readyPath: r"C:\Users\O'Brien\ready",
      );
      expect(script, contains("O''Brien"));
      expect(script, contains('Get-Process -Id 123'));
      expect(
        script.indexOf('WaitForExit'),
        lessThan(script.indexOf('-Verb RunAs')),
      );
      expect(script, contains('/NORESTART'));
      expect(script, contains('finally'));
    },
  );
}
