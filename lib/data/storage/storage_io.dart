import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'storage.dart';

AppStorage createStorage() => FileStorage();

class FileStorage implements AppStorage {
  late Directory _root;
  late Directory _blobs;

  @override
  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory('${docs.path}${Platform.pathSeparator}photo_album');
    _blobs = Directory('${_root.path}${Platform.pathSeparator}blobs');
    await _blobs.create(recursive: true);
  }

  File get _metaFile => File('${_root.path}${Platform.pathSeparator}events.json');
  File _blob(String key) => File('${_blobs.path}${Platform.pathSeparator}$key');

  @override
  Future<String?> readMeta() async =>
      await _metaFile.exists() ? _metaFile.readAsString() : null;

  @override
  Future<void> writeMeta(String json) async {
    // Write-then-rename so a crash mid-write never corrupts the album list.
    final tmp = File('${_metaFile.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_metaFile.path);
  }

  @override
  Future<void> putBlob(String key, Uint8List bytes) =>
      _blob(key).writeAsBytes(bytes, flush: true);

  @override
  Future<Uint8List?> getBlob(String key) async {
    final f = _blob(key);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> deleteBlob(String key) async {
    final f = _blob(key);
    if (await f.exists()) await f.delete();
  }
}
