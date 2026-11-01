import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'rust_core_builder.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('rust_builder');

class RustBuilder {
  RustBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    this.harnessInputs = const [],
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;
  final Map<String, String> environment;

  String get _helperPath => p.join(rootDir, config.helperDir);
  String get _outputPath => p.join(rootDir, config.outputDir);

  Future<BuildExecution> build(Target target, String coreSha256) async {
    final triple = target.rustTriple;
    final targetDirectory = p.normalize(p.join(_helperPath, 'target'));
    final args = [
      'build',
      '--locked',
      '--target',
      triple,
      '--target-dir',
      targetDirectory,
      if (target.goos == 'windows') ...['--features', 'windows-service'],
      '--release',
    ];
    final env = {
      ...rustBuildEnvironment(environment),
      'CORE_SHA256': coreSha256,
      'CORE_NAME': '${config.coreName}${target.executableExtension}',
    };

    final srcPath = p.join(
      targetDirectory,
      triple,
      'release',
      'helper${target.executableExtension}',
    );
    final destDir = p.join(_outputPath, target.platformDir);
    final destPath = p.join(
      destDir,
      '${config.helperName}${target.executableExtension}',
    );
    return cache.run(
      key: '${target.platformDir}-${target.goarch}-helper-release',
      fingerprint: () => _calculateFingerprint(
        target: target,
        coreSha256: coreSha256,
        args: args,
      ),
      primaryOutput: destPath,
      notice: notice,
      build: () async {
        _log.info('Building Rust helper: $target');

        await runCommandStream(
          'cargo',
          args,
          workingDirectory: _helperPath,
          environment: env,
        );

        ensureDir(destDir);
        copyFile(srcPath, destPath);

        _log.info('Built: $destPath');
        return [destPath];
      },
    );
  }

  Future<Fingerprint> _calculateFingerprint({
    required Target target,
    required String coreSha256,
    required List<String> args,
  }) async {
    final builder = FingerprintBuilder(rootDir: rootDir)
      ..addValue('cache_schema', BuildCache.schemaVersion)
      ..addValue('kind', 'helper')
      ..addValue('target', {'goos': target.goos, 'goarch': target.goarch})
      ..addValue('arguments', args)
      ..addValue('core_sha256', coreSha256)
      ..addValue('environment', rustBuildEnvironment(environment))
      ..addValue('native_tools', rustNativeTools(environment))
      ..addValue('config', config.toFingerprintMap());

    final cargoVersion = runCommand(
      'cargo',
      ['--version'],
      workingDirectory: _helperPath,
      environment: rustBuildEnvironment(environment),
    );
    builder.addValue('cargo_version', (cargoVersion.stdout as String).trim());
    final rustVersion = runCommand(
      'rustc',
      ['-Vv'],
      workingDirectory: _helperPath,
      environment: rustBuildEnvironment(environment),
    );
    builder.addValue('rustc_version', (rustVersion.stdout as String).trim());

    final inputs = rustBuildInputs(
      _helperPath,
      rootDir,
      environment: environment,
    )..addAll(harnessInputs);
    builder.addFiles(inputs);
    return builder.finishWithInputs();
  }
}
