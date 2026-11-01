import 'dart:convert';
import 'package:fl_clash/common/application_history.dart';
import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'history survives reload, merges installs by name, and remembers the view',
    () async {
      String? saved;
      ApplicationHistory store() => ApplicationHistory(
        read: () async => saved,
        write: (value) async {
          saved = value;
        },
      );
      final history = store();
      final at = DateTime.utc(2026, 10, 25);
      ApplicationConnection connection(String path) => (
        id: '1',
        process: 'browser.exe',
        path: path,
        outbound: 'DIRECT',
        start: at,
        upload: 0,
        download: 0,
      );
      await history.record([connection(r'C:\Apps\Browser.exe')], true, at);
      await history.record(
        [connection(r'D:\Apps\v2\browser.exe')],
        true,
        at.add(const Duration(minutes: 1)),
      );
      await history.select(true);
      final reloaded = store();
      await reloaded.load();
      expect(reloaded.entries.length, 1);
      expect(
        reloaded.entries.values.single.identity.action,
        RuleAction.PROCESS_NAME,
      );
      expect(reloaded.entries.values.single.identity.content, 'browser.exe');
      expect(reloaded.entries.values.single.firstSeen, at);
      expect(
        reloaded.entries.values.single.lastSeen,
        at.add(const Duration(minutes: 1)),
      );
      expect(reloaded.showHistory, isTrue);
      await reloaded.remove(reloaded.entries.keys.single);
      expect((jsonDecode(saved!) as Map)['entries'], isEmpty);
      history.dispose();
      reloaded.dispose();
    },
  );

  test(
    'saved paths and names merge with their full first and last seen range',
    () async {
      final at = DateTime.utc(2026, 10, 25);
      final history = ApplicationHistory(
        read: () async => jsonEncode({
          'entries': [
            for (final row in [
              (content: r'C:\Apps\Browser.exe', path: true, first: 2, last: 4),
              (content: 'browser.exe', path: false, first: 1, last: 3),
              (content: r'D:\Apps\BROWSER.exe', path: true, first: 3, last: 5),
            ])
              {
                'content': row.content,
                'path': row.path,
                'windows': true,
                'first': at.add(Duration(minutes: row.first)).toIso8601String(),
                'last': at.add(Duration(minutes: row.last)).toIso8601String(),
              },
          ],
        }),
        write: (_) async {},
      );
      await history.load();
      final entry = history.entries.values.single;
      expect(entry.identity.key, 'PROCESS-NAME:browser.exe');
      expect(entry.firstSeen, at.add(const Duration(minutes: 1)));
      expect(entry.lastSeen, at.add(const Duration(minutes: 5)));
      history.dispose();
    },
  );

  test(
    'missing process names use the same filename identity as live statistics',
    () async {
      final at = DateTime.utc(2026, 10, 25);
      final history = ApplicationHistory(
        read: () async => null,
        write: (_) async {},
      );
      await history.record(
        [
          for (final path in ['/apps/v1/browser', '/apps/v2/browser'])
            (
              id: path,
              process: '',
              path: path,
              outbound: null,
              start: at,
              upload: 0,
              download: 0,
            ),
        ],
        false,
        at,
      );
      expect(
        history.entries.values.single.identity.key,
        'PROCESS-NAME:browser',
      );
      history.dispose();
    },
  );

  test(
    'unknown processes are excluded and damaged history is recoverable',
    () async {
      final history = ApplicationHistory(
        read: () async => '{bad',
        write: (_) async {},
      );
      await history.record(
        [
          (
            id: 'unknown',
            process: '',
            path: '',
            outbound: null,
            start: DateTime(2026),
            upload: 0,
            download: 0,
          ),
        ],
        false,
        DateTime(2026),
      );
      expect(history.entries, isEmpty);
      await history.remove(null);
      history.dispose();
    },
  );
}
