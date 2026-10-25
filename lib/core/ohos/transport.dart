import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../desktop/transport.dart';

final class OhosCoreTransport implements DesktopCoreTransport {
  @override
  final String address;
  @override
  DesktopTransportState state = DesktopTransportState.idle;
  final _events = StreamController<DesktopTransportEvent>.broadcast();
  final _frames = StreamController<Uint8List>.broadcast();
  final _connected = Completer<TransportConnected>();
  ServerSocket? _server;
  Socket? _socket;
  Future<void>? _run;
  final _readers = <Future<void>>{};
  Future<void>? _closeOperation;
  final _candidates = <Socket>{};
  late String _token;
  static const _channel = MethodChannel('com.follow.clash/vpn');

  OhosCoreTransport(this.address) {
    unawaited(
      _connected.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  @override
  Stream<DesktopTransportEvent> get events => _events.stream;
  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> open() async {
    if (state != DesktopTransportState.idle) {
      throw StateError('HarmonyOS Core transport already opened');
    }
    state = DesktopTransportState.starting;
    final random = Random.secure();
    _token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) {
      if (_socket != null ||
          _closeOperation != null ||
          _candidates.length >= 8) {
        socket.destroy();
        return;
      }
      _candidates.add(socket);
      final reader = _readFrames(socket);
      _readers.add(reader);
      unawaited(reader.whenComplete(() => _readers.remove(reader)));
    });
    _run = _channel
        .invokeMethod<bool>('startCore', {
          'request': jsonEncode({
            'endpoint': jsonEncode({
              'address': '127.0.0.1:${_server!.port}',
              'token': _token,
            }),
            'control': address,
          }),
        })
        .then<void>((_) {})
        .catchError((Object error, StackTrace stack) {
          state = DesktopTransportState.failed;
          if (!_connected.isCompleted) _connected.completeError(error, stack);
          _events.add(TransportFailed(error, stack));
        });
  }

  Future<void> _readFrames(Socket socket) async {
    final chunks = StreamIterator<Uint8List>(socket);
    Uint8List chunk = Uint8List(0);
    var offset = 0;
    Future<Uint8List?> read(int length) async {
      final result = Uint8List(length);
      var written = 0;
      while (written < length) {
        if (offset == chunk.length) {
          if (!await chunks.moveNext()) {
            if (written == 0) return null;
            throw const FormatException('Truncated Core frame');
          }
          chunk = chunks.current;
          offset = 0;
        }
        final count = (length - written).clamp(0, chunk.length - offset);
        result.setRange(written, written + count, chunk, offset);
        written += count;
        offset += count;
      }
      return result;
    }

    try {
      final authentication = await (() async {
        final header = await read(4);
        if (header == null ||
            ByteData.sublistView(header).getUint32(0, Endian.little) != 64) {
          return false;
        }
        final token = await read(64);
        return token != null && utf8.decode(token) == _token;
      })().timeout(const Duration(seconds: 5));
      if (!authentication || _socket != null || _closeOperation != null) return;
      _socket = socket;
      _candidates.remove(socket);
      state = DesktopTransportState.connected;
      const connection = TransportConnected(pid: null, generation: 1);
      _connected.complete(connection);
      _events.add(connection);
      while (_closeOperation == null) {
        final header = await read(4);
        if (header == null) break;
        final size = ByteData.sublistView(header).getUint32(0, Endian.little);
        if (size > 64 * 1024 * 1024) {
          throw const FormatException('Core frame exceeds 64 MiB');
        }
        final frame = await read(size);
        if (frame == null) throw const FormatException('Missing Core frame');
        _frames.add(frame);
      }
    } catch (error, stack) {
      if (_closeOperation == null && identical(socket, _socket)) {
        _events.add(TransportFailed(error, stack));
      }
    } finally {
      await chunks.cancel();
      socket.destroy();
      _candidates.remove(socket);
      if (identical(socket, _socket) && !_events.isClosed) {
        state = DesktopTransportState.closed;
        _events.add(const TransportDisconnected(1));
      }
    }
  }

  @override
  Future<TransportConnected> waitUntilConnected(Duration timeout) =>
      _connected.future.timeout(timeout);

  @override
  void send(List<int> frame) {
    if (state != DesktopTransportState.connected) {
      throw StateError('HarmonyOS Core is disconnected');
    }
    final header = ByteData(4)..setUint32(0, frame.length, Endian.little);
    _socket!.add(header.buffer.asUint8List());
    _socket!.add(frame);
  }

  @override
  Future<void> close() => _closeOperation ??= _close();

  Future<void> _close() async {
    final disconnected =
        state == DesktopTransportState.closed ||
        state == DesktopTransportState.failed;
    _socket?.destroy();
    for (final socket in _candidates.toList()) {
      socket.destroy();
    }
    await _server?.close();
    await Future.wait(_readers.toList());
    await _run;
    await _channel.invokeMethod<bool>('stopCore', {
      'control': address,
      'disconnected': disconnected,
    });
    state = DesktopTransportState.closed;
    await _events.close();
    await _frames.close();
  }
}
