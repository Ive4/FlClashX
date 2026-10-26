import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../backup_codec.dart' show backupMaxWireBytes, BackupCodecException;

Uint8List runOhosBackupWorker(Uint8List input) {
  final library = DynamicLibrary.open('libflclash.so');
  final codec = library
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Uint8>, Int32),
        Pointer<Utf8> Function(Pointer<Uint8>, int)
      >('FlClashBackupCodec');
  final release = library
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('FlClashFree');
  final request = calloc<Uint8>(input.length);
  Pointer<Utf8> response = nullptr;
  try {
    request.asTypedList(input.length).setAll(0, input);
    response = codec(request, input.length);
    if (response == nullptr) throw const BackupCodecException('internal');
    final length = response.length;
    if (length > backupMaxWireBytes) {
      throw const BackupCodecException('tooLarge');
    }
    return Uint8List.fromList(response.cast<Uint8>().asTypedList(length));
  } finally {
    calloc.free(request);
    if (response != nullptr) release(response);
  }
}
