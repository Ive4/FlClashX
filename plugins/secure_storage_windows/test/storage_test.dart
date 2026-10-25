import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final String directory;

  @override
  Future<String> getApplicationSupportPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DPAPI persists encrypted records without calling the legacy plugin', () async {
    final directory = await Directory.systemTemp.createTemp('flclash-dpapi-test-');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      await directory.delete(recursive: true);
    });
    final storage = FlutterSecureStorageWindows();
    const options = {'useBackwardCompatibility': 'true'};
    const value = 'synthetic-test-token-do-not-use';
    expect(await storage.containsKey(key: 'session', options: options), isFalse);
    await storage.write(key: 'session', value: value, options: options);
    final encrypted = await File('${directory.path}/flutter_secure_storage.dat').readAsBytes();
    expect(utf8.decode(encrypted, allowMalformed: true), isNot(contains(value)));
    final reopened = FlutterSecureStorageWindows();
    expect(await reopened.read(key: 'session', options: options), value);
    await reopened.delete(key: 'session', options: options);
    expect(await reopened.read(key: 'session', options: options), isNull);
    await reopened.write(key: 'other', value: value, options: options);
    await reopened.deleteAll(options: options);
    expect(await reopened.readAll(options: options), isEmpty);
  }, skip: !Platform.isWindows);
}
