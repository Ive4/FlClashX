import 'dart:async';

final class OhosCoreRecovery {
  final Future<bool> Function() recover;
  final bool Function() shouldRecover;
  final Future<bool> Function() canRecover;
  final void Function(String event) record;
  final DateTime Function() _now;
  final _attempts = <DateTime>[];
  bool _pending = false;
  bool _foreground = false;
  bool _recovering = false;
  bool _disposed = false;

  OhosCoreRecovery({
    required this.recover,
    required this.shouldRecover,
    required this.record,
    Future<bool> Function()? canRecover,
    DateTime Function()? now,
  }) : canRecover = canRecover ?? (() async => true),
       _now = now ?? DateTime.now;

  void request() {
    if (_disposed || _recovering) return;
    _pending = true;
    record('recovery_requested');
    unawaited(_drain());
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_disposed || !_pending || _recovering) return;
    _pending = false;
    if (!shouldRecover()) {
      record('recovery_cancelled');
      return;
    }
    _recovering = true;
    try {
      final eligible = await canRecover();
      if (_disposed) return;
      if (!eligible || !shouldRecover()) {
        record('recovery_cancelled');
        return;
      }
      final now = _now();
      _attempts.removeWhere(
        (attempt) => now.difference(attempt) >= const Duration(minutes: 2),
      );
      if (_attempts.length >= 2) {
        record('recovery_rate_limited');
        return;
      }
      _attempts.add(now);
      if (!_foreground) record('recovery_in_background');
      record('recovery_started');
      final restored = await recover();
      if (!_disposed) {
        record(restored ? 'recovery_succeeded' : 'recovery_failed');
        if (!restored) _deferUntilForeground();
      }
    } catch (_) {
      if (!_disposed) {
        record('recovery_failed');
        _deferUntilForeground();
      }
    } finally {
      _recovering = false;
      if (_pending && _foreground) unawaited(_drain());
    }
  }

  void _deferUntilForeground() {
    if (!_foreground && shouldRecover()) {
      _pending = true;
      record('recovery_deferred_until_foreground');
    }
  }

  void dispose() {
    _disposed = true;
    _pending = false;
  }
}
