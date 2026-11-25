import 'dart:io';

import 'package:path/path.dart' as p;

import 'fingerprint.dart';

typedef ToolchainCommand =
    ProcessResult Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

Map<String, Object> rustNativeTools(Map<String, String> environment) {
  final suffix = Platform.isWindows ? '.exe' : '';
  final directories = (environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  );
  final tools = <String, Object>{};
  for (final name in [
    'clang',
    'clang++',
    'cc',
    'c++',
    if (Platform.isWindows) ...['cl', 'link'],
  ]) {
    for (final directory in directories) {
      final file = File(p.join(directory, '$name$suffix'));
      if (!file.existsSync()) continue;
      final stat = file.statSync();
      tools[name] = {
        'path': file.path,
        'size': stat.size,
        'modified': stat.modified.microsecondsSinceEpoch,
      };
      break;
    }
  }
  return tools;
}

Map<String, String> rustBuildEnvironment(Map<String, String> environment) {
  const names = {
    'PATH',
    'PATHEXT',
    'SystemRoot',
    'SYSTEMROOT',
    'WINDIR',
    'ComSpec',
    'USERPROFILE',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'INCLUDE',
    'LIB',
    'LIBPATH',
    'RUSTC',
    'RUSTFLAGS',
    'RUSTUP_TOOLCHAIN',
    'RUSTC_WRAPPER',
    'RUSTC_WORKSPACE_WRAPPER',
    'SDKROOT',
    'DEVELOPER_DIR',
    'MACOSX_DEPLOYMENT_TARGET',
    'CC',
    'CXX',
    'AR',
    'CFLAGS',
    'CXXFLAGS',
    'CPPFLAGS',
    'LDFLAGS',
    'CC_SHELL_ESCAPED_FLAGS',
    'CARGO_HOME',
    'CARGO_ENCODED_RUSTFLAGS',
    'RUSTUP_HOME',
  };
  const prefixes = [
    'CARGO_PROFILE_',
    'CARGO_TARGET_',
    'CARGO_BUILD_',
    'CC_',
    'CXX_',
    'AR_',
    'CFLAGS_',
    'CXXFLAGS_',
    'CPPFLAGS_',
    'LDFLAGS_',
    'PKG_CONFIG',
  ];
  final keys =
      environment.keys
          .where((key) => names.contains(key) || prefixes.any(key.startsWith))
          .toList()
        ..sort();
  return {for (final key in keys) key: environment[key]!};
}

List<String> rustBuildInputs(
  String crate,
  String rootDir, {
  Map<String, String>? environment,
}) {
  final files = collectFiles(
    crate,
    excludedDirectories: const {'target', 'target-ohos', '.git', '.idea'},
  );
  for (final directory in {crate, rootDir}) {
    for (final name in const [
      '.cargo/config',
      '.cargo/config.toml',
      'rust-toolchain',
      'rust-toolchain.toml',
      'build_config.yaml',
      'tool/rust_windows.ps1',
    ]) {
      final file = p.join(directory, name);
      if (File(file).existsSync()) files.add(file);
    }
  }
  final buildEnvironment = environment ?? Platform.environment;
  final profileKey = Platform.isWindows ? 'USERPROFILE' : 'HOME';
  final cargoHome =
      buildEnvironment['CARGO_HOME'] ??
      p.join(
        buildEnvironment[profileKey] ?? Platform.environment[profileKey] ?? '',
        '.cargo',
      );
  for (final name in const ['config', 'config.toml']) {
    final file = p.join(cargoHome, name);
    if (File(file).existsSync()) files.add(file);
  }
  return files;
}
