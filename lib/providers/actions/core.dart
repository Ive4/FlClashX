part of '../action.dart';

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  int _requestedRestartRevision = 0;
  Future<bool>? _restartOperation;

  @override
  void build() {}

  Future<void> initCore() async {
    final isInit = await _core.isInit;

    final version = ref.read(versionProvider);
    if (!isInit) {
      if (!await _core.init(version)) {
        throw const CoreMethodException(
          code: 'init_failed',
          message: 'Core did not complete initialization',
        );
      }
    } else {
      await ref.read(proxiesActionProvider.notifier).updateGroups();
      await ref.read(providersProvider.notifier).syncProviders();
    }
  }

  Future<void> startCore() async {
    ref.read(coreStopReasonProvider.notifier).value = null;
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    try {
      final result = await startLifecycle();
      await _applyLifecycleResult(result);
    } catch (error) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      final message = compactError(error);
      ref.read(coreStopReasonProvider.notifier).value = message;
      dialogs.showNotifier(message, level: MessageLevel.error);
    }
  }

  @protected
  Future<CoreLifecycleResult> startLifecycle() {
    return _core.start();
  }

  @protected
  Future<CoreLifecycleResult> restartLifecycle() {
    return _core.restart();
  }

  // Nothing in lib/ calls CoreController.stop(); only close() (app exit)
  // supersedes a start/restart. statusFirst lets onCrash catch a crash
  // during initCore itself (it early-returns unless status is connected).
  Future<bool> _applyLifecycleResult(
    CoreLifecycleResult result, {
    bool statusFirst = false,
  }) async {
    if (result.outcome == CoreLifecycleOutcome.superseded) {
      return false;
    }
    if (statusFirst) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      await initCore();
    } else {
      await initCore();
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
    }
    return true;
  }

  Future<void> closeConnection(String id) async {
    await _core.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await _core.closeConnections();
  }

  Future<void> clearDnsCacheOnNetworkChange() async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    try {
      await _core.clearDnsCache();
    } catch (error) {
      commonPrint.log(
        'clearDnsCache error: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  Future<void> requestGc() async {
    await _core.requestGc();
  }

  Future<void> crash() async {
    await _core.crash();
  }

  Future<bool> restartCore() {
    _requestedRestartRevision++;
    final activeOperation = _restartOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    final operation = _runRestartWorker();
    _restartOperation = operation;
    return operation;
  }

  Future<bool> _runRestartWorker() async {
    try {
      ref.read(coreStopReasonProvider.notifier).value = null;
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      final result = await restartLifecycle();
      if (!await _applyLifecycleResult(result, statusFirst: true)) {
        return false;
      }

      var appliedRevision = 0;
      var applied = true;
      while (appliedRevision < _requestedRestartRevision) {
        final revision = _requestedRestartRevision;
        if (ref.read(setupActionProvider.notifier).wantsRunning) {
          applied = await ref
              .read(setupActionProvider.notifier)
              .setRunning(true, initialize: true);
        } else {
          applied = await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);
        }
        appliedRevision = revision;
      }
      return applied;
    } catch (error) {
      ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      ref.read(coreStopReasonProvider.notifier).value = compactError(error);
      rethrow;
    } finally {
      _restartOperation = null;
    }
  }
}
