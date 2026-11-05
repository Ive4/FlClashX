part of 'connections_table.dart';

class ApplicationProxyView extends ConsumerStatefulWidget {
  const ApplicationProxyView({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  ConsumerState<ApplicationProxyView> createState() =>
      _ApplicationProxyViewState();
}

class _ApplicationProxyViewState extends ConsumerState<ApplicationProxyView>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<ApplicationProxyView>,
        RouteMotionHoldMixin<ApplicationProxyView>,
        ConnectionsPolling<ApplicationProxyView> {
  @override
  bool get pollsConnections =>
      ref.read(networkSettingProvider).applicationProxyEnabled;

  @override
  bool get sortsConnections => false;

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: context.appLocalizations.applicationProxy,
      body: Builder(
        builder: (context) => AppBarClearance(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, context.bottomInset + 16),
            child: ApplicationProxyPanel(
              connections: connections,
              sampledAt: connectionsSampledAt,
              stale: connectionsStale,
              rowHeight: 44 * MediaQuery.textScalerOf(context).scale(1),
              scrollController: widget.scrollController,
            ),
          ),
        ),
      ),
    );
  }
}

class ApplicationProxyPanel extends ConsumerStatefulWidget {
  const ApplicationProxyPanel({
    super.key,
    required this.connections,
    required this.sampledAt,
    required this.stale,
    required this.rowHeight,
    this.scrollController,
    this.onCountChanged,
    this.isWindows,
  });

  final List<TrackerInfo> connections;
  final DateTime? sampledAt;
  final bool stale;
  final double rowHeight;
  final ScrollController? scrollController;
  final ValueChanged<int>? onCountChanged;
  final bool? isWindows;

  @override
  ConsumerState<ApplicationProxyPanel> createState() =>
      _ApplicationProxyPanelState();
}

class _ApplicationProxyPanelState extends ConsumerState<ApplicationProxyPanel> {
  String? _saving;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.listenManual(currentProfileIdProvider, (_, _) {
      setState(() => _error = null);
    });
  }

  Future<void> _change(
    int profileId,
    ApplicationIdentity application,
    String? target,
    ApplicationProxyMode mode,
  ) async {
    if (_saving != null || ref.read(currentProfileIdProvider) != profileId) {
      return;
    }
    final l = context.appLocalizations;
    setState(() {
      _saving = application.byName.key;
      _error = null;
    });
    // ignore: avoid_print
    print('>>> _change start key=${application.key} mounted=$mounted');
    try {
      final applied = await ref
          .read(setupActionProvider.notifier)
          .setApplicationProxy(
            profileId: profileId,
            application: application,
            target: target,
            mode: mode,
          );
      // ignore: avoid_print
      print('>>> _change returned applied=$applied');
      if (!applied &&
          mounted &&
          ref.read(currentProfileIdProvider) == profileId) {
        setState(() => _error = l.applicationProxyApplyFailed);
      }
    } catch (error) {
      // ignore: avoid_print
      print('>>> _change error $error');
      if (mounted && ref.read(currentProfileIdProvider) == profileId) {
        setState(() => _error = error.toString());
      }
    } finally {
      // ignore: avoid_print
      print('>>> _change finally mounted=$mounted');
      if (mounted) setState(() => _saving = null);
    }
  }

  ApplicationIdentity? _identity(ApplicationProxyInfo application) {
    final source = application.policyIdentity ?? application.identity;
    return source != null && !source.canRoute ? source.byName : source;
  }

  Widget _policy(
    ApplicationProxyInfo application,
    int? profileId,
    bool editable,
    List<String> groups,
    ApplicationProxyMode defaultMode,
  ) {
    final l = context.appLocalizations;
    final identity = _identity(application);
    String label(String? target) => switch (target) {
      null => l.applicationProxyFollowRules,
      'DIRECT' => l.direct,
      final String value => value,
    };
    final mode = application.mode ?? defaultMode;
    final enabled =
        editable &&
        identity?.canRoute == true &&
        _saving == null &&
        mode != ApplicationProxyMode.httpSocks;
    return _selector(
      label: identity == null
          ? l.unknown
          : label(
              mode == ApplicationProxyMode.httpSocks
                  ? null
                  : application.target,
            ),
      enabled: enabled,
      saving: _saving != null && _saving == identity?.byName.key,
      items: [
        for (final target in <String?>[null, 'DIRECT', ...groups])
          CommonPopupMenuItem(
            label: label(target),
            checked: target == application.target,
            onPressed: enabled
                ? () => _change(profileId!, identity!, target, mode)
                : null,
          ),
      ],
    );
  }

  Widget _mode(
    ApplicationProxyInfo application,
    int? profileId,
    bool editable,
    String followLabel,
    ApplicationProxyMode defaultMode,
  ) {
    final identity = _identity(application);
    final enabled = editable && identity?.canRoute == true && _saving == null;
    final selected = application.mode ?? defaultMode;
    return Tooltip(
      message: context.appLocalizations.applicationProxyModeHint,
      child: _selector(
        label: selected == ApplicationProxyMode.follow
            ? followLabel
            : selected.label,
        enabled: enabled,
        items: [
          for (final mode in ApplicationProxyMode.values)
            CommonPopupMenuItem(
              label: mode.label,
              checked: mode == selected,
              onPressed: enabled
                  ? () =>
                        _change(profileId!, identity!, application.target, mode)
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _selector({
    required String label,
    required bool enabled,
    required List<CommonPopupMenuItem> items,
    bool saving = false,
    Key? key,
  }) {
    return CommonPopupBox(
      targetBuilder: (open) => TextButton(
        key: key,
        onPressed: enabled ? open : null,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          foregroundColor: context.colorScheme.onSurface,
          disabledForegroundColor: context.colorScheme.onSurface.withValues(
            alpha: 0.38,
          ),
          textStyle: AppTextStyle.footnote.of(context),
        ),
        child: saving
            ? const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (enabled) const GlyphIcon(AppGlyphs.chevronDown, size: 12),
                ],
              ),
      ),
      popupBuilder: (_) => CommonPopupMenu(maxVisibleItems: 7, items: items),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    // ignore: avoid_print
    print('>>> panel build saving=$_saving');
    final profile = ref.watch(currentProfileProvider);
    final profileId = profile?.id;
    final featureEnabled = ref.watch(
      networkSettingProvider.select((state) => state.applicationProxyEnabled),
    );
    final editable =
        featureEnabled &&
        profile != null &&
        (profile.type == ProfileType.custom ||
            profile.extendType == ExtendType.standard);
    final rulesState = profileId == null || !editable
        ? const AsyncData<List<Rule>>([])
        : ref.watch(applicationRulesProvider(profileId));
    final patch = ref.watch(patchClashConfigProvider);
    final defaultMode = ref.watch(
      networkSettingProvider.select((state) => state.applicationProxyMode),
    );
    final invalidTarget = RegExp(r'[,\r\n]');
    final groups = ref
        .watch(groupsProvider)
        .map((group) => group.name)
        .where((name) => name != 'DIRECT' && !invalidTarget.hasMatch(name))
        .toSet()
        .toList();
    String? action;
    VoidCallback? onAction;
    String? notice;
    if (!featureEnabled) {
      notice = l.applicationProxyDisabled;
    } else if (widget.stale) {
      notice = l.applicationProxyRefreshFailed;
    } else if (profile == null) {
      notice = l.applicationProxyNoProfile;
    } else if (!editable) {
      notice = l.applicationProxyScriptUnsupported;
    } else if (patch.mode != Mode.rule) {
      notice = l.applicationProxyRuleMode;
      action = l.rule;
      onAction = () =>
          ref.read(setupActionProvider.notifier).changeMode(Mode.rule);
    }
    final message = _error ?? notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: _cellInset,
            right: _cellInset,
            bottom: 6,
          ),
          child: Row(
            children: [
              Text(
                l.applicationProxyDefaultMode,
                style: AppTextStyle.footnote.of(context),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Tooltip(
                  message: l.applicationProxyDefaultModeHint,
                  child: _selector(
                    key: const ValueKey('application-proxy-default-mode'),
                    label: defaultMode.label,
                    enabled: editable && _saving == null,
                    items: [
                      for (final mode in ApplicationProxyMode.values)
                        CommonPopupMenuItem(
                          label: mode.label,
                          checked: mode == defaultMode,
                          onPressed: () {
                            ref
                                .read(networkSettingProvider.notifier)
                                .update(
                                  (state) => state.copyWith(
                                    applicationProxyMode: mode,
                                  ),
                                );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (message != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cellInset),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Tooltip(
                    message: message,
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(
                            color: _error == null
                                ? context.colorScheme.onSurfaceVariant
                                : context.colorScheme.error,
                          ),
                    ),
                  ),
                ),
                if (action != null)
                  TextButton(
                    onPressed: _saving == null ? onAction : null,
                    child: Text(action),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
        Expanded(
          child: rulesState.hasError
              ? Center(child: Text(l.error))
              : rulesState.value == null
              ? const SizedBox.shrink()
              : _ApplicationRows(
                  key: ValueKey(profileId),
                  connections: widget.connections,
                  sampledAt: widget.sampledAt,
                  stale: widget.stale,
                  rules: rulesState.value!,
                  isWindows: widget.isWindows ?? system.isWindows,
                  aggregator: ref.watch(applicationProxyAggregatorProvider),
                  rowHeight: widget.rowHeight,
                  scrollController: widget.scrollController,
                  onCountChanged: widget.onCountChanged,
                  modeBuilder: (application) => _mode(
                    application,
                    profileId,
                    editable,
                    l.applicationProxyModeCurrent(
                      patch.tun.enable
                          ? l.tun
                          : l.applicationProxyModeHttpSocks,
                    ),
                    defaultMode,
                  ),
                  policyBuilder: (application) => _policy(
                    application,
                    profileId,
                    editable,
                    groups,
                    defaultMode,
                  ),
                ),
        ),
      ],
    );
  }
}

class _ApplicationRows extends ConsumerStatefulWidget {
  const _ApplicationRows({
    super.key,
    required this.connections,
    required this.sampledAt,
    required this.stale,
    required this.rules,
    required this.isWindows,
    required this.aggregator,
    required this.rowHeight,
    required this.policyBuilder,
    required this.modeBuilder,
    this.scrollController,
    this.onCountChanged,
  });

  final List<TrackerInfo> connections;
  final DateTime? sampledAt;
  final bool stale;
  final List<Rule> rules;
  final bool isWindows;
  final ApplicationProxyAggregator aggregator;
  final double rowHeight;
  final Widget Function(ApplicationProxyInfo application) policyBuilder;
  final Widget Function(ApplicationProxyInfo application) modeBuilder;
  final ScrollController? scrollController;
  final ValueChanged<int>? onCountChanged;

  @override
  ConsumerState<_ApplicationRows> createState() => _ApplicationRowsState();
}

class _ApplicationRowsState extends ConsumerState<_ApplicationRows>
    with RouteMotionHoldMixin<_ApplicationRows> {
  final _search = TextEditingController();
  final _resetting = <String>{};

  void _clearSearch() {
    _search.clear();
    setState(() {});
  }

  Widget _searchButton(BuildContext context) {
    final l = context.appLocalizations;
    final active = _search.text.trim().isNotEmpty;
    return CommonPopupBox(
      targetBuilder: (open) => IconButton(
        tooltip: l.search,
        onPressed: open,
        color: active ? context.colorScheme.primary : null,
        icon: Badge(
          isLabelVisible: active,
          child: const GlyphIcon(AppGlyphs.search, size: 20),
        ),
      ),
      popupBuilder: (popupContext) => Material(
        color: SurfaceLevel.floatingOf(
          context.colorScheme,
        ).colorOf(context.colorScheme),
        shape: AppShape.md,
        child: SizedBox(
          width: (MediaQuery.sizeOf(popupContext).width - 32)
              .clamp(0.0, 360.0)
              .toDouble(),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _search,
              builder: (_, value, _) => TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => Navigator.of(popupContext).pop(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l.applicationSearch,
                  prefixIcon: const Padding(
                    padding: EdgeInsets.all(12),
                    child: GlyphIcon(AppGlyphs.search, size: 18),
                  ),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l.clearSearch,
                          onPressed: _clearSearch,
                          icon: const GlyphIcon(AppGlyphs.close, size: 16),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _historyAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        dialogs.showNotifier(error.toString(), level: MessageLevel.error);
      }
    }
  }

  Future<void> _reset(ApplicationProxyInfo item) async {
    final key = item.identity?.key ?? '';
    if (!_resetting.add(key)) return;
    setState(() {});
    final l = context.appLocalizations;
    var failed = false;
    final core = ref.read(coreHandlerProvider);
    for (final id in List<String>.of(item.connectionIds)) {
      try {
        if (!await core.closeConnection(id)) failed = true;
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() => _resetting.remove(key));
    dialogs.showNotifier(
      failed ? l.applicationResetFailed : l.applicationResetDone,
    );
  }

  Future<void> _clearHistory() async {
    final l = context.appLocalizations;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.applicationClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.applicationClearHistory),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _historyAction(() => applicationHistory.remove(null));
    }
  }

  @override
  void dispose() {
    applicationHistory.removeListener(_historyChanged);
    _search.dispose();
    super.dispose();
  }

  ApplicationProxySnapshot? _snapshot;
  int _generation = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    applicationHistory.addListener(_historyChanged);
    unawaited(_historyAction(applicationHistory.load));
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant _ApplicationRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.connections, oldWidget.connections) ||
        widget.sampledAt != oldWidget.sampledAt ||
        !identical(widget.rules, oldWidget.rules)) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final snapshot = await widget.aggregator((
        connections: applicationConnectionsOf(widget.connections),
        rules: widget.rules,
        sampledAt: widget.sampledAt,
        previousSamples: _snapshot?.samples ?? const {},
        previousAt: _snapshot?.sampledAt,
        windows: widget.isWindows,
      ));
      if (!mounted || generation != _generation) return;
      void show() {
        if (!mounted || generation != _generation) return;
        setState(() {
          _snapshot = snapshot;
          _failed = false;
        });
        widget.onCountChanged?.call(
          snapshot.applications.where((item) => item.connections > 0).length,
        );
      }

      if (_snapshot == null) {
        show();
      } else {
        updateWhenRouteSettled(show);
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      commonPrint.log('application proxy statistics error: $error');
      setState(() => _failed = true);
    }
  }

  String _speed(ApplicationProxyInfo application, bool download) =>
      widget.stale || application.connections == 0
      ? '—'
      : '${dashboardTraffic(download ? application.downloadSpeed : application.uploadSpeed)}/s';

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    // ignore: avoid_print
    print('>>> rows build');
    if (_failed) return Center(child: Text(l.error));
    final snapshot = _snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final live = snapshot.applications
        .where((item) => item.connections > 0)
        .toList();
    final history = applicationHistory;
    final all = <String, ApplicationProxyInfo>{
      for (final item in live) item.identity?.key ?? '': item,
    };
    final configured = <String, ApplicationProxyInfo>{
      for (final item in snapshot.applications) item.identity?.key ?? '': item,
    };
    for (final entry in history.entries.values) {
      final identity = entry.identity;
      all.putIfAbsent(
        identity.key,
        () => configured[identity.key] ?? ApplicationProxyInfo(identity),
      );
    }
    final query = _search.text.trim().toLowerCase();
    final applications = (history.showHistory ? all.values : live)
        .where(
          (item) =>
              query.isEmpty ||
              (item.identity?.content.toLowerCase().contains(query) ?? false),
        )
        .toList();
    if (history.showHistory) {
      applications.sort((a, b) {
        final active = (b.connections > 0 ? 1 : 0).compareTo(
          a.connections > 0 ? 1 : 0,
        );
        if (active != 0) return active;
        final epoch = DateTime.fromMillisecondsSinceEpoch(0);
        return (history.entries[b.identity?.key]?.lastSeen ?? epoch).compareTo(
          history.entries[a.identity?.key]?.lastSeen ?? epoch,
        );
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    spacing: 6,
                    children: [
                      ChoiceChip(
                        label: Text('${l.applicationCurrent} (${live.length})'),
                        showCheckmark: false,
                        side: BorderSide.none,
                        shape: AppShape.sm,
                        labelStyle: AppTextStyle.footnote.of(context),
                        selected: !history.showHistory,
                        onSelected: (_) =>
                            _historyAction(() => history.select(false)),
                      ),
                      ChoiceChip(
                        label: Text('${l.applicationHistory} (${all.length})'),
                        showCheckmark: false,
                        side: BorderSide.none,
                        shape: AppShape.sm,
                        labelStyle: AppTextStyle.footnote.of(context),
                        selected: history.showHistory,
                        onSelected: (_) =>
                            _historyAction(() => history.select(true)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _searchButton(context),
              if (query.isNotEmpty)
                IconButton(
                  tooltip: l.clearSearch,
                  onPressed: _clearSearch,
                  icon: const GlyphIcon(AppGlyphs.close, size: 18),
                ),
              if (history.showHistory)
                IconButton(
                  tooltip: l.applicationClearHistory,
                  onPressed: history.entries.isEmpty ? null : _clearHistory,
                  icon: const GlyphIcon(AppGlyphs.delete, size: 18),
                ),
            ],
          ),
        ),
        Expanded(
          child: applications.isEmpty
              ? Center(
                  child: Text(
                    query.isNotEmpty
                        ? l.applicationNoMatches
                        : history.showHistory
                        ? l.applicationHistoryEmpty
                        : l.applicationProxyNoConnections,
                  ),
                )
              : _Table<ApplicationProxyInfo>(
                  tableId: history.showHistory
                      ? 'applications.history'
                      : 'applications.current',
                  items: applications,
                  subtleRows: true,
                  rowHeight: widget.rowHeight,
                  maxRows: null,
                  scrollController: widget.scrollController,
                  columnsOf: (width) => [
                    RecordColumn(
                      TableColumn('application', l.app, flex: 2),
                      cell: (_, item) => Tooltip(
                        message: item.identity?.content ?? l.unknown,
                        child: _Source(item.identity?.name ?? l.unknown),
                      ),
                      sortKey: (item) =>
                          item.identity?.name.toLowerCase() ?? '',
                    ),
                    if (width >= 620)
                      RecordColumn(
                        TableColumn('status', l.status, width: 76),
                        cell: (_, item) => _ApplicationRouteText(item),
                        sortKey: (item) => item.route.index,
                      ),
                    RecordColumn(
                      TableColumn(
                        'mode',
                        l.applicationProxyMode,
                        width: width < 460
                            ? (history.showHistory ? 80 : 96)
                            : width < 700
                            ? 116
                            : 164,
                      ),
                      cell: (_, item) => widget.modeBuilder(item),
                      sortKey: (item) => item.mode?.index ?? -1,
                    ),
                    RecordColumn(
                      width < 460
                          ? TableColumn(
                              'policy',
                              l.strategy,
                              width: history.showHistory ? 80 : 96,
                            )
                          : width < 700
                          ? TableColumn('policy', l.strategy, width: 112)
                          : TableColumn('policy', l.strategy, flex: 1),
                      cell: (_, item) => widget.policyBuilder(item),
                      sortKey: (item) => item.target ?? '',
                    ),
                    if (history.showHistory && width >= 1000)
                      RecordColumn(
                        TableColumn(
                          'lastSeen',
                          l.applicationLastSeen,
                          width: 140,
                        ),
                        cell: (_, item) => Text(
                          history.entries[item.identity?.key]?.lastSeen
                                  .toLocal()
                                  .toString()
                                  .substring(0, 16) ??
                              '—',
                        ),
                        sortKey: (item) =>
                            history
                                .entries[item.identity?.key]
                                ?.lastSeen
                                .millisecondsSinceEpoch ??
                            0,
                      ),
                    if (width >= 850) ...[
                      RecordColumn(
                        TableColumn(
                          'connections',
                          l.liveConnections,
                          width: 70,
                          end: true,
                        ),
                        cell: (_, item) =>
                            _Number(dashboardCount(item.connections)),
                        sortKey: (item) => item.connections,
                        descendingFirst: true,
                      ),
                      for (final download in [true, false])
                        RecordColumn(
                          TableColumn(
                            download ? 'download' : 'upload',
                            download ? l.download : l.upload,
                            width: 80,
                            end: true,
                          ),
                          cell: (_, item) => Tooltip(
                            message: dashboardTraffic(
                              download ? item.download : item.upload,
                            ),
                            child: _Number(_speed(item, download)),
                          ),
                          sortKey: (item) =>
                              download ? item.downloadSpeed : item.uploadSpeed,
                          descendingFirst: true,
                        ),
                    ] else if (width >= 460)
                      RecordColumn(
                        TableColumn(
                          'speed',
                          l.networkSpeed,
                          width: 88,
                          end: true,
                        ),
                        cell: (_, item) => Tooltip(
                          message:
                              '${l.download}: ${_speed(item, true)} · ${l.upload}: ${_speed(item, false)}',
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (final download in [true, false])
                                Text(
                                  '${download ? '↓' : '↑'} ${_speed(item, download)}',
                                  style: AppTextStyle.caption2
                                      .of(context)
                                      .toTabular,
                                ),
                            ],
                          ),
                        ),
                        sortKey: (item) =>
                            item.downloadSpeed + item.uploadSpeed,
                        descendingFirst: true,
                      ),
                    RecordColumn(
                      TableColumn(
                        'actions',
                        '',
                        width: history.showHistory ? 112 : 64,
                      ),
                      cell: (_, item) => Row(
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            tooltip: l.applicationResetHint,
                            onPressed:
                                widget.stale ||
                                    item.connections == 0 ||
                                    _resetting.contains(
                                      item.identity?.key ?? '',
                                    )
                                ? null
                                : () => _reset(item),
                            icon: _resetting.contains(item.identity?.key ?? '')
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const GlyphIcon(AppGlyphs.refresh, size: 18),
                          ),
                          if (history.showHistory && item.identity != null)
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              tooltip: l.applicationRemoveHistory,
                              onPressed: () => _historyAction(
                                () => history.remove(item.identity!.key),
                              ),
                              icon: const GlyphIcon(AppGlyphs.delete, size: 18),
                            ),
                        ],
                      ),
                      sortKey: (item) => item.connections,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ApplicationRouteText extends StatelessWidget {
  const _ApplicationRouteText(this.application);

  final ApplicationProxyInfo application;

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final label = application.route.label;
    return Tooltip(
      message: [
        label,
        '${l.proxies}: ${application.proxy}',
        '${l.direct}: ${application.direct}',
        '${l.applicationProxyBlocked}: ${application.blocked}',
        '${l.unknown}: ${application.unknown}',
      ].join(' · '),
      child: Text(
        label,
        style: TextStyle(
          color: switch (application.route) {
            ApplicationRoute.direct => context.colorScheme.success,
            ApplicationRoute.mixed => context.colorScheme.warning,
            ApplicationRoute.blocked => context.colorScheme.error,
            _ => context.colorScheme.onSurfaceVariant,
          },
        ),
      ),
    );
  }
}
