import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets ||
      input.userDefines['build_assets'] == false) {
    return;
  }
  final code = input.config.code;
  final cc = code.cCompiler?.compiler.toFilePath();
  final ohos = cc?.toLowerCase().contains('openharmony') ?? false;
  final os = switch (code.targetOS) {
    _ when ohos => 'openharmony',
    OS.windows => 'windows',
    OS.linux => 'linux',
    OS.macOS => 'darwin',
    OS.android => 'android',
    _ => throw UnsupportedError('Go library target ${code.targetOS}'),
  };
  final arch = switch (code.targetArchitecture) {
    Architecture.x64 => 'amd64',
    Architecture.arm64 => 'arm64',
    Architecture.arm => 'arm',
    Architecture.ia32 => '386',
    _ => throw UnsupportedError('Go library target ${code.targetArchitecture}'),
  };
  final native = Directory.fromUri(input.packageRoot.resolve('native/'));
  final directory = Directory.fromUri(input.outputDirectory);
  await directory.create(recursive: true);
  final library = directory.uri.resolve(switch (os) {
    'windows' => 'flclash_go.dll',
    'darwin' => 'libflclash_go.dylib',
    _ => 'libflclash_go.so',
  });

  final separator = Platform.isWindows ? ';' : ':';
  final paths = [
    ...(Platform.environment['PATH'] ?? '').split(separator),
    if (!Platform.isWindows) ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/local/go/bin',
      if (Platform.environment['HOME'] case final home?)
        p.join(home, 'go', 'bin'),
    ],
  ];
  final environment = <String, String>{
    'GOOS': os,
    'GOARCH': arch,
    'CGO_ENABLED': '1',
    'GOWORK': 'off',
    'PATH': paths.join(separator),
  };
  final go =
      _find(paths, 'go') ??
      (throw StateError('Go is required to build the FlClash native library'));
  output.dependencies.add(File(go).uri);
  if (os == 'windows') {
    final target = arch == 'arm64' ? 'aarch64' : 'x86_64';
    final compiler =
        _find(paths, '$target-w64-mingw32-clang') ??
        (throw StateError(
          'LLVM MinGW is required. Run tool/setup_windows_go_cgo.ps1',
        ));
    _setCompiler(compiler, environment, output);
  } else if (os == 'android') {
    final api = code.android.targetNdkApi;
    final target = switch (arch) {
      'amd64' => 'x86_64-linux-android',
      'arm64' => 'aarch64-linux-android',
      'arm' => 'armv7a-linux-androideabi',
      _ => 'i686-linux-android',
    };
    if (cc == null) {
      throw StateError('Flutter did not provide an Android NDK compiler');
    }
    _setCompiler(cc, environment, output);
    environment['CGO_CFLAGS'] = '--target=$target$api';
    environment['CGO_LDFLAGS'] = '--target=$target$api';
  } else if (ohos) {
    final compiler = p.join(p.dirname(go), 'ohos-clang.cmd');
    _setCompiler(compiler, environment, output);
    environment['GOTOOLCHAIN'] = 'local';
  } else {
    final compiler = cc ?? _find(paths, os == 'darwin' ? 'clang' : 'cc');
    if (compiler == null) {
      throw StateError('A C compiler is required to build the FlClash library');
    }
    _setCompiler(compiler, environment, output);
    if (os == 'darwin') {
      final flags = '-mmacosx-version-min=${code.macOS.targetVersion}.0';
      environment['CGO_CFLAGS'] = flags;
      environment['CGO_LDFLAGS'] = flags;
    }
  }

  final result = await Process.run(
    go,
    [
      'build',
      '-mod=readonly',
      '-buildmode=c-shared',
      '-trimpath',
      if (ohos) '-tags=flclash_ohos',
      '-ldflags=-s -w',
      '-o',
      library.toFilePath(),
      '.',
    ],
    workingDirectory: native.path,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'FlClash Go library build failed:\n${result.stdout}${result.stderr}',
    );
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/bridge.dart',
      linkMode: DynamicLoadingBundled(),
      file: library,
    ),
  );
  output.dependencies.addAll([
    for (final file in native.listSync(recursive: true).whereType<File>())
      if (const {
        '.go',
        '.mod',
        '.sum',
        '.c',
        '.h',
        '.m',
      }.contains(p.extension(file.path)))
        file.uri,
  ]);
});

void _setCompiler(
  String compiler,
  Map<String, String> environment,
  BuildOutputBuilder output,
) {
  if (!File(compiler).existsSync()) {
    throw StateError('C compiler does not exist: $compiler');
  }
  environment['CC'] = '"$compiler"';
  output.dependencies.add(File(compiler).uri);
}

String? _find(List<String> paths, String name) {
  for (final dir in paths) {
    if (dir.isEmpty) continue;
    final path = p.join(dir, Platform.isWindows ? '$name.exe' : name);
    if (File(path).existsSync()) return path;
  }
  return null;
}
