import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';

import '../helpers/backup_codec.dart';

void main() {
  useGoBackupCodec();
  test('merge preserves both sets of IDs; local conflicts and settings win', () async {
    final root = await Directory.systemTemp.createTemp('backup-merge-');
    addTearDown(() => root.delete(recursive: true));

    Future<String> backup(String name, Map<int, String> profiles) async {
      final directory = await Directory(join(root.path, name)).create();
      final source = db.Database(NativeDatabase.memory());
      final snapshot = join(directory.path, backupDatabaseName);
      try {
        await source.profilesDao.putAll([
          for (final entry in profiles.entries)
            Profile(id: entry.key, label: entry.value,
              autoUpdateDuration: Duration.zero).toCompanion(),
        ]);
        await source.customStatement('VACUUM INTO ?', [snapshot]);
      } finally {
        await source.close();
      }
      for (final entry in profiles.entries) {
        final file = File(BackupEntries.resolve(directory.path, BackupEntries.profile(entry.key)));
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value);
      }
      final path = join(directory.path, 'backup.tar.xz');
      await writeBackupArchive(
        archivePath: path,
        configMap: {'version': Migration.currentVersion, 'source': name},
        databaseSnapshotPath: snapshot,
        homeDirPath: directory.path,
        entries: profiles.keys.map(BackupEntries.profile),
      );
      return path;
    }

    final local = await backup('local', {1: 'Local conflict', 2: 'Local only'});
    final remote = await backup('remote', {1: 'Remote conflict', 3: 'Remote only'});
    final original = await File(local).readAsBytes();
    final output = join(root.path, 'merged.tar.xz');
    await mergeBackupArchives((
      localPath: local, remotePath: remote, outputPath: output, workDir: root.path,
    ));
    final staging = join(root.path, 'verify');
    final restored = await readBackupArchive(archivePath: output, stagingDirPath: staging);
    expect({for (final p in restored.profiles) p.id: p.label}, {
      1: 'Local conflict', 2: 'Local only', 3: 'Remote only',
    });
    expect(restored.configMap?['source'], 'local');
    for (final profile in restored.profiles) {
      expect(await File(BackupEntries.resolve(staging, BackupEntries.profile(profile.id))).readAsString(), profile.label);
    }
    expect(await File(local).readAsBytes(), original);
    expect(jsonEncode(restored.configMap), isNot(contains('password')));
  });
}
