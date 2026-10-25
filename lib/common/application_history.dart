import 'dart:convert';

import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';

class ApplicationHistoryEntry {
  const ApplicationHistoryEntry(this.identity, this.firstSeen, this.lastSeen);
  final ApplicationIdentity identity;
  final DateTime firstSeen;
  final DateTime lastSeen;
}

class ApplicationHistory extends ChangeNotifier {
  ApplicationHistory({Future<String?> Function()? read,
    Future<void> Function(String)? write})
    : _read = read ?? preferences.getApplicationHistory,
      _write = write ?? preferences.saveApplicationHistory;

  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final entries = <String, ApplicationHistoryEntry>{};
  bool showHistory = false;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  DateTime? _lastSave;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await _read();
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        showHistory = data['showHistory'] == true;
        for (final row in data['entries'] as List) {
          try {
            final identity = ApplicationIdentity(
              action: row['path'] == true
                  ? RuleAction.PROCESS_PATH : RuleAction.PROCESS_NAME,
              content: row['content'] as String,
              windows: row['windows'] == true,
            );
            if (identity.content.trim().isEmpty) continue;
            entries[identity.key] = ApplicationHistoryEntry(identity,
              DateTime.parse(row['first'] as String),
              DateTime.parse(row['last'] as String));
          } catch (_) { /* Skip a damaged entry, retaining the others. */ }
        }
      } catch (_) { /* Old or damaged history does not prevent startup. */ }
    }
    notifyListeners();
  }

  Future<void> record(List<ApplicationConnection> connections, bool windows,
      DateTime at) async {
    await load();
    var added = false;
    for (final connection in connections) {
      final hasPath = connection.path.trim().isNotEmpty;
      final content = hasPath ? connection.path : connection.process;
      if (content.trim().isEmpty) continue;
      final identity = ApplicationIdentity(
        action: hasPath ? RuleAction.PROCESS_PATH : RuleAction.PROCESS_NAME,
        content: content, windows: windows);
      final old = entries[identity.key];
      if (old != null && old.lastSeen.isAfter(at)) continue;
      added |= old == null;
      entries[identity.key] = ApplicationHistoryEntry(
        identity, old?.firstSeen ?? at, at);
    }
    if (connections.isEmpty) return;
    notifyListeners();
    if (added || _lastSave == null || at.difference(_lastSave!).inSeconds >= 30) {
      _lastSave = at;
      await _save();
    }
  }

  Future<void> select(bool value) async {
    await load();
    showHistory = value;
    notifyListeners();
    await _save();
  }

  Future<void> remove(String? key) async {
    await load();
    if (key == null) {
      entries.clear();
    } else {
      entries.remove(key);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _save() {
    final value = jsonEncode({
      'showHistory': showHistory,
      'entries': [for (final entry in entries.values) {
        'path': entry.identity.action == RuleAction.PROCESS_PATH,
        'content': entry.identity.content,
        'windows': entry.identity.windows,
        'first': entry.firstSeen.toIso8601String(),
        'last': entry.lastSeen.toIso8601String(),
      }],
    });
    final write = _writes.then((_) => _write(value));
    _writes = write.catchError((Object _) {});
    return write;
  }
}

final applicationHistory = ApplicationHistory();
