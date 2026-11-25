import 'dart:convert';
import 'dart:io';

class PacServer {
  static const _path = '/flclash.pac';
  static final _contentType = ContentType(
    'application',
    'x-ns-proxy-autoconfig',
    charset: 'utf-8',
  );

  HttpServer? _server;
  var _revision = 0;
  List<int> _script = const [];

  Future<Uri> serve(String script) async {
    final server = _server ??= await _bind();
    _script = utf8.encode(script);
    return Uri.http('${server.address.address}:${server.port}', _path, {
      'v': '${_revision++}',
    });
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.idleTimeout = const Duration(seconds: 5);
    server.listen(_respond);
    return server;
  }

  void _respond(HttpRequest request) {
    final response = request.response;
    if (request.uri.path != _path) {
      response.statusCode = HttpStatus.notFound;
    } else if (request.method == 'GET' || request.method == 'HEAD') {
      response.headers
        ..contentType = _contentType
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = _script.length;
      if (request.method == 'GET') {
        response.add(_script);
      }
    } else {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
    }
    response.close().ignore();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
