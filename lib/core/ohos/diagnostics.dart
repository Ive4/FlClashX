import 'package:flutter/services.dart';

abstract final class OhosDiagnostics {
  static const _channel = MethodChannel('com.follow.clash/vpn');

  static Future<void> record(String event, [String detail = '']) async {
    try {
      await _channel.invokeMethod<void>('diagnostic', {
        'event': event,
        'detail': detail,
      });
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  static Future<String> read() async {
    try {
      return await _channel.invokeMethod<String>('diagnostics') ?? '';
    } on PlatformException catch (error) {
      return '[HarmonyOS diagnostics unavailable: ${error.code}]';
    } on MissingPluginException {
      return '[HarmonyOS diagnostics unavailable]';
    }
  }

  static Future<bool> canRecover() async {
    try {
      return await _channel.invokeMethod<bool>('canRecover') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
