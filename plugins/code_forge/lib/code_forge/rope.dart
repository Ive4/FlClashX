import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:go_api/go_api.dart';

/// From this many UTF-16 code units on, text is handled off the UI isolate.
const backgroundTextLength = 1 << 17;

const _uploadChunkBytes = 1 << 18;

typedef RopeFold = ({int startLine, int endLine});
typedef RopeGuide = ({
  int startLine,
  int endLine,
  int indentLevel,
  int leadingSpaces,
});

class Rope {
  Rope([String initialText = ''])
    : this._(GoApi.invoke('editor.create', {'text': initialText}) as int);

  Rope._(int id) : _id = id {
    _finalizer.attach(this, id, detach: this);
  }

  static final _finalizer = Finalizer<int>(_release);

  static void _release(int id) {
    GoApi.invoke('editor.dispose', {'id': id});
  }

  int? _id;
  int? _length, _lineCount;

  bool get isDisposed => _id == null;

  int get _handle => _id ?? (throw StateError('The rope is disposed'));

  T _invoke<T>(String operation, [Map<String, Object?> args = const {}]) =>
      GoApi.invoke('editor.$operation', {'id': _handle, ...args}) as T;

  String _readText(String operation, [Map<String, Object?> args = const {}]) {
    final bytes = _invoke<Uint8List>(operation, args);
    final text = utf8.decode(bytes);
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return '\uFEFF$text';
    }
    return text;
  }

  static Future<Rope> openFile(String path) async {
    final result = await GoApi.invokeAsync('editor.openFile', {'path': path});
    return _opened(result, path: path);
  }

  static Future<Rope> fromUtf8(Uint8List bytes) async {
    if (bytes.length <= _uploadChunkBytes) {
      final result = await GoApi.invokeAsync(
        'editor.fromUtf8',
        null,
        bytes: bytes,
      );
      return _opened(result);
    }
    final id = await GoApi.invokeAsync('editor.beginUpload', {
      'length': bytes.length,
    }) as int;
    final args = {'id': id};
    try {
      for (var start = 0; start < bytes.length; start += _uploadChunkBytes) {
        final end = min(start + _uploadChunkBytes, bytes.length);
        await GoApi.invokeAsync(
          'editor.uploadChunk',
          args,
          bytes: bytes.sublist(start, end),
        );
      }
      return _opened(await GoApi.invokeAsync('editor.finishUpload', args));
    } finally {
      GoApi.invoke('editor.discardUpload', args);
    }
  }

  static Rope _opened(Object? result, {String? path}) {
    return switch (result) {
      {'id': final int id} => Rope._(id),
      {'kind': 'notUtf8', 'message': final String message} =>
        throw FormatException(message),
      {'kind': 'notFound', 'message': final String message} when path != null =>
        throw PathNotFoundException(path, OSError(message)),
      {'kind': 'unreadable', 'message': final String message} =>
        throw FileSystemException(message, path),
      _ => throw StateError('Invalid response from the editor backend'),
    };
  }

  Rope snapshot() => Rope._(_invoke<int>('snapshot'));

  Future<Uint8List> utf8Bytes() async =>
      await GoApi.invokeAsync('editor.utf8Bytes', {'id': _handle}) as Uint8List;

  bool sameText(
    Rope original, {
    int spliceStart = 0,
    int spliceLength = 0,
    String spliceText = '',
  }) => _invoke<bool>('sameText', {
    'original': original._handle,
    'start': spliceStart,
    'length': spliceLength,
    'text': spliceText,
  });

  int get length => _length ??= _invoke<int>('length');

  void dispose() {
    if (_id case final int id) {
      _finalizer.detach(this);
      _id = null;
      _release(id);
    }
  }

  String getText() => _readText('text');

  String substring(int start, [int? end]) =>
      _readText('slice', {'start': start, 'end': end ?? length});

  void insert(int position, String text) {
    _invoke<Object?>('insert', {'index': position, 'text': text});
    _length = _lineCount = null;
  }

  void delete(int start, int end) {
    _invoke<Object?>('remove', {'start': start, 'end': end});
    _length = _lineCount = null;
  }

  List<String> cachedLinesRange(int startLine, int endLine) =>
      _invoke<List<Object?>>('lines', {
        'start': startLine,
        'end': endLine,
      }).cast<String>();

  int get lineCount => _lineCount ??= _invoke<int>('lineCount');

  String getLineText(int lineIndex) => _readText('line', {'index': lineIndex});

  int getLineAtOffset(int charOffset) =>
      _invoke<int>('charToLine', {'index': charOffset});

  int getLineStartOffset(int lineIndex) =>
      _invoke<int>('lineToChar', {'index': lineIndex});

  int? matchingBracket(int offset) =>
      _invoke<int?>('matchingBracket', {'index': offset});

  Future<List<RopeFold>> computeFolds(int tabSize) async {
    final folds = await _scan('folds', {'tabSize': tabSize});
    return [
      for (final fold in folds.cast<Map<String, Object?>>())
        (startLine: fold['startLine'] as int, endLine: fold['endLine'] as int),
    ];
  }

  List<RopeGuide> computeGuides(int firstLine, int lastLine, int tabSize) {
    final guides = _invoke<List<Object?>>('guides', {
      'firstLine': firstLine,
      'lastLine': lastLine,
      'tabSize': tabSize,
    });
    return [
      for (final guide in guides.cast<Map<String, Object?>>())
        (
          startLine: guide['startLine'] as int,
          endLine: guide['endLine'] as int,
          indentLevel: guide['indentLevel'] as int,
          leadingSpaces: guide['leadingSpaces'] as int,
        ),
    ];
  }

  Future<Set<String>> extractWords() async =>
      (await _scan('words')).cast<String>().toSet();

  Future<List<Object?>> _scan(
    String operation, [
    Map<String, Object?> args = const {},
  ]) async {
    final copy = snapshot();
    try {
      return await GoApi.invokeAsync('editor.$operation', {
        'id': copy._handle,
        ...args,
      }) as List<Object?>;
    } finally {
      copy.dispose();
    }
  }
}
