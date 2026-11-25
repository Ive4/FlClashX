import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/enum/enum.dart';

class SystemDnsRecord {
  final String service;
  final List<String> servers;

  const SystemDnsRecord({required this.service, required this.servers});

  static SystemDnsRecord? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final service = json['service'];
    final servers = json['servers'];
    if (service is! String || service.isEmpty || servers is! List) {
      return null;
    }
    return SystemDnsRecord(
      service: service,
      servers: servers.whereType<String>().toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SystemDnsRecord &&
          other.service == service &&
          stringListEquality.equals(other.servers, servers);

  @override
  int get hashCode => Object.hash(service, stringListEquality.hash(servers));

  @override
  String toString() => 'SystemDnsRecord($service, $servers)';
}

abstract interface class SystemDnsPort {
  Future<List<String>?> readDnsServers(String service);

  Future<bool> writeDnsServers(String service, List<String> servers);
}

abstract interface class SystemDnsStore {
  Future<SystemDnsRecord?> read();

  Future<void> clear();
}

final class PreferencesSystemDnsStore implements SystemDnsStore {
  const PreferencesSystemDnsStore();

  @override
  Future<SystemDnsRecord?> read() => preferences.getSystemDnsRecord();

  @override
  Future<void> clear() => preferences.clearSystemDnsRecord();
}

Future<void> restoreLegacySystemDns({
  SystemDnsPort? port,
  SystemDnsStore store = const PreferencesSystemDnsStore(),
}) async {
  final dnsPort = port ?? (safeModeBuild ? null : macOS);
  if (dnsPort == null) {
    return;
  }
  try {
    final record = await store.read();
    if (record == null) {
      return;
    }
    final current = await dnsPort.readDnsServers(record.service);
    if (current == null) {
      return;
    }
    final applied = [...record.servers, defaultSystemDnsFallback];
    if (!record.servers.contains(defaultSystemDnsFallback) &&
        stringListEquality.equals(current, applied) &&
        !await dnsPort.writeDnsServers(record.service, record.servers)) {
      return;
    }
    await store.clear();
  } catch (error) {
    commonPrint.log(
      'Restoring the system DNS failed: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
  }
}
