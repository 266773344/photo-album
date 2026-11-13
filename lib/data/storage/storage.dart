import 'dart:typed_data';

import 'storage_io.dart' if (dart.library.js_interop) 'storage_web.dart' as impl;

/// Minimal persistence API: one JSON metadata document plus binary blobs.
///
/// On Android (and other native platforms) data lives in the app's documents
/// directory; in the browser it lives in IndexedDB.
abstract class AppStorage {
  Future<void> init();
  Future<String?> readMeta();
  Future<void> writeMeta(String json);
  Future<void> putBlob(String key, Uint8List bytes);
  Future<Uint8List?> getBlob(String key);
  Future<void> deleteBlob(String key);

  static AppStorage create() => impl.createStorage();
}

/// In-memory implementation, used by tests.
class MemoryStorage implements AppStorage {
  String? _meta;
  final Map<String, Uint8List> blobs = {};

  @override
  Future<void> init() async {}
  @override
  Future<String?> readMeta() async => _meta;
  @override
  Future<void> writeMeta(String json) async => _meta = json;
  @override
  Future<void> putBlob(String key, Uint8List bytes) async => blobs[key] = bytes;
  @override
  Future<Uint8List?> getBlob(String key) async => blobs[key];
  @override
  Future<void> deleteBlob(String key) async => blobs.remove(key);
}
