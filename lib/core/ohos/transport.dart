import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../desktop/transport.dart';
import '../desktop/model.dart';
import 'diagnostics.dart';

final class OhosCoreTransport implements DesktopCoreTransport {
  @override
  String address;
  static CoreResumeState? resumeState;
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
    unawaited(OhosDiagnostics.record('transport_open'));
    if (await _resume()) {
      return;
    }
    if (_closeOperation != null) {
      throw StateError('HarmonyOS Core transport is closed');
    }
    final random = Random.secure();
    _token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    if (_closeOperation != null) {
      await server.close();
      throw StateError('HarmonyOS Core transport is closed');
    }
    _server = server;
    _server!.listen((socket) {
      if (_socket != null ||
          _closeOperation != null ||
          _candidates.length >= 8) {
        socket.destroy();
        return;
      }
      _candidates.add(socket);
      unawaited(
        socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
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
              'control': address,
            }),
            'control': address,
          }),
        })
        .then<void>((_) {})
        .catchError((Object error, StackTrace stack) {
          unawaited(
            OhosDiagnostics.record('transport_start_failed', error.toString()),
          );
          state = DesktopTransportState.failed;
          if (!_connected.isCompleted) _connected.completeError(error, stack);
          _events.add(TransportFailed(error, stack));
        });
  }

  Future<bool> _resume() async {
    if (!p.isAbsolute(address)) {
      return false;
    }
    final file = File(p.join(p.dirname(address), '.ohos-core-host.json'));
    if (!await file.exists()) {
      return false;
    }
    final snapshot = await file.readAsString();
    final record = jsonDecode(snapshot) as Map;
    final endpoint = record['address'];
    final token = record['token'];
    final control = record['control'];
    final uri = endpoint is String ? Uri.tryParse('tcp://$endpoint') : null;
    if (uri == null ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        token is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
        control is! String ||
        p.dirname(control) != p.dirname(address)) {
      throw const FormatException('Invalid HarmonyOS backend session');
    }
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        uri.port,
        timeout: const Duration(seconds: 3),
      );
    } on SocketException catch (error) {
      if (!const {61, 111, 1225, 10061}.contains(error.osError?.errorCode)) {
        rethrow;
      }
      await OhosDiagnostics.record('transport_resume_refused');
      if (_closeOperation != null) {
        throw StateError('HarmonyOS Core transport is closed');
      }
      if (await file.exists() && await file.readAsString() != snapshot) {
        throw StateError('HarmonyOS backend session changed during reconnect');
      }
      return false;
    }
    if (_closeOperation != null) {
      socket.destroy();
      throw StateError('HarmonyOS Core transport is closed');
    }
    address = control;
    _token = token;
    _candidates.add(socket);
    unawaited(
      socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    final reader = _readFrames(socket);
    _readers.add(reader);
    unawaited(reader.whenComplete(() => _readers.remove(reader)));
    final header = ByteData(4)..setUint32(0, 64, Endian.little);
    socket.add(header.buffer.asUint8List());
    socket.add(utf8.encode(token));
    await socket.flush();
    await _connected.future.timeout(const Duration(seconds: 3));
    await _channel.invokeMethod<bool>('resumeCore', {
      'control': control,
      'status': record['tunnelStatus'],
    });
    resumeState = CoreResumeState(
      coreReused: true,
      runningSince: switch (record['runningSince']) {
        final int value => DateTime.fromMillisecondsSinceEpoch(value),
        _ => null,
      },
    );
    return true;
  }

  static Future<void> enterLightweight(DateTime? runningSince) async {
    if (await _channel.invokeMethod<bool>('enterLightweight', {
          'runningSince': runningSince?.millisecondsSinceEpoch,
        }) !=
        true) {
      throw StateError('HarmonyOS backend did not accept lightweight mode');
    }
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
      unawaited(OhosDiagnostics.record('transport_connected'));
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
        state = DesktopTransportState.failed;
        unawaited(OhosDiagnostics.record('transport_failed', error.toString()));
        _events.add(TransportFailed(error, stack));
      }
    } finally {
      await chunks.cancel();
      socket.destroy();
      _candidates.remove(socket);
      if (identical(socket, _socket) &&
          _closeOperation == null &&
          !_events.isClosed) {
        state = DesktopTransportState.closed;
        unawaited(OhosDiagnostics.record('transport_disconnected'));
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
    unawaited(OhosDiagnostics.record('transport_close'));
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
