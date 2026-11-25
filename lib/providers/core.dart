import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/common/common.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/core.g.dart';

@Riverpod(keepAlive: true)
CoreController coreHandler(Ref ref) => coreController;

@Riverpod(keepAlive: true)
class CoreStopReason extends _$CoreStopReason
    with AutoDisposeNotifierMixin<String?> {
  @override
  String? build() => null;
}
