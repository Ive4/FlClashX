import 'dart:io';

import 'package:fl_clash/common/tray.dart';
import 'package:fl_clash/core/desktop/background_client.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/app_paths.dart';

class _Background extends DesktopBackgroundClient {
  final settings = <Map<String, Object?>>[];
  final titles = <String>[];
  final actions = <Map<String, Object?>>[];

  @override
  bool get available => true;

  @override
  Future<void> configureTray(Map<String, Object?> value) async {
    settings.add(value);
  }

  @override
  Future<void> updateTrayTitle(String title) async => titles.add(title);

  @override
  Future<List<Map<String, Object?>>> takeTrayActions({
    required bool ready,
  }) async {
    final pending = actions
        .where(
          (action) =>
              ready || action['action'] == 'show' || action['action'] == 'exit',
        )
        .toList();
    actions.removeWhere(pending.contains);
    return pending;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Background background;
  late AppTray tray;
  late Directory root;
  final pluginCalls = <MethodCall>[];

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('background-tray-');
    await useAppPaths(root);
    await AppLocalizations.load(const Locale('en'));
  });

  tearDownAll(() async => root.delete(recursive: true));

  setUp(() {
    container = ProviderContainer(
      overrides: [currentProfileProvider.overrideWithValue(null)],
    );
    globalState.container = container;
    background = _Background();
    tray = AppTray.forPlatform(
      isMacOS: true,
      isWindows: false,
      background: background,
    );
    pluginCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tray'), (call) async {
          pluginCalls.add(call);
          return true;
        });
  });

  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tray'), null);
  });

  test(
    'background owns the only tray, including after Flutter detaches',
    () async {
      await tray.update(
        trayState: const TrayState(
          mode: Mode.rule,
          port: 7890,
          autoLaunch: false,
          systemProxy: true,
          tunEnable: false,
          isStart: false,
          groups: [],
          selectedMap: {},
          showTrayTitle: true,
          safeMode: false,
        ),
        traffic: const Traffic(up: 1024, down: 2048),
        read: container.read,
      );
      expect(background.settings.single['title'], '1 KB/s\n2 KB/s');
      expect(background.settings.single['template'], isTrue);
      expect(background.settings.single['systemProxy'], isTrue);
      expect(background.settings.single['mode'], 'rule');
      await tray.updateTitle(showTrayTitle: false, traffic: const Traffic());
      expect(background.titles, ['']);
      await tray.shutdown();
      await tray.updateTitle(showTrayTitle: true, traffic: const Traffic());
      expect(background.titles, ['']);
      expect(pluginCalls, isEmpty);
    },
  );

  test('native menu commands reuse the original settings owners', () async {
    container.read(initProvider.notifier).value = true;
    final previous = container.read(networkSettingProvider).systemProxy;
    background.actions.addAll([
      {'action': 'systemProxy'},
      {'action': 'global'},
    ]);
    await tray.processPendingActions(read: container.read);
    expect(container.read(networkSettingProvider).systemProxy, !previous);
    expect(container.read(patchClashConfigProvider).mode, Mode.global);
    await tray.processPendingActions(read: container.read);
    expect(container.read(networkSettingProvider).systemProxy, !previous);
    expect(pluginCalls, isEmpty);
  });

  test('initialization keeps deferred commands pending', () async {
    background.actions.add({'action': 'direct'});
    await tray.processPendingActions(read: container.read);
    expect(background.actions, hasLength(1));
    container.read(initProvider.notifier).value = true;
    await tray.processPendingActions(read: container.read);
    expect(background.actions, isEmpty);
    expect(container.read(patchClashConfigProvider).mode, Mode.direct);
  });
}
