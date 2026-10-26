import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fl_clash/common/common.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';

class Picker {
  Picker({bool? isOhos}) : _isOhos = isOhos ?? system.isOhos;

  final bool _isOhos;
  static const _ohosChannel = MethodChannel('com.follow.clash/file_picker');

  Future<PlatformFile?> pickerFile() async {
    if (_isOhos) {
      final path = await _ohosChannel.invokeMethod<String>('pickFile');
      return path == null ? null : _OhosPlatformFile(File(path));
    }
    return FilePicker.pickFile(initialDirectory: await appPath.downloadDirPath);
  }

  Future<Uri?> saveFile(String fileName, Uint8List bytes) async {
    if (_isOhos) {
      final uri = await _ohosChannel.invokeMethod<String>('saveFile', {
        'fileName': fileName,
        'bytes': bytes,
      });
      return uri == null ? null : Uri.parse(uri);
    }
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory: await appPath.downloadDirPath,
      bytes: bytes,
    );
    if (!system.isAndroid && uri != null && uri.scheme == 'file') {
      final file = File(uri.toFilePath());
      await file.safeWriteAsBytes(bytes);
    }
    return uri;
  }

  Future<Uri?> saveFileWithPath(String fileName, String localPath) async {
    if (_isOhos) {
      final uri = await _ohosChannel.invokeMethod<String>('saveFile', {
        'fileName': fileName,
        'path': localPath,
      });
      return uri == null ? null : Uri.parse(uri);
    }
    final localFile = File(localPath);
    if (!await localFile.exists()) {
      await localFile.create(recursive: true);
    }
    final bytes = await localFile.readAsBytes();
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory: await appPath.downloadDirPath,
      bytes: bytes,
    );
    await localFile.safeDelete();
    return uri;
  }

  Future<String?> pickerConfigQRCode() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (xFile == null) {
      return null;
    }
    // Not through a throwaway MobileScannerController: disposing one clears
    // the platform scan window of a scanner page that is still open.
    final capture = await MobileScannerPlatform.instance.analyzeImage(
      xFile.path,
      formats: const [BarcodeFormat.qrCode],
    );
    final url = profileUrlFromQrCodes(
      capture?.barcodes.map((barcode) => barcode.rawValue) ?? const [],
    );
    if (url == null) {
      throw MessageException(currentAppLocalizations.pleaseUploadValidQrcode);
    }
    return url;
  }
}

final class _OhosPlatformFile extends PlatformFile {
  _OhosPlatformFile(this._file);

  final File _file;

  @override
  String get name =>
      _file.uri.pathSegments.last.replaceFirst(RegExp(r'^picked-\d+-'), '');

  @override
  Uri get uri => _file.uri;

  @override
  XFile get xFile => XFile(_file.path);

  @override
  int? lengthSync() => null;

  @override
  Future<int> length() => _file.length();

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      _file.openRead().map(Uint8List.fromList);
}

extension PlatformFileExt on PlatformFile {
  Future<Uint8List> readBytes() {
    return readAsBytes();
  }
}

final picker = Picker();
