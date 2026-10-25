import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/github_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/backup_codec.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Object Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _password = 'example-password-123';
late String _encrypted;

const _session = GitHubSession(token: 'test-token', login: 'tester', userId: 7);
final _date = DateTime.utc(2026, 10, 25);
final _backup = GitHubBackup('abc123', _date);

Map<String, dynamic> _gist({bool public = false, int owner = 7}) => {
  'id': _backup.id,
  'updated_at': _date.toIso8601String(),
  'public': public,
  'owner': {'id': owner},
  'description': githubBackupDescription,
  'files': {
    githubBackupFile: {'content': _encrypted},
  },
};

Matcher _failure(GitHubSyncFailure failure) => isA<GitHubSyncException>()
    .having((error) => error.failure, 'failure', failure);

void main() {
  useGoBackupCodec();
  setUpAll(() async {
    _encrypted = await encodeGitHubBackup(
      Uint8List.fromList([1, 2, 3]),
      _password,
    );
  });

  test('encrypted archive round trip preserves bytes', () async {
    expect(await decodeGitHubBackup(_encrypted, _password), [1, 2, 3]);
    expect(_encrypted, isNot(contains(_password)));
    expect(jsonDecode(_encrypted), isNot(contains('archive')));
  });

  test('each encryption uses a fresh salt and nonce', () async {
    final other =
        jsonDecode(
              await encodeGitHubBackup(
                Uint8List.fromList([1, 2, 3]),
                _password,
              ),
            )
            as Map;
    final first = jsonDecode(_encrypted) as Map;
    expect(other['salt'], isNot(first['salt']));
    expect(other['nonce'], isNot(first['nonce']));
    expect(other['ciphertext'], isNot(first['ciphertext']));
  });

  test('wrong password and modified ciphertext fail authentication', () async {
    await expectLater(
      decodeGitHubBackup(_encrypted, 'wrong-password'),
      throwsA(_failure(GitHubSyncFailure.decryption)),
    );
    final json = jsonDecode(_encrypted) as Map;
    final bytes = base64Decode(json['ciphertext'] as String);
    bytes[0] ^= 1;
    json['ciphertext'] = base64Encode(bytes);
    await expectLater(
      decodeGitHubBackup(jsonEncode(json), _password),
      throwsA(_failure(GitHubSyncFailure.decryption)),
    );
  });

  test(
    'incompatible schema, unbounded KDF and oversized payloads fail',
    () async {
      final json = jsonDecode(_encrypted) as Map;
      json['iterations'] = 999999999;
      await expectLater(
        decodeGitHubBackup(jsonEncode(json), _password),
        throwsA(_failure(GitHubSyncFailure.invalidBackup)),
      );
      json['schema'] = 99;
      await expectLater(
        decodeGitHubBackup(jsonEncode(json), _password),
        throwsA(_failure(GitHubSyncFailure.invalidBackup)),
      );
      await expectLater(
        encodeGitHubBackup(Uint8List(githubBackupMaxBytes + 1), _password),
        throwsA(_failure(GitHubSyncFailure.tooLarge)),
      );
      await expectLater(
        encodeGitHubBackup(Uint8List(1), 'short'),
        throwsA(_failure(GitHubSyncFailure.password)),
      );
    },
  );

  test(
    'device flow honors pending and slow_down, then validates identity',
    () async {
      var polls = 0;
      final waits = <Duration>[];
      final adapter = _Adapter((request) {
        if (request.uri.path == '/login/device/code') {
          expect(request.data, {'client_id': 'client', 'scope': 'gist'});
          return {
            'user_code': 'ABCD-1234',
            'device_code': 'device',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          };
        }
        if (request.uri.path == '/user') {
          expect(request.headers['Authorization'], 'Bearer test-token');
          return {'login': 'tester', 'id': 7};
        }
        expect(
          (request.data as Map)['grant_type'],
          'urn:ietf:params:oauth:grant-type:device_code',
        );
        return switch (polls++) {
          0 => {'error': 'authorization_pending'},
          1 => {'error': 'slow_down'},
          _ => {
            'access_token': 'test-token',
            'scope': 'gist',
            'token_type': 'bearer',
          },
        };
      });
      final client = GitHubSyncClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (duration) async {
          waits.add(duration);
        },
      );
      addTearDown(client.close);
      final session = await client.authorize(
        'client',
        cancel: CancelToken(),
        onCode: (code) async {
          expect(code.userCode, 'ABCD-1234');
        },
      );
      expect(session.userId, 7);
      expect(waits.map((d) => d.inSeconds), [5, 5, 10]);
    },
  );

  for (final error in [
    'access_denied',
    'expired_token',
    'incorrect_client_credentials',
  ]) {
    test('device authorization handles $error', () async {
      final adapter = _Adapter(
        (request) => request.uri.path.endsWith('/device/code')
            ? {
                'user_code': 'ABCD-1234',
                'device_code': 'device',
                'verification_uri': 'https://github.com/login/device',
                'expires_in': 900,
                'interval': 5,
              }
            : {'error': error},
      );
      final client = GitHubSyncClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (_) async {},
      );
      addTearDown(client.close);
      await expectLater(
        client.authorize('client', cancel: CancelToken(), onCode: (_) async {}),
        throwsA(
          _failure(switch (error) {
            'access_denied' => GitHubSyncFailure.denied,
            'expired_token' => GitHubSyncFailure.expired,
            _ => GitHubSyncFailure.clientId,
          }),
        ),
      );
    });
  }

  test(
    'token without gist permission is rejected before loading identity',
    () async {
      final adapter = _Adapter(
        (request) => request.uri.path.endsWith('/device/code')
            ? {
                'user_code': 'ABCD-1234',
                'device_code': 'device',
                'verification_uri': 'https://github.com/login/device',
                'expires_in': 900,
                'interval': 5,
              }
            : {'access_token': 'test-token', 'scope': 'read:user'},
      );
      final client = GitHubSyncClient(
        dio: Dio()..httpClientAdapter = adapter,
        delay: (_) async {},
      );
      addTearDown(client.close);
      await expectLater(
        client.authorize('client', cancel: CancelToken(), onCode: (_) async {}),
        throwsA(_failure(GitHubSyncFailure.forbidden)),
      );
      expect(adapter.requests.any((r) => r.uri.path == '/user'), false);
    },
  );

  test('cancelled browser login never exchanges or saves a token', () async {
    final adapter = _Adapter(
      (_) => {
        'user_code': 'ABCD-1234',
        'device_code': 'device',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 900,
        'interval': 5,
      },
    );
    final client = GitHubSyncClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);
    final cancel = CancelToken();
    await expectLater(
      client.authorize(
        'client',
        cancel: cancel,
        onCode: (_) async {
          cancel.cancel();
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests.length, 1);
  });

  test('discovery filters public, unrelated and other-account Gists', () async {
    final adapter = _Adapter(
      (_) => [
        _gist(),
        _gist(public: true),
        _gist(owner: 8),
        {..._gist(), 'description': 'not a backup'},
      ],
    );
    final client = GitHubSyncClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);
    expect((await client.list(_session)).map((b) => b.id), ['abc123']);
  });

  test(
    'new uploads create secret Gists and omit credentials from content',
    () async {
      final temp = await Directory.systemTemp.createTemp('github-sync-');
      addTearDown(() => temp.delete(recursive: true));
      final archive = await File(
        '${temp.path}/backup.tar.xz',
      ).writeAsBytes([1, 2, 3]);
      final adapter = _Adapter((request) {
        expect(request.method, 'POST');
        final body = request.data as Map;
        expect(body['public'], false);
        expect(jsonEncode(body), isNot(contains(_session.token)));
        expect(jsonEncode(body), isNot(contains('client_secret')));
        return _gist();
      });
      final client = GitHubSyncClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(client.close);
      await client.upload(_session, archive.path, null, password: _password);
      expect(adapter.requests.length, 1);
    },
  );

  test('changed backup aborts upload before PATCH', () async {
    final temp = await Directory.systemTemp.createTemp('github-sync-');
    addTearDown(() => temp.delete(recursive: true));
    final archive = await File('${temp.path}/backup.tar.xz').writeAsBytes([1]);
    final adapter = _Adapter(
      (_) => {
        ..._gist(),
        'updated_at': _date.add(const Duration(seconds: 1)).toIso8601String(),
      },
    );
    final client = GitHubSyncClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);
    await expectLater(
      client.upload(_session, archive.path, _backup, password: _password),
      throwsA(_failure(GitHubSyncFailure.changed)),
    );
    expect(adapter.requests.map((r) => r.method), ['GET']);
  });

  test('truncated backup uses raw URL without forwarding credentials', () async {
    final temp = await Directory.systemTemp.createTemp('github-sync-');
    addTearDown(() => temp.delete(recursive: true));
    final adapter = _Adapter((request) {
      if (request.uri.host == 'gist.githubusercontent.com') {
        expect(request.headers.containsKey('Authorization'), false);
        expect(request.followRedirects, false);
        return jsonDecode(_encrypted);
      }
      return {
        ..._gist(),
        'files': {
          githubBackupFile: {
            'truncated': true,
            'raw_url':
                'https://gist.githubusercontent.com/tester/abc123/raw/backup.json',
          },
        },
      };
    });
    final client = GitHubSyncClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);
    final path = '${temp.path}/backup.tar.xz';
    await client.download(_session, _backup, path, password: _password);
    expect(await File(path).readAsBytes(), [1, 2, 3]);
  });

  test('foreign raw URL is rejected before requesting it', () async {
    final adapter = _Adapter(
      (_) => {
        ..._gist(),
        'files': {
          githubBackupFile: {
            'truncated': true,
            'raw_url': 'http://localhost/secret',
          },
        },
      },
    );
    final client = GitHubSyncClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);
    await expectLater(
      client.download(_session, _backup, 'unused.tar.xz', password: _password),
      throwsA(_failure(GitHubSyncFailure.invalidBackup)),
    );
    expect(adapter.requests.length, 1);
  });
  for (final service in SnippetService.values) {
    test(
      '${service.name} token login validates identity on its own host',
      () async {
        final adapter = _Adapter((request) {
          expect(request.uri.host, Uri.parse(service.apiBase).host);
          expect(request.uri.path, '${Uri.parse(service.apiBase).path}/user');
          if (service == SnippetService.gitee) {
            expect(
              request.uri.queryParameters['access_token'],
              'personal-token',
            );
            expect(request.headers, isNot(contains('Authorization')));
          } else {
            expect(request.headers['Authorization'], 'Bearer personal-token');
            expect(request.queryParameters, isNot(contains('access_token')));
          }
          return {'login': 'tester', 'id': 7};
        });
        final client = GitHubSyncClient(
          service: service,
          dio: Dio()..httpClientAdapter = adapter,
        );
        addTearDown(client.close);
        final session = await client.signInWithToken(' personal-token ');
        expect(session.userId, 7);
        expect(session.token, 'personal-token');
        await expectLater(
          client.signInWithToken('  '),
          throwsA(_failure(GitHubSyncFailure.unauthorized)),
        );
        expect(adapter.requests.length, 1);
      },
    );

    test(
      '${service.name} encrypted create, update and restore round trip',
      () async {
        final temp = await Directory.systemTemp.createTemp('snippet-sync-');
        addTearDown(() => temp.delete(recursive: true));
        final source = await File(
          '${temp.path}/source',
        ).writeAsBytes([4, 5, 6]);
        var encrypted = '';
        final adapter = _Adapter((request) {
          expect(request.uri.host, Uri.parse(service.apiBase).host);
          if (request.method != 'GET') {
            final data = request.data as Map;
            if (request.method == 'POST') expect(data['public'], false);
            if (service == SnippetService.gitee) {
              expect(data['access_token'], _session.token);
              expect(
                request.uri.queryParameters,
                isNot(contains('access_token')),
              );
            }
            encrypted =
                ((data['files'] as Map)[githubBackupFile] as Map)['content']
                    as String;
            expect(encrypted, isNot(contains(_session.token)));
            expect(encrypted, isNot(contains(_password)));
            expect((jsonDecode(encrypted) as Map)['cipher'], 'AES-256-GCM');
          }
          return {
            ..._gist(),
            'files': {
              githubBackupFile: {'content': encrypted},
            },
          };
        });
        final client = GitHubSyncClient(
          service: service,
          dio: Dio()..httpClientAdapter = adapter,
        );
        addTearDown(client.close);
        final backup = await client.upload(
          _session,
          source.path,
          null,
          password: _password,
        );
        await client.upload(_session, source.path, backup, password: _password);
        final destination = '${temp.path}/restored';
        await client.download(
          _session,
          backup,
          destination,
          password: _password,
        );
        expect(await File(destination).readAsBytes(), [4, 5, 6]);
        expect(adapter.requests.map((r) => r.method), [
          'POST',
          'GET',
          'PATCH',
          'GET',
        ]);
        await File(destination).writeAsBytes([99]);
        await expectLater(
          client.download(
            _session,
            backup,
            destination,
            password: 'incorrect-password',
          ),
          throwsA(_failure(GitHubSyncFailure.decryption)),
        );
        expect(await File(destination).readAsBytes(), [99]);
      },
    );
  }

  test('Gitee lists paginated snippets and parses serialized files', () async {
    final adapter = _Adapter((request) {
      expect(request.uri.path, '/api/v5/gists');
      expect(request.uri.queryParameters['access_token'], _session.token);
      if (request.uri.queryParameters['page'] == '1') {
        return List.generate(100, (_) => _gist(public: true));
      }
      return [
        {..._gist(), 'files': jsonEncode(_gist()['files'])},
        _gist(owner: 8),
      ];
    });
    final client = GitHubSyncClient(
      service: SnippetService.gitee,
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(client.close);
    expect((await client.list(_session)).map((b) => b.id), ['abc123']);
    expect(adapter.requests.length, 2);
  });

  test('Gitee raw download never forwards its token', () async {
    final temp = await Directory.systemTemp.createTemp('gitee-sync-');
    addTearDown(() => temp.delete(recursive: true));
    final adapter = _Adapter((request) {
      if (request.uri.path.startsWith('/tester/')) {
        expect(request.headers, isNot(contains('Authorization')));
        expect(request.queryParameters, isNot(contains('access_token')));
        expect(request.followRedirects, false);
        return jsonDecode(_encrypted);
      }
      return {
        ..._gist(),
        'files': {
          githubBackupFile: {
            'truncated': true,
            'raw_url': 'https://gitee.com/tester/codes/abc123/raw/backup.json',
          },
        },
      };
    });
    final client = GitHubSyncClient(
      service: SnippetService.gitee,
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(client.close);
    final destination = '${temp.path}/restored';
    await client.download(_session, _backup, destination, password: _password);
    expect(await File(destination).readAsBytes(), [1, 2, 3]);
  });
}
