import 'dart:io';

import 'package:fl_clash/core/backup_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void useGoBackupCodec() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('flclash-backup-codec-');
    final executable = path.join(directory.path, Platform.isWindows ? 'codec.exe' : 'codec');
    final result = await Process.run(
      Platform.environment['FLCLASHX_TEST_GO'] ?? 'go',
      ['build', '-o', executable, '../test/support/backup_codec/main.go'],
      workingDirectory: path.join(Directory.current.path, 'core'),
      environment: {'CGO_ENABLED': '0'},
    );
    if (result.exitCode != 0) {
      throw StateError('Building backup codec failed: ${result.stderr}');
    }
    backupCodecTestExecutable = executable;
  });
  tearDownAll(() async {
    backupCodecTestExecutable = null;
    await directory.delete(recursive: true);
  });
}
