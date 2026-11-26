import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class ApplicationHistoryEntry {
  const ApplicationHistoryEntry(this.identity, this.firstSeen, this.lastSeen);
  final ApplicationIdentity identity;
  final DateTime firstSeen;
  final DateTime lastSeen;
}

class ApplicationHistory extends ChangeNotifier {
  ApplicationHistory({
    Future<String?> Function()? read,
    Future<String?> Function()? readBackground,
    Future<void> Function(String)? write,
  }) : _read = read ?? preferences.getApplicationHistory,
       _readBackground = readBackground,
       _write = write ?? preferences.saveApplicationHistory;

  final Future<String?> Function() _read;
  final Future<String?> Function()? _readBackground;
  final Future<void> Function(String) _write;
  final entries = <String, ApplicationHistoryEntry>{};
  Future<void>? _loading;
  Future<void>? _refreshing;
  Future<void> _writes = Future.value();
  DateTime? _lastSave;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await _read();
    var merged = false;
    for (final entry in _decode(raw)) {
      merged |= !_merge(entry);
    }
    notifyListeners();
    if (merged) {
      await _save().catchError((Object _) {});
    }
  }

  Future<void> refreshBackground() =>
      _refreshing ??= _mergeBackground().whenComplete(() => _refreshing = null);

  Future<void> _mergeBackground() async {
    final String? raw;
    try {
      raw = await _readBackground?.call();
    } on FileSystemException {
      return;
    }
    if (raw == null) return;
    await load();
    final history = await compute(_decode, raw);
    var changed = false;
    for (final entry in history) {
      final previous = entries[entry.identity.forRouting.selectionKey];
      if (previous == null ||
          entry.firstSeen.isBefore(previous.firstSeen) ||
          entry.lastSeen.isAfter(previous.lastSeen)) {
        _merge(entry);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  static List<ApplicationHistoryEntry> _decode(String? raw) {
    if (raw == null) return const [];
    final result = <ApplicationHistoryEntry>[];
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      for (final row in data['entries'] as List) {
        try {
          final identity = ApplicationIdentity(
            action: row['path'] == true
                ? RuleAction.PROCESS_PATH
                : RuleAction.PROCESS_NAME,
            content: row['content'] as String,
            windows: row['windows'] == true,
          );
          if (!identity.canRoute) continue;
          final first = DateTime.parse(row['first'] as String);
          final last = DateTime.parse(row['last'] as String);
          result.add(ApplicationHistoryEntry(identity, first, last));
        } catch (_) {}
      }
    } catch (_) {}
    return result;
  }

  bool _merge(ApplicationHistoryEntry entry) {
    final key = entry.identity.forRouting.selectionKey;
    final old = entries[key];
    if (old == null) {
      entries[key] = entry;
      return true;
    }
    final latest = entry.lastSeen.isAfter(old.lastSeen) ? entry : old;
    final first = entry.firstSeen.isBefore(old.firstSeen)
        ? entry.firstSeen
        : old.firstSeen;
    entries[key] = ApplicationHistoryEntry(
      latest.identity,
      first,
      latest.lastSeen,
    );
    return false;
  }

  Future<void> record(
    List<ApplicationConnection> connections,
    bool windows,
    DateTime? at, {
    bool preservePaths = true,
    bool persist = true,
  }) async {
    await load();
    var added = false;
    var recorded = false;
    for (final connection in connections) {
      final identity = ApplicationIdentity.fromConnection(
        connection,
        windows: windows,
        preservePath: preservePaths,
      );
      if (!identity.canRoute) continue;
      recorded = true;
      final seen = at ?? connection.start;
      added |= _merge(ApplicationHistoryEntry(identity, seen, seen));
    }
    if (!recorded) return;
    final now = at ?? DateTime.now();
    if (added ||
        _lastSave == null ||
        now.difference(_lastSave!).inSeconds >= 30) {
      _lastSave = now;
      notifyListeners();
      if (persist) await _save();
    }
  }

  List<Package> packages(AccessControlProps access, {required bool windows}) {
    final identities = {
      for (final MapEntry(:key, :value) in entries.entries)
        if (value.identity.windows == windows) key: value.identity,
    };
    final selected = <String>{};
    for (final key in {...access.acceptList, ...access.rejectList}) {
      final identity = ApplicationIdentity.fromSelection(key, windows: windows);
      if (identity == null) continue;
      final routingKey = identity.forRouting.selectionKey;
      selected.add(routingKey);
      identities.putIfAbsent(routingKey, () => identity);
    }
    final lastSeen = <String, DateTime>{};
    if (windows) {
      final pathsByName = <String, String?>{};
      for (final MapEntry(:key, :value) in identities.entries) {
        if (value.action == RuleAction.PROCESS_NAME) continue;
        final name = value.name.toLowerCase();
        pathsByName[name] = pathsByName.containsKey(name) ? null : key;
      }
      for (final MapEntry(:key, :value) in entries.entries) {
        final identity = value.identity;
        if (!identity.windows ||
            identity.action != RuleAction.PROCESS_NAME ||
            selected.contains(key)) {
          continue;
        }
        final pathKey = pathsByName[identity.name.toLowerCase()];
        if (pathKey == null) continue;
        identities.remove(key);
        final pathLastSeen = entries[pathKey]?.lastSeen;
        if (pathLastSeen == null || value.lastSeen.isAfter(pathLastSeen)) {
          lastSeen[pathKey] = value.lastSeen;
        }
      }
    }
    return [
      for (final MapEntry(key: key, value: identity) in identities.entries)
        Package(
          packageName: key,
          label: identity.name,
          system: false,
          internet: true,
          lastUpdateTime:
              (lastSeen[key] ?? entries[key]?.lastSeen)
                  ?.millisecondsSinceEpoch ??
              0,
          applicationPath: identity.action == RuleAction.PROCESS_PATH
              ? identity.content
              : null,
        ),
    ];
  }

  Future<void> _save() {
    final value = jsonEncode({
      'entries': [
        for (final entry in entries.values)
          {
            'path': entry.identity.action == RuleAction.PROCESS_PATH,
            'content': entry.identity.content,
            'windows': entry.identity.windows,
            'first': entry.firstSeen.toIso8601String(),
            'last': entry.lastSeen.toIso8601String(),
          },
      ],
    });
    final write = _writes.then((_) => _write(value));
    _writes = write.catchError((Object _) {});
    return write;
  }
}

Future<String?> Function() _backgroundHistoryReader() {
  FileStat? lastRead;
  return () async {
    final file = File(
      p.join(await appPath.homeDirPath, 'application-history.json'),
    );
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      lastRead = null;
      return null;
    }
    if (lastRead?.modified == stat.modified && lastRead?.size == stat.size) {
      return null;
    }
    final raw = await file.readAsString();
    lastRead = stat;
    return raw;
  };
}

final applicationHistory = ApplicationHistory(
  readBackground: _backgroundHistoryReader(),
);
