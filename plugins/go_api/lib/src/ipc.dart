import 'dart:convert';
import 'dart:typed_data';

import 'bridge.dart';

enum IpcEventKind { connected, message, disconnected, failed }

final class IpcEvent {
  const IpcEvent({
    required this.kind,
    this.pid,
    required this.payload,
    this.error,
  });

  final IpcEventKind kind;
  final int? pid;
  final Uint8List payload;
  final String? error;
}

abstract interface class IpcServer {
  static Future<IpcServer> bind({required String address}) async {
    final events = GoApi.openEvents();
    try {
      final id = await GoApi.invokeAsync('ipc.bind', {
        'address': address,
        'events': events.id,
      });
      return _GoIpcServer(id as int, events);
    } catch (_) {
      events.close();
      rethrow;
    }
  }

  Stream<IpcEvent> events();

  void send({required List<int> message});

  Future<void> close();
}

final class _GoIpcServer implements IpcServer {
  _GoIpcServer(this._id, this._nativeEvents);

  final int _id;
  final GoEvents _nativeEvents;
  Future<void>? _closing;

  @override
  Stream<IpcEvent> events() async* {
    try {
      await for (final event in _nativeEvents.stream) {
        final decoded = _decodeEvent(event);
        yield decoded;
        if (decoded.kind == IpcEventKind.failed) {
          return;
        }
      }
    } finally {
      await close();
    }
  }

  static IpcEvent _decodeEvent(GoEvent event) {
    final kind = IpcEventKind.values[event.kind - 1];
    if (kind == IpcEventKind.message) {
      return IpcEvent(kind: kind, payload: event.data);
    }
    final pid = kind == IpcEventKind.connected
        ? ByteData.sublistView(event.data).getUint32(0, Endian.little)
        : 0;
    return IpcEvent(
      kind: kind,
      pid: pid == 0 ? null : pid,
      payload: Uint8List(0),
      error: kind == IpcEventKind.connected || event.data.isEmpty
          ? null
          : utf8.decode(event.data),
    );
  }

  @override
  void send({required List<int> message}) {
    if (_closing != null) {
      throw StateError('IPC server is closed');
    }
    GoApi.invoke('ipc.send', {
      'id': _id,
    }, bytes: message is Uint8List ? message : Uint8List.fromList(message));
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await GoApi.invokeAsync('ipc.close', {'id': _id});
    } finally {
      _nativeEvents.close();
    }
  }
}
