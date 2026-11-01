part of '../action.dart';

@Riverpod(keepAlive: true)
class SystemAction extends _$SystemAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  SystemExitCoordinator? _exitCoordinator;
  Future<void>? _lightweightOperation;

  @override
  void build() {}

  Future<void> enterLightweightMode({
    bool automatic = false,
    bool Function()? shouldContinue,
  }) {
    return _lightweightOperation ??=
        _enterLightweightMode(automatic, shouldContinue).whenComplete(() {
          _lightweightOperation = null;
        });
  }

  bool _canEnterAutomatically(bool Function()? shouldContinue) {
    if (shouldContinue?.call() == false ||
        !ref.mounted ||
        (shouldContinue == null && ref.read(appVisibleProvider)) ||
        ref.read(appSettingProvider).autoLightweightMinutes <= 0 ||
        ref.read(excludeSSIDsProvider).isNotEmpty ||
        ref.read(coreStatusProvider) != CoreStatus.connected ||
        _exitCoordinator != null) {
      return false;
    }
    final navigator = globalState.navigatorKey.currentState;
    if (navigator == null || navigator.canPop()) {
      return false;
    }
    var blocked = false;
    void check(Element element) {
      if (blocked) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        blocked = (element.state as NavigatorState).canPop();
        return;
      }
      element.visitChildElements(check);
    }

    navigator.context.visitChildElements(check);
    return !blocked;
  }

  Future<void> _enterLightweightMode(
    bool automatic,
    bool Function()? shouldContinue,
  ) async {
    final supported =
        system.isAndroid || system.isOhos || desktopBackground.available;
    if (!supported || ref.read(coreStatusProvider) != CoreStatus.connected) {
      return;
    }
    if (automatic && !_canEnterAutomatically(shouldContinue)) return;
    final localizations = currentAppLocalizations;
    if (ref.read(excludeSSIDsProvider).isNotEmpty) {
      throw MessageException(localizations.lightweightModeOnDemand);
    }
    final updating = ref.read(updatingKeysProvider.notifier);
    if (ref
        .read(updatingKeysProvider)
        .any((key) => updating.scopeOf(key) == UpdatingScope.local)) {
      if (automatic) return;
      throw MessageException(localizations.lightweightModeBusy);
    }
    final confirmed =
        automatic ||
        await dialogs.showMessage(
              title: localizations.lightweightMode,
              message: TextSpan(text: localizations.lightweightModeConfirm),
            ) ==
            true;
    if (confirmed != true || _exitCoordinator != null || !ref.mounted) {
      return;
    }
    if (!await ref
        .read(setupActionProvider.notifier)
        .applyProfile(silence: automatic)) {
      return;
    }
    if (_exitCoordinator != null || !ref.mounted) {
      return;
    }
    if (automatic && !_canEnterAutomatically(shouldContinue)) return;
    if (ref
        .read(updatingKeysProvider)
        .any((key) => updating.scopeOf(key) == UpdatingScope.local)) {
      if (automatic) return;
      throw MessageException(localizations.lightweightModeBusy);
    }
    await savePreferences();
    if (automatic && !_canEnterAutomatically(shouldContinue)) return;
    if (system.isAndroid) {
      await preferences.saveLightweightResume();
      await bootGuard.markClosed();
      _core.stopLog();
      await SystemNavigator.pop();
      return;
    }
    final runningSince = ref.read(setupActionProvider.notifier).runningSince;
    if (system.isOhos) {
      await OhosCoreTransport.enterLightweight(runningSince);
      _core.stopLog();
      await app?.enterLightweightMode();
      return;
    }
    await desktopBackground.enter(
      cleanupProxy: systemProxyQueue?.hasAppliedProxy ?? false,
      runningSince: runningSince,
      mode: ref.read(patchClashConfigProvider).mode.name,
    );
    if (automatic && !_canEnterAutomatically(shouldContinue)) {
      await desktopBackground.cancelEnter();
      return;
    }
    _core.stopLog();
    if (_exitCoordinator != null) {
      await handleExit();
      return;
    }
    await trayPort?.shutdown().onError<Object>((error, stackTrace) {
      commonPrint.log('Tray handoff failed: ${compactError(error)}');
    });
    await exitApplication();
  }

  Future<List<Package>> getPackages() async {
    final access = ref.read(vpnSettingProvider).accessControlProps;
    ref.read(packagesProvider.notifier).value =
        await app?.getPackages(
          knownPackages: system.isOhos
              ? {...access.acceptList, ...access.rejectList}.toList()
              : const [],
        ) ??
        [];
    return ref.read(packagesProvider);
  }

  Future<bool> isInstalledAppsPermissionGranted() async {
    return await app?.isInstalledAppsPermissionGranted() ?? true;
  }

  Future<bool> requestInstalledAppsPermission() async {
    return await app?.requestInstalledAppsPermission() ?? false;
  }

  Future<void> handleExit([bool needSave = true]) {
    final coordinator = _exitCoordinator ??= SystemExitCoordinator(
      watchdogDuration: exitWatchdogDuration,
      closeWindow: closeWindow,
      closeCore: closeCore,
      exitApplication: exitApplication,
    );
    return coordinator.exit(cleanup: () => cleanupExitResources(needSave));
  }

  @protected
  Duration get exitWatchdogDuration => const Duration(seconds: 3);

  @protected
  Future<void> cleanupExitResources(bool needSave) async {
    final saveOperation = needSave ? _savePreferencesSafely() : null;
    final tray = trayPort;
    if (tray != null) {
      await tray.shutdown().onError<Object>((error, stackTrace) {
        commonPrint.log(
          'Tray shutdown failed: ${compactError(error)}',
          logLevel: LogLevel.error,
        );
      });
    }
    await Future.wait([
      ?saveOperation,
      bootGuard.markClosed(),
      if (systemDnsCoordinator != null) systemDnsCoordinator!.shutdown(),
      ?systemProxyQueue?.close(),
    ]);
  }

  Future<void> _savePreferencesSafely() async {
    try {
      await savePreferences();
    } catch (error) {
      commonPrint.log(
        'Preferences save failed: ${compactError(error)}',
        logLevel: LogLevel.error,
      );
    }
  }

  @protected
  Future<void> savePreferences() async {
    final port = windowPort;
    if (port != null) {
      try {
        final current = ref.read(windowSettingProvider);
        final geometry = await port.captureNormalGeometry(current);
        if (geometry != null) {
          ref.read(windowSettingProvider.notifier).value = geometry;
        }
      } catch (error) {
        commonPrint.log(
          'Window geometry capture failed: ${compactError(error)}',
          logLevel: LogLevel.warning,
        );
      }
    }
    await preferences.saveConfig(ref.read(configProvider));
  }

  @protected
  Future<void> closeWindow() async {
    await windowPort?.close();
  }

  @protected
  Future<void> closeCore() async {
    await _core.close();
    commonPrint.log('exit');
  }

  @protected
  Future<void> exitApplication() async {
    await system.exit();
    windowPort?.forceExit();
  }

  Future<void> handleClose([bool exit = true]) async {
    if (ref.read(appSettingProvider).minimizeOnExit || !exit) {
      if (system.isDesktop) {
        await _savePreferencesSafely();
      }
      await system.back();
      await windowPort?.hide();
    } else {
      await handleExit();
    }
  }

  Future<void> updateVisible() async {
    await windowPort?.toggle();
  }

  void updateTun() {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: !state.systemProxy));
  }

  Future<void> copyProxyEnv() async {
    final port = ref.read(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    await Clipboard.setData(
      ClipboardData(text: proxyEnvCommand(port, isWindows: system.isWindows)),
    );
  }

  void updateAutoLaunch() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(autoLaunch: !state.autoLaunch));
  }

  Future<void> updateTray() async {
    await trayPort?.update(
      trayState: ref.read(trayStateProvider),
      traffic: ref.read(
        trafficsProvider.select(
          (state) => state.list.safeLast(const Traffic()),
        ),
      ),
      read: globalState.container.read,
    );
  }

  Future<void> updateLocalIp() async {
    ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    ref.read(localIpProvider.notifier).value = await getLocalIpAddress();
  }
}
