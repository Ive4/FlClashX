import 'dart:io';

import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

class HelperBuilder {
  const HelperBuilder({
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

  Future<BuildExecution> build(Target target, String coreSha256) async {
    final source = p.join(rootDir, config.helperDir);
    final output = p.join(
      rootDir,
      config.outputDir,
      target.platformDir,
      '${config.helperName}${target.executableExtension}',
    );
    final environment = {
      'GOOS': target.goos,
      'GOARCH': target.goarch,
      'CGO_ENABLED': '0',
      'GOWORK': 'off',
    };
    final exe = '${config.coreName}${target.executableExtension}';
    final flags =
        '-s -w -X main.expectedCoreSHA256=$coreSha256 -X "main.coreName=$exe"';
    final args = ['build', '-mod=readonly', '-trimpath', '-ldflags=$flags'];
    return cache.run(
      key: '${target.platformDir}-${target.goarch}-helper-release',
      primaryOutput: output,
      notice: notice,
      fingerprint: () async {
        final inputs = Directory(source)
            .listSync()
            .whereType<File>()
            .where(
              (file) => const {
                '.go',
                '.mod',
                '.sum',
              }.contains(p.extension(file.path)),
            )
            .map((file) => file.path);
        final fingerprint = FingerprintBuilder(rootDir: rootDir)
          ..addValue('kind', 'go-helper')
          ..addValue('target', environment)
          ..addValue('arguments', args)
          ..addValue('config', config.toFingerprintMap())
          ..addValue(
            'go',
            runCommand(
              'go',
              [
                'env',
                '-json',
                'GOVERSION',
                'GOTOOLCHAIN',
                'GOFLAGS',
                'GOEXPERIMENT',
                'GOAMD64',
              ],
              workingDirectory: source,
              environment: environment,
            ).stdout,
          )
          ..addFiles([...inputs, ...harnessInputs]);
        return fingerprint.finishWithInputs();
      },
      build: () async {
        ensureDir(p.dirname(output));
        final staging = '$output.staging-$pid';
        try {
          await runCommandStream(
            'go',
            [...args, '-o', staging, '.'],
            workingDirectory: source,
            environment: environment,
          );
          replaceFile(staging, output);
          return [output];
        } finally {
          final staged = File(staging);
          if (staged.existsSync()) staged.deleteSync();
        }
      },
    );
  }
}
