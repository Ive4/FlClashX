import 'dart:async';

import 'package:fl_clash/common/window.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNativeWindow {
  final List<String> calls = [];
  bool visible = true;
  Completer<void>? hideGate;

  WindowVisibilityController controller({bool keepOffTaskbar = false}) {
    return WindowVisibilityController(
      showWindow: () async {
        calls.add('show');
        visible = true;
      },
      hideWindow: () async {
        calls.add('hide');
        await hideGate?.future;
        visible = false;
      },
      isWindowVisible: () async => visible,
      setSkipTaskbar: (skip) async {
        calls.add(skip ? 'dock:off' : 'dock:on');
      },
      keepOffTaskbar: keepOffTaskbar,
    );
  }
}

void main() {
  testWidgets('a menu bar application never adds a Dock icon', (tester) async {
    final native = _FakeNativeWindow()..visible = false;
    final controller = native.controller(keepOffTaskbar: true);

    await controller.show();
    await controller.hide();
    await controller.toggle();

    expect(native.calls, [
      'show',
      'dock:off',
      'hide',
      'dock:off',
      'show',
      'dock:off',
    ]);
    expect(native.visible, isTrue);
  });

  test('other platforms show the taskbar entry only while visible', () async {
    final native = _FakeNativeWindow()..visible = false;
    final controller = native.controller();

    unawaited(controller.show());
    await controller.hide();

    expect(native.calls, ['show', 'dock:on', 'hide', 'dock:off']);
  });

  testWidgets('rapid toggles run one at a time and flip parity each press', (
    tester,
  ) async {
    final native = _FakeNativeWindow();
    native.hideGate = Completer<void>();
    final controller = native.controller();

    unawaited(controller.toggle());
    unawaited(controller.toggle());
    final last = controller.toggle();
    await tester.pump();

    expect(native.calls, ['hide']);

    native.hideGate!.complete();
    native.hideGate = null;
    await last;

    expect(native.calls, [
      'hide',
      'dock:off',
      'show',
      'dock:on',
      'hide',
      'dock:off',
    ]);
    expect(native.visible, isFalse);
  });

  test('an idle controller starts a request without waiting a tick', () {
    final native = _FakeNativeWindow()..visible = false;
    final controller = native.controller();

    unawaited(controller.show());

    expect(native.calls, ['show']);
  });

  test('a failed step does not block later requests', () async {
    var failShow = true;
    final calls = <String>[];
    final controller = WindowVisibilityController(
      showWindow: () async {
        if (failShow) {
          throw StateError('show failed');
        }
        calls.add('show');
      },
      hideWindow: () async => calls.add('hide'),
      isWindowVisible: () async => false,
      setSkipTaskbar: (skip) async => calls.add(skip ? 'dock:off' : 'dock:on'),
    );

    await expectLater(controller.show(), throwsStateError);
    failShow = false;
    await controller.hide();
    await controller.show();

    expect(calls, ['hide', 'dock:off', 'show', 'dock:on']);
  });
}
