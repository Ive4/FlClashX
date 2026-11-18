import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'connections.dart';

class RequestsView extends ConsumerStatefulWidget {
  final RequestFeed? initialFeed;
  final Future<List<TrackerInfo>> Function()? connectionsReader;

  const RequestsView({
    super.key,
    this.initialFeed,
    @visibleForTesting this.connectionsReader,
  });

  @override
  ConsumerState<RequestsView> createState() => _RequestsViewState();
}

class _RequestsViewState extends ConsumerState<RequestsView> {
  final _recent = TrackerInfoListController();
  final _live = TrackerInfoListController();
  final _liveKey = GlobalKey<_LiveConnectionsState>();
  late var _feed =
      widget.initialFeed ??
      (ref.read(currentPageLabelProvider) == PageLabel.connections
          ? RequestFeed.live
          : ref.read(appSettingProvider).requestFeed);

  void _selectFeed(RequestFeed feed) {
    if (feed == _feed) {
      return;
    }
    setState(() => _feed = feed);
    if (widget.initialFeed == null) {
      ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(requestFeed: feed));
    }
  }

  @override
  void dispose() {
    _recent.dispose();
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = context.appLocalizations;
    String labelOf(RequestFeed feed) => switch (feed) {
      RequestFeed.recent => localizations.recentRequests,
      RequestFeed.live => localizations.liveConnections,
    };

    return CommonScaffold(
      title: labelOf(_feed),
      titleMenuItems: [
        for (final feed in RequestFeed.values)
          CommonPopupMenuItem(
            label: labelOf(feed),
            checked: feed == _feed,
            onPressed: () => _selectFeed(feed),
          ),
      ],
      searchState: AppBarSearchState(
        onSearch: (query) {
          _recent.search(query);
          _live.search(query);
        },
      ),
      onKeywordsUpdate: (keywords) {
        _recent.updateKeywords(keywords);
        _live.updateKeywords(keywords);
      },
      iconActions: [
        if (_feed == RequestFeed.live)
          IconButtonData(
            glyph: AppGlyphs.clearAll,
            tooltip: localizations.closeConnections,
            onPressed: () => _liveKey.currentState?.closeAll(),
          ),
      ],
      body: switch (_feed) {
        RequestFeed.recent => _RecentRequests(listController: _recent),
        RequestFeed.live => _LiveConnections(
          key: _liveKey,
          listController: _live,
          connectionsReader: widget.connectionsReader,
        ),
      },
    );
  }
}

class _RecentRequests extends ConsumerStatefulWidget {
  const _RecentRequests({required this.listController});

  final TrackerInfoListController listController;

  @override
  ConsumerState<_RecentRequests> createState() => _RecentRequestsState();
}

class _RecentRequestsState extends ConsumerState<_RecentRequests>
    with RouteMotionHoldMixin<_RecentRequests> {
  final _throttler = Throttler();
  TrackerInfoListController get _listController => widget.listController;
  late final ScrollController _scrollController;
  late final _physics = FollowEndScrollPhysics(
    isFollowing: () => _listController.value.autoScrollToEnd,
  );

  @override
  void initState() {
    super.initState();
    _scrollController = sheetScrollController(
      context,
      initialScrollOffset: double.maxFinite,
    );
    _listController.resumeAutoScrollToEnd(ref.read(requestsProvider).list);
    ref.listenManual(requestsProvider.select((state) => state.revision), (
      _,
      _,
    ) {
      _throttleRequestsUpdate();
    });
  }

  @override
  void dispose() {
    _throttler.cancel(FunctionTag.requests);
    _scrollController.dispose();
    super.dispose();
  }

  void _throttleRequestsUpdate() {
    _throttler.call(FunctionTag.requests, () {
      if (!mounted) {
        return;
      }
      updateWhenRouteSettled(
        () => _listController.setTrackerInfos(ref.read(requestsProvider).list),
      );
    }, duration: renderThrottleDuration);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return ValueListenableBuilder<TrackerInfosState>(
      valueListenable: _listController,
      builder: (context, state, _) {
        final requests = state.list;
        return NullStatusSwitcher(
          isEmpty: requests.isEmpty,
          isSearching: state.isSearching,
          nullStatus: NullStatus(
            label: appLocalizations.nullTip(appLocalizations.requests),
            illustration: NullStatusIllustration.requests,
          ),
          child: RecordTableFrame<TrackerInfo>(
            tableId: 'requests',
            items: requests,
            keepSort: true,
            reverse: true,
            columnsOf: (width) =>
                trackerInfoColumns(context, width: width, isLive: false),
            builder: (context, table, requests) => Align(
              alignment: Alignment.topCenter,
              child: FloatingScrollbar(
                controller: _scrollController,
                hintBuilder: (fraction) {
                  final index = (fraction * (requests.length - 1)).round();
                  return requests[index].start.showFull;
                },
                child: ScrollToEndBox(
                  controller: _scrollController,
                  enable: state.autoScrollToEnd,
                  onCancelToEnd: () {
                    _listController.setAutoScrollToEnd(false);
                  },
                  onResumeToEnd: () {
                    _listController.resumeAutoScrollToEnd(
                      ref.read(requestsProvider).list,
                    );
                  },
                  child: TrackerInfoList(
                    reverse: true,
                    shrinkWrap: true,
                    physics: _physics,
                    controller: _scrollController,
                    padding: EdgeInsets.only(
                      top: context.contentTopPadding,
                      bottom: 16 + context.bottomInset,
                    ),
                    trackerInfos: requests,
                    table: table,
                    detailTitle: appLocalizations.details(
                      appLocalizations.request,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
