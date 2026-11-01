import 'dart:async';

import 'package:fl_clash/core/ohos/recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late OhosCoreRecovery recovery;
  late List<String> events;
  late DateTime now;
  late bool wanted;
  late int calls;
  late bool eligible;
  late Future<bool> Function() restore;

  setUp(() {
    events = [];
    now = DateTime(2026, 10, 27);
    wanted = true;
    calls = 0;
    eligible = true;
    restore = () async => true;
    recovery = OhosCoreRecovery(
      recover: () {
        calls++;
        return restore();
      },
      shouldRecover: () => wanted,
      canRecover: () async => eligible,
      record: events.add,
      now: () => now,
    );
  });

  tearDown(() => recovery.dispose());

  test(
    'a background disconnect restores without waiting for foreground',
    () async {
      recovery.request();
      await pumpEventQueue();
      expect(calls, 1);
      expect(events, contains('recovery_in_background'));
      expect(events.last, 'recovery_succeeded');
      recovery.setForeground(true);
      expect(calls, 1);
    },
  );

  test('a failed background restore retries once on foreground', () async {
    restore = () async => false;
    recovery.request();
    await pumpEventQueue();
    expect(calls, 1);
    expect(events.last, 'recovery_deferred_until_foreground');
    restore = () async => true;
    recovery.setForeground(true);
    await pumpEventQueue();
    expect(calls, 2);
    expect(events.last, 'recovery_succeeded');
  });

  test(
    'a stop cancels a failed background restore before foreground',
    () async {
      restore = () async => throw StateError('background launch rejected');
      recovery.request();
      await pumpEventQueue();
      expect(calls, 1);
      expect(events.last, 'recovery_deferred_until_foreground');
      wanted = false;
      recovery.setForeground(true);
      await pumpEventQueue();
      expect(calls, 1);
      expect(events.last, 'recovery_cancelled');
    },
  );

  test('a stop while backgrounded cancels the pending recovery', () async {
    recovery.request();
    wanted = false;
    recovery.setForeground(true);
    await pumpEventQueue();
    expect(calls, 0);
    expect(events.last, 'recovery_cancelled');
  });

  test('overlapping disconnect and resume events coalesce', () async {
    final result = Completer<bool>();
    restore = () => result.future;
    recovery.setForeground(true);
    recovery.request();
    recovery.request();
    recovery.setForeground(true);
    await pumpEventQueue();
    expect(calls, 1);
    result.complete(true);
    await pumpEventQueue();
    expect(calls, 1);
    expect(
      events.where((event) => event == 'recovery_succeeded'),
      hasLength(1),
    );
  });

  test('repeated exits cannot cause an unlimited restart loop', () async {
    recovery.setForeground(true);
    for (var attempt = 0; attempt < 3; attempt++) {
      recovery.request();
      await pumpEventQueue();
    }
    expect(calls, 2);
    expect(events.last, 'recovery_rate_limited');
    now = now.add(const Duration(minutes: 2));
    recovery.request();
    await pumpEventQueue();
    expect(calls, 3);
  });

  test(
    'a failed restart is logged without an unhandled error or retry',
    () async {
      restore = () async => throw StateError('native start failed');
      recovery.setForeground(true);
      recovery.request();
      await pumpEventQueue();
      expect(calls, 1);
      expect(events.last, 'recovery_failed');
    },
  );

  test('disposal prevents a deferred restart', () async {
    recovery.request();
    recovery.dispose();
    recovery.setForeground(true);
    expect(calls, 0);
  });

  test(
    'a clean native teardown or system VPN disable is not restarted',
    () async {
      eligible = false;
      recovery.setForeground(true);
      recovery.request();
      await pumpEventQueue();
      expect(calls, 0);
      expect(events.last, 'recovery_cancelled');
    },
  );
}
