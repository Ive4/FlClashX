import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/core/backup_codec.dart';

const githubOAuthClientId = String.fromEnvironment('FLCLASHX_GITHUB_CLIENT_ID');
const giteeOAuthUrl = String.fromEnvironment('FLCLASHX_GITEE_OAUTH_URL');
const githubBackupFile = 'flclashx-backup.json';
const githubBackupDescription = 'FlClashX configuration backup';
const githubBackupMaxBytes = 5 * 1024 * 1024;
const _maxResponseBytes = 8 * 1024 * 1024;

enum SnippetService {
  github('https://api.github.com'),
  gitee('https://gitee.com/api/v5');

  const SnippetService(this.apiBase);
  final String apiBase;
}

enum GitHubSyncFailure {
  network,
  browser,
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
    required this.token,
    required this.login,
    required this.userId,
    this.refreshToken,
    this.expiresAt,
  });
  final String token;
  final String login;
  final int userId;
  final String? refreshToken;
  final DateTime? expiresAt;

  Map<String, dynamic> toJson() => {
    'token': token,
    'login': login,
    'userId': userId,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
  };

  factory GitHubSession.fromJson(Map<String, dynamic> json) => GitHubSession(
    token: json['token'] as String,
    login: json['login'] as String,
    userId: json['userId'] as int,
    refreshToken: json['refreshToken'] as String?,
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
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
    json['id'] as String,
    DateTime.parse(json['updated_at'] as String),
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

Future<String> _encryptBackupFile(
  ({String path, String password}) request,
) async {
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
  GitHubSyncClient({
    Dio? dio,
    Future<void> Function(Duration)? delay,
    this.githubClientId = githubOAuthClientId,
    this.giteeAuthorizationUrl = giteeOAuthUrl,
    this.service = SnippetService.github,
  }) : _dio = dio ?? _createDio(),
       _delay = delay;

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

  final SnippetService service;
  final String githubClientId;
  final String giteeAuthorizationUrl;
  final Dio _dio;
  final Future<void> Function(Duration)? _delay;

  void close() => _dio.close(force: true);

  Uri? get _giteeAuthorizationBase {
    final uri = Uri.tryParse(giteeAuthorizationUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  bool get browserAuthorizationAvailable => switch (service) {
    SnippetService.github => githubClientId.trim().isNotEmpty,
    SnippetService.gitee => _giteeAuthorizationBase != null,
  };

  Future<void> _wait(Duration duration, CancelToken cancel) async {
    if (cancel.isCancelled) throw cancel.cancelError!;
    final completer = Completer<void>();
    final timer = _delay == null ? Timer(duration, completer.complete) : null;
    try {
      await Future.any([
        _delay?.call(duration) ?? completer.future,
        cancel.whenCancel.then<void>((error) => throw error),
      ]);
    } finally {
      timer?.cancel();
    }
  }

  Future<dynamic> _request(
    String url, {
    String method = 'GET',
    String? token,
    Object? data,
    CancelToken? cancel,
  }) async {
    try {
      final isGitee =
          service == SnippetService.gitee &&
          url.startsWith('${service.apiBase}/');
      final uri = Uri.parse(url);
      final requestUrl = isGitee && token != null && method == 'GET'
          ? uri
                .replace(
                  queryParameters: {
                    ...uri.queryParameters,
                    'access_token': token,
                  },
                )
                .toString()
          : url;
      final requestData = isGitee && token != null && method != 'GET'
          ? {...?data as Map<String, dynamic>?, 'access_token': token}
          : data;
      final response = await _dio.request<ResponseBody>(
        requestUrl,
        data: requestData,
        cancelToken: cancel,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          contentType: url.startsWith('https://github.com/login/')
              ? Headers.formUrlEncodedContentType
              : Headers.jsonContentType,
          followRedirects: false,
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'FlClashX',
            if (token != null && !isGitee) 'Authorization': 'Bearer $token',
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
        return await Isolate.run(() => jsonDecode(utf8.decode(body)));
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

  Future<GitHubSession> signInWithToken(String token) async {
    token = token.trim();
    if (token.isEmpty) {
      throw const GitHubSyncException(GitHubSyncFailure.unauthorized);
    }
    final user =
        await _request('${service.apiBase}/user', token: token)
            as Map<String, dynamic>;
    return GitHubSession(
      token: token,
      login: user['login'] as String,
      userId: user['id'] as int,
    );
  }

  Future<GitHubSession> refreshSession(GitHubSession session) async {
    final expires = session.expiresAt;
    if (expires == null ||
        expires.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return session;
    }
    final refresh = session.refreshToken;
    final base = _giteeAuthorizationBase;
    if (service != SnippetService.gitee || refresh == null || base == null) {
      throw const GitHubSyncException(GitHubSyncFailure.unauthorized);
    }
    final result =
        await _request(
              '$base/refresh',
              method: 'POST',
              data: {'refresh_token': refresh},
            )
            as Map<String, dynamic>;
    final token = result['access_token'];
    if (token is! String || token.isEmpty) {
      throw const GitHubSyncException(GitHubSyncFailure.unauthorized);
    }
    return GitHubSession(
      token: token,
      login: session.login,
      userId: session.userId,
      refreshToken: result['refresh_token'] as String? ?? refresh,
      expiresAt: _expiresAt(result),
    );
  }

  DateTime? _expiresAt(Map<String, dynamic> response) {
    final seconds = response['expires_in'];
    return seconds is int && seconds > 0
        ? DateTime.now().add(Duration(seconds: seconds))
        : null;
  }

  Future<GitHubSession> authorize(
    String clientId, {
    required CancelToken cancel,
    required Future<void> Function(GitHubDeviceCode) onCode,
  }) async {
    final giteeBase = _giteeAuthorizationBase;
    if ((service == SnippetService.github && clientId.trim().isEmpty) ||
        (service == SnippetService.gitee && giteeBase == null)) {
      throw const GitHubSyncException(GitHubSyncFailure.clientId);
    }
    final response =
        await _request(
              service == SnippetService.github
                  ? 'https://github.com/login/device/code'
                  : '$giteeBase/device/code',
              method: 'POST',
              data: service == SnippetService.github
                  ? {'client_id': clientId, 'scope': 'gist'}
                  : <String, dynamic>{},
              cancel: cancel,
            )
            as Map<String, dynamic>;
    if (response['error'] != null) {
      throw const GitHubSyncException(GitHubSyncFailure.clientId);
    }
    final uri = Uri.tryParse(response['verification_uri'] as String? ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const GitHubSyncException(GitHubSyncFailure.network);
    }
    final validUri = service == SnippetService.github
        ? uri.scheme == 'https' &&
              uri.host == 'github.com' &&
              uri.path == '/login/device' &&
              uri.port == 443 &&
              uri.userInfo.isEmpty &&
              !uri.hasFragment
        : uri.origin == giteeBase!.origin &&
              uri.path == '${giteeBase.path}/authorize' &&
              uri.userInfo.isEmpty &&
              !uri.hasFragment;
    if (!validUri) {
      throw const GitHubSyncException(GitHubSyncFailure.network);
    }
    final deadline = DateTime.now().add(
      Duration(seconds: response['expires_in'] as int),
    );
    var interval = (response['interval'] as int?) ?? 5;
    if (interval < 1) interval = 1;
    await onCode(GitHubDeviceCode(response['user_code'] as String? ?? '', uri));
    while (DateTime.now().isBefore(deadline)) {
      await _wait(Duration(seconds: interval), cancel);
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (!DateTime.now().isBefore(deadline)) break;
      final result =
          await _request(
                service == SnippetService.github
                    ? 'https://github.com/login/oauth/access_token'
                    : '$giteeBase/token',
                method: 'POST',
                cancel: cancel,
                data: {
                  if (service == SnippetService.github) 'client_id': clientId,
                  'device_code': response['device_code'],
                  'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
                },
              )
              as Map<String, dynamic>;
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
        case 'exchange_failed':
          throw const GitHubSyncException(GitHubSyncFailure.network);
        case null:
          break;
        default:
          throw const GitHubSyncException(GitHubSyncFailure.clientId);
      }
      final scopes = (result['scope'] as String? ?? '').split(RegExp(r'[, ]+'));
      final token = result['access_token'];
      final requiredScopes = service == SnippetService.github
          ? ['gist']
          : ['gists', 'user_info'];
      if (token is! String ||
          token.isEmpty ||
          !requiredScopes.every(scopes.contains)) {
        throw const GitHubSyncException(GitHubSyncFailure.forbidden);
      }
      final user =
          await _request(
                '${service.apiBase}/user',
                token: token,
                cancel: cancel,
              )
              as Map<String, dynamic>;
      if (cancel.isCancelled) throw cancel.cancelError!;
      return GitHubSession(
        token: token,
        login: user['login'] as String,
        userId: user['id'] as int,
        refreshToken: result['refresh_token'] as String?,
        expiresAt: _expiresAt(result),
      );
    }
    throw const GitHubSyncException(GitHubSyncFailure.expired);
  }

  Map<dynamic, dynamic> _files(Map<String, dynamic> gist) {
    final files = gist['files'];
    if (files is Map) return files;
    if (service == SnippetService.gitee && files is String) {
      try {
        final decoded = jsonDecode(files);
        if (decoded is Map) return decoded;
      } on FormatException {
        throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
      }
    }
    throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
  }

  bool _isBackup(Map<String, dynamic> gist, GitHubSession session) =>
      gist['public'] == false &&
      (gist['owner'] as Map?)?['id'] == session.userId &&
      gist['description'] == githubBackupDescription &&
      _files(gist).containsKey(githubBackupFile);

  Future<List<GitHubBackup>> list(GitHubSession session) async {
    final backups = <GitHubBackup>[];
    for (var page = 1; ; page++) {
      final rows =
          await _request(
                '${service.apiBase}/gists?per_page=100&page=$page',
                token: session.token,
              )
              as List;
      for (final row in rows.cast<Map<String, dynamic>>()) {
        if (_isBackup(row, session)) backups.add(GitHubBackup.fromJson(row));
      }
      if (rows.length < 100) break;
    }
    return backups..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<Map<String, dynamic>> _get(
    GitHubSession session,
    GitHubBackup backup,
  ) async {
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(backup.id)) {
      throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
    }
    final gist =
        await _request(
              '${service.apiBase}/gists/${backup.id}',
              token: session.token,
            )
            as Map<String, dynamic>;
    if (!_isBackup(gist, session)) {
      throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
    }
    if (GitHubBackup.fromJson(gist).updatedAt != backup.updatedAt) {
      throw const GitHubSyncException(GitHubSyncFailure.changed);
    }
    return gist;
  }

  Future<GitHubBackup> upload(
    GitHubSession session,
    String path,
    GitHubBackup? backup, {
    required String password,
  }) async {
    final content = await runBackupWorker(_encryptBackupFile, (
      path: path,
      password: password,
    ));
    if (backup != null) await _get(session, backup);
    final gist =
        await _request(
              backup == null
                  ? '${service.apiBase}/gists'
                  : '${service.apiBase}/gists/${backup.id}',
              method: backup == null ? 'POST' : 'PATCH',
              token: session.token,
              data: {
                if (backup == null) 'public': false,
                'description': githubBackupDescription,
                'files': {
                  githubBackupFile: {'content': content},
                },
              },
            )
            as Map<String, dynamic>;
    return GitHubBackup.fromJson(gist);
  }

  Future<void> download(
    GitHubSession session,
    GitHubBackup backup,
    String path, {
    required String password,
  }) async {
    final gist = await _get(session, backup);
    final file = _files(gist)[githubBackupFile] as Map;
    final Object? payload;
    if (file['truncated'] == true) {
      final uri = Uri.parse(file['raw_url'] as String);
      if (uri.scheme != 'https' ||
          uri.host !=
              (service == SnippetService.github
                  ? 'gist.githubusercontent.com'
                  : 'gitee.com') ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty) {
        throw const GitHubSyncException(GitHubSyncFailure.invalidBackup);
      }
      // Raw URLs are untrusted API data; never forward the OAuth token.
      payload = await _request(uri.toString());
    } else {
      payload = file['content'];
    }
    await runBackupWorker(_decryptBackupFile, (
      payload: payload,
      password: password,
      path: path,
    ));
  }
}
