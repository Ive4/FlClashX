import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/common/application_history.dart';
import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/access.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _PendingConnections extends Fake implements CoreHandlerInterface {
  Completer<List<TrackerInfo>>? _result;
  Completer<List<TrackerInfo>> get result =>
      _result ??= Completer<List<TrackerInfo>>();

  @override
  Future<List<TrackerInfo>> getConnections() => result.future;
}

ApplicationConnection _connection(String path) => (
  id: path,
  process: 'Browser',
  path: path,
  outbound: 'DIRECT',
  start: DateTime.utc(2026),
  upload: 0,
  download: 0,
);

void main() {
  late ProviderContainer container;
  late ApplicationHistory history;
  late _PendingConnections core;

  setUp(() {
    core = _PendingConnections();
    history = ApplicationHistory(read: () async => null, write: (_) async {});
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        applicationHistoryProvider.overrideWithValue(history),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = container;
    container.read(vpnSettingProvider.notifier).value = const VpnProps(
      accessControlProps: AccessControlProps(enable: true),
    );
  });

  tearDown(() {
    container.dispose();
    history.dispose();
  });

  Future<void> open(WidgetTester tester, {required bool windows}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: AccessView(isDesktop: true, isWindows: windows, isOhos: false),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Windows chooses remembered programs through the original blacklist',
    (tester) async {
      await tester.runAsync(
        () => history.record(
          [
            _connection(r'C:\Apps\Browser.exe'),
            _connection(r'D:\Other\Browser.exe'),
          ],
          true,
          DateTime.utc(2026),
        ),
      );
      await open(tester, windows: true);
      expect(find.byType(PackageListItem), findsNWidgets(2));
      await tester.tap(find.byType(PackageListItem).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(container.read(vpnSettingProvider).accessControlProps.rejectList, [
        r'windows:PROCESS-PATH:c:\apps\browser.exe',
      ]);
      expect(
        container.read(vpnSettingProvider).accessControlProps.mode,
        AccessControlMode.rejectSelected,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Mac helpers share one remembered app and both lists are retained',
    (tester) async {
      const selected = 'macos:PROCESS-PATH:/Applications/Old.app';
      container
          .read(vpnSettingProvider.notifier)
          .update(
            (state) => state.copyWith(
              accessControlProps: const AccessControlProps(
                enable: true,
                mode: AccessControlMode.acceptSelected,
                acceptList: [selected],
                rejectList: ['macos:PROCESS-PATH:/Applications/Other.app'],
              ),
            ),
          );
      await tester.runAsync(
        () => history.record(
          [
            _connection('/Applications/Chat.app/Contents/MacOS/Chat'),
            _connection(
              '/Applications/Chat.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper',
            ),
          ],
          false,
          DateTime.utc(2026),
        ),
      );
      await open(tester, windows: false);
      expect(find.byType(PackageListItem), findsNWidgets(3));
      expect(find.text('Chat.app'), findsOneWidget);
      expect(find.text('Old.app'), findsOneWidget);
      await tester.tap(find.text('Chat.app'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final saved = container.read(vpnSettingProvider).accessControlProps;
      expect(
        saved.acceptList,
        containsAll([selected, 'macos:PROCESS-PATH:/Applications/Chat.app']),
      );
      expect(saved.rejectList, ['macos:PROCESS-PATH:/Applications/Other.app']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a newly remembered program appears while the list is open', (
    tester,
  ) async {
    await open(tester, windows: true);
    expect(find.byType(PackageListItem), findsNothing);
    await tester.runAsync(
      () => history.record(
        [_connection(r'C:\New\Tool.exe')],
        true,
        DateTime.utc(2026),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tool.exe'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'saved memory stays usable while a Core snapshot stalls or fails',
    (tester) async {
      await tester.runAsync(
        () => history.record(
          [_connection(r'C:\Saved\Browser.exe')],
          true,
          DateTime.utc(2026),
        ),
      );
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await open(tester, windows: true);
      expect(find.text('Browser.exe'), findsOneWidget);
      await tester.runAsync(() async {
        core.result.completeError(StateError('snapshot unavailable'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('Browser.exe'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
