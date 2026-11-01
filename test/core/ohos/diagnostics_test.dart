import 'package:fl_clash/core/ohos/diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.follow.clash/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('diagnostics remain readable independently of the dead Core', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'diagnostics');
      return 'system_APP_KILLED LowMemoryKill';
    });
    expect(await OhosDiagnostics.read(), contains('LowMemoryKill'));
  });

  test('a diagnostic write failure does not block Core recovery', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'storage_unavailable');
    });
    await OhosDiagnostics.record('recovery_started');
    expect(await OhosDiagnostics.read(), contains('storage_unavailable'));
  });

  test('an older native plugin can still export ordinary logs', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await OhosDiagnostics.read(), '');
    expect(await OhosDiagnostics.canRecover(), isFalse);
  });
}
