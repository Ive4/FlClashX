import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'rust_core_builder.dart';
import 'target.dart';
import 'util.dart';

Map<String, String> windowsRustEnvironment(
  String rootDir,
  Target target, {
  Map<String, String> environment = const {},
  RustCommand command = runCommand,
}) {
  if (!Platform.isWindows || target.goos != 'windows') return const {};
  final result = command(
    'powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      p.join(rootDir, 'tool', 'rust_windows.ps1'),
      '-Architecture',
      target.goarch,
      '-PrintEnvironment',
    ],
    workingDirectory: rootDir,
    environment: {'PATHEXT': '.COM;.EXE;.BAT;.CMD', ...environment},
  );
  final values = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  return values.map((key, value) => MapEntry(key, value as String));
}
