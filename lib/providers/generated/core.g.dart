// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../core.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(coreHandler)
final coreHandlerProvider = CoreHandlerProvider._();

final class CoreHandlerProvider
    extends $FunctionalProvider<CoreController, CoreController, CoreController>
    with $Provider<CoreController> {
  CoreHandlerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'coreHandlerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$coreHandlerHash();

  @$internal
  @override
  $ProviderElement<CoreController> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  CoreController create(Ref ref) {
    return coreHandler(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CoreController value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CoreController>(value),
    );
  }
}

String _$coreHandlerHash() => r'b00cbd733d546e4edd1a0b9b98e9ace46da1eff2';

@ProviderFor(CoreStopReason)
final coreStopReasonProvider = CoreStopReasonProvider._();

final class CoreStopReasonProvider
    extends $NotifierProvider<CoreStopReason, String?> {
  CoreStopReasonProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'coreStopReasonProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$coreStopReasonHash();

  @$internal
  @override
  CoreStopReason create() => CoreStopReason();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String?>(value),
    );
  }
}

String _$coreStopReasonHash() => r'36b7fbff2428bab5ecbb0c2c7ce37e040cfe57e2';

abstract class _$CoreStopReason extends $Notifier<String?> {
  String? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<String?, String?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<String?, String?>,
              String?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
