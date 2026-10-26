import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/common/picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

base class _LocalPlatformFile extends PlatformFile {
  _LocalPlatformFile(this._file);

  final File _file;

  @override
  String get name => _file.uri.pathSegments.last;

  @override
  Uri get uri => _file.uri;

  @override
  XFile get xFile => XFile(_file.path);

  @override
  int? lengthSync() => null;

  @override
  Future<int> length() => _file.length();

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      _file.openRead().map(Uint8List.fromList);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HarmonyOS picker', () {
    const channel = MethodChannel('com.follow.clash/file_picker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final picker = Picker(isOhos: true);
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('flclash-ohos-picker-');
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });

    test(
      'a selected document is readable through the PlatformFile API',
      () async {
        final file = File('${directory.path}/picked-123-备份.tar.xz');
        await file.writeAsBytes([1, 2, 3]);
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickFile');
          return file.path;
        });

        final selected = (await picker.pickerFile())!;

        expect(selected.name, '备份.tar.xz');
        expect(selected.path, file.uri.toFilePath());
        expect(await selected.length(), 3);
        expect(await selected.readBytes(), [1, 2, 3]);
        expect(await selected.xFile.readAsBytes(), [1, 2, 3]);
        expect(
          await selected.readAsByteStream().expand((chunk) => chunk).toList(),
          [1, 2, 3],
        );
      },
    );

    test('cancelled open and save return null', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);

      expect(await picker.pickerFile(), isNull);
      expect(await picker.saveFile('backup.tar.xz', Uint8List(0)), isNull);
    });

    test('backup export passes a file path and preserves its source', () async {
      final file = File('${directory.path}/backup.tar.xz');
      await file.writeAsBytes([1, 2, 3]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveFile');
        final arguments = call.arguments as Map;
        expect(arguments['path'], file.path);
        expect(arguments.containsKey('bytes'), isFalse);
        return 'file://docs/backup.tar.xz';
      });

      expect(
        await picker.saveFileWithPath('backup.tar.xz', file.path),
        Uri.parse('file://docs/backup.tar.xz'),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
    });

    test('cancelling or failing export keeps the original archive', () async {
      final file = File('${directory.path}/backup.tar.xz');
      await file.writeAsBytes([1, 2, 3]);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await picker.saveFileWithPath('backup.tar.xz', file.path), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'file_picker_failed');
      });

      await expectLater(
        picker.saveFileWithPath('backup.tar.xz', file.path),
        throwsA(isA<PlatformException>()),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
    });
  });

  group('PlatformFileExt.readBytes', () {
    test('loads bytes from the picked file path', () async {
      final directory = await Directory.systemTemp.createTemp(
        'fl_clash_picker_test_',
      );
      addTearDown(() => directory.delete(recursive: true));

      final file = File('${directory.path}/profile.yaml');
      await file.writeAsString('mixed-port: 7890');

      final platformFile = _LocalPlatformFile(file);

      final bytes = await platformFile.readBytes();

      expect(String.fromCharCodes(bytes), 'mixed-port: 7890');
    });
  });
}
