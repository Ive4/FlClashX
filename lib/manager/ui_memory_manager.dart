import 'package:fl_clash/widgets/icon.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

class UiMemoryManager extends StatefulWidget {
  const UiMemoryManager({super.key, required this.child});

  final Widget child;

  @override
  State<UiMemoryManager> createState() => _UiMemoryManagerState();
}

class _UiMemoryManagerState extends State<UiMemoryManager>
    with WidgetsBindingObserver {
  late final int _imageCacheBytes;
  late final int _svgCacheEntries;
  bool? _visible;

  @override
  void initState() {
    super.initState();
    _imageCacheBytes = imageCache.maximumSizeBytes;
    _svgCacheEntries = svg.cache.maximumSize;
    WidgetsBinding.instance.addObserver(this);
    didChangeAppLifecycleState(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _setVisible(switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      _ => false,
    });
  }

  void _setVisible(bool visible) {
    if (_visible == visible) {
      return;
    }
    _visible = visible;
    setTargetIconCacheEnabled(visible);
    // Zero budgets also prevent in-flight loads from refilling hidden caches.
    imageCache.maximumSizeBytes = visible ? _imageCacheBytes : 0;
    svg.cache.maximumSize = visible ? _svgCacheEntries : 0;
  }

  @override
  void didHaveMemoryPressure() {
    imageCache.clear();
    svg.cache.clear();
    clearTargetIconCache();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setVisible(true);
    super.dispose();
  }
}
