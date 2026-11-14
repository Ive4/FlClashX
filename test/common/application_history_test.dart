import 'dart:convert';

import 'package:fl_clash/common/application_history.dart';
import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

ApplicationConnection connection(
  String path, {
  String process = 'browser.exe',
}) => (
  id: path,
  process: process,
  path: path,
  outbound: null,
  start: DateTime.utc(2026),
  upload: 0,
  download: 0,
);

void main() {
  test(
    'memory survives restart and distinguishes same-name programs',
    () async {
      String? saved;
      ApplicationHistory store() => ApplicationHistory(
        read: () async => saved,
        write: (value) async {
          saved = value;
        },
      );
      final history = store();
      await history.record(
        [
          connection(r'C:\Apps\Browser.exe'),
          connection(r'D:\Apps\Browser.exe'),
        ],
        true,
        DateTime.utc(2026),
      );
      final restored = store();
      await restored.load();
      expect(restored.entries.length, 2);
      expect(
        restored.entries.values.every(
          (entry) => entry.identity.action == RuleAction.PROCESS_PATH,
        ),
        isTrue,
      );
      final packages = restored.packages(
        const AccessControlProps(),
        windows: true,
      );
      expect(packages.map((app) => app.packageName).toSet(), {
        r'windows:PROCESS-PATH:c:\apps\browser.exe',
        r'windows:PROCESS-PATH:d:\apps\browser.exe',
      });
      history.dispose();
      restored.dispose();
    },
  );

  test(
    'Windows case changes merge, macOS app helpers share a bundle row',
    () async {
      final history = ApplicationHistory(
        read: () async => null,
        write: (_) async {},
      );
      final at = DateTime.utc(2026);
      await history.record(
        [connection(r'C:\Apps\Browser.exe'), connection('c:/apps/browser.EXE')],
        true,
        at,
      );
      expect(history.entries.length, 1);
      await history.record(
        [
          connection('/Applications/Chat.app/Contents/MacOS/Chat'),
          connection(
            '/Applications/Chat.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper',
          ),
          connection('/Applications/Other.app/Contents/MacOS/Chat'),
        ],
        false,
        at,
      );
      final packages = history.packages(
        const AccessControlProps(),
        windows: false,
      );
      expect(packages.map((app) => app.packageName).toSet(), {
        'macos:PROCESS-PATH:/Applications/Chat.app',
        'macos:PROCESS-PATH:/Applications/Other.app',
      });
      history.dispose();
    },
  );

  test(
    'saved selections remain available when no process is running',
    () async {
      final history = ApplicationHistory(
        read: () async => null,
        write: (_) async {},
      );
      await history.load();
      final packages = history.packages(
        const AccessControlProps(
          acceptList: [r'windows:PROCESS-PATH:c:\old\browser.exe'],
          rejectList: [
            r'windows:PROCESS-PATH:d:\other\tool.exe',
            'macos:PROCESS-PATH:/Applications/Chat.app',
          ],
        ),
        windows: true,
      );
      expect(packages.length, 2);
      history.dispose();
    },
  );

  test(
    'damaged history rows do not discard legacy names or valid paths',
    () async {
      final at = DateTime.utc(2026).toIso8601String();
      final history = ApplicationHistory(
        read: () async => jsonEncode({
          'entries': [
            {
              'content': 'legacy.exe',
              'path': false,
              'windows': true,
              'first': at,
              'last': at,
            },
            {
              'content': r'C:\Apps\Browser.exe',
              'path': true,
              'windows': true,
              'first': at,
              'last': at,
            },
            {'content': 17},
          ],
        }),
        write: (_) async {},
      );
      await history.load();
      expect(history.entries.length, 2);
      expect(
        history.entries.values.map((entry) => entry.identity.action).toSet(),
        {RuleAction.PROCESS_NAME, RuleAction.PROCESS_PATH},
      );
      history.dispose();
    },
  );

  test('unknown owners are not remembered as applications', () async {
    var writes = 0;
    final history = ApplicationHistory(
      read: () async => null,
      write: (_) async {
        writes++;
      },
    );
    await history.record(
      [connection('', process: '')],
      true,
      DateTime.utc(2026),
    );
    expect(history.entries, isEmpty);
    expect(writes, 0);
    history.dispose();
  });
  test('mobile history retains package-name identities', () async {
    final history = ApplicationHistory(
      read: () async => null,
      write: (_) async {},
    );
    await history.record(
      [
        connection('com.example.browser', process: 'com.example.browser'),
        connection('', process: ''),
      ],
      false,
      DateTime.utc(2026),
      preservePaths: false,
    );
    expect(
      history.entries.values.single.identity.action,
      RuleAction.PROCESS_NAME,
    );
    expect(
      history.entries.values.single.identity.content,
      'com.example.browser',
    );
    history.dispose();
  });
}
