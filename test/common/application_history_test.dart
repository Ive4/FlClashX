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
  test('loads requests made before the desktop interface was opened', () async {
    final history = ApplicationHistory(
      read: () async => null,
      readBackground: () async => '''
        {"entries":[{"content":"C:/Apps/Browser.exe","path":true,
        "windows":true,"first":"2026-11-25T12:00:00Z",
        "last":"2026-11-26T12:00:00Z"}]}
        ''',
      write: (_) async {},
    );
    await history.refreshBackground();
    final package = history
        .packages(const AccessControlProps(), windows: true)
        .single;
    expect(package.packageName, r'windows:PROCESS-PATH:c:\apps\browser.exe');
    expect(
      package.lastUpdateTime,
      DateTime.utc(2026, 11, 26, 12).millisecondsSinceEpoch,
    );
    history.dispose();
  });

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
    'legacy versioned history is compacted once and stays grouped',
    () async {
      const old = r'C:\nvm\v20.19.0\node.exe';
      const newer = r'C:\nvm\v22.14.0\node.exe';
      const upgraded = r'C:\nvm\v24.3.0\node.exe';
      const other = r'D:\nvm\v22.14.0\node.exe';
      final first = DateTime.utc(2026, 1, 1);
      final last = DateTime.utc(2026, 1, 2);
      final upgradeTime = DateTime.utc(2026, 1, 3);

      Map<String, Object> row(String path, DateTime at) => {
        'path': true,
        'content': path,
        'windows': true,
        'first': at.toIso8601String(),
        'last': at.toIso8601String(),
      };

      var saved = jsonEncode({
        'entries': [row(newer, last), row(old, first), row(other, last)],
      });
      var writes = 0;
      ApplicationHistory store() => ApplicationHistory(
        read: () async => saved,
        write: (value) async {
          writes++;
          saved = value;
        },
      );

      final history = store();
      addTearDown(history.dispose);
      const grouped = r'windows:PROCESS-PATH-REGEX:c:\nvm\v*\node.exe';
      await history.load();
      expect(history.entries, hasLength(2));
      expect(history.entries[grouped]?.identity.content, newer);
      expect(history.entries[grouped]?.firstSeen, first);
      expect(history.entries[grouped]?.lastSeen, last);
      final packages = history.packages(
        const AccessControlProps(
          rejectList: [r'windows:PROCESS-PATH:C:\nvm\v20.19.0\node.exe'],
        ),
        windows: true,
      );
      expect(packages, hasLength(2));
      expect(
        packages
            .singleWhere((app) => app.packageName == grouped)
            .applicationPath,
        newer,
      );
      expect(writes, 1);
      final restored = store();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.entries, hasLength(2));
      expect(restored.entries[grouped]?.firstSeen, first);
      expect(writes, 1);

      await restored.record([connection(upgraded)], true, upgradeTime);
      await restored.record([connection(old)], true, last);
      expect(restored.entries, hasLength(2));
      expect(restored.entries[grouped]?.identity.content, upgraded);
      expect(restored.entries[grouped]?.firstSeen, first);
      expect(restored.entries[grouped]?.lastSeen, upgradeTime);
      expect(writes, 2);
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

  test('Windows history combines a bare name with its unique path', () async {
    final history = ApplicationHistory(
      read: () async => null,
      write: (_) async {},
    );
    addTearDown(history.dispose);
    final first = DateTime.utc(2026, 1);
    final last = DateTime.utc(2026, 2);
    const nameKey = 'windows:PROCESS-NAME:browser.exe';
    const path = r'C:\Apps\Browser.exe';
    const pathKey = r'windows:PROCESS-PATH:c:\apps\browser.exe';
    await history.record([connection(path)], true, first);
    await history.record([connection('', process: 'BROWSER.exe')], true, last);

    final merged = history.packages(const AccessControlProps(), windows: true);
    expect(merged.single.packageName, pathKey);
    expect(merged.single.applicationPath, path);
    expect(merged.single.lastUpdateTime, last.millisecondsSinceEpoch);
    expect(
      history
          .packages(
            const AccessControlProps(acceptList: [nameKey]),
            windows: true,
          )
          .map((package) => package.packageName),
      unorderedEquals([nameKey, pathKey]),
    );

    await history.record([connection(r'D:\Other\Browser.exe')], true, last);
    expect(
      history
          .packages(const AccessControlProps(), windows: true)
          .map((package) => package.packageName),
      unorderedEquals([
        nameKey,
        pathKey,
        r'windows:PROCESS-PATH:d:\other\browser.exe',
      ]),
    );
  });

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
