import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'application.dart';
import 'bootstrap.dart';
import 'common/app_data.dart';
import 'common/common.dart';
import 'common/preferences_store.dart';
import 'common/window.dart';
import 'common/system_dns.dart';
import 'core/desktop/background_client.dart';

void main(List<String> args) {
  if (args.contains('--safe-instance') && !safeModeBuild) {
    exit(64);
  }
  desktopBackground.showOnLaunch = args.contains('--show');
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      LicenseRegistry.addLicense(() async* {
        final license = await rootBundle.loadString(
          'assets/data/meow-rs-license.txt',
        );
        yield LicenseEntryWithLineBreaks(['meow-rs'], license);
      });
      if (Platform.isWindows || Platform.isLinux || system.isOhos) {
        SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
          appPath.sharedPreferencesPath,
        );
      }
      if (Platform.isLinux) {
        linkManager.seedInitialLink(args);
      }
      if (args.contains('--lightweight-cleanup') && system.isDesktop) {
        try {
          if (!safeModeBuild) {
            if (args.contains('--proxy') && await proxy?.stopProxy() == false) {
              exit(1);
            }
            await systemDnsCoordinator?.shutdown();
            if (await preferences.getSystemDnsRecord() != null) {
              exit(1);
            }
          }
          exit(0);
        } catch (_) {
          exit(1);
        }
      }
      FlutterError.onError = (details) {
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      try {
        await RustLib.init();
        final version = await system.init();
        final container = await bootstrap.init(version);
        await desktopBackground.inspectExisting();
        await FlClashHttpOverrides.trustCoreRoots();
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        runApp(
          UncontrolledProviderScope(
            container: container,
            child: const Application(),
          ),
        );
      } catch (e, s) {
        runApp(
          InitErrorApp(
            error: e,
            stack: s,
            onClearData: clearAppData,
            onExit: _exitAfterInitFailure,
          ),
        );
        unawaited(window?.showInitFailure(onExit: _exitAfterInitFailure));
      }
    },
    (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

Future<void> _exitAfterInitFailure() async {
  await system.exit();
  window?.forceExit();
}
