import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:path/path.dart' as p;

const _versionNumber =
    r'[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[-+][a-zA-Z0-9._-]+)*';
const _versionPrefix = r'(v|[a-zA-Z][a-zA-Z0-9._-]*-)?';
final _versionDirectory = RegExp('^$_versionPrefix$_versionNumber\$');
final _versionSlot = RegExp(
  '^$_versionPrefix'
  r'\*$',
);

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

  static ApplicationIdentity? fromManualInput(
    String value, {
    required bool windows,
  }) {
    final path = windows ? p.windows : p.posix;
    var content = value.trim();
    final isPath = path.isAbsolute(content);
    if (isPath) {
      if (path.basename(content).isEmpty ||
          (windows && path.rootPrefix(content).length < 2)) {
        return null;
      }
      content = path.normalize(content);
      if (!windows) {
        final bundle = content.indexOf('.app/Contents/');
        if (bundle >= 0) content = content.substring(0, bundle + 4);
      }
    } else if (content == '.' ||
        content == '..' ||
        path.basename(content) != content ||
        (windows && content.contains(':'))) {
      return null;
    }
    final identity = ApplicationIdentity(
      action: isPath ? RuleAction.PROCESS_PATH : RuleAction.PROCESS_NAME,
      content: content,
      windows: windows,
    );
    return identity.canRoute ? identity : null;
  }

  String get _normalizedContent =>
      windows ? p.windows.normalize(content).toLowerCase() : content;
  String get _separator => windows ? r'\' : '/';
  String get key => '${action.value}:$_normalizedContent';
  String get selectionKey => '${windows ? 'windows' : 'macos'}:$key';
  String get name => action == RuleAction.PROCESS_NAME
      ? content
      : (windows ? p.windows : p.posix).basename(content);

  ApplicationIdentity get forRouting {
    if (action != RuleAction.PROCESS_PATH) return this;
    final parts = _normalizedContent.split(_separator);
    if (parts.length < 4 || parts.any(_versionSlot.hasMatch)) return this;
    final index = parts.lastIndexWhere(
      _versionDirectory.hasMatch,
      parts.length - 2,
    );
    if (index < 2) return this;
    final prefix = _versionDirectory.firstMatch(parts[index])!.group(1) ?? '';
    parts[index] = '$prefix*';
    return ApplicationIdentity(
      action: RuleAction.PROCESS_PATH_REGEX,
      content: parts.join(_separator),
      windows: windows,
    );
  }

  bool get canRoute =>
      content.trim().isNotEmpty &&
      !RegExp(r'[\x00\r\n]').hasMatch(content) &&
      (action == RuleAction.PROCESS_NAME ||
          action == RuleAction.PROCESS_PATH ||
          (action == RuleAction.PROCESS_PATH_REGEX && _versionSlotIndex >= 2));

  int get _versionSlotIndex {
    final parts = _normalizedContent.split(_separator);
    if (parts.length < 4) return -1;
    return parts.lastIndexWhere(_versionSlot.hasMatch, parts.length - 2);
  }

  String get _rulePattern {
    final bundle =
        !windows &&
        action != RuleAction.PROCESS_NAME &&
        content.endsWith('.app');
    var pattern = _escapeRuleRegex(content);
    if (action == RuleAction.PROCESS_PATH_REGEX) {
      final parts = _normalizedContent.split(_separator);
      final index = _versionSlotIndex;
      final prefix = _versionSlot.firstMatch(parts[index])!.group(1) ?? '';
      final escaped = parts.map(_escapeRuleRegex).toList();
      escaped[index] = '$prefix$_versionNumber';
      pattern = escaped.join(_escapeRuleRegex(_separator));
    }
    return '${windows ? '(?i)' : ''}^$pattern${bundle ? '/Contents/' : r'$'}';
  }

  static ApplicationIdentity? fromSelection(
    String value, {
    required bool windows,
  }) {
    final prefix = windows ? 'windows:' : 'macos:';
    if (!value.startsWith(prefix)) return null;
    final key = value.substring(prefix.length);
    for (final action in [
      RuleAction.PROCESS_PATH,
      RuleAction.PROCESS_NAME,
      RuleAction.PROCESS_PATH_REGEX,
    ]) {
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

String _escapeRuleRegex(String value) => RegExp.escape(value)
    .replaceAll(r'\(', r'\x28')
    .replaceAll(r'\)', r'\x29')
    .replaceAll(',', r'\x2c');

AccessControlProps groupVersionedApplications(
  AccessControlProps access, {
  required bool windows,
}) {
  List<String> group(List<String> values) => {
    for (final value in values)
      ApplicationIdentity.fromSelection(
            value,
            windows: windows,
          )?.forRouting.selectionKey ??
          value,
  }.toList();
  return access.copyWith(
    acceptList: group(access.acceptList),
    rejectList: group(access.rejectList),
  );
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
    final identity = ApplicationIdentity.fromSelection(
      value,
      windows: windows,
    )?.forRouting;
    if (identity == null) continue;
    final action = identity.action == RuleAction.PROCESS_NAME
        ? RuleAction.PROCESS_NAME_REGEX
        : RuleAction.PROCESS_PATH_REGEX;
    conditions.add('(${action.value},${identity._rulePattern})');
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
