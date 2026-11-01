import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('rust_core_builder');

typedef RustCommand =
    ProcessResult Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

typedef RustCompile =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

class RustCoreBuilder {
  RustCoreBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    this.harnessInputs = const [],
    this.command = runCommand,
    this.compile = runCommandStream,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;
  final RustCommand command;
  final RustCompile compile;
  final Map<String, String> environment;

  String get _crate => p.normalize(p.join(rootDir, config.coreDir));

  Future<BuildExecution> build(Target target) async {
    final triple = target.rustTriple;
    final cargoTarget = p.normalize(
      p.absolute(
        environment['FLCLASH_CORE_TARGET_DIR'] ?? p.join(_crate, 'target'),
      ),
    );
    final arguments = [
      'build',
      '--locked',
      '--release',
      '--bin',
      'FlClashCore',
      '--target',
      triple,
      '--target-dir',
      cargoTarget,
      if (config.coreFeatures.isNotEmpty) ...[
        '--features',
        config.coreFeatures,
      ],
    ];
    final fileName = '${config.coreName}${target.executableExtension}';
    final destination = p.join(
      rootDir,
      config.outputDir,
      target.platformDir,
      fileName,
    );
    return cache.run(
      key: '${target.platformDir}-${target.goarch}-rust-core',
      fingerprint: () async {
        final fingerprint = FingerprintBuilder(rootDir: rootDir)
          ..addValue('cache_schema', BuildCache.schemaVersion)
          ..addValue('kind', 'rust-core')
          ..addValue('target', triple)
          ..addValue('arguments', arguments)
          ..addValue('config', config.toFingerprintMap())
          ..addValue('environment', rustBuildEnvironment(environment))
          ..addValue('native_tools', rustNativeTools(environment));
        for (final tool in const ['cargo', 'rustc']) {
          fingerprint.addValue(
            tool,
            command(
              tool,
              tool == 'rustc' ? ['-Vv'] : ['--version', '--verbose'],
              workingDirectory: _crate,
              environment: rustBuildEnvironment(environment),
            ).stdout,
          );
        }
        fingerprint.addFiles([
          ...rustBuildInputs(_crate, rootDir),
          ...harnessInputs,
        ]);
        return fingerprint.finishWithInputs();
      },
      primaryOutput: destination,
      notice: notice,
      build: () async {
        _log.info('Building Rust core: $target ($triple)');
        await compile(
          'cargo',
          arguments,
          workingDirectory: _crate,
          environment: rustBuildEnvironment(environment),
        );
        final built = p.join(
          cargoTarget,
          triple,
          'release',
          'FlClashCore${target.executableExtension}',
        );
        copyFile(built, destination);
        _log.info('Built: $destination');
        return [destination];
      },
    );
  }
}

Map<String, Object> rustNativeTools(Map<String, String> environment) {
  final suffix = Platform.isWindows ? '.exe' : '';
  final directories = (environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  );
  final tools = <String, Object>{};
  for (final name in [
    'cmake',
    'nasm',
    'clang',
    'clang++',
    'cc',
    'c++',
    'llvm-ar',
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
  final libclang = environment['LIBCLANG_PATH'];
  if (libclang != null) {
    final directory = Directory(libclang);
    if (directory.existsSync()) {
      for (final file in directory.listSync().whereType<File>().where(
        (file) => p.basename(file.path).startsWith('libclang.'),
      )) {
        final stat = file.statSync();
        tools[file.path] = {
          'size': stat.size,
          'modified': stat.modified.microsecondsSinceEpoch,
        };
      }
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
    'LIBCLANG_PATH',
    'SDKROOT',
    'DEVELOPER_DIR',
    'MACOSX_DEPLOYMENT_TARGET',
    'ANDROID_NDK_HOME',
    'OHOS_NDK_HOME',
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
    'FLCLASH_CORE_TARGET_DIR',
  };
  const prefixes = [
    'CARGO_PROFILE_',
    'CARGO_TARGET_',
    'CARGO_BUILD_',
    'CMAKE_',
    'BORING_',
    'BINDGEN_',
    'CC_',
    'CXX_',
    'AR_',
    'CFLAGS_',
    'CXXFLAGS_',
    'CPPFLAGS_',
    'LDFLAGS_',
    'NASM',
    'PKG_CONFIG',
  ];
  final keys =
      environment.keys
          .where((key) => names.contains(key) || prefixes.any(key.startsWith))
          .toList()
        ..sort();
  return {for (final key in keys) key: environment[key]!};
}

List<String> rustBuildInputs(String crate, String rootDir) {
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
  final cargoHome =
      Platform.environment['CARGO_HOME'] ??
      p.join(
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '',
        '.cargo',
      );
  for (final name in const ['config', 'config.toml']) {
    final file = p.join(cargoHome, name);
    if (File(file).existsSync()) files.add(file);
  }
  return files;
}
