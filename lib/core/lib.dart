import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'desktop/model.dart';
import 'interface.dart';
import 'method.dart';
import 'spill.dart';

class CoreLib extends CoreHandlerInterface {
  static CoreLib? _instance;

  final Service? _service;

  Completer<bool> _connectedCompleter = Completer<bool>();
  Future<CoreLifecycleResult>? _closeOperation;
  Future<void> _lastOperation = Future<void>.value();
  int _lifecycleRevision = 0;
  int _methodCallId = 0;
  bool _wantsSession = false;
  bool _closed = false;

  CoreLib._internal() : _service = service;

  @visibleForTesting
  CoreLib.scoped(Service this._service);

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  Future<CoreLifecycleResult> _enqueue(
    Future<CoreLifecycleResult> Function(int revision) transition,
  ) {
    final revision = ++_lifecycleRevision;
    final result = _lastOperation.then((_) => transition(revision));
    _lastOperation = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<CoreLifecycleResult> start() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    _wantsSession = true;
    return _enqueue(_start);
  }

  Future<CoreLifecycleResult> _start(int revision) async {
    if (!_wantsSession) {
      return _superseded(revision);
    }
    if (_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    final initializationError = await _service?.init() ?? '';
    if (initializationError.isNotEmpty) {
      throw StateError(initializationError);
    }
    try {
      await globalState.container.read(vpnOptionsProvider.future);
      if (_wantsSession) {
        _connectedCompleter.complete(true);
        final syncError =
            await _service?.syncState(
              globalState.container.read(sharedStateProvider),
            ) ??
            '';
        if (syncError.isNotEmpty) {
          throw StateError(syncError);
        }
      }
    } catch (_) {
      await _disconnect();
      rethrow;
    }
    if (!_wantsSession) {
      if (!_connectedCompleter.isCompleted) {
        await _disconnect();
      }
      return _superseded(revision);
    }
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  CoreLifecycleResult _superseded(int revision) => CoreLifecycleResult(
    revision: revision,
    outcome: CoreLifecycleOutcome.superseded,
  );

  @override
  Future<CoreLifecycleResult> restart() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    _wantsSession = true;
    return _enqueue((revision) async {
      if (!_wantsSession) {
        return _superseded(revision);
      }
      await _stop(revision);
      return _start(revision);
    });
  }

  @override
  Future<CoreLifecycleResult> stop() {
    if (_closed) {
      return Future.error(StateError('Core lifecycle is closed'));
    }
    _wantsSession = false;
    return _enqueue(
      (revision) async =>
          _wantsSession ? _superseded(revision) : _stop(revision),
    );
  }

  Future<CoreLifecycleResult> _stop(int revision) async {
    if (!_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    await _disconnect();
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  Future<void> _disconnect() async {
    _connectedCompleter = Completer<bool>();
    if (!(await _service?.shutdown() ?? true)) {
      throw StateError('Android Core service shutdown failed');
    }
  }

  @override
  Future<CoreLifecycleResult> close() {
    return _closeOperation ??= _close();
  }

  Future<CoreLifecycleResult> _close() {
    _closed = true;
    _wantsSession = false;
    return _enqueue(_stop);
  }

  // The service opens and closes the Core's listeners itself and reports a run
  // that ends, so once it takes the command the Core's own answer is moot.
  @override
  Future<bool> startListener() async {
    await super.startListener();
    return await _service?.start() ?? false;
  }

  @override
  Future<bool> stopListener() async {
    final serviceStopped = await _service?.stop() ?? false;
    await super.stopListener();
    return serviceStopped;
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) {
    final call = _invokeMethod<T>(
      method: method,
      arguments: arguments,
      model: model,
    );
    return call.withTimeout(
      timeout: timeout,
      onTimeout: () {
        unawaited(call.then(discardSpilledFile, onError: (_) {}));
        return null;
      },
    );
  }

  Future<T?> _invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    CoreResultModel? model,
  }) async {
    try {
      await _connectedCompleter.future.timeout(coreConnectionWaitDuration);
    } catch (error) {
      commonPrint.log(
        'Invoke method ${method.name} before connection timed out: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
    final id = '${++_methodCallId}';
    final response = await _service?.invokeMethod(
      CoreMethodCall(id: id, method: method, arguments: arguments),
      model: model,
    );
    if (response == null) {
      return null;
    }
    return response.unwrap<T>();
  }
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
