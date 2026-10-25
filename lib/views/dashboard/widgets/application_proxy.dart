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
  bool get pollsConnections => true;

  @override
  bool get sortsConnections => false;

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      title: context.appLocalizations.applicationProxy,
      body: Builder(
        builder: (context) => AppBarClearance(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, context.bottomInset + 16),
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
  ) async {
    if (_saving != null || ref.read(currentProfileIdProvider) != profileId) {
      return;
    }
    final l = context.appLocalizations;
    setState(() {
      _saving = application.key;
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
          );
      // ignore: avoid_print
      print('>>> _change returned applied=$applied');
      if (!applied && mounted && ref.read(currentProfileIdProvider) == profileId) {
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

  Widget _policy(
    ApplicationProxyInfo application,
    int? profileId,
    bool editable,
    List<String> groups,
  ) {
    final l = context.appLocalizations;
    final source = application.policyIdentity ?? application.identity;
    final identity = source != null && !source.canRoute
        ? ApplicationIdentity(action: RuleAction.PROCESS_NAME,
            content: source.name, windows: source.windows)
        : source;
    String label(String? target) => switch (target) {
      null => l.applicationProxyFollowRules,
      'DIRECT' => l.direct,
      String value => value,
    };
    final enabled = editable && identity?.canRoute == true && _saving == null;
    // ignore: avoid_print
    print(
      '>>> _policy saving=$_saving identityKey=${identity?.key} '
      'identityNull=${identity == null} enabled=$enabled',
    );
    return CommonPopupBox(
      targetBuilder: (open) => TextButton(
        onPressed: enabled ? open : null,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
        ),
        child: _saving != null && _saving == identity?.key
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
                      identity == null ? l.unknown : label(application.target),
                    ),
                  ),
                  if (enabled)
                    const GlyphIcon(AppGlyphs.chevronDown, size: 12),
                ],
              ),
      ),
      popupBuilder: (_) => CommonPopupMenu(
        maxVisibleItems: 7,
        items: [
          for (final target in <String?>[null, 'DIRECT', ...groups])
            CommonPopupMenuItem(
              label: label(target),
              checked: target == application.target,
              onPressed: enabled
                  ? () => _change(profileId!, identity!, target)
                  : null,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    // ignore: avoid_print
    print('>>> panel build saving=$_saving');
    final profile = ref.watch(currentProfileProvider);
    final profileId = profile?.id;
    final editable = profile != null &&
        (profile.type == ProfileType.custom ||
            profile.extendType == ExtendType.standard);
    final rulesState = profileId == null || !editable
        ? const AsyncData<List<Rule>>([])
        : ref.watch(applicationRulesProvider(profileId));
    final patch = ref.watch(patchClashConfigProvider);
    final invalidTarget = RegExp(r'[,\r\n]');
    final groups = ref.watch(groupsProvider)
        .map((group) => group.name)
        .where((name) => name != 'DIRECT' && !invalidTarget.hasMatch(name))
        .toSet()
        .toList();
    String? action;
    VoidCallback? onAction;
    String notice;
    if (widget.stale) {
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
    } else if (patch.findProcessMode != FindProcessMode.always) {
      notice = l.applicationProxyEnableProcess;
      action = l.findProcessMode;
      onAction = () => ref.read(patchClashConfigProvider.notifier).update(
        (state) => state.copyWith(findProcessMode: FindProcessMode.always),
      );
    } else {
      notice = l.applicationProxyScope;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _cellInset),
          child: Row(
            spacing: 8,
            children: [
              Expanded(
                child: Tooltip(
                  message: _error ?? notice,
                  child: Text(
                    _error ?? notice,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption1.of(context).copyWith(
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
              Tooltip(
                message: l.applicationProxyCoverage,
                child: const GlyphIcon(AppGlyphs.info, size: 16),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
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
                  policyBuilder: (application) => _policy(
                    application,
                    profileId,
                    editable,
                    groups,
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
  final ScrollController? scrollController;
  final ValueChanged<int>? onCountChanged;

  @override
  ConsumerState<_ApplicationRows> createState() => _ApplicationRowsState();
}

class _ApplicationRowsState extends ConsumerState<_ApplicationRows>
    with RouteMotionHoldMixin<_ApplicationRows> {
  final _search = TextEditingController();
  final _resetting = <String>{};

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _historyAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) dialogs.showNotifier(error.toString(), level: MessageLevel.error);
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
    dialogs.showNotifier(failed ? l.applicationResetFailed : l.applicationResetDone);
  }

  Future<void> _clearHistory() async {
    final l = context.appLocalizations;
    final confirmed = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(content: Text(l.applicationClearConfirm), actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.applicationClearHistory)),
      ]));
    if (confirmed == true) await _historyAction(() => applicationHistory.remove(null));
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
        widget.onCountChanged?.call(snapshot.applications.where((item) => item.connections > 0).length);
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

  String _speed(ApplicationProxyInfo application, bool download) => widget.stale || application.connections == 0
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
    final live = snapshot.applications.where((item) => item.connections > 0).toList();
    final history = applicationHistory;
    final all = <String, ApplicationProxyInfo>{
      for (final item in live) item.identity?.key ?? '': item,
    };
    for (final entry in history.entries.values) {
      final identity = entry.identity;
      final nameIdentity = ApplicationIdentity(action: RuleAction.PROCESS_NAME,
        content: identity.name, windows: identity.windows);
      final rule = widget.rules.where((rule) =>
        identity.matchesRule(rule) || nameIdentity.matchesRule(rule)).firstOrNull;
      all.putIfAbsent(identity.key, () => ApplicationProxyInfo(identity, target: rule?.ruleTarget,
        policyIdentity: rule == null ? null : ApplicationIdentity(
          action: rule.ruleAction, content: rule.content ?? '', windows: identity.windows)));
    }
    final query = _search.text.trim().toLowerCase();
    final applications = (history.showHistory ? all.values : live).where((item) =>
      query.isEmpty || (item.identity?.content.toLowerCase().contains(query) ?? false)).toList();
    if (history.showHistory) {
      applications.sort((a, b) {
        final active = (b.connections > 0 ? 1 : 0).compareTo(a.connections > 0 ? 1 : 0);
        if (active != 0) return active;
        final epoch = DateTime.fromMillisecondsSinceEpoch(0);
        return (history.entries[b.identity?.key]?.lastSeen ?? epoch)
          .compareTo(history.entries[a.identity?.key]?.lastSeen ?? epoch);
      });
    }
    return Column(children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ChoiceChip(label: Text('${l.applicationCurrent} (${live.length})'),
          selected: !history.showHistory,
          onSelected: (_) => _historyAction(() => history.select(false))),
        ChoiceChip(label: Text('${l.applicationHistory} (${all.length})'),
          selected: history.showHistory,
          onSelected: (_) => _historyAction(() => history.select(true))),
        SizedBox(width: 220, child: TextField(controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(isDense: true, hintText: l.applicationSearch))),
        if (history.showHistory)
          TextButton(onPressed: history.entries.isEmpty ? null : _clearHistory,
            child: Text(l.applicationClearHistory)),
      ]),
      const SizedBox(height: 8),
      Expanded(child: applications.isEmpty
        ? Center(child: Text(query.isNotEmpty ? l.applicationNoMatches
            : history.showHistory ? l.applicationHistoryEmpty : l.applicationProxyNoConnections))
        : _Table<ApplicationProxyInfo>(
      tableId: history.showHistory ? 'applications.history' : 'applications.current',
      items: applications,
      rowHeight: widget.rowHeight,
      maxRows: null,
      scrollController: widget.scrollController,
      columnsOf: (width) => [
        RecordColumn(
          TableColumn('application', l.app, flex: 1),
          cell: (_, item) => Tooltip(
            message: item.identity?.content ?? l.unknown,
            child: _Source(item.identity?.name ?? l.unknown),
          ),
          sortKey: (item) => item.identity?.name.toLowerCase() ?? '',
        ),
        RecordColumn(
          TableColumn('status', l.status, width: 76),
          cell: (_, item) => _ApplicationRouteText(item),
          sortKey: (item) => item.route.index,
        ),
        RecordColumn(
          TableColumn('policy', l.strategy, width: width < _midTableWidth ? 112 : 144),
          cell: (_, item) => widget.policyBuilder(item),
          sortKey: (item) => item.target ?? '',
        ),
        if (history.showHistory && width >= 1000)
          RecordColumn(TableColumn('lastSeen', l.applicationLastSeen, width: 140),
            cell: (_, item) => Text(history.entries[item.identity?.key]?.lastSeen
                .toLocal().toString().substring(0, 16) ?? '—'),
            sortKey: (item) => history.entries[item.identity?.key]?.lastSeen.millisecondsSinceEpoch ?? 0),
        if (width >= 850) ...[
          RecordColumn(
            TableColumn('connections', l.liveConnections, width: 70, end: true),
            cell: (_, item) => _Number(dashboardCount(item.connections)),
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
                message: dashboardTraffic(download ? item.download : item.upload),
                child: _Number(_speed(item, download)),
              ),
              sortKey: (item) => download ? item.downloadSpeed : item.uploadSpeed,
              descendingFirst: true,
            ),
        ] else
          RecordColumn(
            TableColumn('speed', l.networkSpeed, width: 88, end: true),
            cell: (_, item) => Tooltip(
              message: '${l.download}: ${_speed(item, true)} · ${l.upload}: ${_speed(item, false)}',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final download in [true, false])
                    Text(
                      '${download ? '↓' : '↑'} ${_speed(item, download)}',
                      style: AppTextStyle.caption2.of(context).toTabular,
                    ),
                ],
              ),
            ),
            sortKey: (item) => item.downloadSpeed + item.uploadSpeed,
            descendingFirst: true,
          ),
        RecordColumn(
          TableColumn('actions', '', width: history.showHistory ? 94 : 48),
          cell: (_, item) => Row(children: [
            IconButton(padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32), tooltip: l.applicationResetHint,
              onPressed: widget.stale || item.connections == 0 || _resetting.contains(item.identity?.key ?? '')
                ? null : () => _reset(item),
              icon: _resetting.contains(item.identity?.key ?? '')
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const GlyphIcon(AppGlyphs.refresh, size: 18)),
            if (history.showHistory && item.identity != null)
              IconButton(padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32), tooltip: l.applicationRemoveHistory,
                onPressed: () => _historyAction(() => history.remove(item.identity!.key)),
                icon: const GlyphIcon(AppGlyphs.delete, size: 18)),
          ]),
          sortKey: (item) => item.connections,
        ),
      ],
    )),
    ]);
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
