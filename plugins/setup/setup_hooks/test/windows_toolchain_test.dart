import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/target.dart';
import 'package:setup_hooks/src/windows_toolchain.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows hook restores executable discovery and forwards explicit tools',
    () {
      Map<String, String>? seen;
      final environment = windowsRustEnvironment(
        'C:/repository',
        Target.windowsAmd64,
        environment: {'FLCLASH_RUST_TOOLCHAIN': '1.99.1-msvc'},
        command: (executable, arguments, {workingDirectory, environment}) {
          seen = environment;
          return ProcessResult(0, 0, jsonEncode({'RUSTC': 'C:/rustc.exe'}), '');
        },
      );
      expect(seen?['PATHEXT'], contains('.EXE'));
      expect(seen?['FLCLASH_RUST_TOOLCHAIN'], '1.99.1-msvc');
      expect(environment['RUSTC'], 'C:/rustc.exe');
    },
    skip: !Platform.isWindows,
  );
  test(
    'Windows tool discovery recovers system paths without inherited environment',
    () async {
      final repository = p.normalize(
        p.join(Directory.current.path, '..', '..', '..'),
      );
      final systemRoot = Platform.environment['SYSTEMROOT']!;
      final result = await Process.run(
        p.join(
          systemRoot,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          p.join(repository, 'tool', 'rust_windows.ps1'),
          '-PrintSystemPaths',
        ],
        environment: {'SYSTEMROOT': systemRoot},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final paths = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      for (final key in [
        'program_files_x86',
        'program_files',
        'user_profile',
      ]) {
        expect(
          Directory(paths[key] as String).existsSync(),
          isTrue,
          reason: key,
        );
      }
      expect(File(paths['command_processor'] as String).existsSync(), isTrue);
    },
    skip: !Platform.isWindows,
  );
}
