import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime.utc(2026);
final _later = _start.add(const Duration(seconds: 3));

TrackerInfo _request(
  String id, {
  DateTime? start,
  DateTime? closedAt,
  RequestFailure? failure,
  List<int> dnsQueries = const [],
}) => TrackerInfo(
  id: id,
  start: start ?? _start,
  metadata: const Metadata(),
  chains: const [],
  rule: '',
  rulePayload: '',
  closedAt: closedAt,
  failure: failure,
  dnsQueries: dnsQueries,
);

void main() {
  test('retains all open connections alongside bounded finished history', () {
    final log = ConnectionLog(2)
        .open([
          _request('open'),
          _request('closed'),
          _request(
            'failed',
            closedAt: _start,
            failure: const RequestFailure(kind: 'timeout', message: 'timeout'),
          ),
        ])
        .close(['closed'], _later)
        .open([_request('latest', closedAt: _later)]);

    expect(log.list.map((request) => request.id), ['open', 'closed', 'latest']);
    expect(log.count(ConnectionStatus.active), 1);
    expect(log.count(ConnectionStatus.closed), 2);
    expect(log.count(ConnectionStatus.failed), 0);
  });

  test('a poll preserves DNS associations and does not close a new event', () {
    final log = ConnectionLog(10)
        .open([
          _request('gone'),
          _request('open', dnsQueries: [42]),
          _request('new', start: _later),
        ])
        .sync([_request('open')], _later);

    expect(log['gone']?.closedAt, _later);
    expect(log['new']?.closedAt, isNull);
    expect(log['open']?.dnsQueries, [42]);
  });

  test(
    'late snapshots cannot reverse traffic or reopen a closed connection',
    () {
      final log = ConnectionLog(10)
          .open([_request('open')])
          .sync([_request('open').copyWith(upload: 60)], _later)
          .updateTraffic({'open': (upload: 100, download: 250)})
          .sync([_request('open').copyWith(upload: 30)], _later);

      expect(log['open']?.upload, 100);
      expect(log['open']?.download, 250);
      final closed = log.close(['open'], _later).sync([
        _request('open'),
      ], _later.add(const Duration(seconds: 1)));
      expect(closed['open']?.closedAt, _later);
    },
  );
}
