part of 'requests.dart';

class _LiveConnections extends ConsumerStatefulWidget {
  final TrackerInfoListController listController;
  final Future<List<TrackerInfo>> Function()? connectionsReader;

  const _LiveConnections({
    super.key,
    required this.listController,
    required this.connectionsReader,
  });

  @override
  ConsumerState<_LiveConnections> createState() => _LiveConnectionsState();
}

class _LiveConnectionsState extends ConsumerState<_LiveConnections>
    with
        WidgetsBindingObserver,
        ActivePollingMixin<_LiveConnections>,
        RouteMotionHoldMixin<_LiveConnections> {
  CoreController get _core => ref.read(coreHandlerProvider);

  final _speedRanker = TrackerSpeedRanker();
  late final ScrollController _scrollController;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _scrollController = sheetScrollController(context);
  }

  @override
  Duration get pollInterval => const Duration(seconds: 1);

  Future<void> closeAll() => _close(_core.closeConnections);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    final trackerInfos = await _readConnections();
    if (!isCurrent()) {
      return;
    }
    _showConnections(trackerInfos);
  }

  Future<List<TrackerInfo>?> _readConnections() async {
    try {
      final connectionsReader = widget.connectionsReader;
      return connectionsReader != null
          ? await connectionsReader()
          : await _core.getConnections();
    } catch (error) {
      commonPrint.log(
        'updateConnections error: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
  }

  void _showConnections(List<TrackerInfo>? trackerInfos) {
    final readAt = DateTime.now();
    if (!_loaded) {
      setState(() => _loaded = true);
      _applyConnections(trackerInfos ?? const [], readAt);
      return;
    }
    updateWhenRouteSettled(() => _applyConnections(trackerInfos, readAt));
  }

  void _applyConnections(List<TrackerInfo>? trackerInfos, DateTime readAt) {
    if (trackerInfos == null) {
      return;
    }
    widget.listController.setTrackerInfos(
      _speedRanker.rank(trackerInfos, readAt),
    );
  }

  Future<void> _close(Future<void> Function() close) async {
    await globalState.safeRun(close);
    if (mounted) {
      restartPolling();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return ValueListenableBuilder<TrackerInfosState>(
      valueListenable: widget.listController,
      builder: (context, state, _) {
        final connections = state.list;
        Widget buildAction(TrackerInfo trackerInfo) {
          return _BlockConnectionButton(
            onPressed: () =>
                _close(() => _core.closeConnection(trackerInfo.id)),
          );
        }

        return NullStatusSwitcher(
          isLoading: !_loaded,
          isEmpty: connections.isEmpty,
          isSearching: state.isSearching,
          nullStatus: NullStatus(
            label: appLocalizations.nullTip(appLocalizations.connections),
            illustration: NullStatusIllustration.connections,
          ),
          child: RecordTableFrame<TrackerInfo>(
            tableId: 'connections',
            items: connections,
            keepSort: true,
            columnsOf: (width) => trackerInfoColumns(
              context,
              width: width,
              isLive: true,
              actionBuilder: buildAction,
            ),
            builder: (context, table, connections) => TrackerInfoAnimatedList(
              controller: _scrollController,
              padding: EdgeInsets.only(
                top: context.contentTopPadding,
                bottom: 16 + context.bottomInset,
              ),
              trackerInfos: connections,
              table: table,
              detailTitle: appLocalizations.details(
                appLocalizations.connection,
              ),
              actionBuilder: buildAction,
            ),
          ),
        );
      },
    );
  }
}

// One per live row: an IconButton would add a theme animation to each.
class _BlockConnectionButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _BlockConnectionButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: context.appLocalizations.blockConnection,
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onPressed,
          customBorder: AppShape.circle,
          child: SizedBox.square(
            dimension: 28,
            child: Center(
              child: GlyphIcon(
                AppGlyphs.block,
                size: 16,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
