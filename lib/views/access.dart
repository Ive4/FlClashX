import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/application_history.dart';
import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _androidPackageNamePattern = RegExp(r'^[a-zA-Z]\w*(\.[a-zA-Z]\w*)+$');

class AccessView extends ConsumerStatefulWidget {
  const AccessView({super.key, this.isOhos, this.isDesktop, this.isWindows});

  final bool? isOhos;
  final bool? isDesktop;
  final bool? isWindows;

  @override
  ConsumerState<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends ConsumerState<AccessView>
    with RouteSettledMixin<AccessView> {
  late ScrollController _controller;
  List<String>? _pinedList;
  bool _isInit = false;
  bool _installedAppsPermissionGranted = true;
  bool _showHistory = false;
  bool _groupByName = true;
  final _expandedNames = <String>{};
  bool get _isOhos => widget.isOhos ?? system.isOhos;
  bool get _isDesktop =>
      widget.isDesktop ?? (system.isWindows || system.isMacOS);
  bool get _isWindows => widget.isWindows ?? system.isWindows;
  late final ApplicationHistory _history;
  Timer? _historyRefresh;

  final _completer = Completer();

  @override
  void initState() {
    super.initState();
    _controller = sheetScrollController(context);
    final accessControl = ref
        .read(vpnSettingProvider.select((state) => state.accessControlProps))
        .copyWith();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(accessControlStateProvider.notifier).value = _isDesktop
          ? groupVersionedApplications(accessControl, windows: _isWindows)
          : accessControl;
      _isInit = true;
      _pinList();
    });
    ref.listenManual(
      accessControlStateProvider.select((state) => state.mode),
      (_, _) => _pinList(),
    );
    if (_isDesktop) {
      _history = ref.read(applicationHistoryProvider);
      _history.addListener(_historyChanged);
      _historyRefresh = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_history.refreshBackground());
      });
    }
    _completer.complete(_loadPackages());
  }

  @override
  void didSettleRoute() => setState(() {});

  Future<void> _loadPackages() async {
    final action = ref.read(systemActionProvider.notifier);
    if (_isDesktop) {
      await action.getDesktopPackages(windows: _isWindows);
      return;
    }
    if (_isOhos) {
      final packages = await action.getPackages();
      _updateInstalledAppsPermission(
        packages.isNotEmpty || await action.isInstalledAppsPermissionGranted(),
      );
      return;
    }
    await Future.wait<void>([
      action.getPackages(),
      action.isInstalledAppsPermissionGranted().then(
        _updateInstalledAppsPermission,
      ),
    ]);
  }

  void _updateInstalledAppsPermission(bool granted) {
    if (!mounted || granted == _installedAppsPermissionGranted) {
      return;
    }
    setState(() {
      _installedAppsPermissionGranted = granted;
    });
  }

  Future<void> _handleGrantInstalledAppsPermission() async {
    final appLocalizations = context.appLocalizations;
    final granted = await ref
        .read(systemActionProvider.notifier)
        .requestInstalledAppsPermission();
    if (!mounted) {
      return;
    }
    if (!granted) {
      final res = await dialogs.showMessage(
        message: TextSpan(
          text: appLocalizations.installedAppsPermissionDeniedMessage,
        ),
        confirmText: appLocalizations.settings,
      );
      if (res == true) {
        await app?.openAppSettings();
      }
      return;
    }
    await globalState.loadingRun(_loadPackages, tag: LoadingTag.access);
  }

  void _pinList() {
    if (!_isInit || !mounted) {
      return;
    }
    setState(() {
      _pinedList = ref.read(accessControlStateProvider).currentList;
    });
  }

  void _historyChanged() {
    if (!mounted) return;
    final access = _isInit
        ? ref.read(accessControlStateProvider)
        : ref.read(vpnSettingProvider).accessControlProps;
    ref.read(packagesProvider.notifier).value = _history.packages(
      access,
      windows: _isWindows,
    );
  }

  @override
  void dispose() {
    _historyRefresh?.cancel();
    if (_isDesktop) _history.removeListener(_historyChanged);
    _controller.dispose();
    super.dispose();
  }

  IconButtonData _buildSelectAllAction({
    required bool isSelectedAll,
    required Set<String> visibleNames,
  }) {
    void onPressed() {
      ref.read(accessControlStateProvider.notifier).update((state) {
        final newSet = Set<String>.from(state.currentList);
        final isSelectedAll = newSet.containsAll(visibleNames);
        if (isSelectedAll) {
          newSet.removeAll(visibleNames);
        } else {
          newSet.addAll(visibleNames);
        }
        return state.copyWithNewList(newSet.toList());
      });
    }

    final appLocalizations = context.appLocalizations;
    return isSelectedAll
        ? IconButtonData(
            glyph: AppGlyphs.deselect,
            tooltip: appLocalizations.cancelSelectAll,
            onPressed: onPressed,
          )
        : IconButtonData(
            glyph: AppGlyphs.selectAll,
            tooltip: appLocalizations.selectAll,
            onPressed: onPressed,
          );
  }

  Future<void> _intelligentSelected(Set<String> visibleNames) async {
    if (visibleNames.isEmpty || ref.read(loadingProvider(LoadingTag.access))) {
      return;
    }
    final action = ref.read(systemActionProvider.notifier);
    final chinaPackageNames = await globalState.loadingRun(
      action.getChinaPackageNames,
      tag: LoadingTag.access,
    );
    if (!mounted || chinaPackageNames == null) return;
    final china = chinaPackageNames.toSet();

    List<String> replaceVisible(
      List<String> list,
      bool Function(String) test,
    ) => [
      ...list.where((name) => !visibleNames.contains(name)),
      ...visibleNames.where(test),
    ];

    _update(
      (state) => state.copyWith(
        acceptList: replaceVisible(
          state.acceptList,
          (name) => !china.contains(name),
        ),
        rejectList: replaceVisible(state.rejectList, china.contains),
      ),
    );
  }

  void _handleSelected(String packageName) {
    ref.read(accessControlStateProvider.notifier).update((state) {
      final newSet = Set<String>.from(state.currentList)
        ..addOrRemove(packageName);
      return state.copyWithNewList(newSet.toList());
    });
  }

  Future<void> _addDesktopApplication() async {
    final labels = context.appLocalizations;
    final value = await dialogs.showCommonDialog<String>(
      child: InputDialog(
        title: labels.desktopAccessAddApplication,
        value: '',
        hintText: labels.desktopAccessManualEntry,
        selectAll: true,
        inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
        validator: (value) =>
            ApplicationIdentity.fromManualInput(
                  value ?? '',
                  windows: _isWindows,
                ) ==
                null
            ? labels.applicationProxyInvalidProcess
            : null,
      ),
    );
    if (!mounted || value == null) return;
    final identity = ApplicationIdentity.fromManualInput(
      value,
      windows: _isWindows,
    );
    if (identity == null) return;
    _update(
      (state) => state.copyWithNewList(
        {...state.currentList, identity.forRouting.selectionKey}.toList(),
      ),
    );
    setState(() {
      _showHistory = false;
      _expandedNames.add(identity.name.toLowerCase());
    });
    _historyChanged();
  }

  void _update(AccessControlProps Function(AccessControlProps state) update) {
    ref.read(accessControlStateProvider.notifier).update(update);
  }

  Future<void> _handleBack() async {
    final res = await dialogs.showSaveChanges();
    if (res == null) {
      return;
    }
    if (res) {
      _handleSave();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  AccessControlProps _accessControlForSave(
    AccessControlProps draft,
    AccessControlProps saved,
  ) {
    if (_isDesktop) {
      return groupVersionedApplications(draft, windows: _isWindows);
    }
    if (_isOhos || identical(draft, saved)) {
      return draft;
    }

    List<String> sortChangedList(List<String> list, List<String> previous) =>
        const ListEquality<String>().equals(list, previous) ||
            const UnorderedIterableEquality<String>().equals(list, previous)
        ? previous
        : ([...list]..sort());

    return draft.copyWith(
      acceptList: sortChangedList(draft.acceptList, saved.acceptList),
      rejectList: sortChangedList(draft.rejectList, saved.rejectList),
    );
  }

  void _handleSave() {
    final accessControl = ref.read(accessControlStateProvider);
    ref
        .read(vpnSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            accessControlProps: _accessControlForSave(
              accessControl,
              state.accessControlProps,
            ),
          ),
        );
  }

  Future<void> _exportToClipboard() async {
    await globalState.safeRun(() {
      final currentList = ref.read(
        accessControlStateProvider.select((state) => state.currentList),
      );
      Clipboard.setData(ClipboardData(text: currentList.join('\n')));
    });
  }

  Future<void> _importFromClipboard() async {
    await globalState.safeRun(() async {
      final text = (await Clipboard.getData('text/plain'))?.text;
      if (!mounted) return;
      final List<String> list;
      if (_isDesktop || _isOhos) {
        if (text == null) return;
        list = text.split('\n').toSet().toList();
      } else {
        list = const LineSplitter()
            .convert(text ?? '')
            .map((line) => line.trim())
            .where(_androidPackageNamePattern.hasMatch)
            .toSet()
            .toList();
        if (list.isEmpty) {
          throw MessageException(
            context.appLocalizations.clipboardNoPackageNames,
          );
        }
      }
      _update((state) {
        final updated = state.copyWithNewList(list);
        return _isDesktop
            ? groupVersionedApplications(updated, windows: _isWindows)
            : updated;
      });
      if (_isDesktop) _historyChanged();
    });
  }

  List<CommonPopupMenuItem> _buildMenuItems(
    BuildContext context,
    AccessControlProps accessControl,
    Set<String> visibleNames,
  ) {
    final appLocalizations = context.appLocalizations;
    String modeText(AccessControlMode mode) => switch (mode) {
      AccessControlMode.acceptSelected => appLocalizations.whitelistMode,
      AccessControlMode.rejectSelected => appLocalizations.blacklistMode,
    };
    return [
      CommonPopupMenuItem(
        glyph: AppGlyphs.toggleOn,
        label: appLocalizations.turnOn,
        checked: accessControl.enable,
        section: CommonPopupMenuSection(title: appLocalizations.accessControl),
        onPressed: () => _update((state) => state.copyWith(enable: true)),
      ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.toggle,
        label: appLocalizations.turnOff,
        checked: !accessControl.enable,
        onPressed: () => _update((state) => state.copyWith(enable: false)),
      ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.sliders,
        label: appLocalizations.settings,
        subtitle: modeText(accessControl.mode),
        section: const CommonPopupMenuSection(),
        subItems: [
          ..._optionsSection(
            title: appLocalizations.mode,
            options: AccessControlMode.values,
            value: accessControl.mode,
            textOf: modeText,
            onSelected: (mode) =>
                _update((state) => state.copyWith(mode: mode)),
          ),
          ..._optionsSection(
            title: appLocalizations.sort,
            options: AccessSortType.values,
            value: accessControl.sort,
            textOf: (type) => switch (type) {
              AccessSortType.none => appLocalizations.defaultText,
              AccessSortType.name => appLocalizations.name,
              AccessSortType.time => appLocalizations.time,
            },
            onSelected: (sort) =>
                _update((state) => state.copyWith(sort: sort)),
          ),
          if (_isDesktop)
            CommonPopupMenuItem(
              label: appLocalizations.desktopAccessGroupByName,
              checked: _groupByName,
              section: CommonPopupMenuSection(title: appLocalizations.source),
              onPressed: () => setState(() => _groupByName = !_groupByName),
            ),
          if (!_isDesktop)
            CommonPopupMenuItem(
              label: appLocalizations.systemApp,
              checked: !accessControl.isFilterSystemApp,
              section: CommonPopupMenuSection(title: appLocalizations.source),
              onPressed: () => _update(
                (state) =>
                    state.copyWith(isFilterSystemApp: !state.isFilterSystemApp),
              ),
            ),
          if (!_isDesktop)
            CommonPopupMenuItem(
              label: appLocalizations.noNetworkApp,
              checked: !accessControl.isFilterNonInternetApp,
              onPressed: () => _update(
                (state) => state.copyWith(
                  isFilterNonInternetApp: !state.isFilterNonInternetApp,
                ),
              ),
            ),
        ],
      ),
      CommonPopupMenuItem(
        glyph: AppGlyphs.moreCircle,
        label: appLocalizations.action,
        subItems: [
          if (_isOhos || _isDesktop)
            CommonPopupMenuItem(
              glyph: AppGlyphs.refresh,
              label: appLocalizations.update,
              onPressed: () =>
                  globalState.loadingRun(_loadPackages, tag: LoadingTag.access),
            ),
          if (!_isOhos && !_isDesktop)
            CommonPopupMenuItem(
              glyph: AppGlyphs.sparkle,
              label: appLocalizations.intelligentSelected,
              onPressed: () => _intelligentSelected(visibleNames),
            ),
          CommonPopupMenuItem(
            glyph: AppGlyphs.copy,
            label: appLocalizations.clipboardExport,
            onPressed: _exportToClipboard,
          ),
          CommonPopupMenuItem(
            glyph: AppGlyphs.paste,
            label: appLocalizations.clipboardImport,
            onPressed: _importFromClipboard,
          ),
        ],
      ),
    ];
  }

  Widget _buildContent({
    required List<Package> packages,
    required Set<String> selected,
    required bool isSearching,
  }) {
    final processMode = ref.watch(
      patchClashConfigProvider.select((state) => state.findProcessMode),
    );
    final needsProcessLookup = _isDesktop
        ? processMode == FindProcessMode.off &&
              !ref.watch(
                vpnSettingProvider.select(
                  (state) => state.accessControlProps.enable,
                ),
              )
        : _isOhos && processMode != FindProcessMode.always;
    final groups = _isDesktop && _groupByName
        ? groupBy(
            packages,
            (package) => package.label.toLowerCase(),
          ).values.toList()
        : null;
    final list = FutureBuilder(
      future: _completer.future,
      builder: (context, snapshot) {
        final appLocalizations = context.appLocalizations;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CommonCircleLoading.page());
        }
        return NullStatusSwitcher(
          isEmpty: packages.isEmpty,
          isSearching: isSearching,
          nullStatus: NullStatus(
            label: snapshot.hasError
                ? snapshot.error.toString()
                : _isOhos || _isDesktop
                ? appLocalizations.applicationHistoryEmpty
                : appLocalizations.noData,
            illustration: NullStatusIllustration.apps,
            description: needsProcessLookup
                ? appLocalizations.applicationProxyEnableProcess
                : _isDesktop
                ? appLocalizations.desktopAccessHistoryDesc
                : null,
            action: needsProcessLookup
                ? TonalButton(
                    size: TonalButtonSize.bar,
                    glyph: AppGlyphs.appsList,
                    label: appLocalizations.findProcessMode,
                    onPressed: () => ref
                        .read(patchClashConfigProvider.notifier)
                        .update(
                          (state) => state.copyWith(
                            findProcessMode: FindProcessMode.always,
                          ),
                        ),
                  )
                : null,
          ),
          child: CommonScrollBar(
            controller: _controller,
            child: ListView.builder(
              controller: _controller,
              padding: EdgeInsets.only(
                top: _isDesktop ? 0 : context.contentTopPadding,
                bottom: context.bottomInset,
              ),
              scrollCacheExtent: arrivalScrollCacheExtent(routeSettled),
              itemCount: groups?.length ?? packages.length,
              itemExtent: _isDesktop ? null : 72,
              itemBuilder: (_, index) {
                if (groups == null) {
                  return _packageRow(packages[index], selected);
                }
                final group = groups[index];
                if (group.length == 1) {
                  return _packageRow(group.single, selected);
                }
                final name = group.first.label.toLowerCase();
                final expanded = _expandedNames.contains(name);
                return Column(
                  key: ValueKey(name),
                  children: [
                    ListItem(
                      title: Text(group.first.label),
                      subtitle: Text(
                        appLocalizations.accessControlSelectedCount(
                          group
                              .where(
                                (package) =>
                                    selected.contains(package.packageName),
                              )
                              .length,
                        ),
                      ),
                      leading: const GlyphIcon(AppGlyphs.appsList, size: 32),
                      trailing: RotatedBox(
                        quarterTurns: expanded ? 1 : 0,
                        child: const GlyphIcon(AppGlyphs.chevronForward),
                      ),
                      onTap: () =>
                          setState(() => _expandedNames.addOrRemove(name)),
                    ),
                    if (expanded)
                      for (final package in group)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(start: 20),
                          child: _packageRow(
                            package,
                            selected,
                            showName: false,
                          ),
                        ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
    return _isDesktop ? _buildDesktopTools(list) : list;
  }

  Widget _buildDesktopTools(Widget list) {
    final labels = context.appLocalizations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            16,
            context.contentTopPadding,
            16,
            4,
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final history in [false, true])
                Semantics(
                  selected: _showHistory == history,
                  child: TonalButton(
                    size: TonalButtonSize.section,
                    glyph: _showHistory == history ? AppGlyphs.check : null,
                    label: history
                        ? labels.desktopAccessRequestHistory
                        : labels.desktopAccessCandidates,
                    onPressed: () => setState(() => _showHistory = history),
                  ),
                ),
              Tooltip(
                message: labels.desktopAccessAddApplication,
                child: TonalButton(
                  size: TonalButtonSize.section,
                  glyph: AppGlyphs.add,
                  label: labels.desktopAccessAddApplication,
                  onPressed: _addDesktopApplication,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  Widget _packageRow(
    Package package,
    Set<String> selected, {
    bool showName = true,
  }) {
    return PackageListItem(
      key: Key(package.packageName),
      package: package,
      value: selected.contains(package.packageName),
      desktop: _isDesktop,
      showName: showName,
      showLastSeen: _showHistory,
      onChanged: (_) => _handleSelected(package.packageName),
    );
  }

  Widget _buildInstalledAppsPermissionStatus() {
    final appLocalizations = context.appLocalizations;
    return NullStatus(
      label: appLocalizations.installedAppsPermissionRequired,
      description: appLocalizations.installedAppsPermissionDesc,
      illustration: NullStatusIllustration.permission,
      action: TonalButton(
        size: TonalButtonSize.bar,
        glyph: AppGlyphs.lockOpen,
        label: appLocalizations.authorize,
        onPressed: _handleGrantInstalledAppsPermission,
      ),
    );
  }

  void _onSearch(String value) {
    ref.read(queryProvider(QueryTag.access).notifier).value = value;
    _pinList();
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(loadingProvider(LoadingTag.access));
    final query = SearchQuery(ref.watch(queryProvider(QueryTag.access)));
    final packages = ref.watch(packagesProvider);
    final accessControl = ref.watch(accessControlStateProvider);
    final visibleSource = _showHistory
        ? packages.where((package) => package.lastUpdateTime > 0).toList()
        : packages;
    final viewPackages = visibleSource
        .getViewList(
          pinedList: _showHistory ? const [] : _pinedList ?? [],
          sortType: _showHistory ? AccessSortType.time : accessControl.sort,
          isFilterNonInternetApp:
              !_isDesktop && accessControl.isFilterNonInternetApp,
          isFilterSystemApp: !_isDesktop && accessControl.isFilterSystemApp,
        )
        .whereMatches(
          query,
          (package) => [
            package.label,
            package.packageName,
            ?package.applicationPath,
          ],
        )
        .toList();
    final selected = accessControl.currentList.toSet();
    final visibleNames = viewPackages
        .map((package) => package.packageName)
        .toSet();
    final countableNames = _isDesktop || _isOhos
        ? visibleNames
        : packages.map((package) => package.packageName).toSet();
    final needsInstalledAppsPermission =
        packages.isEmpty && !_installedAppsPermissionGranted;
    final selectAllAction =
        accessControl.enable &&
            !needsInstalledAppsPermission &&
            visibleNames.isNotEmpty
        ? _buildSelectAllAction(
            isSelectedAll: selected.containsAll(visibleNames),
            visibleNames: visibleNames,
          )
        : null;
    final saved = ref.watch(
      vpnSettingProvider.select((state) => state.accessControlProps),
    );
    final hasChanges =
        _accessControlForSave(accessControl, saved) !=
        _accessControlForSave(saved, saved);
    return CommonPopScope(
      onPop: hasChanges
          ? (_) {
              _handleBack();
              return false;
            }
          : null,
      child: CommonScaffold(
        isLoading: isLoading,
        searchState: AppBarSearchState(onSearch: _onSearch),
        searchActions: [?selectAllAction],
        searchInBar: true,
        title: context.appLocalizations.appAccessControl,
        confirmationAction: hasChanges
            ? IconButtonData(
                glyph: AppGlyphs.check,
                onPressed: _handleSave,
                tooltip: context.appLocalizations.save,
              )
            : null,
        iconActions: [?selectAllAction],
        menuItems: _buildMenuItems(context, accessControl, visibleNames),
        body: needsInstalledAppsPermission
            ? _buildInstalledAppsPermissionStatus()
            : FloatingFootBar(
                bar: _AccessStatus(
                  desktop: _isDesktop,
                  desktopReady: ref.watch(
                    patchClashConfigProvider.select(
                      (state) => state.tun.enable && state.mode == Mode.rule,
                    ),
                  ),
                  accessControl: accessControl,
                  selectedCount: selected.intersection(countableNames).length,
                  onAuthorize: _installedAppsPermissionGranted
                      ? null
                      : _handleGrantInstalledAppsPermission,
                  onEnable: () =>
                      _update((state) => state.copyWith(enable: true)),
                ),
                body: DisabledMask(
                  status: !_isDesktop && !accessControl.enable,
                  child: _buildContent(
                    packages: viewPackages,
                    selected: selected,
                    isSearching: query.isNotEmpty,
                  ),
                ),
              ),
      ),
    );
  }
}

class _AccessStatus extends StatelessWidget {
  const _AccessStatus({
    required this.accessControl,
    required this.selectedCount,
    required this.onEnable,
    this.onAuthorize,
    this.desktop = false,
    this.desktopReady = true,
  });

  final AccessControlProps accessControl;
  final int selectedCount;
  final VoidCallback onEnable;
  final VoidCallback? onAuthorize;
  final bool desktop;
  final bool desktopReady;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final enabled = accessControl.enable;
    final showsSelectedCount = enabled && onAuthorize == null;
    final description = onAuthorize != null
        ? appLocalizations.installedAppsPermissionRequired
        : desktop && enabled
        ? desktopReady
              ? appLocalizations.desktopAccessDirectDesc
              : appLocalizations.desktopAccessRequiresTun
        : enabled
        ? switch (accessControl.mode) {
            AccessControlMode.acceptSelected =>
              appLocalizations.accessControlAllowDesc,
            AccessControlMode.rejectSelected =>
              appLocalizations.accessControlNotAllowDesc,
          }
        : appLocalizations.accessControlDisabledDesc;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        16,
        6,
        showsSelectedCount ? 16 : 8,
        6,
      ),
      child: Row(
        spacing: 12,
        children: [
          GlyphIcon(
            showsSelectedCount ? AppGlyphs.appsList : AppGlyphs.info,
            size: 20,
            color: colorScheme.onSurfaceVariant,
          ),
          Expanded(
            child: Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: colorScheme.onSurface),
            ),
          ),
          if (onAuthorize case final authorize?)
            TonalButton(
              size: TonalButtonSize.compact,
              label: appLocalizations.authorize,
              onPressed: authorize,
            )
          else if (enabled)
            TonalChip(
              label: appLocalizations.accessControlSelectedCount(selectedCount),
              color: colorScheme.primary.opacity15,
              foregroundColor: colorScheme.primary,
            )
          else
            TonalButton(
              size: TonalButtonSize.compact,
              label: appLocalizations.turnOn,
              onPressed: onEnable,
            ),
        ],
      ),
    );
  }
}

class PackageListItem extends StatelessWidget {
  final Package package;
  final bool value;
  final void Function(bool?) onChanged;
  final bool desktop;
  final bool showName;
  final bool showLastSeen;

  const PackageListItem({
    super.key,
    required this.package,
    required this.value,
    required this.onChanged,
    this.desktop = false,
    this.showName = true,
    this.showLastSeen = false,
  });

  @override
  Widget build(BuildContext context) {
    final identity = desktop
        ? ApplicationIdentity.fromSelection(
            package.packageName,
            windows: package.packageName.startsWith('windows:'),
          )
        : null;
    final subtitle = identity?.action == RuleAction.PROCESS_NAME
        ? context.appLocalizations.desktopAccessNameOnly(identity!.content)
        : package.applicationPath ?? identity?.content ?? package.packageName;
    final shownAt = showLastSeen && package.lastUpdateTime > 0
        ? DateTime.fromMillisecondsSinceEpoch(package.lastUpdateTime)
        : null;
    final material = MaterialLocalizations.of(context);
    final lastSeen = shownAt == null
        ? null
        : '${context.appLocalizations.desktopAccessLastSeen} · '
              '${material.formatCompactDate(shownAt)} '
              '${material.formatTimeOfDay(TimeOfDay.fromDateTime(shownAt))}';
    final details = [if (showName) subtitle, ?lastSeen].join('\n');
    return ListItem.checkbox(
      leading: desktop
          ? switch (package.applicationPath) {
              final path? => PackageIcon(
                packageName: path,
                size: 32,
                desktop: true,
              ),
              null => const GlyphIcon(AppGlyphs.appsList, size: 32),
            }
          : PackageIcon(packageName: package.packageName, size: 48),
      title: Text(
        showName ? package.label : subtitle,
        style: const TextStyle(overflow: TextOverflow.ellipsis),
        maxLines: 1,
      ),
      subtitle: details.isEmpty
          ? null
          : Text(
              details,
              style: const TextStyle(overflow: TextOverflow.ellipsis),
              maxLines: showName && lastSeen != null ? 2 : 1,
            ),
      value: value,
      onChanged: onChanged,
    );
  }
}

List<CommonPopupMenuItem> _optionsSection<T>({
  required String title,
  required List<T> options,
  required T value,
  required String Function(T option) textOf,
  required ValueSetter<T> onSelected,
}) {
  return [
    for (final option in options)
      CommonPopupMenuItem(
        label: textOf(option),
        checked: option == value,
        section: option == options.first
            ? CommonPopupMenuSection(title: title)
            : null,
        onPressed: () => onSelected(option),
      ),
  ];
}
