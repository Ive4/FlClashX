import 'dart:io';

import 'proxy_platform_interface.dart';
import 'src/linux_proxy.dart';
import 'src/macos_proxy.dart';
import 'src/pac_server.dart';
import 'src/proxy_command.dart';
import 'src/windows_proxy.dart';

export 'src/proxy_command.dart' show ProxyExecutableChecker, ProxyProcessRunner;

class Proxy {
  static const int _minPort = 1;
  static const int _maxPort = 65535;

  final _pacServer = PacServer();
  final Future<Uri?> Function(String script)? _servePac;
  late final LinuxProxy _linuxProxy;
  late final MacosProxy _macosProxy;

  Proxy({
    ProxyProcessRunner? processRunner,
    ProxyExecutableChecker? executableChecker,
    Future<Uri?> Function(String script)? servePac,
  }) : _servePac = servePac {
    final commandRunner = ProxyCommandRunner(processRunner ?? Process.run);
    _linuxProxy = LinuxProxy(
      commandRunner: commandRunner,
      executableChecker: executableChecker,
    );
    _macosProxy = MacosProxy(commandRunner: commandRunner);
  }

  Future<bool> startProxy(
    int port, [
    List<String> bypassDomain = const [],
  ]) async {
    final applied = await _start(port, bypassDomain);
    if (applied) {
      await _pacServer.close();
    }
    return applied;
  }

  Future<bool> startPacProxy(int port, String script) async {
    if (port < _minPort || port > _maxPort || script.trim().isEmpty) {
      return false;
    }
    final content = script.replaceAll('%mixed-port%', '$port');
    final url =
        await _servePac?.call(content) ?? await _pacServer.serve(content);
    return _start(port, const [], pacUrl: url);
  }

  Future<bool> _start(
    int port,
    List<String> bypassDomain, {
    Uri? pacUrl,
  }) async {
    if (port < _minPort || port > _maxPort) {
      return false;
    }
    return switch (Platform.operatingSystem) {
      'macos' => await _macosProxy.start(port, bypassDomain, pacUrl: pacUrl),
      'linux' => await _linuxProxy.start(
        port,
        bypassDomain,
        pacUrl: pacUrl,
        desktop: Platform.environment['XDG_CURRENT_DESKTOP'],
        homeDir: Platform.environment['HOME'],
      ),
      'windows' when pacUrl != null =>
        await ProxyPlatform.instance.startPacProxy(pacUrl),
      'windows' => await ProxyPlatform.instance.startProxy(
        port,
        windowsBypassList(bypassDomain),
      ),
      String() => false,
    };
  }

  Future<bool> stopProxy() async {
    final stopped = switch (Platform.operatingSystem) {
      'macos' => await _macosProxy.stop(),
      'linux' => await _linuxProxy.stop(
        desktop: Platform.environment['XDG_CURRENT_DESKTOP'],
        homeDir: Platform.environment['HOME'],
      ),
      'windows' => await ProxyPlatform.instance.stopProxy(),
      String() => false,
    };
    if (stopped) {
      await _pacServer.close();
    }
    return stopped;
  }
}
