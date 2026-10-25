part of '../action.dart';

@Riverpod(keepAlive: true)
class CommonAction extends _$CommonAction {
  CoreController get _core => ref.read(coreHandlerProvider);
  bool _isUpdatingTraffic = false;
  bool _isInstallingUpdate = false;

  @override
  void build() {}

  void toggleRunning() {
    final running = !ref.read(isStartProvider);
    unawaited(
      globalState.safeRun(
        () => ref
            .read(setupActionProvider.notifier)
            .setRunning(
              running,
              initialize: running && !ref.read(initProvider),
            ),
      ),
    );
  }

  void updateSpeedStatistics() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(showTrayTitle: !state.showTrayTitle));
  }

  void updateMonochromeTrayIcon() {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(monochromeTrayIcon: !state.monochromeTrayIcon),
        );
  }

  void updateMode() {
    ref.read(patchClashConfigProvider.notifier).update((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) return state;
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  Future<void> updateTraffic() async {
    if (_isUpdatingTraffic) {
      return;
    }
    _isUpdatingTraffic = true;
    try {
      final onlyStatisticsProxy = ref.read(
        appSettingProvider.select((state) => state.onlyStatisticsProxy),
      );
      final [traffic, totalTraffic] = await Future.wait([
        _readTraffic(() => _core.getTraffic(onlyStatisticsProxy)),
        _readTraffic(() => _core.getTotalTraffic(onlyStatisticsProxy)),
      ]);
      if (traffic != null) {
        ref.read(trafficsProvider.notifier).addTraffic(traffic);
      }
      if (totalTraffic != null) {
        ref.read(totalTrafficProvider.notifier).value = totalTraffic;
      }
    } finally {
      _isUpdatingTraffic = false;
    }
  }

  Future<Traffic?> _readTraffic(Future<Traffic> Function() request) async {
    try {
      return await request();
    } catch (error) {
      commonPrint.log(
        'updateTraffic error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }

  Future<bool> autoCheckUpdate() async {
    if (!ref.read(appSettingProvider).autoCheckUpdate) return false;
    final AppUpdateRelease? res;
    try {
      res = await appUpdater.check();
    } catch (error) {
      commonPrint.log(
        'checkForUpdate failed: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return false;
    }
    await checkUpdateResultHandle(data: res);
    return res != null;
  }

  TextSpan _releaseSpan(BuildContext context, String tagName, String? body) {
    final version = parseReleaseChangelog(body);
    return TextSpan(
      text: '$tagName \n',
      style: AppTextStyle.title2.of(context),
      children: version == null
          ? [
              TextSpan(text: '\n', style: AppTextStyle.subheadline.of(context)),
              for (final submit in parseReleaseBody(body))
                TextSpan(
                  text: '- $submit \n',
                  style: AppTextStyle.subheadline.of(context),
                ),
            ]
          : _changelogSpans(context, version),
    );
  }

  List<TextSpan> _changelogSpans(
    BuildContext context,
    ChangelogVersion version,
  ) {
    return [
      for (final group in version.visibleGroups) ...[
        TextSpan(
          text:
              '\n${changelogGroupTitle(currentAppLocalizations, group.type)}\n',
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .copyWith(
                color: group.type == ChangelogType.breaking
                    ? context.colorScheme.error
                    : context.colorScheme.primary,
              ),
        ),
        for (final entry in group.entries)
          TextSpan(
            text: '• ${entry.text}\n',
            style: AppTextStyle.subheadline.of(context),
          ),
      ],
    ];
  }

  Future<void> checkUpdateResultHandle({
    AppUpdateRelease? data,
    bool isUser = false,
  }) async {
    if (_isInstallingUpdate) return;
    _isInstallingUpdate = true;
    try {
      final context = globalState.navigatorKey.currentContext!;
      final l = currentAppLocalizations;
      if (data == null) {
        if (isUser) await dialogs.showAlert(
          title: l.checkUpdate, message: TextSpan(text: l.updateAlreadyCurrent));
        return;
      }
      final result = await dialogs.showMessage(
        title: l.discoverNewVersion,
        message: TextSpan(children: [
          _releaseSpan(context, 'v${data.version}', data.notes),
          TextSpan(text: '\n\n${l.updateRestartNotice}'),
        ]),
        confirmText: l.updateDownloadInstall,
        cancelText: isUser ? null : l.noLongerRemind,
      );
      if (result != true) {
        if (!isUser && result == false) {
          ref.read(appSettingProvider.notifier).update(
            (state) => state.copyWith(autoCheckUpdate: false));
        }
        return;
      }
      if (!context.mounted) return;
      final installer = await showDialog<File>(context: context,
        barrierDismissible: false,
        builder: (_) => AppUpdateDialog(release: data));
      if (installer == null) return;
      // Persist before launching a worker; a failed save must not shut down the app.
      await preferences.saveConfig(ref.read(configProvider));
      await preferences.setUpdateResume(ref.read(isStartProvider));
      try {
        await appUpdater.scheduleInstall(installer);
      } catch (_) {
        await preferences.clearUpdateResume();
        rethrow;
      }
      await ref.read(systemActionProvider.notifier).handleExit();
    } catch (error) {
      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
    } finally {
      _isInstallingUpdate = false;
    }
  }
}
