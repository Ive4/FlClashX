import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

const _iconSize = 48;
const _diNormal = 0x0003;
final _localExecutable = RegExp(r'^[a-z]:[\\/].+\.exe$', caseSensitive: false);

Future<Uint8List?> loadWindowsApplicationIcon(String path) async {
  if (!_localExecutable.hasMatch(path)) return null;
  final pixels = await Isolate.run(() => _extractPixels(path));
  if (pixels == null) return null;
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    _iconSize,
    _iconSize,
    ui.PixelFormat.bgra8888,
    decoded.complete,
  );
  final image = await decoded.future;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Uint8List? _extractPixels(String path) => using((arena) {
  final fileName = PCWSTR(path.toNativeUtf16(allocator: arena));
  final handle = arena<Pointer>();
  final count = PrivateExtractIcons(
    fileName,
    0,
    _iconSize,
    _iconSize,
    handle,
    null,
    1,
    0,
  );
  if (count != 1 || handle.value == nullptr) {
    return null;
  }
  final icon = HICON(handle.value);
  try {
    final info = arena<BITMAPINFO>();
    info.ref.bmiHeader
      ..biSize = sizeOf<BITMAPINFOHEADER>()
      ..biWidth = _iconSize
      ..biHeight = -_iconSize
      ..biPlanes = 1
      ..biBitCount = 32
      ..biCompression = BI_RGB;
    final data = arena<Pointer>();
    final bitmap = CreateDIBSection(
      null,
      info,
      DIB_RGB_COLORS,
      data,
      null,
      0,
    ).value;
    if (bitmap == nullptr) return null;
    try {
      final dc = CreateCompatibleDC(null);
      if (dc == nullptr) return null;
      try {
        if (SelectObject(dc, HGDIOBJ(bitmap)) == nullptr) return null;
        if (_drawIcon(
              dc,
              0,
              0,
              icon,
              _iconSize,
              _iconSize,
              0,
              nullptr,
              _diNormal,
            ) ==
            0) {
          return null;
        }
        _flushGdi();
        final pixels = data.value.cast<Uint8>().asTypedList(
          _iconSize * _iconSize * 4,
        );
        for (var alpha = 3; alpha < pixels.length; alpha += 4) {
          if (pixels[alpha] != 0) return Uint8List.fromList(pixels);
        }
        return null;
      } finally {
        DeleteDC(dc);
      }
    } finally {
      DeleteObject(HGDIOBJ(bitmap));
    }
  } finally {
    DestroyIcon(icon);
  }
});

final _drawIcon = DynamicLibrary.open('user32.dll')
    .lookupFunction<
      Int32 Function(
        Pointer,
        Int32,
        Int32,
        Pointer,
        Int32,
        Int32,
        Uint32,
        Pointer,
        Uint32,
      ),
      int Function(Pointer, int, int, Pointer, int, int, int, Pointer, int)
    >('DrawIconEx');

final _flushGdi = DynamicLibrary.open(
  'gdi32.dll',
).lookupFunction<Int32 Function(), int Function()>('GdiFlush');
