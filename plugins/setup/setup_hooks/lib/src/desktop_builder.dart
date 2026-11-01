import 'dart:io';

import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

class DesktopBuilder {
  const DesktopBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    required this.harnessInputs,
  });

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;

  Future<BuildExecution> build(Target target) async {
    final source = p.join(rootDir, 'services', 'desktop');
    final output = p.join(
      rootDir,
      config.outputDir,
      target.platformDir,
      'FlClashDesktop${target.executableExtension}',
    );
    final environment = {
      'GOOS': target.goos,
      'GOARCH': target.goarch,
      'CGO_ENABLED': target.goos == 'darwin' ? '1' : '0',
    };
    final flags = '-s -w${target.goos == 'windows' ? ' -H=windowsgui' : ''}';
    final arguments = [
      'build',
      '-trimpath',
      '-ldflags=$flags',
      '-o',
      output,
      '.',
    ];
    return cache.run(
      key: '${target.platformDir}-${target.goarch}-desktop',
      primaryOutput: output,
      notice: notice,
      fingerprint: () async {
        final files = Directory(source)
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.go') ||
                  file.path.endsWith('go.mod') ||
                  file.path.endsWith('go.sum'),
            )
            .map((file) => file.path)
            .toList();
        final fingerprint = FingerprintBuilder(rootDir: rootDir)
          ..addValue('target', environment)
          ..addValue('arguments', arguments)
          ..addValue('go', runCommand('go', ['version']).stdout)
          ..addFiles([...files, ...harnessInputs]);
        return fingerprint.finishWithInputs();
      },
      build: () async {
        final staging = '$output.staging-$pid';
        try {
          await runCommandStream(
            'go',
            ['build', '-trimpath', '-ldflags=$flags', '-o', staging, '.'],
            workingDirectory: source,
            environment: environment,
          );
          replaceFile(staging, output);
          return [output];
        } finally {
          final staged = File(staging);
          if (staged.existsSync()) {
            staged.deleteSync();
          }
        }
      },
    );
  }
}
