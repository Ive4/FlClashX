import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/core/backup_codec.dart';

const githubOAuthClientId = String.fromEnvironment('FLCLASHX_GITHUB_CLIENT_ID');
const githubBackupFile = 'flclashx-backup.json';
const githubBackupDescription = 'FlClashX configuration backup';
const githubBackupMaxBytes = 5 * 1024 * 1024;
const _maxResponseBytes = 8 * 1024 * 1024;

enum GitHubSyncFailure {
  network,
  unauthorized,
  forbidden,
  expired,
  denied,
  clientId,
  invalidBackup,
  tooLarge,
  changed,
  missing,
  password,
  decryption,
}

class GitHubSyncException implements Exception {
  const GitHubSyncException(this.failure);
  final GitHubSyncFailure failure;

  @override
  String toString() => 'GitHub sync: ${failure.name}';
}

class GitHubSession {
  const GitHubSession({
    required this.token, required this.login, required this.userId,
  });
  final String token;
  final String login;
  final int userId;

  Map<String, dynamic> toJson() => {
    'token': token, 'login': login, 'userId': userId,
  };

  factory GitHubSession.fromJson(Map<String, dynamic> json) => GitHubSession(
    token: json['token'] as String,
    login: json['login'] as String,
    userId: json['userId'] as int,
  );
}

class GitHubDeviceCode {
  const GitHubDeviceCode(this.userCode, this.verificationUri);
  final String userCode;
  final Uri verificationUri;
}

class GitHubBackup {
  const GitHubBackup(this.id, this.updatedAt);
  final String id;
  final DateTime updatedAt;

  factory GitHubBackup.fromJson(Map<String, dynamic> json) => GitHubBackup(
    json['id'] as String, DateTime.parse(json['updated_at'] as String),
  );
}

Future<String> encodeGitHubBackup(Uint8List bytes, String password) async {
  final result = await _cryptBackup('encrypt', bytes, password);
  return utf8.decode(result);
}

Future<Uint8List> decodeGitHubBackup(String content, String password) async {
  if (content.length > _maxResponseBytes) {
    throw const GitHubSyncException(GitHubSyncFailure.tooLarge);
  }
  return _cryptBackup('decrypt', utf8.encode(content), password);
}

Future<Uint8List> _cryptBackup(
  String operation,
  Uint8List bytes,
  String password,
) async {
  try {
    return await invokeBackupCodec(operation, bytes, password: password);
  } on BackupCodecException catch (error) {
    final failure = switch (error.code) {
      'tooLarge' => GitHubSyncFailure.tooLarge,
      'password' => GitHubSyncFailure.password,
      'decryption' => GitHubSyncFailure.decryption,
      _ => GitHubSyncFailure.invalidBackup,
    };
    throw GitHubSyncException(failure);
  }
}

Future<String> _encryptBackupFile(({String path, String password}) request) async {
  final file = File(request.path);
  if (await file.length() > githubBackupMaxBytes) {
    throw const GitHubSyncException(GitHubSyncFailure.tooLarge);
  }
  return encodeGitHubBackup(await file.readAsBytes(), request.password);
}

Future<void> _decryptBackupFile(
  ({Object? payload, String password, String path}) request,
) async {
  final payload = request.payload;
  final content = payload is String ? payload : jsonEncode(payload);
  final bytes = await decodeGitHubBackup(content, request.password);
  await File(request.path).writeAsBytes(bytes, flush: true);
}

class GitHubSyncClient {
  GitHubSyncClient({Dio? dio, Future<void> Function(Duration)? delay})
    : _dio = dio ?? _createDio(),
      _delay = delay ?? Future<void>.delayed;

  static Dio _createDio() {
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20)));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        // Keep the app proxy, but never inherit relaxed TLS for OAuth secrets.
        return HttpClient()..badCertificateCallback = null;
      },
    );
    return dio;
  }

  final Dio _dio;
  final Future<void> Function(Duration) _delay;

  void close() => _dio.close(force: true);

  Future<dynamic> _request(
    String url, {
    String method = 'GET', String? token, Object? data, CancelToken? cancel,
  }) async {
    try {
      final response = await _dio.request<ResponseBody>(
        url, data: data, cancelToken: cancel,
        options: Options(
          method: method, responseType: ResponseType.stream,
          contentType: url.startsWith('https://github.com/login/')
              ? Headers.formUrlEncodedContentType : Headers.jsonContentType,
          followRedirects: false,
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            'Accept': 'application/json', 'User-Agent': 'FlClashX',
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        if (bytes.length + chunk.length > _maxResponseBytes) {
          throw const GitHubSyncException(GitHubSyncFailure.tooLarge);
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      if (body.length > 64 * 1024) {
        return Isolate.run(() => jsonDecode(utf8.decode(body)));
      }
      return jsonDecode(utf8.decode(body));
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw GitHubSyncException(switch (error.response?.statusCode) {
        401 => GitHubSyncFailure.unauthorized,
        403 || 429 => GitHubSyncFailure.forbidden,
        404 => GitHubSyncFailure.missing,
        _ => GitHubSyncFailure.network,
      });
    } on FormatException {
      throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
    }
  }

  Future<GitHubSession> authorize(
    String clientId, {
    required CancelToken cancel,
    required Future<void> Function(GitHubDeviceCode) onCode,
  }) async {
    final response = await _request(
      'https://github.com/login/device/code', method: 'POST',
      data: {'client_id': clientId, 'scope': 'gist'}, cancel: cancel,
    ) as Map<String, dynamic>;
    if (response['error'] != null) {
      throw const GitHubSyncException(GitHubSyncFailure.clientId);
    }
    final uri = Uri.parse(response['verification_uri'] as String);
    if (uri.scheme != 'https' || uri.host != 'github.com' ||
        uri.path != '/login/device' || uri.userInfo.isNotEmpty || uri.port != 443) {
      throw const GitHubSyncException(GitHubSyncFailure.network);
    }
    final deadline = DateTime.now().add(
      Duration(seconds: response['expires_in'] as int),
    );
    var interval = (response['interval'] as int?) ?? 5;
    if (interval < 1) interval = 1;
    await onCode(GitHubDeviceCode(response['user_code'] as String, uri));
    while (DateTime.now().isBefore(deadline)) {
      await Future.any([
        _delay(Duration(seconds: interval)),
        cancel.whenCancel.then<void>((error) => throw error),
      ]);
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (!DateTime.now().isBefore(deadline)) break;
      final result = await _request(
        'https://github.com/login/oauth/access_token', method: 'POST',
        cancel: cancel,
        data: {
          'client_id': clientId, 'device_code': response['device_code'],
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      ) as Map<String, dynamic>;
      switch (result['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += 5;
          continue;
        case 'access_denied':
          throw const GitHubSyncException(GitHubSyncFailure.denied);
        case 'expired_token':
          throw const GitHubSyncException(GitHubSyncFailure.expired);
        case null:
          break;
        default:
          throw const GitHubSyncException(GitHubSyncFailure.clientId);
      }
      final scopes = (result['scope'] as String? ?? '').split(RegExp(r'[, ]+'));
      final token = result['access_token'];
      if (token is! String || token.isEmpty || !scopes.contains('gist')) {
        throw const GitHubSyncException(GitHubSyncFailure.forbidden);
      }
      final user = await _request(
        'https://api.github.com/user', token: token, cancel: cancel,
      ) as Map<String, dynamic>;
      if (cancel.isCancelled) throw cancel.cancelError!;
      return GitHubSession(
        token: token, login: user['login'] as String, userId: user['id'] as int,
      );
    }
    throw const GitHubSyncException(GitHubSyncFailure.expired);
  }

  bool _isBackup(Map<String, dynamic> gist, GitHubSession session) =>
      gist['public'] == false &&
      (gist['owner'] as Map?)?['id'] == session.userId &&
      gist['description'] == githubBackupDescription &&
      (gist['files'] as Map?)?.containsKey(githubBackupFile) == true;

  Future<List<GitHubBackup>> list(GitHubSession session) async {
    final backups = <GitHubBackup>[];
    for (var page = 1; ; page++) {
      final rows = await _request(
        'https://api.github.com/gists?per_page=100&page=$page', token: session.token,
      ) as List;
      for (final row in rows.cast<Map<String, dynamic>>()) {
        if (_isBackup(row, session)) backups.add(GitHubBackup.fromJson(row));
      }
      if (rows.length < 100) break;
    }
    return backups..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<Map<String, dynamic>> _get(
    GitHubSession session, GitHubBackup backup,
  ) async {
    if (!RegExp(r'^[a-fA-F0-9]+$').hasMatch(backup.id)) {
      throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
    }
    final gist = await _request(
      'https://api.github.com/gists/${backup.id}', token: session.token,
    ) as Map<String, dynamic>;
    if (!_isBackup(gist, session)) {
      throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
    }
    if (GitHubBackup.fromJson(gist).updatedAt != backup.updatedAt) {
      throw const GitHubSyncException(GitHubSyncFailure.changed);
    }
    return gist;
  }

  Future<GitHubBackup> upload(
    GitHubSession session, String path, GitHubBackup? backup, {
    required String password,
  }) async {
    final content = await runBackupWorker(_encryptBackupFile, (
      path: path, password: password,
    ));
    if (backup != null) await _get(session, backup);
    final gist = await _request(
      backup == null ? 'https://api.github.com/gists'
          : 'https://api.github.com/gists/${backup.id}',
      method: backup == null ? 'POST' : 'PATCH', token: session.token,
      data: {
        if (backup == null) 'public': false,
        'description': githubBackupDescription,
        'files': {githubBackupFile: {'content': content}},
      },
    ) as Map<String, dynamic>;
    return GitHubBackup.fromJson(gist);
  }

  Future<void> download(
    GitHubSession session, GitHubBackup backup, String path, {
    required String password,
  }) async {
    final gist = await _get(session, backup);
    final file = (gist['files'] as Map)[githubBackupFile] as Map;
    final Object? payload;
    if (file['truncated'] == true) {
      final uri = Uri.parse(file['raw_url'] as String);
      if (uri.scheme != 'https' || uri.host != 'gist.githubusercontent.com' ||
          uri.port != 443 || uri.userInfo.isNotEmpty) {
        throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
      }
      // Raw URLs are untrusted API data; never forward the OAuth token.
      payload = await _request(uri.toString());
    } else {
      payload = file['content'];
    }
    await runBackupWorker(_decryptBackupFile, (
      payload: payload, password: password, path: path,
    ));
  }
}
