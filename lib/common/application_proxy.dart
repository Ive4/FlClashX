import 'dart:math' as math;

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:path/path.dart' as p;

final _invalidProcessRuleContent = RegExp(r'[,\r\n]');
final _applicationInboundRule = RegExp(
  r'^\(\((PROCESS-NAME|PROCESS-PATH),([^(),\r\n]+)\),\(IN-TYPE,TUN\)\)$',
);

typedef ApplicationProxyPolicy = ({
  ApplicationIdentity identity,
  ApplicationProxyMode mode,
  String? target,
  int index,
});

ApplicationIdentity? applicationRuleIdentity(
  Rule rule, {
  required bool windows,
}) {
  if (rule.src) return null;
  final match = rule.ruleAction == RuleAction.AND
      ? _applicationInboundRule.firstMatch(rule.content ?? '')
      : null;
  if (rule.ruleAction == RuleAction.AND &&
      (match == null ||
          !const ['DIRECT', 'PASS', 'PASS-RULE'].contains(rule.ruleTarget))) {
    return null;
  }
  final identity = ApplicationIdentity(
    action: match == null
        ? rule.ruleAction
        : match[1] == 'PROCESS-NAME'
        ? RuleAction.PROCESS_NAME
        : RuleAction.PROCESS_PATH,
    content: match == null ? rule.content ?? '' : match[2]!,
    windows: windows,
  );
  return identity.canRoute ? identity : null;
}

Map<String, ApplicationProxyPolicy> applicationProxyPoliciesOf(
  List<Rule> rules, {
  required bool windows,
}) {
  final policies = <String, ApplicationProxyPolicy>{};
  for (var index = 0; index < rules.length; index++) {
    final rule = rules[index];
    final identity = applicationRuleIdentity(rule, windows: windows);
    if (identity == null) continue;
    final mode =
        rule.ruleAction == RuleAction.AND && rule.ruleTarget == 'DIRECT'
        ? ApplicationProxyMode.httpSocks
        : ApplicationProxyMode.follow;
    policies.putIfAbsent(
      identity.key,
      () => (
        identity: identity,
        mode: mode,
        target: rule.ruleAction == RuleAction.AND ? null : rule.ruleTarget,
        index: index,
      ),
    );
  }
  return policies;
}

String applicationProxyRuntimeRule(Rule rule, {required bool windows}) {
  if (rule.ruleAction == RuleAction.AND &&
      rule.ruleTarget == 'PASS-RULE' &&
      applicationRuleIdentity(rule, windows: windows) != null) {
    return rule.copyWith(ruleTarget: 'PASS').rawValue;
  }
  return rule.rawValue;
}

String applicationProxyDefaultRule(List<Rule> rules, {required bool windows}) {
  final exceptions = applicationProxyPoliciesOf(rules, windows: windows).values
      .where((policy) => policy.mode == ApplicationProxyMode.follow)
      .map(
        (policy) => '(NOT,(${_applicationProcessCondition(policy.identity)}))',
      );
  return exceptions.isEmpty
      ? 'IN-TYPE,TUN,DIRECT'
      : 'AND,((IN-TYPE,TUN),${exceptions.join(',')}),DIRECT';
}

String _applicationProcessCondition(ApplicationIdentity identity) {
  if (!RegExp(r'[()]').hasMatch(identity.content)) {
    return '(${identity.action.value},${identity.content})';
  }
  final action = identity.action == RuleAction.PROCESS_NAME
      ? RuleAction.PROCESS_NAME_REGEX
      : RuleAction.PROCESS_PATH_REGEX;
  final escaped = RegExp.escape(
    identity.content,
  ).replaceAll(r'\(', r'\x28').replaceAll(r'\)', r'\x29');
  return '(${action.value},^$escaped\$)';
}

class ApplicationIdentity {
  const ApplicationIdentity({
    required this.action,
    required this.content,
    required this.windows,
  });

  factory ApplicationIdentity.fromConnection(
    ApplicationConnection connection, {
    required bool windows,
  }) {
    final hasName = connection.process.trim().isNotEmpty;
    return ApplicationIdentity(
      action: hasName ? RuleAction.PROCESS_NAME : RuleAction.PROCESS_PATH,
      content: hasName ? connection.process : connection.path,
      windows: windows,
    ).byName;
  }

  final RuleAction action;
  final String content;
  final bool windows;

  String get key => '${action.value}:${_normalize(content)}';

  String get name => action == RuleAction.PROCESS_PATH
      ? (windows ? p.windows : p.posix).basename(content)
      : content;

  ApplicationIdentity get byName => action == RuleAction.PROCESS_PATH
      ? ApplicationIdentity(
          action: RuleAction.PROCESS_NAME,
          content: content.trim().isEmpty ? '' : name,
          windows: windows,
        )
      : this;

  bool get canRoute =>
      (action == RuleAction.PROCESS_PATH ||
          action == RuleAction.PROCESS_NAME) &&
      content.trim().isNotEmpty &&
      !_invalidProcessRuleContent.hasMatch(content);

  String _normalize(String value) => windows
      ? (action == RuleAction.PROCESS_PATH ? p.windows.normalize(value) : value)
            .toLowerCase()
      : value;

  bool matchesRule(Rule rule) =>
      rule.ruleAction == action &&
      !rule.src &&
      _normalize(rule.content ?? '') == _normalize(content);
}

enum ApplicationRoute { proxy, direct, mixed, blocked, unknown, idle }

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

class ApplicationProxyInfo {
  ApplicationProxyInfo(
    this.identity, {
    this.target,
    this.policyIdentity,
    this.mode,
  });

  final ApplicationIdentity? identity;
  String? target;
  ApplicationIdentity? policyIdentity;
  ApplicationProxyMode? mode;
  final connectionIds = <String>[];
  int connections = 0;
  int proxy = 0;
  int direct = 0;
  int blocked = 0;
  int unknown = 0;
  int upload = 0;
  int download = 0;
  int uploadSpeed = 0;
  int downloadSpeed = 0;

  ApplicationRoute get route {
    if (connections == 0) return ApplicationRoute.idle;
    if (proxy == connections) return ApplicationRoute.proxy;
    if (direct == connections) return ApplicationRoute.direct;
    if (blocked == connections) return ApplicationRoute.blocked;
    if (unknown == connections) return ApplicationRoute.unknown;
    return ApplicationRoute.mixed;
  }
}

typedef ApplicationTrafficSample = ({
  DateTime start,
  int upload,
  int download,
  int uploadSpeed,
  int downloadSpeed,
});

class ApplicationProxySnapshot {
  const ApplicationProxySnapshot({
    required this.applications,
    required this.samples,
    required this.sampledAt,
  });

  final List<ApplicationProxyInfo> applications;
  final Map<String, ApplicationTrafficSample> samples;
  final DateTime? sampledAt;
}

typedef ApplicationProxyInput = ({
  List<ApplicationConnection> connections,
  List<Rule> rules,
  DateTime? sampledAt,
  Map<String, ApplicationTrafficSample> previousSamples,
  DateTime? previousAt,
  bool windows,
});

ApplicationProxySnapshot aggregateApplicationProxies(
  ApplicationProxyInput input,
) {
  final configured = applicationProxyPoliciesOf(
    input.rules,
    windows: input.windows,
  );
  final applications = <String, ApplicationProxyInfo>{};
  for (final policy in configured.values) {
    final identity = policy.identity.byName;
    applications.putIfAbsent(
      identity.key,
      () => ApplicationProxyInfo(
        identity,
        target: policy.target,
        mode: policy.mode,
        policyIdentity: policy.identity,
      ),
    );
  }
  final activePolicies = <String, ApplicationProxyPolicy>{};
  final samples = <String, ApplicationTrafficSample>{};
  final previousTime = input.previousAt;
  final sampledAt = input.sampledAt;
  final elapsed = sampledAt != null && previousTime != null
      ? sampledAt.difference(previousTime).inMicroseconds / 1000000
      : null;
  for (final connection in input.connections) {
    final path = ApplicationIdentity(
      action: RuleAction.PROCESS_PATH,
      content: connection.path,
      windows: input.windows,
    );
    final name = ApplicationIdentity.fromConnection(
      connection,
      windows: input.windows,
    );
    final pathRule = configured[path.key];
    final nameRule = configured[name.key];
    final identity = name.content.trim().isNotEmpty ? name : null;
    final policy =
        pathRule != null &&
            (nameRule == null || pathRule.index < nameRule.index)
        ? pathRule
        : nameRule;
    final key = identity?.key ?? '';
    final application = applications.putIfAbsent(
      key,
      () => ApplicationProxyInfo(identity),
    );
    if (application.connections == 0) {
      application.target = null;
      application.mode = null;
      application.policyIdentity = null;
    }
    final previousPolicy = activePolicies[key];
    if (policy != null &&
        (previousPolicy == null || policy.index < previousPolicy.index)) {
      activePolicies[key] = policy;
      application.target = policy.target;
      application.mode = policy.mode;
      application.policyIdentity = policy.identity;
    }
    application.connections++;
    application.connectionIds.add(connection.id);
    application.upload += connection.upload;
    application.download += connection.download;
    switch (connection.outbound) {
      case 'DIRECT':
      case 'COMPATIBLE':
        application.direct++;
      case 'REJECT':
      case 'REJECT-DROP':
        application.blocked++;
      case null:
      case '':
      case 'PASS':
      case 'PASS-RULE':
        application.unknown++;
      default:
        application.proxy++;
    }
    final old = input.previousSamples[connection.id];
    var uploadSpeed = 0;
    var downloadSpeed = 0;
    if (elapsed == 0 && old?.start == connection.start) {
      uploadSpeed = old!.uploadSpeed;
      downloadSpeed = old.downloadSpeed;
    } else if (elapsed != null && elapsed > 0 && elapsed <= 10) {
      final sameConnection = old?.start == connection.start;
      final newlyObserved =
          old == null && !connection.start.isBefore(previousTime!);
      if (sameConnection || newlyObserved) {
        uploadSpeed =
            (math.max(
                      0,
                      connection.upload - (sameConnection ? old!.upload : 0),
                    ) /
                    elapsed)
                .round();
        downloadSpeed =
            (math.max(
                      0,
                      connection.download -
                          (sameConnection ? old!.download : 0),
                    ) /
                    elapsed)
                .round();
      }
    }
    application.uploadSpeed += uploadSpeed;
    application.downloadSpeed += downloadSpeed;
    samples[connection.id] = (
      start: connection.start,
      upload: connection.upload,
      download: connection.download,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
    );
  }
  final rows = applications.values.toList()
    ..sort((a, b) {
      final active = b.connections.compareTo(a.connections);
      return active != 0
          ? active
          : (a.identity?.key ?? '').compareTo(b.identity?.key ?? '');
    });
  return ApplicationProxySnapshot(
    applications: rows,
    samples: samples,
    sampledAt: sampledAt,
  );
}
