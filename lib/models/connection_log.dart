import 'dart:collection';
import 'dart:math';

import 'package:collection/collection.dart';

import 'common.dart';

enum ConnectionStatus { all, active, closed, failed }

extension ConnectionStatusOfRequest on TrackerInfo {
  ConnectionStatus get connectionStatus => switch ((failure, closedAt)) {
    (final RequestFailure _, _) => ConnectionStatus.failed,
    (_, final DateTime _) => ConnectionStatus.closed,
    _ => ConnectionStatus.active,
  };
}

class _Entries {
  final byId = <String, TrackerInfo>{};
  final activeIds = <String>{};
  final closedOrder = Queue<String>();
  var failed = 0;
  DateTime? lastPoll;
  DateTime? latestStart;
}

/// Keeps every active connection and the most recently closed or failed ones.
class ConnectionLog {
  final int closedCapacity;
  final _Entries _entries;
  final int revision;
  List<TrackerInfo>? _list;

  ConnectionLog(this.closedCapacity)
    : assert(closedCapacity > 0),
      _entries = _Entries(),
      revision = 0;

  ConnectionLog._(this.closedCapacity, this._entries, this.revision);

  Object get lineage => _entries;

  List<TrackerInfo> get list =>
      _list ??= List.unmodifiable(_entries.byId.values);

  int get length => _entries.byId.length;

  TrackerInfo? operator [](String id) => _entries.byId[id];

  int count(ConnectionStatus status) => switch (status) {
    ConnectionStatus.all => length,
    ConnectionStatus.active => _entries.activeIds.length,
    ConnectionStatus.closed => _entries.closedOrder.length - _entries.failed,
    ConnectionStatus.failed => _entries.failed,
  };

  ConnectionLog _next() =>
      ConnectionLog._(closedCapacity, _entries, revision + 1);

  ConnectionLog open(Iterable<TrackerInfo> requests) {
    final byId = _entries.byId;
    var changed = false;
    var outOfOrder = false;
    for (final request in requests) {
      final known = byId[request.id];
      if (known != null) {
        if (request.dnsQueries.isNotEmpty && known.dnsQueries.isEmpty) {
          byId[request.id] = known.copyWith(dnsQueries: request.dnsQueries);
          changed = true;
        }
        continue;
      }
      final latest = _entries.latestStart;
      if (latest != null && request.start.isBefore(latest)) {
        outOfOrder = true;
      } else {
        _entries.latestStart = request.start;
      }
      byId[request.id] = request;
      if (request.connectionStatus == ConnectionStatus.active) {
        _entries.activeIds.add(request.id);
      } else {
        _entries.closedOrder.add(request.id);
        if (request.failure != null) _entries.failed++;
      }
      changed = true;
    }
    if (outOfOrder) _sortByStart();
    _trim();
    return changed ? _next() : this;
  }

  ConnectionLog updateTraffic(Map<String, RequestTraffic> traffic) {
    var changed = false;
    traffic.forEach((id, totals) {
      final request = this[id];
      if (request == null) return;
      final upload = max(request.upload, totals.upload);
      final download = max(request.download, totals.download);
      if (upload == request.upload && download == request.download) return;
      _entries.byId[id] = request.copyWith(upload: upload, download: download);
      changed = true;
    });
    return changed ? _next() : this;
  }

  ConnectionLog close(Iterable<String> ids, DateTime at) {
    var changed = false;
    for (final id in ids) {
      final request = this[id];
      if (request == null || !_entries.activeIds.remove(id)) {
        continue;
      }
      _entries.byId[id] = request.copyWith(
        closedAt: at.isBefore(request.start) ? request.start : at,
        uploadSpeed: null,
        downloadSpeed: null,
      );
      _entries.closedOrder.add(id);
      changed = true;
    }
    _trim();
    return changed ? _next() : this;
  }

  ConnectionLog sync(List<TrackerInfo> active, DateTime requestedAt) {
    final lastPoll = _entries.lastPoll;
    if (lastPoll != null && requestedAt.isBefore(lastPoll)) return this;
    _entries.lastPoll = requestedAt;
    var updated = this;
    final listed = <String>{};
    final discovered = <TrackerInfo>[];
    for (final request in active) {
      listed.add(request.id);
      final known = this[request.id];
      if (known == null) {
        discovered.add(request);
      } else if (known.connectionStatus == ConnectionStatus.active) {
        final next = request.copyWith(
          dnsQueries: request.dnsQueries.isEmpty
              ? known.dnsQueries
              : request.dnsQueries,
          upload: max(known.upload, request.upload),
          download: max(known.download, request.download),
        );
        if (next != known) {
          _entries.byId[request.id] = next;
          if (identical(updated, this)) updated = _next();
        }
      }
    }
    updated = updated.open(discovered);
    // The Core sends the opening event before it puts the connection in its snapshot.
    final settled = requestedAt.subtract(const Duration(seconds: 1));
    final gone = [
      for (final id in _entries.activeIds)
        if (!listed.contains(id) && _entries.byId[id]!.start.isBefore(settled))
          id,
    ];
    return updated.close(gone, requestedAt);
  }

  void _trim() {
    final closedOrder = _entries.closedOrder;
    while (closedOrder.length > closedCapacity) {
      if (_entries.byId.remove(closedOrder.removeFirst())?.failure != null) {
        _entries.failed--;
      }
    }
  }

  void _sortByStart() {
    final byId = _entries.byId;
    final sorted = byId.values.toList();
    mergeSort(sorted, compare: (a, b) => a.start.compareTo(b.start));
    byId
      ..clear()
      ..addEntries(sorted.map((request) => MapEntry(request.id, request)));
  }
}
