import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/backup_xz.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/core/backup_codec.dart' show runBackupWorker;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart';

enum BackupFailure { invalid, newerVersion }

final class BackupException implements Exception {
  final BackupFailure failure;

  const BackupException(this.failure);

  @override
  String toString() => 'BackupException(${failure.name})';
}

/// Archive entries mirror the data directory, so an entry name is also the
/// file's path relative to the home directory.
abstract final class BackupEntries {
  static String profile(Object id) => '$profilesDirectoryName/$id.yaml';

  static String script(Object id) => 'scripts/$id.js';

  static String provider(ClashProvider provider) =>
      '$providersDirectoryName/$rulesProviderDirectoryName/${provider.fileName}';

  /// A remote provider's cache belongs to the Core and downloads again.
  static List<String> of({
    required Iterable<int> profileIds,
    required Iterable<int> scriptIds,
    required Iterable<ClashProvider> providers,
  }) {
    return [
      ...profileIds.map(profile),
      ...scriptIds.map(script),
      ...providers.where((item) => !item.isRemote).map(provider),
    ];
  }

  static List<String> ofData(MigrationData data) {
    return of(
      profileIds: data.profiles.map((item) => item.id),
      scriptIds: data.scripts.map((item) => item.id),
      providers: data.clashProviders,
    );
  }

  static String resolve(String root, String entry) {
    return joinAll([root, ...posix.split(entry)]);
  }
}

typedef BackupArchiveRequest = ({
  String archivePath,
  Map<String, Object?> configMap,
  String databaseSnapshotPath,
  String homeDirPath,
  List<String> entries,
});

typedef RestoreArchiveRequest = ({String archivePath, String stagingDirPath});

Future<void> backupTask(BackupArchiveRequest request) {
  return runBackupWorker(_backupTask, request);
}

Future<void> _backupTask(BackupArchiveRequest request) {
  return writeBackupArchive(
    archivePath: request.archivePath,
    configMap: request.configMap,
    databaseSnapshotPath: request.databaseSnapshotPath,
    homeDirPath: request.homeDirPath,
    entries: request.entries,
  );
}

Future<void> writeCompressedBackupArchive(BackupArchiveRequest request) async {
  final archive = Archive();
  var size = 0;
  void add(String name, List<int> bytes) {
    size += bytes.length + 1024;
    if (size > backupMaxExpandedBytes - 2048) {
      throw const BackupException(BackupFailure.invalid);
    }
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  Future<void> addFile(String name, String path) async {
    final file = File(path);
    if (await file.length() + size > backupMaxExpandedBytes - 4096) {
      throw const BackupException(BackupFailure.invalid);
    }
    add(name, await file.readAsBytes());
  }
  add(configJsonName, utf8.encode(jsonEncode(request.configMap)));
  await addFile(backupDatabaseName, request.databaseSnapshotPath);
  for (final entry in request.entries) {
    final path = BackupEntries.resolve(request.homeDirPath, entry);
    if (await File(path).exists()) await addFile(entry, path);
  }
  final tar = TarEncoder().encodeBytes(archive);
  if (tar.length > backupMaxExpandedBytes) {
    throw const BackupException(BackupFailure.invalid);
  }
  final compressed = await encodeBackupXz(tar);
  await File(request.archivePath).writeAsBytes(compressed, flush: true);
}

typedef MergeBackupRequest = ({
  String localPath,
  String remotePath,
  String outputPath,
  String workDir,
});

Future<void> mergeBackupTask(MergeBackupRequest request) {
  return runBackupWorker(mergeBackupArchives, request);
}

Future<void> mergeBackupArchives(MergeBackupRequest request) async {
  final localDir = join(request.workDir, 'merge-local');
  final remoteDir = join(request.workDir, 'merge-remote');
  final local = await readBackupArchive(
    archivePath: request.localPath, stagingDirPath: localDir,
  );
  final remote = await readBackupArchive(
    archivePath: request.remotePath, stagingDirPath: remoteDir,
  );
  final mergedDir = join(request.workDir, 'merge-result');
  await Directory(mergedDir).create(recursive: true);
  final snapshot = join(mergedDir, backupDatabaseName);
  final merged = Database(NativeDatabase.memory());
  late List<String> entries;
  try {
    for (final data in [remote, local]) {
      await merged.restore(
        data.profiles, data.scripts, data.rules, data.disabledRules,
        data.proxyGroups, clashProviders: data.clashProviders,
        customProxies: data.customProxies, proxyDialers: data.proxyDialers,
      );
    }
    entries = BackupEntries.of(
      profileIds: await merged.profilesDao.ids().get(),
      scriptIds: (await merged.scriptsDao.query().get()).map((item) => item.id),
      providers: await merged.clashProvidersDao.query().get(),
    );
    await merged.customStatement('VACUUM INTO ?', [snapshot]);
  } finally {
    await merged.close();
  }
  final localEntries = BackupEntries.ofData(local).toSet();
  for (final entry in entries) {
    final source = File(BackupEntries.resolve(
      localEntries.contains(entry) ? localDir : remoteDir, entry,
    ));
    if (!await source.exists()) continue;
    final target = File(BackupEntries.resolve(mergedDir, entry));
    await target.parent.create(recursive: true);
    await source.copy(target.path);
  }
  await writeCompressedBackupArchive((
    archivePath: request.outputPath,
    configMap: {...?local.configMap, 'version': Migration.currentVersion},
    databaseSnapshotPath: snapshot,
    homeDirPath: mergedDir,
    entries: entries,
  ));
}

Future<MigrationData> restoreTask(RestoreArchiveRequest request) {
  return runBackupWorker(_restoreTask, request);
}

Future<MigrationData> _restoreTask(RestoreArchiveRequest request) {
  return readBackupArchive(
    archivePath: request.archivePath,
    stagingDirPath: request.stagingDirPath,
  );
}

@visibleForTesting
Future<void> writeBackupArchive({
  required String archivePath,
  required Map<String, Object?> configMap,
  required String databaseSnapshotPath,
  required String homeDirPath,
  required Iterable<String> entries,
}) async {
  return writeCompressedBackupArchive((
    archivePath: archivePath,
    configMap: configMap,
    databaseSnapshotPath: databaseSnapshotPath,
    homeDirPath: homeDirPath,
    entries: entries.toList(),
  ));
}

/// Writes nothing outside [stagingDirPath]; the files the result names are left
/// there at their [BackupEntries] paths.
@visibleForTesting
Future<MigrationData> readBackupArchive({
  required String archivePath,
  required String stagingDirPath,
}) async {
  await _extract(archivePath, stagingDirPath);
  final configFile = File(join(stagingDirPath, configJsonName));
  if (!await configFile.exists()) {
    throw const BackupException(BackupFailure.invalid);
  }
  final configMap = _decodeConfig(await configFile.readAsString());
  final version = configMap['version'] ?? 0;
  if (version is! int) {
    throw const BackupException(BackupFailure.invalid);
  }
  if (version > Migration.currentVersion) {
    throw const BackupException(BackupFailure.newerVersion);
  }
  if (version == 0) {
    return migrateLegacyConfig(
      configMap: configMap,
      sourcePath: stagingDirPath,
      targetPath: stagingDirPath,
    );
  }
  final databaseFile = File(join(stagingDirPath, backupDatabaseName));
  if (!await databaseFile.exists()) {
    return MigrationData(configMap: configMap);
  }
  final schemaVersion = await _readSchemaVersion(databaseFile);
  final database = Database(
    driftDatabase(
      name: basenameWithoutExtension(backupDatabaseName),
      // Left unset, drift asks path_provider for a temp directory, and this
      // isolate has no platform channel to answer it.
      native: DriftNativeOptions(
        databaseDirectory: () async => Directory(stagingDirPath),
        tempDirectoryPath: () async => stagingDirPath,
      ),
    ),
  );
  try {
    if (schemaVersion > database.schemaVersion) {
      throw const BackupException(BackupFailure.newerVersion);
    }
    final results = await Future.wait([
      database.profilesDao.query().get(),
      database.scriptsDao.query().get(),
      (database.select(database.rules)..orderBy([
            (t) => OrderingTerm(expression: t.order, nulls: NullsOrder.last),
          ]))
          .map((item) => item.toRule())
          .get(),
      database
          .select(database.disabledRules)
          .map((item) => item.toDisabledRule())
          .get(),
      (database.select(database.proxyGroups)..orderBy([
            (t) => OrderingTerm(expression: t.order, nulls: NullsOrder.last),
          ]))
          .map((item) => item.toProxyGroup())
          .get(),
      database.clashProvidersDao.query().get(),
      database.customProxiesDao.query().get(),
      database.proxyDialers.readable((row) => row.toProxyDialer()).get(),
    ]);
    return MigrationData(
      configMap: configMap,
      profiles: results[0].cast<Profile>(),
      scripts: results[1].cast<Script>(),
      rules: results[2].cast<Rule>(),
      disabledRules: results[3].cast<DisabledRule>(),
      proxyGroups: results[4].cast<ProxyGroup>(),
      clashProviders: results[5].cast<ClashProvider>(),
      customProxies: results[6].cast<CustomProxy>(),
      proxyDialers: results[7].cast<ProxyDialer>(),
    );
  } finally {
    await database.close();
  }
}

Future<void> _extract(String archivePath, String stagingDirPath) async {
  await Directory(stagingDirPath).create(recursive: true);
  if (await File(archivePath).length() > backupMaxExpandedBytes + 1024 * 1024) {
    throw const BackupException(BackupFailure.invalid);
  }
  final input = InputFileStream(archivePath);
  try {
    final Archive archive;
    try {
      final tar = await decodeBackupXz(input.toUint8List());
      archive = TarDecoder().decodeBytes(tar);
    } on Exception {
      throw const BackupException(BackupFailure.invalid);
    }
    for (final file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      final outPath = _stagedEntryPath(stagingDirPath, file.name);
      if (outPath == null) {
        continue;
      }
      await Directory(dirname(outPath)).create(recursive: true);
      final output = OutputFileStream(outPath);
      try {
        file.writeContent(output);
      } finally {
        await output.close();
      }
    }
  } finally {
    await input.close();
  }
}

/// `posix.normalize` collapses `a/../b`, but a name that starts with `../`
/// normalizes to itself and an absolute one stays absolute, so either would
/// write wherever the archive asks. A backup file is untrusted input.
String? _stagedEntryPath(String stagingDirPath, String name) {
  final normalized = posix.normalize(name.replaceAll('\\', '/'));
  if (normalized.isEmpty ||
      posix.isAbsolute(normalized) ||
      normalized == '..' ||
      normalized.startsWith('../')) {
    return null;
  }
  final outPath = normalize(BackupEntries.resolve(stagingDirPath, normalized));
  if (!isWithin(stagingDirPath, outPath)) {
    return null;
  }
  return outPath;
}

Map<String, Object?> _decodeConfig(String source) {
  final Object? decoded;
  try {
    decoded = json.decode(source);
  } on FormatException {
    throw const BackupException(BackupFailure.invalid);
  }
  if (decoded is! Map<String, Object?>) {
    throw const BackupException(BackupFailure.invalid);
  }
  return decoded;
}

/// Opening the database through drift would already run its migrations, so the
/// version is read from the file header: SQLite keeps `user_version` as a
/// big-endian integer at byte 60.
Future<int> _readSchemaVersion(File databaseFile) async {
  final handle = await databaseFile.open();
  try {
    final header = await handle.read(64);
    if (header.length < 64) {
      throw const BackupException(BackupFailure.invalid);
    }
    return ByteData.sublistView(header).getInt32(60);
  } finally {
    await handle.close();
  }
}
