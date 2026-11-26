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

  String get _normalizedContent => windows
      ? p.windows.normalize(content).toLowerCase()
      : action == RuleAction.PROCESS_NAME
      ? content.toLowerCase()
      : content;
  String get _separator => windows ? r'\' : '/';
  String get key => '${action.value}:$_normalizedContent';
  String get selectionKey => '${windows ? 'windows' : 'macos'}:$key';
  String get name => action == RuleAction.PROCESS_NAME
      ? content
      : (windows ? p.windows : p.posix).basename(content);

  ApplicationIdentity get byName => ApplicationIdentity(
    action: RuleAction.PROCESS_NAME,
    content: name,
    windows: windows,
  );

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

extension DesktopApplicationAccess on AccessControlProps {
  bool get defaultProxy => mode == AccessControlMode.rejectSelected;

  AccessControlProps get withDesktopRules => desktopRules == null
      ? copyWith(desktopRules: importDesktopRules(currentList))
      : this;

  Map<String, bool> importDesktopRules(Iterable<String> rules) {
    final imported = <String, bool>{};
    for (final key in rules) {
      final identity = ApplicationIdentity.fromSelection(
        key,
        windows: key.startsWith('windows:'),
      );
      if (identity != null) {
        imported[identity.forRouting.selectionKey] = !defaultProxy;
      }
    }
    return imported;
  }

  bool allowsProxy(ApplicationIdentity identity) {
    final rules = desktopRules ?? const <String, bool>{};
    return rules[identity.selectionKey] ??
        rules[identity.forRouting.selectionKey] ??
        rules[identity.byName.selectionKey] ??
        defaultProxy;
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
  if (access.desktopRules != null) {
    return _desktopApplicationAccessRules(access, windows: windows);
  }
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
  var condition = _anyApplicationCondition(conditions.toList());
  if (whitelist) condition = '(NOT,($condition))';
  return ['AND,((IN-TYPE,TUN),$condition),DIRECT'];
}

List<String> _desktopApplicationAccessRules(
  AccessControlProps access, {
  required bool windows,
}) {
  final proxy = <RuleAction, List<String>>{};
  final direct = <RuleAction, List<String>>{};
  for (final MapEntry(:key, :value) in access.desktopRules!.entries) {
    final identity = ApplicationIdentity.fromSelection(key, windows: windows);
    if (identity == null) continue;
    final conditions = value ? proxy : direct;
    (conditions[identity.action] ??= []).add(_applicationCondition(identity));
  }

  var allDirect = !access.defaultProxy;
  String? condition;
  for (final action in [
    RuleAction.PROCESS_NAME,
    RuleAction.PROCESS_PATH_REGEX,
    RuleAction.PROCESS_PATH,
  ]) {
    if (proxy[action] case final allows?) {
      final exclusion = '(NOT,(${_anyApplicationCondition(allows)}))';
      if (allDirect) {
        allDirect = false;
        condition = exclusion;
      } else if (condition != null) {
        condition = '(AND,($exclusion,$condition))';
      }
    }
    final exclusions = direct[action];
    if (!allDirect && exclusions != null) {
      condition = _anyApplicationCondition([...exclusions, ?condition]);
    }
  }
  if (allDirect) return const ['IN-TYPE,TUN,DIRECT'];
  return condition == null
      ? const []
      : ['AND,((IN-TYPE,TUN),$condition),DIRECT'];
}

String _anyApplicationCondition(List<String> conditions) =>
    conditions.length == 1
    ? conditions.single
    : '(OR,(${conditions.join(',')}))';

String _applicationCondition(ApplicationIdentity identity) {
  if (identity.action == RuleAction.PROCESS_NAME) {
    if (!identity.windows && identity.content.toLowerCase().endsWith('.app')) {
      final bundle = _escapeRuleRegex(identity.content);
      return '(PROCESS-PATH-REGEX,'
          r'^(?:(?!\.app/Contents/).)*'
          '/$bundle/Contents/)';
    }
    return '(PROCESS-NAME-REGEX,${identity._rulePattern})';
  }
  return '(PROCESS-PATH-REGEX,${identity._rulePattern})';
}
