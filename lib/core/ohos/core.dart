import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/core.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/services.dart';

import '../desktop/model.dart';
import '../desktop/rpc_client.dart';
import '../desktop/transport.dart';
import '../event.dart';
import '../interface.dart';
import '../method.dart';
import 'transport.dart';

final class OhosCore extends CoreHandlerInterface {
  static const vpnChannel = MethodChannel('com.follow.clash/vpn');
  OhosCoreTransport? _transport;
  CoreRpcClient? _rpc;
  StreamSubscription<DesktopTransportEvent>? _events;
  Future<void> _tail = Future.value();
  Future<CoreLifecycleResult>? _closeOperation;
  var _revision = 0;
  var _closed = false;

  Future<CoreLifecycleResult> _transition(
    bool running, {
    bool restart = false,
  }) {
    final revision = ++_revision;
    final operation = _tail.then((_) async {
      if (revision != _revision) {
        return CoreLifecycleResult(
          revision: revision,
          outcome: CoreLifecycleOutcome.superseded,
        );
      }
      final unchanged =
          !restart &&
          (running
              ? _transport?.state == DesktopTransportState.connected
              : _transport == null);
      if (!unchanged) {
        await _stop();
        if (running && revision == _revision) {
          final directory = await appPath.homeDirPath;
          await Directory(directory).create(recursive: true);
          final transport = OhosCoreTransport(
            '$directory/core-${DateTime.now().microsecondsSinceEpoch}-$revision.control',
          );
          _transport = transport;
          _rpc = CoreRpcClient(transport);
          _events = transport.events.listen((event) {
            if (event is TransportDisconnected || event is TransportFailed) {
              coreEventManager.sendEvent(
                const CoreEvent(
                  type: CoreEventType.crash,
                  data: 'HarmonyOS VPN Core disconnected',
                ),
              );
            }
          });
          try {
            await transport.open();
            await transport.waitUntilConnected(const Duration(seconds: 65));
          } catch (_) {
            await _stop();
            rethrow;
          }
        }
      }
      return CoreLifecycleResult(
        revision: revision,
        outcome: revision != _revision
            ? CoreLifecycleOutcome.superseded
            : unchanged
            ? CoreLifecycleOutcome.coalesced
            : CoreLifecycleOutcome.applied,
      );
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _stop() async {
    final transport = _transport;
    final rpc = _rpc;
    if (transport?.state == DesktopTransportState.connected) {
      await vpnChannel.invokeMethod<bool>('stop');
    }
    await _events?.cancel();
    _events = null;
    await transport?.close();
    await rpc?.close();
    _transport = null;
    _rpc = null;
  }

  @override
  Future<CoreLifecycleResult> start() {
    if (_closed) throw StateError('HarmonyOS Core is closed');
    return _transition(true);
  }

  @override
  Future<CoreLifecycleResult> restart() {
    if (_closed) throw StateError('HarmonyOS Core is closed');
    return _transition(true, restart: true);
  }

  @override
  Future<CoreLifecycleResult> stop() {
    if (_closed) return _closeOperation!;
    return _transition(false);
  }

  @override
  Future<bool> startListener() async {
    final options = await globalState.container.read(vpnOptionsProvider.future);
    if (!await super.startListener()) return false;
    if (!options.enable) return true;
    final transport = _transport;
    if (transport == null) throw StateError('HarmonyOS Core has not started');
    final access = options.accessControlProps;
    final accepts =
        access.enable && access.mode == AccessControlMode.acceptSelected;
    const ownBundle = 'com.follow.fl_clash';
    final accepted = accepts
        ? access.acceptList.where((name) => name != ownBundle).toSet().toList()
        : <String>[];
    final blocked = <String>{
      ownBundle,
      if (access.enable && !accepts) ...access.rejectList,
    }.toList();
    try {
      if (accepts && accepted.isEmpty) {
        throw StateError('Select at least one application for the VPN');
      }
      if (accepted.length > 256 || blocked.length > 256) {
        throw StateError(
          'HarmonyOS supports up to 256 applications per VPN list',
        );
      }
      final started = await vpnChannel.invokeMethod<bool>('start', {
        'request': jsonEncode({
          'status':
              '${transport.address}.${DateTime.now().microsecondsSinceEpoch}.status',
          'ipv6': options.ipv6,
          'dnsHijacking': options.dnsHijacking,
          'stack': options.stack,
          'mtu': options.mtu == 0 ? 1500 : options.mtu.clamp(576, 1500),
          'routes': options.routeAddress,
          'accepted': accepted,
          'blocked': blocked,
        }),
      });
      if (started != true) throw StateError('HarmonyOS VPN did not start');
      return true;
    } catch (_) {
      await super.stopListener();
      rethrow;
    }
  }

  @override
  Future<bool> stopListener() async {
    await vpnChannel.invokeMethod<bool>('stop');
    return super.stopListener();
  }

  @override
  Future<CoreLifecycleResult> close() {
    _closed = true;
    return _closeOperation ??= _transition(false);
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) {
    final rpc = _rpc;
    if (rpc == null) throw StateError('HarmonyOS Core has not started');
    return rpc.invoke<T>(
      method: method,
      arguments: arguments,
      timeout: timeout,
    );
  }
}
