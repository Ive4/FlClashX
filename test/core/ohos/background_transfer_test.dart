import 'package:fl_clash/core/ohos/background_transfer.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.follow.clash/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'background transfer reports actual counters without a percentage',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'updateTransfer');
        expect(call.arguments, {'up': 1536, 'down': 32768});
        return null;
      });
      await OhosBackgroundTransfer.update(const Traffic(up: 1536, down: 32768));
    },
  );

  test('a rejected notification does not interrupt the running Core', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'notification_disabled');
    });
    await OhosBackgroundTransfer.update(const Traffic(up: 42));
  });
}
