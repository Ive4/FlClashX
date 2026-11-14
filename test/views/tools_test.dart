import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/tools.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets(
    'Tools uses the original access-control entry without advanced routing',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          moreToolsSelectorStateProvider.overrideWith(
            (_) => const MoreToolsSelectorState(navigationItems: []),
          ),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TestApp(child: ToolsView()),
        ),
      );
      await tester.pumpAndSettle();
      final supported =
          system.isAndroid ||
          system.isOhos ||
          system.isWindows ||
          system.isMacOS;
      expect(
        find.text(currentAppLocalizations.accessControl),
        supported ? findsOneWidget : findsNothing,
      );
      expect(
        container.read(vpnSettingProvider).accessControlProps.enable,
        isFalse,
      );
      expect(
        container.read(networkSettingProvider).toJson().keys,
        isNot(contains('applicationProxyEnabled')),
      );
    },
  );
}
