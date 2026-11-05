import 'dart:io';

import 'package:setup_hooks/src/error.dart';
import 'package:setup_hooks/src/macos_toolchain.dart';
import 'package:setup_hooks/src/target.dart';
import 'package:test/test.dart';

void main() {
  test('discovers the selected Xcode SDK in a stripped hook environment', () {
    final result = macosBuildEnvironment(
      Target.macosArm64,
      environment: {
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
      },
      command: (executable, arguments, {workingDirectory, environment}) {
        expect(executable, 'xcrun');
        expect(arguments, ['--sdk', 'macosx', '--show-sdk-path']);
        expect(environment!['DEVELOPER_DIR'], contains('Xcode.app'));
        return ProcessResult(0, 0, '/Xcode/MacOSX.sdk\n', '');
      },
    );
    expect(result, {'SDKROOT': '/Xcode/MacOSX.sdk'});
  });

  test('keeps an explicit SDK and leaves other platforms alone', () {
    ProcessResult unexpected(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    }) => throw StateError('unexpected Xcode invocation');
    expect(
      macosBuildEnvironment(
        Target.macosAmd64,
        environment: {'SDKROOT': '/custom/MacOSX.sdk'},
        command: unexpected,
      ),
      {'SDKROOT': '/custom/MacOSX.sdk'},
    );
    for (final target in [Target.windowsAmd64, Target.linuxArm64]) {
      expect(macosBuildEnvironment(target, command: unexpected), isEmpty);
    }
  });

  test('fails before native compilation when Xcode returns no SDK', () {
    expect(
      () => macosBuildEnvironment(
        Target.macosArm64,
        command: (executable, arguments, {workingDirectory, environment}) =>
            ProcessResult(0, 0, '\n', ''),
      ),
      throwsA(isA<BuildException>()),
    );
  });
}
