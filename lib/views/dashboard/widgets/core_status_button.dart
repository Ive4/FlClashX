import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/app_update_dialog.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CoreStatusButton extends ConsumerStatefulWidget {
  const CoreStatusButton({super.key, this.separateCore = true});

  final bool separateCore;

  @override
  ConsumerState<CoreStatusButton> createState() => _CoreStatusButtonState();
}

class _CoreStatusButtonState extends ConsumerState<CoreStatusButton> {
  static const _holdDuration = Duration(milliseconds: 600);

  Timer? _holdTimer;
  CoreStatus _status = CoreStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _status = ref.read(coreStatusProvider);
    ref.listenManual(coreStatusProvider, (_, next) {
      _onStatusChanged(next);
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onStatusChanged(CoreStatus next) {
    setState(() {
      _status = next;
      switch (next) {
        case CoreStatus.connecting:
          _holdTimer ??= Timer(_holdDuration, () {
            if (mounted) {
              setState(() {
                _holdTimer = null;
              });
            }
          });
          break;
        case CoreStatus.disconnected:
          _holdTimer?.cancel();
          _holdTimer = null;
          break;
        case CoreStatus.connected:
          break;
      }
    });
  }

  Future<void> _handleConnection() async {
    if (_holdTimer != null || !widget.separateCore) {
      return;
    }
    final coreStatus = ref.read(coreStatusProvider);
    if (coreStatus == CoreStatus.connecting) {
      return;
    }
    final tip = coreStatus == CoreStatus.connected
        ? context.appLocalizations.forceRestartCoreTip
        : context.appLocalizations.restartCoreTip;
    final reason = ref.read(coreStopReasonProvider);
    final res = await dialogs.showMessage(
      message: TextSpan(text: reason == null ? tip : '$reason\n\n$tip'),
    );
    if (res != true || !mounted) {
      return;
    }
    try {
      await ref.read(coreActionProvider.notifier).restartCore();
    } catch (error) {
      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
    }
  }

  void _openStatus() {
    unawaited(
      dialogs.showCommonDialog<void>(
        context: context,
        child: _DashboardStatusDialog(
          separateCore: widget.separateCore,
          onRestart: _handleConnection,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reason = ref.watch(coreStopReasonProvider);
    final coreStatus = _holdTimer != null ? CoreStatus.connecting : _status;
    final update = ref.watch(appUpdateActivityProvider);
    final resourceCount = ref.watch(
      updatingKeysProvider.select((keys) => keys.length),
    );
    final count = resourceCount + (update == null ? 0 : 1);
    final showCore =
        widget.separateCore || coreStatus == CoreStatus.disconnected;
    final coreFirst =
        showCore && (coreStatus != CoreStatus.connected || count == 0);
    if (!coreFirst) {
      if (count == 0) return const SizedBox.shrink();
      return _ActivityButton(
        update: update,
        count: count,
        onPressed: _openStatus,
      );
    }
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final glass = TonalButtonTheme.glassOf(context);
    ButtonStyle? tinted(Color? color) => glass && color != null
        ? LiquidGlass.buttonStyle(
            (_) => LiquidGlassStyle.tinted(colorScheme, color),
          )
        : null;
    final statusColor = switch (coreStatus) {
      CoreStatus.connecting => null,
      CoreStatus.connected => colorScheme.successContainer,
      CoreStatus.disconnected => colorScheme.errorContainer,
    };
    final style = ElasticPress.buttonStyle
        .merge(tinted(statusColor))
        .merge(
          FilledButton.styleFrom(
            backgroundColor: statusColor,
            foregroundColor: switch (coreStatus) {
              CoreStatus.connecting => null,
              CoreStatus.connected => colorScheme.onSuccessContainer,
              CoreStatus.disconnected => colorScheme.onErrorContainer,
            },
          ),
        );
    final iconOnly =
        count == 0 &&
        (coreStatus == CoreStatus.connected || ViewScope.isMobileOf(context));
    final icon = switch (coreStatus) {
      CoreStatus.connecting => CommonCircleLoading(
        color: iconOnly ? null : colorScheme.onPrimary,
      ),
      CoreStatus.connected => const GlyphIcon(AppGlyphs.check, fill: 1),
      CoreStatus.disconnected => const GlyphIcon(AppGlyphs.refresh, fill: 1),
    };
    return Tooltip(
      message: count > 0
          ? appLocalizations.status
          : reason ?? appLocalizations.coreStatus,
      child: FadeScaleBox(
        alignment: Alignment.centerRight,
        child: iconOnly
            ? IconButton.filled(
                key: ValueKey(coreStatus),
                style: style,
                onPressed: _openStatus,
                icon: icon,
              )
            : FilledButton.icon(
                key: ValueKey(coreStatus),
                onPressed: _openStatus,
                style: style,
                icon: SizedBox.square(
                  dimension: globalState.measure.textHeight(
                    AppTextStyle.subheadline,
                  ),
                  child: icon,
                ),
                label: Text(
                  count > 0
                      ? '${count + 1}'
                      : _coreStatusLabel(context, coreStatus),
                ),
              ),
      ),
    );
  }
}

String _coreStatusLabel(BuildContext context, CoreStatus status) {
  final l = context.appLocalizations;
  return switch (status) {
    CoreStatus.connecting => l.connecting,
    CoreStatus.connected => l.connected,
    CoreStatus.disconnected => l.disconnected,
  };
}

class _ActivityButton extends StatelessWidget {
  const _ActivityButton({
    required this.update,
    required this.count,
    required this.onPressed,
  });

  final AppUpdateActivity? update;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final phase = update?.phase;
    final progress = update?.progress;
    final icon = switch (phase) {
      AppUpdatePhase.checking => const CommonCircleLoading(),
      AppUpdatePhase.downloading => CircularProgressIndicator(
        value: progress,
        strokeWidth: 2,
      ),
      AppUpdatePhase.installing => const GlyphIcon(AppGlyphs.check),
      AppUpdatePhase.available => const GlyphIcon(AppGlyphs.arrowDown),
      null => const GlyphIcon(AppGlyphs.resources),
    };
    final label = progress != null ? '${(progress * 100).floor()}%' : '$count';
    return Tooltip(
      message: context.appLocalizations.status,
      child: FadeScaleBox(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          key: ValueKey(phase),
          style: ElasticPress.buttonStyle,
          onPressed: onPressed,
          icon: SizedBox.square(
            dimension: globalState.measure.textHeight(AppTextStyle.subheadline),
            child: icon,
          ),
          label: Text(label),
        ),
      ),
    );
  }
}

class _DashboardStatusDialog extends ConsumerWidget {
  const _DashboardStatusDialog({
    required this.separateCore,
    required this.onRestart,
  });

  final bool separateCore;
  final Future<void> Function() onRestart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.appLocalizations;
    final status = ref.watch(coreStatusProvider);
    final reason = ref.watch(coreStopReasonProvider);
    final keys = ref.watch(updatingKeysProvider);
    final resources = _resourceNames(context, ref, keys);
    final update = ref.watch(appUpdateActivityProvider);
    final action = ref.read(commonActionProvider.notifier);
    return CommonDialog(
      title: l.status,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.close),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (separateCore || status == CoreStatus.disconnected) ...[
            Text(l.coreStatus, style: AppTextStyle.headline.of(context)),
            Text(_coreStatusLabel(context, status)),
            if (reason != null) Text(reason),
            if (separateCore && status != CoreStatus.connecting)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  unawaited(onRestart());
                },
                child: Text(l.restart),
              ),
          ],
          if (update != null) ...[
            Text(
              update.phase == AppUpdatePhase.available
                  ? l.discoverNewVersion
                  : update.phase == AppUpdatePhase.checking
                  ? l.checkUpdate
                  : l.updateDownloadInstall,
              style: AppTextStyle.headline.of(context),
            ),
            if (update.version case final version?) Text('v$version'),
            if (update.phase == AppUpdatePhase.downloading) ...[
              AppUpdateProgress(progress: update.progress),
              TextButton(onPressed: action.cancelUpdate, child: Text(l.cancel)),
            ],
            if (update.phase == AppUpdatePhase.installing) const Text('100%'),
          ] else
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(action.checkUpdate(isUser: true));
              },
              child: Text(l.checkUpdate),
            ),
          if (resources.isNotEmpty) ...[
            Text(
              '${l.resources} (${resources.length})',
              style: AppTextStyle.headline.of(context),
            ),
            for (final name in resources) Text(name),
          ],
        ],
      ),
    );
  }
}

List<String> _resourceNames(
  BuildContext context,
  WidgetRef ref,
  Set<String> keys,
) {
  if (keys.isEmpty) return const [];
  bool has(String prefix) => keys.any((key) => key.startsWith(prefix));
  final localized = context.appLocalizations;
  final names = {
    for (final resource in GeoResource.values)
      resource.updatingKey: resource.name,
    if (has('profile_'))
      for (final profile in ref.watch(profilesProvider))
        profile.updatingKey: profile.realLabel,
    if (has('rule_provider_'))
      for (final provider
          in ref.watch(clashProvidersProvider).asData?.value ?? const [])
        provider.updatingKey: provider.label,
    if (has('script_'))
      for (final script in ref.watch(scriptsProvider).asData?.value ?? const [])
        script.updatingKey: script.label,
    if (has('icon_set_'))
      for (final icon in ref.watch(iconSetsProvider).asData?.value ?? const [])
        icon.updatingKey: icon.name,
  };
  return [
    for (final key in keys)
      names[key] ??
          switch (key) {
            _ when key.startsWith('provider_') => key.substring(
              'provider_'.length,
            ),
            _ when key.startsWith('profile_') => localized.profile,
            _ when key.startsWith('rule_provider_') => localized.ruleProviders,
            _ when key.startsWith('script_') => localized.script,
            _ when key.startsWith('icon_set_') => localized.iconSets,
            _ => localized.resources,
          },
  ];
}
