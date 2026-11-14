import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:path/path.dart' as p;

class ApplicationIdentity {
  const ApplicationIdentity({
    required this.action,
    required this.content,
    required this.windows,
  });

  factory ApplicationIdentity.fromConnection(
    ApplicationConnection connection, {
    required bool windows,
    bool preservePath = true,
  }) {
    if (!preservePath) {
      return ApplicationIdentity(
        action: RuleAction.PROCESS_NAME,
        content: connection.process.isNotEmpty
            ? connection.process
            : connection.path.isEmpty
            ? ''
            : p.posix.basename(connection.path),
        windows: windows,
      );
    }
    var path = connection.path.trim();
    if (!windows) {
      final bundle = path.indexOf('.app/Contents/');
      if (bundle >= 0) path = path.substring(0, bundle + 4);
    }
    return ApplicationIdentity(
      action: path.isEmpty ? RuleAction.PROCESS_NAME : RuleAction.PROCESS_PATH,
      content: path.isEmpty ? connection.process : path,
      windows: windows,
    );
  }

  final RuleAction action;
  final String content;
  final bool windows;

  String get key =>
      '${action.value}:${windows ? p.windows.normalize(content).toLowerCase() : content}';
  String get selectionKey => '${windows ? 'windows' : 'macos'}:$key';
  String get name => action == RuleAction.PROCESS_PATH
      ? (windows ? p.windows : p.posix).basename(content)
      : content;
  bool get canRoute =>
      content.trim().isNotEmpty &&
      !RegExp(r'[\x00\r\n]').hasMatch(content) &&
      (action == RuleAction.PROCESS_NAME || action == RuleAction.PROCESS_PATH);

  static ApplicationIdentity? fromSelection(
    String value, {
    required bool windows,
  }) {
    final prefix = windows ? 'windows:' : 'macos:';
    if (!value.startsWith(prefix)) return null;
    final key = value.substring(prefix.length);
    for (final action in [RuleAction.PROCESS_PATH, RuleAction.PROCESS_NAME]) {
      final marker = '${action.value}:';
      if (!key.startsWith(marker)) continue;
      final identity = ApplicationIdentity(
        action: action,
        content: key.substring(marker.length),
        windows: windows,
      );
      return identity.canRoute ? identity : null;
    }
    return null;
  }
}

typedef ApplicationConnection = ({
  String id,
  String process,
  String path,
  String? outbound,
  DateTime start,
  int upload,
  int download,
});

List<ApplicationConnection> applicationConnectionsOf(
  List<TrackerInfo> connections,
) => [
  for (final connection in connections)
    (
      id: connection.id,
      process: connection.metadata.process,
      path: connection.metadata.processPath,
      outbound: connection.chains.firstOrNull,
      start: connection.start,
      upload: connection.upload,
      download: connection.download,
    ),
];

List<String> applicationAccessRules(
  AccessControlProps access, {
  required bool windows,
}) {
  if (!access.enable) return const [];
  final conditions = <String>{};
  for (final value in access.currentList) {
    final identity = ApplicationIdentity.fromSelection(value, windows: windows);
    if (identity == null) continue;
    var pattern = RegExp.escape(identity.content)
        .replaceAll(r'\(', r'\x28')
        .replaceAll(r'\)', r'\x29')
        .replaceAll(',', r'\x2c');
    final bundle =
        !windows &&
        identity.action == RuleAction.PROCESS_PATH &&
        identity.content.endsWith('.app');
    pattern =
        '${windows ? '(?i)' : ''}^$pattern${bundle ? '/Contents/' : r'$'}';
    final action = identity.action == RuleAction.PROCESS_PATH
        ? RuleAction.PROCESS_PATH_REGEX
        : RuleAction.PROCESS_NAME_REGEX;
    conditions.add('(${action.value},$pattern)');
  }
  final whitelist = access.mode == AccessControlMode.acceptSelected;
  if (conditions.isEmpty) {
    return whitelist ? const ['IN-TYPE,TUN,DIRECT'] : const [];
  }
  var condition = conditions.length == 1
      ? conditions.single
      : '(OR,(${conditions.join(',')}))';
  if (whitelist) condition = '(NOT,($condition))';
  return ['AND,((IN-TYPE,TUN),$condition),DIRECT'];
}
