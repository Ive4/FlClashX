part of '../action.dart';

enum AppUpdatePhase { checking, available, downloading, installing }

typedef AppUpdateActivity = ({
  AppUpdatePhase phase,
  String? version,
  double? progress,
});

final appUpdateActivityProvider =
    NotifierProvider<AppUpdateActivityNotifier, AppUpdateActivity?>(
      AppUpdateActivityNotifier.new,
    );

class AppUpdateActivityNotifier extends Notifier<AppUpdateActivity?> {
  @override
  AppUpdateActivity? build() => null;

  set value(AppUpdateActivity? value) => state = value;
}

@Riverpod(keepAlive: true)
class CommonAction extends _$CommonAction {
  CoreController get _core => ref.read(coreHandlerProvider);
  bool _isUpdatingTraffic = false;
  bool _isInstallingUpdate = false;
  CancelToken? _updateCancel;

  @override
  void build() => ref.onDispose(cancelUpdate);

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
    return checkUpdate();
  }

  Future<bool> checkUpdate({bool isUser = false}) async {
    if (_isInstallingUpdate || ref.read(appUpdateActivityProvider) != null) {
      return false;
    }
    final activity = ref.read(appUpdateActivityProvider.notifier);
    activity.value = (
      phase: AppUpdatePhase.checking,
      version: null,
      progress: null,
    );
    final AppUpdateRelease? res;
    try {
      res = await appUpdater.check(
        channel: ref.read(appSettingProvider).updateChannel,
      );
    } catch (error) {
      if (isUser && ref.mounted) {
        dialogs.showNotifier(
          userFacingErrorMessage(error, currentAppLocalizations),
          level: MessageLevel.error,
        );
      } else {
        commonPrint.log(
          'checkForUpdate failed: ${compactError(error)}',
          logLevel: LogLevel.warning,
        );
      }
      return false;
    } finally {
      if (ref.mounted) activity.value = null;
    }
    if (!ref.mounted) return false;
    await checkUpdateResultHandle(data: res, isUser: isUser);
    return res != null;
  }

  void cancelUpdate() => _updateCancel?.cancel();

  Future<({File file, String? staged})?> _downloadUpdate(
    BuildContext context,
    AppUpdateRelease release,
    AppUpdateActivityNotifier activity,
  ) async {
    final cancel = _updateCancel = CancelToken();
    void report(double? progress) {
      if (!ref.mounted || cancel.isCancelled) return;
      activity.value = (
        phase: AppUpdatePhase.downloading,
        version: release.fullVersion,
        progress: progress,
      );
    }

    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AppUpdateDialog(),
    );
    File? file;
    String? staged;
    try {
      report(0);
      unawaited(navigator.push(route));
      file = await appUpdater.download(release, cancel, report);
      if (release.isMacOS) {
        final macos = appUpdater.macos;
        if (macos == null) {
          throw UnsupportedError(currentAppLocalizations.updateUnavailable);
        }
        staged = await macos.stage(file.path, file.parent.path);
      }
      if (cancel.isCancelled || !ref.mounted) {
        await discardDownloadedUpdate(file, staged: staged);
        return null;
      }
      return (file: file, staged: staged);
    } catch (_) {
      if (file != null) await discardDownloadedUpdate(file, staged: staged);
      if (cancel.isCancelled) throw cancel.cancelError!;
      rethrow;
    } finally {
      _updateCancel = null;
      if (route.isCurrent) {
        navigator.pop();
      } else if (route.isActive) {
        navigator.removeRoute(route);
      }
    }
  }

  Future<void> reportMacosUpdateFailure() async {
    if (!system.isMacOS) return;
    try {
      final failure = await takeMacosInstallFailure(
        await appUpdater.macosFailureMarker,
      );
      if (failure == null || !ref.mounted) return;
      commonPrint.log(
        'Update install failed: ${failure.reason}',
        logLevel: LogLevel.warning,
      );
      await _showMacosUpdateFailure(
        Uri.https(
          'github.com',
          '/$updateRepository/releases/tag/${failure.tag}',
        ),
      );
    } catch (error) {
      commonPrint.log('Update failure report: ${compactError(error)}');
    }
  }

  Future<void> _showMacosUpdateFailure(Uri releasePage) async {
    final l = currentAppLocalizations;
    final confirmed = await dialogs.showMessage(
      title: l.checkUpdate,
      message: TextSpan(text: l.updateInstallFailed),
      confirmText: l.updateOpenReleasePage,
    );
    if (confirmed == true) await dialogs.openUrl(releasePage.toString());
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
    final activity = ref.read(appUpdateActivityProvider.notifier);
    try {
      final context = globalState.navigatorKey.currentContext!;
      final l = currentAppLocalizations;
      if (data == null) {
        if (isUser) {
          await dialogs.showAlert(
            title: l.checkUpdate,
            message: TextSpan(text: l.updateAlreadyCurrent),
          );
        }
        return;
      }
      activity.value = (
        phase: AppUpdatePhase.available,
        version: data.fullVersion,
        progress: null,
      );
      final result = await dialogs.showMessage(
        title: l.discoverNewVersion,
        message: TextSpan(
          children: [
            _releaseSpan(context, data.tag ?? 'v${data.version}', data.notes),
            TextSpan(
              text:
                  '\n\n${!data.canInstall
                      ? l.updateUnavailable
                      : data.isAndroid
                      ? l.updateAndroidInstallNotice
                      : l.updateRestartNotice}',
            ),
          ],
        ),
        confirmText: data.canInstall
            ? l.updateDownloadInstall
            : l.updateOpenReleasePage,
        cancelText: isUser ? null : l.noLongerRemind,
      );
      if (result != true) {
        if (!isUser && result == false) {
          ref
              .read(appSettingProvider.notifier)
              .update((state) => state.copyWith(autoCheckUpdate: false));
        }
        return;
      }
      if (!context.mounted) return;
      if (!data.canInstall) {
        await dialogs.openUrl(data.releasePage.toString());
        return;
      }
      final installer = await _downloadUpdate(context, data, activity);
      if (installer == null) return;
      activity.value = (
        phase: AppUpdatePhase.installing,
        version: data.fullVersion,
        progress: 1,
      );
      try {
        await preferences.saveConfig(ref.read(configProvider));
      } catch (_) {
        await discardDownloadedUpdate(installer.file, staged: installer.staged);
        rethrow;
      }
      if (data.isAndroid) {
        await appUpdater.installAndroid(data, installer.file);
        return;
      }
      try {
        await preferences.setUpdateResume(ref.read(isStartProvider));
        if (installer.staged case final staged?) {
          final started = await appUpdater.macos!.install(
            staged: staged,
            tag: data.tag ?? 'v${data.version}',
            marker: await appUpdater.macosFailureMarker,
          );
          if (!started) {
            await preferences.clearUpdateResume();
            await discardDownloadedUpdate(installer.file, staged: staged);
            return;
          }
        } else {
          await appUpdater.scheduleInstall(installer.file);
        }
      } catch (_) {
        await preferences.clearUpdateResume();
        await discardDownloadedUpdate(installer.file, staged: installer.staged);
        rethrow;
      }
      await ref.read(systemActionProvider.notifier).handleExit();
    } catch (error) {
      if (ref.mounted &&
          (error is! DioException || !CancelToken.isCancel(error))) {
        if (data != null && data.isMacOS) {
          commonPrint.log(
            'Update install failed: ${compactError(error)}',
            logLevel: LogLevel.warning,
          );
          await _showMacosUpdateFailure(data.releasePage);
        } else {
          dialogs.showNotifier(error.toString(), level: MessageLevel.error);
        }
      }
    } finally {
      _isInstallingUpdate = false;
      if (ref.mounted) activity.value = null;
    }
  }
}
