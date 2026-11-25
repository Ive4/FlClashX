@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fl_clash/core/desktop/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_api/go_api.dart';
import 'package:win32/win32.dart';

void main() {
  setUpAll(GoApi.initialize);

  test(
    'Go named-pipe callbacks deliver the peer PID and frame to Dart',
    () async {
      const timeout = Duration(seconds: 5);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final address =
          r'\\.\pipe\FlClashNativeTest-'
          '$pid-$suffix';
      final transport = IpcCoreTransport(address: address);
      addTearDown(transport.close);
      await transport.open();

      final connected = transport.waitUntilConnected(timeout);
      final opened = using(
        (arena) => CreateFile(
          PCWSTR(address.toNativeUtf16(allocator: arena)),
          GENERIC_WRITE,
          FILE_SHARE_NONE,
          null,
          OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL,
          null,
        ),
      );
      expect(opened.error, ERROR_SUCCESS);
      final peer = opened.value;
      try {
        expect((await connected).pid, pid);
        final frame = transport.frames.first.timeout(timeout);
        final payload = utf8.encode('ping');
        final written = using((arena) {
          final size = 4 + payload.length;
          final buffer = arena<Uint8>(size);
          final bytes = buffer.asTypedList(size)..setAll(4, payload);
          ByteData.sublistView(
            bytes,
          ).setUint32(0, payload.length, Endian.little);
          final count = arena<Uint32>();
          expect(WriteFile(peer, buffer, size, count, null).value, isTrue);
          return count.value;
        });
        expect(written, payload.length + 4);
        expect(utf8.decode(await frame), 'ping');
      } finally {
        CloseHandle(peer);
      }
    },
  );
}
