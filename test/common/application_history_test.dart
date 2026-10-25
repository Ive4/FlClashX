import 'dart:convert';
import 'package:fl_clash/common/application_history.dart';
import 'package:fl_clash/common/application_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('history survives reload, normalizes Windows paths, and remembers the view', () async {
    String? saved;
    ApplicationHistory store() => ApplicationHistory(
      read: () async => saved, write: (value) async { saved = value; });
    final history = store();
    final at = DateTime.utc(2026, 10, 25);
    ApplicationConnection connection(String path) => (
      id: '1', process: 'browser.exe', path: path, outbound: 'DIRECT',
      start: at, upload: 0, download: 0);
    await history.record([connection(r'C:\Apps\Browser.exe')], true, at);
    await history.record([connection(r'c:\apps\browser.exe')], true,
      at.add(const Duration(minutes: 1)));
    await history.select(true);
    final reloaded = store();
    await reloaded.load();
    expect(reloaded.entries.length, 1);
    expect(reloaded.entries.values.single.firstSeen, at);
    expect(reloaded.entries.values.single.lastSeen, at.add(const Duration(minutes: 1)));
    expect(reloaded.showHistory, isTrue);
    await reloaded.remove(reloaded.entries.keys.single);
    expect((jsonDecode(saved!) as Map)['entries'], isEmpty);
    history.dispose();
    reloaded.dispose();
  });

  test('unknown processes are excluded and damaged history is recoverable', () async {
    final history = ApplicationHistory(read: () async => '{bad', write: (_) async {});
    await history.record([(
      id: 'unknown', process: '', path: '', outbound: null,
      start: DateTime(2026), upload: 0, download: 0,
    )], false, DateTime(2026));
    expect(history.entries, isEmpty);
    await history.remove(null);
    history.dispose();
  });
}
