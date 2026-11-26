import 'dart:io';

import 'package:fl_clash/common/macos_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final (bundleId, accepted) in [
    ('com.follow.clash', true),
    ('com.example.other', false),
  ]) {
    test('macOS staging checks the bundle identifier $bundleId', () async {
      final root = await Directory.systemTemp.createTemp('flclash-macos-test-');
      addTearDown(() => root.delete(recursive: true));
      final bundle = p.join(root.path, 'FlClashX.app');
      final download = await Directory(p.join(root.path, 'download')).create();
      final image = await File(p.join(download.path, 'FlClashX.dmg')).create();
      final tools = <String>[];
      final updater = MacosAppUpdate(
        bundle,
        runProcess: (executable, args) async {
          final tool = p.posix.basename(executable);
          tools.add(tool);
          if (tool == 'hdiutil' && args.first == 'attach') {
            await Directory(p.join(args.last, 'FlClashX.app')).create();
          }
          if (tool == 'hdiutil' && args.first == 'detach') {
            await Directory(args[1]).delete(recursive: true);
          }
          if (tool == 'ditto') await Directory(args.last).create();
          final installedPlist = p.join(bundle, 'Contents', 'Info.plist');
          final output = tool == 'plutil'
              ? (args.last == installedPlist ? 'com.follow.clash' : bundleId)
              : '';
          return ProcessResult(1, 0, output, '');
        },
      );

      final staged = updater.stage(image.path, download.path);
      if (accepted) {
        expect(await Directory(await staged).exists(), isTrue);
        expect(await image.exists(), isFalse);
        expect(tools, contains('xattr'));
      } else {
        await expectLater(staged, throwsA(isA<MacosUpdateException>()));
        expect(await image.exists(), isTrue);
        expect(
          await Directory(p.join(download.path, 'FlClashX.app')).exists(),
          isFalse,
        );
        expect(tools, isNot(contains('xattr')));
      }
    });
  }
}
