import 'package:fl_clash/common/system_dns.dart';
import 'package:flutter_test/flutter_test.dart';

const _record = SystemDnsRecord(service: 'Wi-Fi', servers: ['1.1.1.1']);

class _FakePort implements SystemDnsPort {
  List<String>? current = ['1.1.1.1', '223.5.5.5'];
  var writable = true;
  final writes = <(String, List<String>)>[];

  @override
  Future<List<String>?> readDnsServers(String service) async => current;

  @override
  Future<bool> writeDnsServers(String service, List<String> servers) async {
    writes.add((service, servers));
    return writable;
  }
}

class _FakeStore implements SystemDnsStore {
  SystemDnsRecord? record = _record;

  @override
  Future<SystemDnsRecord?> read() async => record;

  @override
  Future<void> clear() async => record = null;
}

void main() {
  test('restores a legacy DNS list and consumes its saved record', () async {
    final port = _FakePort();
    final store = _FakeStore();

    await restoreLegacySystemDns(port: port, store: store);
    await restoreLegacySystemDns(port: port, store: store);

    expect(port.writes.single.$1, 'Wi-Fi');
    expect(port.writes.single.$2, ['1.1.1.1']);
    expect(store.record, isNull);
  });

  test('keeps the legacy record when restoration fails', () async {
    final port = _FakePort()..writable = false;
    final store = _FakeStore();

    await restoreLegacySystemDns(port: port, store: store);

    expect(store.record, _record);
  });

  test('preserves a DNS list changed since the legacy app ran', () async {
    final port = _FakePort()..current = ['8.8.8.8'];
    final store = _FakeStore();

    await restoreLegacySystemDns(port: port, store: store);

    expect(port.writes, isEmpty);
    expect(store.record, isNull);
  });

  test('can read the legacy record', () {
    expect(
      SystemDnsRecord.fromJson({
        'service': 'Wi-Fi',
        'servers': ['1.1.1.1', 1],
      }),
      _record,
    );
    expect(SystemDnsRecord.fromJson({'service': '', 'servers': []}), isNull);
    expect(SystemDnsRecord.fromJson({'service': 'Wi-Fi'}), isNull);
  });
}
