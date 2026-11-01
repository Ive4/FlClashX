import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window/window.dart';

class LightweightManager extends ConsumerStatefulWidget {
  const LightweightManager({
    super.key,
    required this.isDesktop,
    required this.child,
  });

  final bool isDesktop;
  final Widget child;

  @override
  ConsumerState<LightweightManager> createState() => _LightweightManagerState();
}

class _LightweightManagerState extends ConsumerState<LightweightManager>
    with WindowListener {
  Timer? _timer;
  bool _entering = false;
  int _revision = 0;
  int _windowRevision = 0;
  bool _windowVisible = true;

  bool get _visible =>
      widget.isDesktop ? _windowVisible : ref.read(appVisibleProvider);

  @override
  void initState() {
    super.initState();
    if (widget.isDesktop) {
      desktopWindow.addListener(this);
      unawaited(_refreshWindowVisibility());
    } else {
      ref.listenManual(appVisibleProvider, (_, _) => _schedule());
    }
    ref.listenManual(
      appSettingProvider.select((state) => state.autoLightweightMinutes),
      (_, _) => _schedule(),
    );
    _schedule();
  }

  void _schedule() {
    _revision++;
    _timer?.cancel();
    _timer = null;
    final minutes = ref.read(appSettingProvider).autoLightweightMinutes;
    if (_entering || _visible || minutes <= 0) {
      return;
    }
    _timer = Timer(Duration(minutes: minutes), _enter);
  }

  Future<void> _enter() async {
    _timer = null;
    if (!mounted || _visible) {
      return;
    }
    _entering = true;
    final revision = _revision;
    try {
      await ref
          .read(systemActionProvider.notifier)
          .enterLightweightMode(
            automatic: true,
            shouldContinue: () => mounted && !_visible && revision == _revision,
          );
    } catch (error) {
      commonPrint.log(
        'Automatic lightweight mode failed: ${compactError(error)}',
      );
    } finally {
      _entering = false;
      if (mounted) {
        _schedule();
      }
    }
  }

  void _setWindowVisible(bool visible) {
    _windowRevision++;
    if (_windowVisible == visible) return;
    _windowVisible = visible;
    _schedule();
  }

  Future<void> _refreshWindowVisibility() async {
    final revision = ++_windowRevision;
    try {
      final states = await Future.wait([
        desktopWindow.isVisible(),
        desktopWindow.isMinimized(),
      ]);
      if (mounted && revision == _windowRevision) {
        _setWindowVisible(states[0] && !states[1]);
      }
    } catch (error) {
      commonPrint.log('Window visibility check failed: ${compactError(error)}');
    }
  }

  @override
  void onWindowShow() {
    _setWindowVisible(true);
    unawaited(_refreshWindowVisibility());
  }

  @override
  void onWindowHide() => _setWindowVisible(false);

  @override
  void onWindowMinimize() => _setWindowVisible(false);

  @override
  void onWindowRestore() {
    _setWindowVisible(true);
    unawaited(_refreshWindowVisibility());
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    _revision++;
    _timer?.cancel();
    if (widget.isDesktop) desktopWindow.removeListener(this);
    super.dispose();
  }
}
