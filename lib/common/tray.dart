import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/core/desktop/background_client.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:tray/tray.dart';

import 'app_localizations.dart';
import 'l10n_labels.dart';
import 'app_ports.dart';
import 'constant.dart';
import 'keyboard.dart';
import 'provider_reader.dart';
import 'system.dart';
import 'window.dart';

class AppTray implements TrayPort {
  static AppTray? _instance;

  final bool isMacOS;
  final bool isWindows;
  final DesktopBackgroundClient? _background;

  bool _isShutDown = false;

  AppTray._internal({
    required this.isMacOS,
    required this.isWindows,
    DesktopBackgroundClient? background,
  }) : _background = background;

  bool get backgroundOwned => _background?.available ?? false;

  factory AppTray() {
    _instance ??= AppTray._internal(
      isMacOS: system.isMacOS,
      isWindows: system.isWindows,
      background: desktopBackground,
    );
    return _instance!;
  }

  @visibleForTesting
  factory AppTray.forPlatform({
    required bool isMacOS,
    required bool isWindows,
    DesktopBackgroundClient? background,
  }) {
    return AppTray._internal(
      isMacOS: isMacOS,
      isWindows: isWindows,
      background: background,
    );
  }

  String get _trayIconSuffix {
    return isWindows ? 'ico' : 'png';
  }

  bool _isTemplate(bool monochrome) => isMacOS && monochrome;

  String _trayIconDir(bool monochrome) {
    if (isWindows) {
      return 'assets/images/tray/windows';
    }
    return _isTemplate(monochrome)
        ? 'assets/images/tray/macos'
        : 'assets/images/tray/unix';
  }

  String getTrayIcon({
    required bool isStart,
    required bool tunEnable,
    required bool safeMode,
    bool monochrome = true,
  }) {
    final status = switch ((
      safeMode,
      _isTemplate(monochrome) || !isStart,
      tunEnable,
    )) {
      (true, _, _) => 4,
      (false, true, _) => 1,
      (false, false, false) => 2,
      (false, false, true) => 3,
    };
    return '${_trayIconDir(monochrome)}/status_$status.$_trayIconSuffix';
  }

  @override
  Future<void> shutdown() async {
    _isShutDown = true;
    if (backgroundOwned) {
      await _background!.closeUnusedTray();
      return;
    }
    // Removing a status item makes macOS forget where the user dragged it in
    // the menu bar; one that goes away with the process keeps its place.
    if (isMacOS) {
      return;
    }
    await Tray.instance.hide();
  }

  @override
  Future<void> update({
    required TrayState trayState,
    required Traffic traffic,
    required ProviderReader read,
  }) async {
    if (_isShutDown) {
      return;
    }
    if (backgroundOwned) {
      final setup = read(setupActionProvider.notifier);
      final config = read(patchClashConfigProvider);
      final appSetting = read(appSettingProvider);
      await _background!.configureTray({
        'mode': trayState.mode.name,
        'runningSince': trayState.isStart
            ? setup.runningSince?.millisecondsSinceEpoch
            : null,
        'tun': trayState.tunEnable,
        'systemProxy': trayState.systemProxy,
        'autoLaunch': trayState.autoLaunch,
        'showTitle': trayState.showTrayTitle,
        'monochrome': trayState.monochromeTrayIcon,
        'icon': getTrayIcon(
          isStart: trayState.isStart && !trayState.suspended,
          tunEnable: trayState.tunEnable,
          safeMode: trayState.safeMode,
          monochrome: trayState.monochromeTrayIcon,
        ),
        'template': _isTemplate(trayState.monochromeTrayIcon),
        'title': trayState.showTrayTitle ? traffic.trayTitle : '',
        'toolTip': trayState.safeMode
            ? currentAppLocalizations.safeModeAppTitle(appName)
            : appName,
        'shortcuts': {
          for (final entry in {
            'show': HotAction.view,
            'running': HotAction.start,
            'rule': HotAction.ruleMode,
            'global': HotAction.globalMode,
            'direct': HotAction.directMode,
            'tun': HotAction.tun,
            'systemProxy': HotAction.proxy,
            'copyEnv': HotAction.copyEnv,
            'exit': HotAction.exit,
          }.entries)
            if (_shortcut(trayState, entry.value) case final String shortcut)
              entry.key: shortcut,
        },
        'profileId': read(currentProfileProvider)?.id.toString() ?? '',
        'testUrl': config.testUrl,
        'timeout': appSetting.delayTestTimeout,
        'closeConnections': appSetting.closeConnections,
        'selectedMap': trayState.selectedMap,
        'onlyProxyTraffic': appSetting.onlyStatisticsProxy,
      });
      return;
    }
    await Tray.instance.show(
      TraySpec(
        icon: TrayIcon.asset(
          getTrayIcon(
            isStart: trayState.isStart && !trayState.suspended,
            tunEnable: trayState.tunEnable,
            safeMode: trayState.safeMode,
            monochrome: trayState.monochromeTrayIcon,
          ),
          isTemplate: _isTemplate(trayState.monochromeTrayIcon),
          size: isMacOS ? 18 : 16,
        ),
        toolTip: trayState.safeMode
            ? currentAppLocalizations.safeModeAppTitle(appName)
            : appName,
        menu: _buildMenu(trayState: trayState, read: read),
      ),
    );
    await updateTitle(showTrayTitle: trayState.showTrayTitle, traffic: traffic);
  }

  Future<void> updateTitle({
    required bool showTrayTitle,
    required Traffic traffic,
  }) async {
    if (_isShutDown || !isMacOS) {
      return;
    }
    if (backgroundOwned) {
      await _background!.updateTrayTitle(
        showTrayTitle ? traffic.trayTitle : '',
      );
      return;
    }
    await Tray.instance.setTitle(showTrayTitle ? traffic.trayTitle : '');
  }

  Future<void> processPendingActions({
    required ProviderReader read,
    bool Function()? shouldContinue,
  }) async {
    if (!backgroundOwned || _isShutDown) return;
    final actions = await _background!.takeTrayActions(
      ready: read(initProvider),
    );
    for (final action in actions) {
      if (_isShutDown || shouldContinue?.call() == false) return;
      await globalState.safeRun(() async {
        final systemAction = read(systemActionProvider.notifier);
        final commonAction = read(commonActionProvider.notifier);
        final setupAction = read(setupActionProvider.notifier);
        switch (action['action']) {
          case 'show':
            await window?.show();
          case 'lightweight':
            await systemAction.enterLightweightMode();
          case 'running':
            commonAction.toggleRunning();
          case 'tun':
            systemAction.updateTun();
          case 'systemProxy':
            systemAction.updateSystemProxy();
          case 'autoLaunch':
            systemAction.updateAutoLaunch();
          case 'copyEnv':
            await systemAction.copyProxyEnv();
          case 'showTitle':
            commonAction.updateSpeedStatistics();
          case 'monochrome':
            commonAction.updateMonochromeTrayIcon();
          case 'rule':
            setupAction.changeMode(Mode.rule);
          case 'global':
            setupAction.changeMode(Mode.global);
          case 'direct':
            setupAction.changeMode(Mode.direct);
          case 'select':
            await read(proxiesActionProvider.notifier).changeProxy(
              groupName: action['group'] as String,
              proxyName: action['proxy'] as String,
            );
          case 'exit':
            await systemAction.handleExit();
        }
      });
    }
  }

  List<TrayMenuItem> _buildMenu({
    required TrayState trayState,
    required ProviderReader read,
  }) {
    final commonAction = read(commonActionProvider.notifier);
    final systemAction = read(systemActionProvider.notifier);
    final setupAction = read(setupActionProvider.notifier);
    final appLocalizations = currentAppLocalizations;
    String? shortcut(HotAction action) => _shortcut(trayState, action);
    final showItem = TrayMenuAction(
      label: appLocalizations.show,
      detail: shortcut(HotAction.view),
      onSelected: () {
        window?.show();
      },
    );
    final exitItem = TrayMenuAction(
      label: appLocalizations.exit,
      detail: shortcut(HotAction.exit),
      onSelected: () {
        systemAction.handleExit();
      },
    );

    return [
      showItem,
      TrayMenuCheckbox(
        label: trayState.isStart
            ? appLocalizations.stop
            : appLocalizations.start,
        checked: false,
        detail: shortcut(HotAction.start),
        onSelected: commonAction.toggleRunning,
      ),
      if (isMacOS) ...[
        TrayMenuCheckbox(
          label: appLocalizations.speedStatistics,
          checked: trayState.showTrayTitle,
          onSelected: commonAction.updateSpeedStatistics,
        ),
        TrayMenuCheckbox(
          label: appLocalizations.monochromeIcon,
          checked: trayState.monochromeTrayIcon,
          onSelected: commonAction.updateMonochromeTrayIcon,
        ),
      ],
      const TrayMenuSeparator(),
      for (final mode in Mode.values)
        TrayMenuCheckbox(
          label: mode.label,
          checked: mode == trayState.mode,
          detail: shortcut(switch (mode) {
            Mode.rule => HotAction.ruleMode,
            Mode.global => HotAction.globalMode,
            Mode.direct => HotAction.directMode,
          }),
          onSelected: () {
            setupAction.changeMode(mode);
          },
        ),
      const TrayMenuSeparator(),
      if (isMacOS) ..._buildGroupMenu(trayState: trayState, read: read),
      if (trayState.isStart) ...[
        TrayMenuCheckbox(
          label: appLocalizations.tun,
          checked: trayState.tunEnable,
          detail: shortcut(HotAction.tun),
          onSelected: systemAction.updateTun,
        ),
        TrayMenuCheckbox(
          label: appLocalizations.systemProxy,
          checked: trayState.systemProxy,
          detail: shortcut(HotAction.proxy),
          onSelected: systemAction.updateSystemProxy,
        ),
        const TrayMenuSeparator(),
      ],
      TrayMenuCheckbox(
        label: appLocalizations.autoLaunch,
        checked: trayState.autoLaunch,
        onSelected: systemAction.updateAutoLaunch,
      ),
      TrayMenuAction(
        label: appLocalizations.copyEnvVar,
        detail: shortcut(HotAction.copyEnv),
        onSelected: systemAction.copyProxyEnv,
      ),
      const TrayMenuSeparator(),
      exitItem,
    ];
  }

  String? _shortcut(TrayState trayState, HotAction action) {
    final hotKey = trayState.hotKeys[action];
    final key = hotKey?.key;
    if (hotKey == null || key == null) {
      return null;
    }
    return ShortcutLabels(
      isMacOS: isMacOS,
      isWindows: isWindows,
    ).text(hotKey.modifiers, key);
  }

  String? _delayText(int? delay) {
    if (delay == null) {
      return null;
    }
    return delay > 0
        ? '$delay'
        : delayFailureText(delay, currentAppLocalizations);
  }

  List<TrayMenuItem> _buildGroupMenu({
    required TrayState trayState,
    required ProviderReader read,
  }) {
    if (trayState.groups.isEmpty) {
      return const [];
    }
    final delays = read(trayDelaysProvider);
    final proxiesAction = read(proxiesActionProvider.notifier);
    return [
      for (final group in trayState.groups)
        _buildGroupSubmenu(
          group,
          selectedName: read(selectedProxyNameProvider(group.name)),
          delays: delays[group.name] ?? const {},
          onSelected: (proxyName) {
            proxiesAction.changeProxy(
              groupName: group.name,
              proxyName: proxyName,
            );
          },
        ),
      TrayMenuAction(
        label: HotAction.delayTest.label,
        detail: _shortcut(trayState, HotAction.delayTest),
        onSelected: () {
          proxiesAction.delayTestGroups(trayState.groups);
        },
      ),
      const TrayMenuSeparator(),
    ];
  }

  TrayMenuSubmenu _buildGroupSubmenu(
    Group group, {
    required String? selectedName,
    required Map<String, int> delays,
    required void Function(String proxyName) onSelected,
  }) {
    return TrayMenuSubmenu(
      label: group.name,
      detail: _delayText(delays[selectedName]),
      items: [
        for (final proxy in group.all)
          TrayMenuCheckbox(
            label: proxy.name,
            checked: selectedName == proxy.name,
            detail: _delayText(delays[proxy.name]),
            onSelected: () {
              onSelected(proxy.name);
            },
          ),
      ],
    );
  }
}

final appTray = system.isDesktop ? AppTray() : null;
