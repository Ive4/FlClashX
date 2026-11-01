import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

final _time = DateTime.utc(2026, 10, 22);

ApplicationConnection _connection(
  String id, {
  String path = '/apps/browser',
  String? process,
  String? outbound = 'Proxy',
  int upload = 0,
  int download = 0,
  DateTime? start,
}) => (
  id: id,
  path: path,
  process: process ?? path.split(RegExp(r'[/\\]')).last,
  outbound: outbound,
  start: start ?? _time.subtract(const Duration(minutes: 1)),
  upload: upload,
  download: download,
);

ApplicationProxySnapshot _snapshot(
  List<ApplicationConnection> connections, {
  List<Rule> rules = const [],
  bool windows = false,
  DateTime? at,
  ApplicationProxySnapshot? previous,
}) => aggregateApplicationProxies((
  connections: connections,
  rules: rules,
  sampledAt: at ?? _time,
  previousSamples: previous?.samples ?? const {},
  previousAt: previous?.sampledAt,
  windows: windows,
));

void main() {
  test(
    'HTTP and SOCKS mode survives rule export without a forced proxy policy',
    () {
      final rule = Rule.parse(
        'AND,((PROCESS-NAME,Browser.exe),(IN-TYPE,TUN)),DIRECT',
      );
      final restored = Rule.fromJson(rule.toJson());
      final snapshot = _snapshot(
        [
          _connection(
            '1',
            path: r'C:\Apps\browser.exe',
            process: 'browser.exe',
          ),
        ],
        windows: true,
        rules: [restored],
      );
      final row = snapshot.applications.singleWhere(
        (row) => row.connections > 0,
      );
      expect(row.mode, ApplicationProxyMode.httpSocks);
      expect(row.target, isNull);
      expect(row.policyIdentity!.content, 'Browser.exe');
      expect(restored.rawValue, rule.rawValue);
      expect(
        _snapshot(
          [],
          windows: true,
          rules: [restored],
        ).applications.single.mode,
        ApplicationProxyMode.httpSocks,
      );
    },
  );

  test(
    'default HTTP and SOCKS exempts explicit follow modes and existing policies',
    () {
      final rules = [
        Rule.parse('PROCESS-NAME,browser,Proxy'),
        Rule.parse('AND,((PROCESS-NAME,editor),(IN-TYPE,TUN)),PASS-RULE'),
        Rule.parse('AND,((PROCESS-NAME,download),(IN-TYPE,TUN)),DIRECT'),
      ];
      final policies = applicationProxyPoliciesOf(rules, windows: false);
      expect(
        policies['PROCESS-NAME:editor']!.mode,
        ApplicationProxyMode.follow,
      );
      expect(policies['PROCESS-NAME:editor']!.target, isNull);
      expect(
        applicationProxyDefaultRule(rules, windows: false),
        'AND,((IN-TYPE,TUN),(NOT,((PROCESS-NAME,browser))),(NOT,((PROCESS-NAME,editor)))),DIRECT',
      );
      expect(
        applicationProxyDefaultRule([], windows: false),
        'IN-TYPE,TUN,DIRECT',
      );
      expect(_snapshot([_connection('1')]).applications.single.mode, isNull);
    },
  );

  test('default mode safely exempts process names containing logic delimiters', () {
    expect(applicationProxyDefaultRule([
      Rule.parse('PROCESS-NAME,odd(app.exe,Proxy'),
    ], windows: true),
      r'AND,((IN-TYPE,TUN),(NOT,((PROCESS-NAME-REGEX,^odd\x28app\.exe$)))),DIRECT');
  });

  test('unrelated logical and source rules are not editable app modes', () {
    for (final rule in [
      Rule.parse('AND,((PROCESS-NAME,browser),(DOMAIN,test.example)),DIRECT'),
      Rule.parse('AND,((PROCESS-NAME,browser),(IN-TYPE,TUN)),Proxy'),
      Rule.parse(
        'AND,((PROCESS-NAME,browser),(IN-TYPE,TUN)),DIRECT',
      ).copyWith(src: true),
    ]) {
      expect(applicationRuleIdentity(rule, windows: false), isNull);
    }
  });

  test('name policies survive versioned install paths and Windows casing', () {
    const identity = ApplicationIdentity(
      action: RuleAction.PROCESS_PATH,
      content: r'C:\Users\L\AppData\Local\App\app-1.0\App.exe',
      windows: true,
    );
    final policy = Rule(
      ruleAction: identity.byName.action,
      content: identity.byName.content,
      ruleTarget: 'DIRECT',
    );
    expect(policy.ruleAction, RuleAction.PROCESS_NAME);
    expect(policy.content, 'App.exe');
    final snapshot = _snapshot(
      [
        _connection('1', path: r'C:\Apps\app-2.0\APP.exe', process: 'APP.exe'),
        _connection('2', path: r'C:\Apps\app-3.0\App.exe', process: ''),
        _connection('3', path: r'C:\Apps\Other.exe', process: 'Other.exe'),
      ],
      windows: true,
      rules: [policy],
    );
    final active = snapshot.applications
        .where((row) => row.connections > 0)
        .toList();
    expect(snapshot.applications, hasLength(2));
    expect(active.singleWhere((row) => row.target == 'DIRECT').connections, 2);
    expect(
      active.singleWhere((row) => row.identity!.name == 'Other.exe').target,
      isNull,
    );
    expect(identity.byName.matchesRule(policy), isTrue);
    expect(
      const ApplicationIdentity(
        action: RuleAction.PROCESS_PATH,
        content: '',
        windows: true,
      ).byName.canRoute,
      isFalse,
    );
  });

  test(
    'Windows names merge installs and casing; other platforms keep casing',
    () {
      final snapshot = _snapshot([
        _connection('1', path: r'C:\Apps\Browser.exe'),
        _connection('2', path: 'c:/apps/browser.exe'),
        _connection('3', path: r'D:\Apps\Browser.exe'),
      ], windows: true);

      expect(snapshot.applications, hasLength(1));
      expect(snapshot.applications.single.connections, 3);
      expect(snapshot.applications.first.identity!.name, 'Browser.exe');
      expect(
        _snapshot([
          _connection('1', path: '/apps/Browser'),
          _connection('2', path: '/apps/browser'),
        ]).applications,
        hasLength(2),
      );
    },
  );

  test(
    'actual routes distinguish mixed, blocked, unknown and named proxies',
    () {
      final snapshot = _snapshot([
        _connection('1'),
        _connection('2', outbound: 'DIRECT'),
        _connection('3', path: '/apps/blocked', outbound: 'REJECT-DROP'),
        _connection('4', path: '/apps/unknown', outbound: null),
        _connection('5', path: '/apps/custom', outbound: 'direct'),
        _connection('6', path: '/apps/direct', outbound: 'COMPATIBLE'),
      ]);
      ApplicationRoute route(String name) => snapshot.applications
          .singleWhere((row) => row.identity?.content == name)
          .route;

      expect(route('browser'), ApplicationRoute.mixed);
      expect(route('blocked'), ApplicationRoute.blocked);
      expect(route('unknown'), ApplicationRoute.unknown);
      expect(route('custom'), ApplicationRoute.proxy);
      expect(route('direct'), ApplicationRoute.direct);
    },
  );

  test('configured apps stay visible while idle and source rules are excluded', () {
    final snapshot = _snapshot([], rules: [
      const Rule(
        ruleAction: RuleAction.PROCESS_PATH,
        content: '/apps/browser',
        ruleTarget: 'DIRECT',
      ),
      const Rule(
        ruleAction: RuleAction.PROCESS_NAME,
        content: 'ignored',
        ruleTarget: 'DIRECT',
        src: true,
      ),
      const Rule(
        ruleAction: RuleAction.DOMAIN,
        content: 'example.test',
        ruleTarget: 'Proxy',
      ),
    ]);

      final row = snapshot.applications.single;
      expect(row.identity!.content, 'browser');
      expect(row.target, 'DIRECT');
      expect(row.route, ApplicationRoute.idle);
    },
  );

  test('the first matching process rule wins across names and paths', () {
    const byName = Rule(
      ruleAction: RuleAction.PROCESS_NAME,
      content: 'browser',
      ruleTarget: 'Proxy',
    );
    const byPath = Rule(
      ruleAction: RuleAction.PROCESS_PATH,
      content: '/apps/browser',
      ruleTarget: 'DIRECT',
    );
    final connection = _connection('1');

    for (final rules in [
      [byName, byPath],
      [byPath, byName],
    ]) {
      final row = _snapshot([connection], rules: rules).applications.singleWhere((row) => row.connections > 0);
      expect(row.target, rules.first.ruleTarget);
      expect(row.identity!.action, RuleAction.PROCESS_NAME);
      expect(row.policyIdentity!.action, rules.first.ruleAction);
      expect(row.connectionIds, [connection.id]);
    }
  });

  test(
    'missing process paths fall back to names; unknown apps cannot be edited',
    () {
      final snapshot = _snapshot([
        _connection('1', path: '', process: 'browser'),
        _connection('2', path: '', process: '', outbound: null),
      ]);

      expect(
        snapshot.applications
            .singleWhere((row) => row.identity != null)
            .identity!
            .action,
        RuleAction.PROCESS_NAME,
      );
      final unknown = snapshot.applications.singleWhere(
        (row) => row.identity == null,
      );
      expect(unknown.route, ApplicationRoute.unknown);
      final fallback = _snapshot([
        _connection('3', path: '/apps/vendor, inc/browser'),
      ]).applications.single;
      expect(fallback.identity!.action, RuleAction.PROCESS_NAME);
      expect(fallback.identity!.content, 'browser');
      expect(fallback.identity!.canRoute, isTrue);
      for (final content in ['', 'app,other', 'app\nother']) {
        expect(
          ApplicationIdentity(
            action: RuleAction.PROCESS_NAME,
            content: content,
            windows: false,
          ).canRoute,
          isFalse,
        );
      }
    },
  );

  test(
    'same-name installs combine traffic, speeds, routes and connection IDs',
    () {
      final first = _snapshot([
        _connection('1', path: '/v1/browser', upload: 100, download: 200),
        _connection('2', path: '/v2/browser', upload: 200, download: 300),
        _connection('3', path: '', process: 'browser'),
      ]);
      final next = _snapshot(
        [
          _connection('1', path: '/v1/browser', upload: 300, download: 600),
          _connection(
            '2',
            path: '/v2/browser',
            process: '',
            outbound: 'DIRECT',
            upload: 600,
            download: 900,
          ),
          _connection(
            '3',
            path: '',
            process: 'browser',
            upload: 100,
            download: 200,
          ),
        ],
        at: _time.add(const Duration(seconds: 1)),
        previous: first,
      );

      final row = next.applications.single;
      expect(row.identity!.content, 'browser');
      expect(row.connections, 3);
      expect(row.connectionIds, ['1', '2', '3']);
      expect(row.upload, 1000);
      expect(row.download, 1700);
      expect(row.uploadSpeed, 700);
      expect(row.downloadSpeed, 1200);
      expect(row.route, ApplicationRoute.mixed);
    },
  );

  test('merged installs show the first matching policy regardless of connection order', () {
    final rules = [
      Rule.parse('PROCESS-PATH,/offline/browser,REJECT'),
      Rule.parse('PROCESS-PATH,/v1/browser,DIRECT'),
      Rule.parse('PROCESS-PATH,/v2/browser,Proxy'),
    ];
    final connections = [
      _connection('1', path: '/v1/browser'),
      _connection('2', path: '/v2/browser'),
      _connection('3', path: '/v3/browser'),
    ];
    expect(_snapshot([], rules: rules).applications.single.target, 'REJECT');
    for (final ordered in [connections, connections.reversed.toList()]) {
      final row = _snapshot(ordered, rules: rules).applications.single;
      expect(row.connections, 3);
      expect(row.target, 'DIRECT');
      expect(row.policyIdentity!.content, '/v1/browser');
    }
  });

  test('speeds use counter deltas and the elapsed sample time', () {
    final first = _snapshot([_connection('1', upload: 100, download: 200)]);
    expect(first.applications.single.downloadSpeed, 0);
    final next = _snapshot([
      _connection('1', upload: 400, download: 800),
      _connection(
        '2',
        upload: 40,
        download: 80,
        start: _time.add(const Duration(seconds: 1)),
      ),
      _connection('3', upload: 10000, download: 20000),
    ], at: _time.add(const Duration(seconds: 2)), previous: first);

    final row = next.applications.single;
    expect(row.uploadSpeed, 170);
    expect(row.downloadSpeed, 340);
    expect(row.upload, 10440);
    expect(row.download, 20880);
  });

  test('a rule refresh at the same sample keeps the last speed', () {
    final connections = [_connection('1', download: 1200)];
    final first = _snapshot([_connection('1', download: 200)]);
    final next = _snapshot(
      connections,
      at: _time.add(const Duration(seconds: 1)),
      previous: first,
    );
    final refreshed = _snapshot(
      connections,
      at: next.sampledAt,
      previous: next,
      rules: [
        const Rule(
          ruleAction: RuleAction.PROCESS_PATH,
          content: '/apps/browser',
          ruleTarget: 'DIRECT',
        ),
      ],
    );

    expect(refreshed.applications.single.downloadSpeed, 1000);
    expect(refreshed.applications.single.target, 'DIRECT');
    expect(refreshed.applications.single.route, ApplicationRoute.proxy);
  });

  test('resets, reused IDs and resumed polling do not create speed spikes', () {
    final first = _snapshot([_connection('1', download: 1000)]);
    for (final seconds in [-1, 20]) {
      final next = _snapshot(
        [_connection('1', download: 100000)],
        at: _time.add(Duration(seconds: seconds)),
        previous: first,
      );
      expect(next.applications.single.downloadSpeed, 0);
    }
    final reset = _snapshot(
      [_connection('1', download: 10)],
      at: _time.add(const Duration(seconds: 1)),
      previous: first,
    );
    expect(reset.applications.single.downloadSpeed, 0);
    final reused = _snapshot(
      [_connection('1', start: _time, download: 10000)],
      at: _time.add(const Duration(seconds: 1)),
      previous: first,
    );
    expect(reused.applications.single.downloadSpeed, 0);
    expect(
      _snapshot([], at: _time, previous: first).samples,
      isEmpty,
    );
  });
}
