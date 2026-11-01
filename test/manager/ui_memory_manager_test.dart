import 'dart:ui' as ui;

import 'package:fl_clash/manager/ui_memory_manager.dart';
import 'package:fl_clash/widgets/icon.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late int imageBytes;
  late int svgEntries;

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    imageBytes = imageCache.maximumSizeBytes;
    svgEntries = svg.cache.maximumSize;
    clearTargetIconCache();
  });

  tearDown(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    imageCache.maximumSizeBytes = imageBytes;
    svg.cache.maximumSize = svgEntries;
    imageCache.clear();
    svg.cache.clear();
    setTargetIconCacheEnabled(true);
    clearTargetIconCache();
    readRemoteIcon = null;
  });

  Future<void> fillCaches() async {
    final picture = ui.PictureRecorder();
    Canvas(picture).drawColor(const Color(0xFFFFFFFF), BlendMode.src);
    final recorded = picture.endRecording();
    final image = recorded.toImageSync(4, 4);
    recorded.dispose();
    imageCache.putIfAbsent(
      Object(),
      () => OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: image)),
      ),
    );
    await svg.cache.putIfAbsent(Object(), () => SynchronousFuture(ByteData(8)));
  }

  testWidgets(
    'hidden caches clear without a frame and stay empty until shown',
    (tester) async {
      await tester.pumpWidget(const UiMemoryManager(child: SizedBox()));
      await fillCaches();
      expect(imageCache.currentSizeBytes, greaterThan(0));
      expect(svg.cache.count, 1);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      expect(imageCache.currentSizeBytes, 0);
      expect(svg.cache.count, 0);
      expect(imageCache.maximumSizeBytes, 0);
      expect(svg.cache.maximumSize, 0);
      await fillCaches();
      expect(imageCache.currentSizeBytes, 0);
      expect(svg.cache.count, 0);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(imageCache.maximumSizeBytes, imageBytes);
      expect(svg.cache.maximumSize, svgEntries);
      await fillCaches();
      expect(imageCache.currentSizeBytes, greaterThan(0));
      expect(svg.cache.count, 1);
    },
  );

  testWidgets('focus loss keeps caches while memory pressure clears them', (
    tester,
  ) async {
    await tester.pumpWidget(const UiMemoryManager(child: SizedBox()));
    await fillCaches();

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(imageCache.currentSizeBytes, greaterThan(0));
    expect(svg.cache.count, 1);
    binding.handleMemoryPressure();
    expect(imageCache.currentSizeBytes, 0);
    expect(svg.cache.count, 0);
    expect(imageCache.maximumSizeBytes, imageBytes);
    expect(svg.cache.maximumSize, svgEntries);
  });

  testWidgets('mounting hidden and disposing restores the original budgets', (
    tester,
  ) async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.scheduleForcedFrame();
    await tester.pumpWidget(const UiMemoryManager(child: SizedBox()));
    expect(imageCache.maximumSizeBytes, 0);
    expect(svg.cache.maximumSize, 0);

    binding.scheduleForcedFrame();
    await tester.pumpWidget(const SizedBox());
    expect(imageCache.maximumSizeBytes, imageBytes);
    expect(svg.cache.maximumSize, svgEntries);
  });

  testWidgets('backgrounding preserves text input and the navigation stack', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = TextEditingController(text: 'unsaved');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      UiMemoryManager(
        child: WidgetsApp(
          color: const Color(0xFFFFFFFF),
          navigatorKey: navigatorKey,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
          home: const SizedBox(),
        ),
      ),
    );
    final route = PageRouteBuilder<void>(
      pageBuilder: (context, _, _) => EditableText(
        controller: controller,
        focusNode: focusNode,
        style: const TextStyle(),
        cursorColor: const Color(0xFF000000),
        backgroundCursorColor: const Color(0xFFFFFFFF),
      ),
    );
    navigatorKey.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final state = tester.state(find.byType(EditableText));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(tester.state(find.byType(EditableText)), same(state));
    expect(controller.text, 'unsaved');
    expect(navigatorKey.currentState!.canPop(), isTrue);
  });
}
