import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/core/desktop/transport.dart';
import 'package:fl_clash/core/ohos/transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.follow.clash/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late OhosCoreTransport transport;
  final sockets = <Socket>[];
  var stops = 0;

  void send(Socket socket, List<int> payload) {
    final header = ByteData(4)..setUint32(0, payload.length, Endian.little);
    socket.add(header.buffer.asUint8List());
    socket.add(payload);
  }

  setUp(() {
    stops = 0;
    OhosCoreTransport.resumeState = null;
    transport = OhosCoreTransport('test-control');
  });

  tearDown(() async {
    OhosCoreTransport.resumeState = null;
    await transport.close();
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'lightweight restore attaches to the native backend without starting it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ohos_lightweight_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final accepted = Completer<Socket>();
      server.listen((socket) {
        sockets.add(socket);
        final bytes = <int>[];
        socket.listen((chunk) {
          bytes.addAll(chunk);
          if (!accepted.isCompleted && bytes.length >= 68) {
            expect(utf8.decode(bytes.sublist(4, 68)), token);
            send(socket, utf8.encode(token));
            accepted.complete(socket);
          }
        });
      });
      final oldControl = p.join(directory.path, 'old.control');
      await File(p.join(directory.path, '.ohos-core-host.json')).writeAsString(
        jsonEncode({
          'address': '127.0.0.1:${server.port}',
          'token': token,
          'control': oldControl,
          'tunnelStatus': '$oldControl.status',
          'runningSince': 12345,
        }),
      );
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'diagnostic') calls.add(call);
        return true;
      });
      final resumed = OhosCoreTransport(p.join(directory.path, 'new.control'));
      await resumed.open();
      await resumed.waitUntilConnected(const Duration(seconds: 2));
      expect(calls.where((call) => call.method == 'startCore'), isEmpty);
      expect(calls.single.method, 'resumeCore');
      expect(resumed.address, oldControl);
      expect(
        OhosCoreTransport.resumeState?.runningSince?.millisecondsSinceEpoch,
        12345,
      );
      final frame = resumed.frames.first;
      send(await accepted.future, utf8.encode('same Core'));
      expect(utf8.decode(await frame), 'same Core');
      await resumed.close();
    },
  );

  test('unauthenticated clients cannot take the Core connection', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'diagnostic') return null;
      if (call.method == 'stopCore') {
        stops++;
        return true;
      }
      final request =
          jsonDecode((call.arguments as Map)['request'] as String) as Map;
      final endpoint = jsonDecode(request['endpoint'] as String) as Map;
      final port = int.parse((endpoint['address'] as String).split(':').last);
      final impostor = await Socket.connect(InternetAddress.loopbackIPv4, port);
      sockets.add(impostor);
      send(impostor, utf8.encode('x' * 64));
      final core = await Socket.connect(InternetAddress.loopbackIPv4, port);
      sockets.add(core);
      send(core, utf8.encode(endpoint['token'] as String));
      return true;
    });
    final events = <DesktopTransportEvent>[];
    final subscription = transport.events.listen(events.add);
    addTearDown(subscription.cancel);
    await transport.open();
    await transport.waitUntilConnected(const Duration(seconds: 2));
    final frame = transport.frames.first;
    send(sockets.last, utf8.encode('valid response'));
    expect(utf8.decode(await frame), 'valid response');
    expect(events.whereType<TransportFailed>(), isEmpty);
    await transport.close();
    await transport.close();
    expect(stops, 1);
  });

  test('closing cancels a client that never sends authentication', () async {
    final connected = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'diagnostic') return null;
      if (call.method == 'stopCore') {
        stops++;
        return true;
      }
      final request =
          jsonDecode((call.arguments as Map)['request'] as String) as Map;
      final endpoint = jsonDecode(request['endpoint'] as String) as Map;
      final port = int.parse((endpoint['address'] as String).split(':').last);
      sockets.add(await Socket.connect(InternetAddress.loopbackIPv4, port));
      connected.complete();
      return true;
    });
    await transport.open();
    await connected.future;
    await transport.close().timeout(const Duration(seconds: 2));
    expect(stops, 1);
    expect(transport.state, DesktopTransportState.closed);
  });

  test(
    'Core exit releases the matching native session without a reply',
    () async {
      Map? stopArguments;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'diagnostic') return null;
        if (call.method == 'stopCore') {
          stopArguments = call.arguments as Map;
          return true;
        }
        final request =
            jsonDecode((call.arguments as Map)['request'] as String) as Map;
        final endpoint = jsonDecode(request['endpoint'] as String) as Map;
        final port = int.parse((endpoint['address'] as String).split(':').last);
        final core = await Socket.connect(InternetAddress.loopbackIPv4, port);
        sockets.add(core);
        send(core, utf8.encode(endpoint['token'] as String));
        return true;
      });
      await transport.open();
      await transport.waitUntilConnected(const Duration(seconds: 2));
      final disconnected = transport.events.firstWhere(
        (event) => event is TransportDisconnected,
      );
      sockets.single.destroy();
      await disconnected.timeout(const Duration(seconds: 2));
      await transport.close().timeout(const Duration(seconds: 2));
      expect(stopArguments, {'control': 'test-control', 'disconnected': true});
    },
  );
}
