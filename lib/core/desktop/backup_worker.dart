import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../backup_codec.dart' show backupMaxWireBytes, BackupCodecException;

Future<Uint8List> runDesktopBackupWorker(
  Uint8List input, {
  String? executable,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final binary = executable ??
      path.join(
        path.dirname(Platform.resolvedExecutable),
        Platform.isWindows ? 'FlClashCore.exe' : 'FlClashCore',
      );
  // This mode exits after one codec request, before any proxy lifecycle starts.
  final process = await Process.start(binary, ['--backup-codec']);
  var exited = false;
  final exitCode = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final result = await Future.wait<Object>([
      _readOutput(process.stdout),
      process.stderr.drain<void>().then((_) => true),
      exitCode,
      (() async {
        process.stdin.add(input);
        await process.stdin.close();
        return true;
      })(),
    ], eagerError: true).timeout(timeout);
    if (result[2] != 0) throw const BackupCodecException('internal');
    return result[0] as Uint8List;
  } finally {
    if (!exited) {
      process.kill();
      await exitCode.timeout(const Duration(seconds: 10));
    }
  }
}

Future<Uint8List> _readOutput(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > backupMaxWireBytes) {
      throw const BackupCodecException('tooLarge');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
