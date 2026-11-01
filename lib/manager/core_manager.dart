import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/ohos/diagnostics.dart';
import 'package:fl_clash/core/ohos/background_transfer.dart';
import 'package:fl_clash/core/ohos/recovery.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CoreManager extends ConsumerStatefulWidget {
  final Widget child;
  final bool? isOhos;

  const CoreManager({super.key, this.isOhos, required this.child});

  @override
  ConsumerState<CoreManager> createState() => _CoreContainerState();
}

class _CoreContainerState extends ConsumerState<CoreManager>
    with CoreEventListener, WidgetsBindingObserver {
  CoreController get _core => ref.read(coreHandlerProvider);
  OhosCoreRecovery? _recovery;
  DateTime? _lastMemoryTrim;
  Timer? _transferTimer;
  bool _updatingTransfer = false;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    if (widget.isOhos ?? system.isOhos) {
      _recovery = OhosCoreRecovery(
        recover: () => ref.read(coreActionProvider.notifier).restartCore(),
        canRecover: OhosDiagnostics.canRecover,
        shouldRecover: () =>
            mounted &&
            !ref.read(safeModeProvider) &&
            ref.read(isStartProvider) &&
            ref.read(coreStatusProvider) == CoreStatus.disconnected,
        record: (event) => unawaited(OhosDiagnostics.record(event)),
      );
      _transferTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_updateBackgroundTransfer()),
      );
      WidgetsBinding.instance.addObserver(this);
      didChangeAppLifecycleState(
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
      );
    }
    coreEventManager.addListener(this);
    ref.read(updatingActionProvider.notifier);
    // A rejected profile stays selected on purpose: silently reverting to
    // the previous one hides the error and looks like the switch was lost.
    ref.listenManual(currentProfileIdProvider, (prev, next) {
      if (prev == next) return;
      runAfterFrame(() {
        unawaited(ref.read(setupActionProvider.notifier).fullSetup());
      });
    });
    ref.listenManual(updateParamsProvider, (prev, next) {
      if (prev != next) {
        ref.read(setupActionProvider.notifier).updateConfigDebounce();
      }
    });
    ref.listenManual(setupPatchProvider, (prev, next) {
      if (prev != next) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(
              silence: true,
              // The test URL changes no YAML, so only a forced apply hands
              // it over.
              force:
                  prev != null &&
                  prev.patchConfig.testUrl != next.patchConfig.testUrl,
            );
      }
    });
    ref.listenManual(globalRulesProvider, (prev, next) {
      if (prev?.value != null && next.hasValue) {
        ref.read(setupActionProvider.notifier).applyIfGlobalRulesUsed();
      }
    });
    ref.listenManual(appSettingProvider.select((state) => state.openLogs), (
      prev,
      next,
    ) {
      if (prev != next) {
        _syncLogStream();
      }
    });
    // Every Core process starts without a log stream.
    ref.listenManual(coreStatusProvider, (prev, next) {
      if (next == CoreStatus.connected && prev != CoreStatus.connected) {
        _syncLogStream();
      }
    }, fireImmediately: true);
  }

  void _syncLogStream() {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    if (ref.read(appSettingProvider).openLogs) {
      _core.startLog();
    } else {
      _core.stopLog();
    }
  }

  @override
  void dispose() {
    _transferTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _recovery?.dispose();
    coreEventManager.removeListener(this);
    super.dispose();
  }

  Future<void> _updateBackgroundTransfer() async {
    if (_updatingTransfer ||
        !mounted ||
        ref.read(safeModeProvider) ||
        !ref.read(isStartProvider) ||
        ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    _updatingTransfer = true;
    try {
      final traffic = await _core.getTotalTraffic(false);
      if (mounted && ref.read(isStartProvider)) {
        await OhosBackgroundTransfer.update(traffic);
      }
    } catch (_) {
      await OhosDiagnostics.record('background_transfer_poll_failed');
    } finally {
      _updatingTransfer = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _recovery?.setForeground(state == AppLifecycleState.resumed);
    if (_recovery != null &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      unawaited(_trimCoreMemory());
    }
  }

  Future<void> _trimCoreMemory() async {
    final now = DateTime.now();
    if (!mounted ||
        ref.read(safeModeProvider) ||
        ref.read(coreStatusProvider) != CoreStatus.connected ||
        (_lastMemoryTrim != null &&
            now.difference(_lastMemoryTrim!) < const Duration(minutes: 1))) {
      return;
    }
    _lastMemoryTrim = now;
    try {
      await _core.requestGc();
      await OhosDiagnostics.record('background_memory_trim');
    } catch (_) {
      await OhosDiagnostics.record('background_memory_trim_failed');
    }
  }

  @override
  Future<void> onDelay(Delay delay) async {
    super.onDelay(delay);
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    proxiesAction.setDelay(delay);
    debouncer.call(FunctionTag.updateDelay, () async {
      proxiesAction.updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
  }

  @override
  void onLog(Log log) {
    ref.read(logsProvider.notifier).add(log);
    if (log.logLevel == LogLevel.error) {
      throttler.call(
        FunctionTag.coreErrorNotifier,
        () => dialogs.showNotifier(log.payload, level: MessageLevel.error),
        duration: const Duration(seconds: 3),
        fire: true,
      );
    }
    super.onLog(log);
  }

  @override
  void onDialerLoop(String proxyName) {
    throttler.call(
      FunctionTag.dialerLoopNotifier,
      () => dialogs.showNotifier(
        currentAppLocalizations.dialerProxyLoopStopped(proxyName),
        level: MessageLevel.error,
      ),
      duration: const Duration(seconds: 3),
      fire: true,
    );
    super.onDialerLoop(proxyName);
  }

  @override
  void onRequest(TrackerInfo trackerInfo) async {
    ref.read(requestsProvider.notifier).addRequest(trackerInfo);
    ref.read(requestCountProvider.notifier).update((count) => count + 1);
    super.onRequest(trackerInfo);
  }

  @override
  void onRequestTraffic(Map<String, RequestTraffic> traffic) {
    ref.read(requestsProvider.notifier).updateTraffic(traffic);
    super.onRequestTraffic(traffic);
  }

  @override
  void onDns(DnsQuery dnsQuery) {
    ref.read(dnsQueriesProvider.notifier).addQuery(dnsQuery);
    ref.read(dnsQueryCountProvider.notifier).update((count) => count + 1);
    super.onDns(dnsQuery);
  }

  @override
  Future<void> onLoaded(String providerName) async {
    final provider = await _core.getExternalProvider(providerName);
    if (!mounted) {
      return;
    }
    ref.read(providersProvider.notifier).setProvider(provider);
    debouncer.call(FunctionTag.loadedProvider, () async {
      if (!mounted) {
        return;
      }
      ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
    }, duration: const Duration(milliseconds: 5000));
    super.onLoaded(providerName);
  }

  @override
  Future<void> onCrash(String message) async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    _recovery?.request();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      context.showNotifier(message, level: MessageLevel.error);
    }
    super.onCrash(message);
  }

  @override
  void onGeoUpdate(String geoType, bool updating, bool skipped, String? error) {
    ref
        .read(geoResourceActionProvider.notifier)
        .handleCoreUpdate(geoType, updating, skipped, error);
    super.onGeoUpdate(geoType, updating, skipped, error);
  }

  @override
  void onRouteChanged(RouteSnapshot snapshot) {
    ref.read(routeTrackerProvider.notifier).applySnapshot(snapshot);
    super.onRouteChanged(snapshot);
  }
}
