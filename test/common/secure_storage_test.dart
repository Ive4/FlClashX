import 'package:fl_clash/common/secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('HarmonyOS sessions use the native secure storage channel', () async {
    final values = <String, String>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map;
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          values[key] = arguments['value'] as String;
        case 'delete':
          values.remove(key);
        default:
          fail('Unexpected method ${call.method}');
      }
      return null;
    });
    final storage = SessionStorage(isOhos: true);

    expect(await storage.read(key: 'session'), isNull);
    await storage.write(key: 'session', value: '会话-token');
    expect(await storage.read(key: 'session'), '会话-token');
    await storage.delete(key: 'session');
    expect(await storage.read(key: 'session'), isNull);
  });

  test(
    'secure storage failures propagate without an insecure fallback',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'secure_storage_failed');
      });
      final storage = SessionStorage(isOhos: true);

      await expectLater(
        storage.read(key: 'session'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        storage.write(key: 'session', value: 'token'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        storage.delete(key: 'session'),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
