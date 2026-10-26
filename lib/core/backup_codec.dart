import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop/backup_worker.dart';
import 'ohos/backup_worker.dart';

const backupMaxExpandedBytes = 128 * 1024 * 1024;
const backupMaxWireBytes = 180 * 1024 * 1024;

@visibleForTesting
String? backupCodecTestExecutable;

class BackupCodecException implements Exception {
  const BackupCodecException(this.code);
  final String code;

  @override
  String toString() => 'BackupCodecException($code)';
}

typedef _BackupWork<Q, R> = ({
  ComputeCallback<Q, R> callback,
  Q message,
  RootIsolateToken? token,
  String? executable,
});

Future<R> runBackupWorker<Q, R>(
  ComputeCallback<Q, R> callback,
  Q message,
) async {
  final token = RootIsolateToken.instance;
  if (token == null) return callback(message);
  return compute(_runBackupWork<Q, R>, (
    callback: callback,
    message: message,
    token: token,
    executable: backupCodecTestExecutable,
  ));
}

Future<R> _runBackupWork<Q, R>(_BackupWork<Q, R> work) async {
  if (Platform.isAndroid && work.token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(work.token!);
  }
  backupCodecTestExecutable = work.executable;
  return work.callback(work.message);
}

typedef _CodecRequest = ({String operation, Uint8List data, String password});

Future<Uint8List> invokeBackupCodec(
  String operation,
  Uint8List data, {
  String password = '',
}) => runBackupWorker(_invokeBackupCodec, (
  operation: operation,
  data: data,
  password: password,
));

Future<Uint8List> _invokeBackupCodec(_CodecRequest request) async {
  if (request.data.length > backupMaxExpandedBytes + 1024 * 1024) {
    throw const BackupCodecException('tooLarge');
  }
  final input = utf8.encode(
    jsonEncode({
      'version': 1,
      'operation': request.operation,
      'data': base64Encode(request.data),
      if (request.password.isNotEmpty) 'password': request.password,
    }),
  );
  final Uint8List output;
  if (Platform.isAndroid) {
    const channel = MethodChannel('com.follow.clash/backup');
    final result = await channel.invokeMethod<Uint8List>('codec', input);
    if (result == null || result.length > backupMaxWireBytes) {
      throw const BackupCodecException('internal');
    }
    output = result;
  } else if (Platform.operatingSystem == 'ohos') {
    output = runOhosBackupWorker(input);
  } else {
    output = await runDesktopBackupWorker(
      input,
      executable: backupCodecTestExecutable,
    );
  }
  final response = jsonDecode(utf8.decode(output)) as Map<String, dynamic>;
  final error = response['error'];
  if (error is String) throw BackupCodecException(error);
  return base64Decode(response['data'] as String? ?? '');
}
