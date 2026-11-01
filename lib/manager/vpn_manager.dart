import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/ohos/diagnostics.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

class VpnManager extends ConsumerStatefulWidget {
  final Widget child;
  final Future<bool?> Function()? vpnStatusReader;

  const VpnManager({super.key, this.vpnStatusReader, required this.child});

  @override
  ConsumerState<VpnManager> createState() => _VpnContainerState();
}

class _VpnContainerState extends ConsumerState<VpnManager> {
  Timer? _statusTimer;
  bool _checkingStatus = false;
  int _coreEpoch = 0;

  @override
  void initState() {
    super.initState();
    ref.listenManual(coreStatusProvider, (_, _) => _coreEpoch++);
    if (system.isOhos || widget.vpnStatusReader != null) {
      _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_checkStatus());
      });
    }
    ref.listenManual(
      vpnOptionsProvider.select((state) => state.value?.effective),
      (prev, next) {
        final running = ref.read(runningVpnOptionsProvider)?.effective;
        if (next != null &&
            prev != next &&
            running != null &&
            running != next) {
          _showRestartTip();
        }
      },
    );
  }

  Future<void> _checkStatus() async {
    final running = ref.read(runningVpnOptionsProvider);
    if (_checkingStatus ||
        running == null ||
        !running.enable ||
        ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    final epoch = _coreEpoch;
    _checkingStatus = true;
    try {
      final active =
          await (widget.vpnStatusReader?.call() ??
              const MethodChannel(
                'com.follow.clash/vpn',
              ).invokeMethod<bool>('status'));
      if (active != false || !_isCurrentStatus(epoch, running)) return;
      final recoverable = await OhosDiagnostics.canRecover();
      if (!_isCurrentStatus(epoch, running)) return;
      if (recoverable) {
        unawaited(
          OhosDiagnostics.record('vpn_status_ignored', 'unfinished_session'),
        );
        return;
      }
      unawaited(OhosDiagnostics.record('vpn_external_stop_confirmed'));
      await ref.read(setupActionProvider.notifier).setRunning(false);
    } on PlatformException catch (error) {
      commonPrint.log(error.toString());
    } finally {
      _checkingStatus = false;
    }
  }

  bool _isCurrentStatus(int epoch, VpnOptions running) {
    return mounted &&
        epoch == _coreEpoch &&
        ref.read(coreStatusProvider) == CoreStatus.connected &&
        identical(running, ref.read(runningVpnOptionsProvider));
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _showRestartTip() {
    dialogs.showNotifier(
      currentAppLocalizations.vpnConfigChangeDetected,
      level: MessageLevel.warning,
      actionState: MessageActionState(
        actionText: currentAppLocalizations.restart,
        action: () async {
          await ref.read(setupActionProvider.notifier).restartVpn();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
