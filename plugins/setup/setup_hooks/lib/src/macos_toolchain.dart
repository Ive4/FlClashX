import 'error.dart';
import 'rust_core_builder.dart';
import 'target.dart';
import 'util.dart';

Map<String, String> macosBuildEnvironment(
  Target target, {
  Map<String, String> environment = const {},
  RustCommand command = runCommand,
}) {
  if (target.goos != 'darwin') return const {};
  var sdk = environment['SDKROOT'];
  if (sdk == null || sdk.isEmpty) {
    sdk =
        (command('xcrun', [
                  '--sdk',
                  'macosx',
                  '--show-sdk-path',
                ], environment: environment).stdout
                as String)
            .trim();
  }
  if (sdk.isEmpty) throw BuildException('Xcode returned no macOS SDK path');
  return {'SDKROOT': sdk};
}
