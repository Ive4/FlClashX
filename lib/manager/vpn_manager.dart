import 'dart:async';

import 'package:fl_clash/common/common.dart';
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

  @override
  void initState() {
    super.initState();
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
    if (_checkingStatus || running?.enable != true) return;
    _checkingStatus = true;
    try {
      final active =
          await (widget.vpnStatusReader?.call() ??
              const MethodChannel(
                'com.follow.clash/vpn',
              ).invokeMethod<bool>('status'));
      if (mounted &&
          active == false &&
          identical(running, ref.read(runningVpnOptionsProvider))) {
        await ref.read(setupActionProvider.notifier).setRunning(false);
      }
    } on PlatformException catch (error) {
      commonPrint.log(error.toString());
    } finally {
      _checkingStatus = false;
    }
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
