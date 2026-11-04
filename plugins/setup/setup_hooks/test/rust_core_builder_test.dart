import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/build_cache.dart';
import 'package:setup_hooks/src/error.dart';
import 'package:setup_hooks/src/options.dart';
import 'package:setup_hooks/src/rust_core_builder.dart';
import 'package:setup_hooks/src/target.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File source;
  late Map<String, String> environment;
  late List<List<String>> invocations;
  late List<Map<String, String>> compileEnvironments;
  var failCompile = false;

  setUp(() {
    root = Directory.systemTemp.createTempSync('setup_rust_core_');
    source = File(p.join(root.path, 'core', 'rust', 'src', 'main.rs'));
    source.parent.createSync(recursive: true);
    source.writeAsStringSync('fn main() {}');
    File(
      p.join(root.path, 'core', 'rust', 'Cargo.toml'),
    ).writeAsStringSync('[package]\nname = "flclash-core"\n');
    File(
      p.join(root.path, 'core', 'rust', 'Cargo.lock'),
    ).writeAsStringSync('version = 4\n');
    environment = {'LIBCLANG_PATH': '/clang-a'};
    invocations = [];
    compileEnvironments = [];
    failCompile = false;
  });

  tearDown(() => root.deleteSync(recursive: true));

  RustCoreBuilder builder() => RustCoreBuilder(
    rootDir: root.path,
    config: BuildConfig.load(rootDir: root.path),
    cache: BuildCache(rootDir: root.path),
    notice: BuildNotice(),
    environment: environment,
    command: (executable, arguments, {workingDirectory, environment}) =>
        ProcessResult(
          0,
          0,
          executable == 'xcrun' ? '/Xcode/MacOSX.sdk' : '$executable 1.99.1',
          '',
        ),
    compile: (executable, arguments, {workingDirectory, environment}) async {
      expect(executable, 'cargo');
      expect(workingDirectory, p.join(root.path, 'core', 'rust'));
      invocations.add(arguments);
      compileEnvironments.add({...?environment});
      if (failCompile) throw BuildException('native compile failed');
      final target = arguments[arguments.indexOf('--target') + 1];
      final targetDir = arguments[arguments.indexOf('--target-dir') + 1];
      final extension = target.contains('windows') ? '.exe' : '';
      final output = File(
        p.join(targetDir, target, 'release', 'FlClashCore$extension'),
      );
      output.parent.createSync(recursive: true);
      output.writeAsStringSync('rust-core-${source.readAsStringSync()}');
    },
  );

  test(
    'builds and stages the locked Rust binary for each desktop triple',
    () async {
      for (final target in Target.all) {
        final result = await builder().build(target);
        expect(
          File(result.primaryOutput).readAsStringSync(),
          startsWith('rust-core-'),
        );
        expect(
          invocations.last,
          containsAllInOrder([
            'build',
            '--locked',
            '--release',
            '--bin',
            'FlClashCore',
            '--target',
            target.rustTriple,
          ]),
        );
      }
    },
  );

  test(
    'cache tracks Rust sources, lockfile, native flags, and Cargo config',
    () async {
      await builder().build(Target.windowsAmd64);
      expect((await builder().build(Target.windowsAmd64)).rebuilt, isFalse);
      source.writeAsStringSync('fn main() { panic!() }');
      expect((await builder().build(Target.windowsAmd64)).rebuilt, isTrue);
      File(
        p.join(root.path, 'core', 'rust', 'Cargo.lock'),
      ).writeAsStringSync('version = 3\n');
      expect((await builder().build(Target.windowsAmd64)).rebuilt, isTrue);
      environment['BINDGEN_EXTRA_CLANG_ARGS'] =
          '--target=x86_64-pc-windows-msvc';
      expect((await builder().build(Target.windowsAmd64)).rebuilt, isTrue);
      final config = File(p.join(root.path, '.cargo', 'config.toml'));
      config.parent.createSync();
      config.writeAsStringSync(
        '[build]\nrustflags = ["-Ctarget-cpu=generic"]\n',
      );
      expect((await builder().build(Target.windowsAmd64)).rebuilt, isTrue);
      expect(invocations, hasLength(5));
    },
  );

  test(
    'macOS resolves its SDK and fingerprints explicit SDK overrides',
    () async {
      environment['MACOSX_DEPLOYMENT_TARGET'] = '12.0';
      await builder().build(Target.macosArm64);
      expect(compileEnvironments.last['SDKROOT'], '/Xcode/MacOSX.sdk');
      expect(compileEnvironments.last['MACOSX_DEPLOYMENT_TARGET'], '12.0');
      expect((await builder().build(Target.macosArm64)).rebuilt, isFalse);
      environment['SDKROOT'] = '/another/MacOSX.sdk';
      expect((await builder().build(Target.macosArm64)).rebuilt, isTrue);
      expect(compileEnvironments.last['SDKROOT'], '/another/MacOSX.sdk');
    },
  );

  test(
    'failed Cargo build preserves the staged core and invalidates no cache',
    () async {
      final result = await builder().build(Target.linuxAmd64);
      final previous = File(result.primaryOutput).readAsBytesSync();
      source.writeAsStringSync('invalid Rust');
      failCompile = true;
      await expectLater(
        builder().build(Target.linuxAmd64),
        throwsA(isA<BuildException>()),
      );
      expect(File(result.primaryOutput).readAsBytesSync(), previous);
      failCompile = false;
      expect((await builder().build(Target.linuxAmd64)).rebuilt, isTrue);
    },
  );

  test('vendored dependency changes invalidate the Core cache', () async {
    final dependency = File(
      p.join(
        root.path,
        'core',
        'rust',
        'vendor',
        'meow-listener',
        'src',
        'lib.rs',
      ),
    );
    dependency.parent.createSync(recursive: true);
    dependency.writeAsStringSync('pub const GENERATION: usize = 1;');
    final first = await builder().build(Target.linuxAmd64);
    expect(first.inputs, contains(dependency.path));
    expect((await builder().build(Target.linuxAmd64)).rebuilt, isFalse);
    dependency.writeAsStringSync('pub const GENERATION: usize = 2;');
    expect((await builder().build(Target.linuxAmd64)).rebuilt, isTrue);
  });

  test('Cargo config follows the selected build environment', () async {
    final config = File(p.join(root.path, 'custom-cargo', 'config.toml'));
    config.parent.createSync();
    config.writeAsStringSync('[build]\nrustflags = ["-Copt-level=2"]\n');
    environment['CARGO_HOME'] = config.parent.path;
    final first = await builder().build(Target.windowsAmd64);
    expect(first.inputs, contains(config.path));
    expect((await builder().build(Target.windowsAmd64)).rebuilt, isFalse);
    config.writeAsStringSync('[build]\nrustflags = ["-Copt-level=3"]\n');
    expect((await builder().build(Target.windowsAmd64)).rebuilt, isTrue);
  });
}
