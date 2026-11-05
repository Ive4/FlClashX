import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/switch.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:fl_clash/views/tools.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('Tools offers application routing as an opt-in setting', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        appSettingProvider.overrideWithBuild((_, _) => const AppSettingProps()),
        networkSettingProvider.overrideWithBuild(
          (_, _) => const NetworkProps(),
        ),
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
    expect(find.text('Application proxy'), findsOneWidget);
    expect(
      tester.widget<CommonSwitch>(find.byType(CommonSwitch)).value,
      isFalse,
    );
    expect(
      Navigation().getItems().any(
        (item) => item.label == PageLabel.applicationProxy,
      ),
      isFalse,
    );
    await tester.tap(find.text('Application proxy'));
    await tester.pumpAndSettle();
    expect(
      container.read(networkSettingProvider).applicationProxyEnabled,
      isTrue,
    );
    expect(
      Navigation()
          .getItems(applicationProxyEnabled: true)
          .any((item) => item.label == PageLabel.applicationProxy),
      isTrue,
    );
    await tester.tap(find.text('Application proxy'));
    await tester.pumpAndSettle();
    expect(
      container.read(networkSettingProvider).applicationProxyEnabled,
      isFalse,
    );
  });
}
