import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

Future<void> buildOhos(BuildInput input, BuildOutputBuilder output) async {
  final architecture = input.config.code.targetArchitecture;
  if (architecture != Architecture.arm64) {
    throw UnsupportedError('The HarmonyOS build currently targets ARM64');
  }
  final compiler = File.fromUri(input.config.code.cCompiler!.compiler);
  final llvm = compiler.parent.parent;
  final native = llvm.parent;
  final target = Directory.fromUri(
    input.outputDirectoryShared.resolve('ohos/'),
  );
  await target.create(recursive: true);
  final linker = File('${target.path}/clang.cmd');
  await linker.writeAsString(
    '@echo off\r\n"${compiler.path}" --target=aarch64-linux-ohos '
    '--sysroot="${native.path}/sysroot" %*\r\n',
  );
  final crate = Directory.fromUri(input.packageRoot.resolve('rust/'));
  final result = await Process.run(
    'rustup',
    [
      'run',
      '1.99.0',
      'cargo',
      'build',
      '--locked',
      '--release',
      '--target',
      'aarch64-unknown-linux-ohos',
      '--target-dir',
      target.path,
    ],
    workingDirectory: crate.path,
    environment: {
      'CC_SHELL_ESCAPED_FLAGS': '1',
      'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER': linker.path,
      'CC_aarch64_unknown_linux_ohos': compiler.path,
      'AR_aarch64_unknown_linux_ohos': '${compiler.parent.path}/llvm-ar.exe',
      'CFLAGS_aarch64_unknown_linux_ohos':
          '--target=aarch64-linux-ohos --sysroot="${native.path}/sysroot"',
      'LIBCLANG_PATH': compiler.parent.path,
      'BINDGEN_EXTRA_CLANG_ARGS':
          '--target=aarch64-linux-ohos --sysroot="${native.path}/sysroot"',
    },
  );
  if (result.exitCode != 0) {
    throw StateError('HarmonyOS Rust build failed:\n${result.stderr}');
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/rust/frb_generated.io.dart',
      linkMode: DynamicLoadingBundled(),
      file: target.uri.resolve(
        'aarch64-unknown-linux-ohos/release/librust_api.so',
      ),
    ),
  );
  output.dependencies.addAll([
    for (final file in crate.listSync(recursive: true))
      if (file is File &&
          !file.path.contains('${Platform.pathSeparator}target'))
        file.uri,
  ]);
}
