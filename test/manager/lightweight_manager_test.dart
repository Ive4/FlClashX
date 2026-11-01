import 'dart:async';

import 'package:fl_clash/manager/lightweight_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window/window.dart';

class _SystemAction extends SystemAction {
  int entries = 0;
  bool fail = false;
  bool? automaticEntry;
  bool Function()? canContinue;
  Completer<void>? gate;

  @override
  Future<void> enterLightweightMode({
    bool automatic = false,
    bool Function()? shouldContinue,
  }) async {
    automaticEntry = automatic;
    canContinue = shouldContinue;
    entries++;
    if (fail) throw StateError('handoff failed');
    await gate?.future;
  }
}

void main() {
  late ProviderContainer container;
  late _SystemAction action;
  var windowVisible = true;
  var windowMinimized = false;
  const windowChannel = MethodChannel('window');

  setUp(() {
    action = _SystemAction();
    container = ProviderContainer(
      overrides: [systemActionProvider.overrideWith(() => action)],
    );
    globalState.container = container;
    windowVisible = true;
    windowMinimized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          windowChannel,
          (call) async => switch (call.method) {
            'isVisible' => windowVisible,
            'isMinimized' => windowMinimized,
            _ => null,
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
    container.dispose();
  });

  void setMinutes(int minutes) {
    container
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(autoLightweightMinutes: minutes));
  }

  void setVisible(bool visible) {
    container.read(appVisibleProvider.notifier).value = visible;
  }

  Future<void> mount(WidgetTester tester, {bool isDesktop = false}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: LightweightManager(
          isDesktop: isDesktop,
          child: const SizedBox(),
        ),
      ),
    );
  }

  testWidgets('defaults to five minutes and can be disabled', (tester) async {
    expect(const AppSettingProps().autoLightweightMinutes, 5);
    setMinutes(0);
    await mount(tester);
    setVisible(false);
    await tester.pump(const Duration(hours: 2));
    expect(action.entries, 0);
    setVisible(true);
    setMinutes(1);
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 0);
  });

  testWidgets('desktop starts hidden even when Flutter reports visible', (
    tester,
  ) async {
    setMinutes(1);
    setVisible(true);
    windowVisible = false;
    await mount(tester, isDesktop: true);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(action.entries, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop hide and minimize count while show and restore reset', (
    tester,
  ) async {
    setMinutes(1);
    await mount(tester, isDesktop: true);
    final listener = desktopWindow.listeners.last;
    listener.onWindowBlur();
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 0);
    listener.onWindowHide();
    await tester.pump(const Duration(seconds: 30));
    listener.onWindowShow();
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 0);
    listener.onWindowMinimize();
    await tester.pump(const Duration(seconds: 30));
    listener.onWindowRestore();
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 0);
    listener.onWindowMinimize();
    await tester.pump(const Duration(minutes: 1));
    expect(action.entries, 1);
    await tester.pumpWidget(const SizedBox());
    expect(desktopWindow.listeners.contains(listener), isFalse);
  });

  testWidgets('a stale desktop visibility reply cannot replace a hide event', (
    tester,
  ) async {
    setMinutes(1);
    final visible = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          windowChannel,
          (call) async => call.method == 'isVisible' ? visible.future : false,
        );
    await mount(tester, isDesktop: true);
    desktopWindow.listeners.last.onWindowHide();
    visible.complete(true);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(action.entries, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('requires a continuous hidden interval and resets on show', (
    tester,
  ) async {
    setMinutes(2);
    await mount(tester);
    setVisible(false);
    await tester.pump(const Duration(seconds: 119));
    expect(action.entries, 0);
    setVisible(true);
    await tester.pump(const Duration(minutes: 3));
    expect(action.entries, 0);
    setVisible(false);
    await tester.pump(const Duration(seconds: 119));
    expect(action.entries, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(action.entries, 1);
    expect(action.automaticEntry, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing or disabling the setting replaces the countdown', (
    tester,
  ) async {
    setMinutes(1);
    setVisible(false);
    await mount(tester);
    await tester.pump(const Duration(seconds: 30));
    setMinutes(3);
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 0);
    setMinutes(0);
    await tester.pump(const Duration(minutes: 5));
    expect(action.entries, 0);
    setMinutes(1);
    await tester.pump(const Duration(minutes: 1));
    expect(action.entries, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a failed handoff retries without leaving an error or timer on dispose',
    (tester) async {
      setMinutes(1);
      setVisible(false);
      action.fail = true;
      await mount(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(action.entries, 1);
      action.fail = false;
      await tester.pump(const Duration(minutes: 1));
      expect(action.entries, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2));
      expect(action.entries, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returning during a handoff cancels further attempts', (
    tester,
  ) async {
    setMinutes(1);
    setVisible(false);
    action.gate = Completer<void>();
    await mount(tester);
    await tester.pump(const Duration(minutes: 1));
    expect(action.entries, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 1);
    setVisible(true);
    expect(action.canContinue!(), isFalse);
    action.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(action.entries, 1);
  });
}
