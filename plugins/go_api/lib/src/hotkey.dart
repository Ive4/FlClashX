import 'dart:async';
import 'dart:typed_data';

import 'bridge.dart';

enum HotKeyModifier { alt, capsLock, control, fn, meta, shift }

final class HotKeySpec {
  const HotKeySpec({
    required this.id,
    required this.key,
    required this.modifiers,
  });

  final int id;
  final int key;
  final List<HotKeyModifier> modifiers;

  Map<String, Object> _toJson() => {
    'id': id,
    'key': key,
    'modifiers': [for (final modifier in modifiers) modifier.name],
  };
}

final class HotKeyFailure {
  const HotKeyFailure({required this.id, required this.reason});

  final int id;
  final String reason;
}

Future<List<HotKeyFailure>> setHotKeys({
  required List<HotKeySpec> specs,
}) async {
  final failures =
      await GoApi.invokeAsync('hotkey.set', [
            for (final spec in specs) spec._toJson(),
          ])
          as List<Object?>;
  return [
    for (final failure in failures.cast<Map<String, Object?>>())
      HotKeyFailure(
        id: failure['id'] as int,
        reason: failure['reason'] as String,
      ),
  ];
}

Stream<int> hotKeyEvents() async* {
  final events = GoApi.openEvents();
  try {
    GoApi.invoke('hotkey.listen', {'events': events.id});
    await for (final event in events.stream) {
      yield ByteData.sublistView(event.data).getUint32(0, Endian.little);
    }
  } finally {
    try {
      GoApi.invoke('hotkey.unlisten', {'events': events.id});
    } finally {
      events.close();
    }
  }
}
