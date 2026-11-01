import 'package:fl_clash/models/models.dart';
import 'package:flutter/services.dart';

abstract final class OhosBackgroundTransfer {
  static const _channel = MethodChannel('com.follow.clash/vpn');

  static Future<void> update(Traffic traffic) async {
    try {
      await _channel.invokeMethod<void>('updateTransfer', {
        'up': traffic.up.toInt(),
        'down': traffic.down.toInt(),
      });
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
