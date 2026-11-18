import 'dart:convert';

import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

class ApplicationHistoryEntry {
  const ApplicationHistoryEntry(this.identity, this.firstSeen, this.lastSeen);
  final ApplicationIdentity identity;
  final DateTime firstSeen;
  final DateTime lastSeen;
}

class ApplicationHistory extends ChangeNotifier {
  ApplicationHistory({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? preferences.getApplicationHistory,
       _write = write ?? preferences.saveApplicationHistory;

  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final entries = <String, ApplicationHistoryEntry>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  DateTime? _lastSave;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await _read();
    var merged = false;
    if (raw != null) {
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
            merged |= !_merge(ApplicationHistoryEntry(identity, first, last));
          } catch (_) {
            /* Skip a damaged entry, retaining the others. */
          }
        }
      } catch (_) {
        /* Old or damaged history does not prevent startup. */
      }
    }
    notifyListeners();
    if (merged) {
      await _save().catchError((Object _) {});
    }
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
    DateTime at, {
    bool preservePaths = true,
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
      added |= _merge(ApplicationHistoryEntry(identity, at, at));
    }
    if (!recorded) return;
    if (added ||
        _lastSave == null ||
        at.difference(_lastSave!).inSeconds >= 30) {
      _lastSave = at;
      notifyListeners();
      await _save();
    }
  }

  List<Package> packages(AccessControlProps access, {required bool windows}) {
    final identities = {
      for (final MapEntry(:key, :value) in entries.entries)
        if (value.identity.windows == windows) key: value.identity,
    };
    for (final key in {...access.acceptList, ...access.rejectList}) {
      final identity = ApplicationIdentity.fromSelection(key, windows: windows);
      if (identity == null) continue;
      identities.putIfAbsent(identity.forRouting.selectionKey, () => identity);
    }
    return [
      for (final MapEntry(key: key, value: identity) in identities.entries)
        Package(
          packageName: key,
          label: identity.name,
          system: false,
          internet: true,
          lastUpdateTime: entries[key]?.lastSeen.millisecondsSinceEpoch ?? 0,
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

final applicationHistory = ApplicationHistory();
