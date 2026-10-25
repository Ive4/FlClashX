import 'dart:typed_data';

import 'package:fl_clash/core/backup_codec.dart';

export 'package:fl_clash/core/backup_codec.dart' show backupMaxExpandedBytes;

Future<Uint8List> encodeBackupXz(Uint8List data) =>
    invokeBackupCodec('compress', data);

Future<Uint8List> decodeBackupXz(List<int> data) => invokeBackupCodec(
  'decompress',
  data is Uint8List ? data : Uint8List.fromList(data),
);
