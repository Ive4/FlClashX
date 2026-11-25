import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _asset = 'package:go_api/src/bridge.dart';

@Native<
  Pointer<Uint8> Function(
    Pointer<Utf8>,
    Pointer<Uint8>,
    IntPtr,
    Pointer<Uint8>,
    IntPtr,
    Pointer<IntPtr>,
    Pointer<Uint8>,
  )
>(assetId: _asset, symbol: 'FlClashGoInvoke')
external Pointer<Uint8> _invokeNative(
  Pointer<Utf8> operation,
  Pointer<Uint8> request,
  int requestLength,
  Pointer<Uint8> data,
  int dataLength,
  Pointer<IntPtr> responseLength,
  Pointer<Uint8> responseKind,
);

@Native<Void Function(Pointer<Uint8>)>(assetId: _asset, symbol: 'FlClashGoFree')
external void _freeNative(Pointer<Uint8> address);

typedef _EventCallback = Void Function(Int64, Int32, Pointer<Uint8>, IntPtr);

@Native<Int64 Function(Pointer<NativeFunction<_EventCallback>>)>(
  assetId: _asset,
  symbol: 'FlClashGoOpenEvents',
)
external int _openNativeEvents(
  Pointer<NativeFunction<_EventCallback>> callback,
);

@Native<Void Function(Int64)>(assetId: _asset, symbol: 'FlClashGoCloseEvents')
external void _closeNativeEvents(int id);

final class GoApiException implements Exception {
  const GoApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class GoApi {
  GoApi._();

  static bool _initialized = false;
  static bool get isInitialized => _initialized;
  static final _subscriptions = <int, GoEvents>{};
  static final _eventCallback = NativeCallable<_EventCallback>.listener(
    _deliverEvent,
  )..keepIsolateAlive = false;

  static void initialize() {
    if (_initialized) return;
    if (invoke('bridge.version', null) != 1) {
      throw const GoApiException('Incompatible FlClash Go library');
    }
    _initialized = true;
  }

  static Object? invoke(String operation, Object? args, {Uint8List? bytes}) {
    return using((arena) {
      final request = utf8.encode(jsonEncode(args));
      final requestAddress = arena<Uint8>(request.length);
      requestAddress.asTypedList(request.length).setAll(0, request);
      final dataLength = bytes?.length ?? 0;
      final dataAddress = dataLength == 0 ? nullptr : arena<Uint8>(dataLength);
      if (dataLength != 0) {
        dataAddress.asTypedList(dataLength).setAll(0, bytes!);
      }
      final length = arena<IntPtr>();
      final kind = arena<Uint8>();
      final response = _invokeNative(
        operation.toNativeUtf8(allocator: arena),
        requestAddress,
        request.length,
        dataAddress,
        dataLength,
        length,
        kind,
      );
      try {
        final data = length.value == 0
            ? Uint8List(0)
            : response.asTypedList(length.value);
        return switch (kind.value) {
          0 => jsonDecode(utf8.decode(data)),
          1 => Uint8List.fromList(data),
          2 => throw GoApiException(utf8.decode(data)),
          _ => throw const GoApiException('Invalid Go library response'),
        };
      } finally {
        _freeNative(response);
      }
    });
  }

  static Future<Object?> invokeAsync(
    String operation,
    Object? args, {
    Uint8List? bytes,
  }) => Isolate.run(() => invoke(operation, args, bytes: bytes));

  static GoEvents openEvents() {
    final id = _openNativeEvents(_eventCallback.nativeFunction);
    final events = GoEvents._(id);
    _subscriptions[id] = events;
    return events;
  }

  static void _deliverEvent(
    int id,
    int kind,
    Pointer<Uint8> address,
    int length,
  ) {
    try {
      final events = _subscriptions[id];
      if (events != null) {
        final data = length == 0
            ? Uint8List(0)
            : Uint8List.fromList(address.asTypedList(length));
        events._events.add(GoEvent(kind, data));
      }
    } finally {
      _freeNative(address);
    }
  }
}

final class GoEvent {
  const GoEvent(this.kind, this.data);

  final int kind;
  final Uint8List data;
}

final class GoEvents {
  GoEvents._(this.id);

  final int id;
  final _events = StreamController<GoEvent>();

  Stream<GoEvent> get stream => _events.stream;

  void close() {
    if (GoApi._subscriptions.remove(id) == null) return;
    _closeNativeEvents(id);
    unawaited(_events.close());
  }
}
