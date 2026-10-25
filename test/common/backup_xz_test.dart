import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/backup_xz.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/backup_codec.dart';

void main() {
  useGoBackupCodec();
  test('reads an XZ fixture produced by reference liblzma', () async {
    final bytes = base64Decode('/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4AIbACRdACMbBGbnKW+r+kmXGQ4tFXwSXgKUJbz5Pu5lbaKuwmWkzsoAAAAbnc0CT8kyZAABQJwEAAAA94OZV7HEZ/sCAAAAAARZWg==');
    expect(await decodeBackupXz(bytes), utf8.encode('FlClashX reference fixture\n' * 20));
  });

  test('real LZMA2 compression reduces repeated data and round trips', () async {
    final bytes = Uint8List.fromList(utf8.encode('proxy-rule: example.com\n' * 10000));
    final compressed = await encodeBackupXz(bytes);
    expect(compressed.take(6), [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]);
    expect(compressed.length, lessThan(bytes.length ~/ 10));
    expect(await decodeBackupXz(compressed), bytes);
  });

  test('empty data and multiple LZMA2 chunks round trip', () async {
    for (final bytes in [Uint8List(0), Uint8List.fromList(
      List.generate(3 * 1024 * 1024, (i) => (i * 31 + i ~/ 7) & 255),
    )]) {
      expect(await decodeBackupXz(await encodeBackupXz(bytes)), bytes);
    }
  });

  test('corrupted XZ checksum is rejected', () async {
    final bytes = await encodeBackupXz(Uint8List.fromList([1, 2, 3]));
    bytes[8] ^= 1;
    expect(() => decodeBackupXz(bytes), throwsA(anything));
  });
}
