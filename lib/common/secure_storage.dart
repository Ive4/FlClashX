import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStorage {
  SessionStorage({bool? isOhos})
    : _isOhos = isOhos ?? Platform.operatingSystem == 'ohos';

  final bool _isOhos;
  final _storage = Platform.isMacOS
      ? const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        )
      : const FlutterSecureStorage();
  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  Future<String?> read({required String key}) {
    return _isOhos
        ? _channel.invokeMethod<String>('read', {'key': key})
        : _storage.read(key: key);
  }

  Future<void> write({required String key, required String value}) {
    return _isOhos
        ? _channel.invokeMethod<void>('write', {'key': key, 'value': value})
        : _storage.write(key: key, value: value);
  }

  Future<void> delete({required String key}) {
    return _isOhos
        ? _channel.invokeMethod<void>('delete', {'key': key})
        : _storage.delete(key: key);
  }
}
