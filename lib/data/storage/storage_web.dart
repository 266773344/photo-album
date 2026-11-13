import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';

import 'storage.dart';

AppStorage createStorage() => IndexedDbStorage();

class IndexedDbStorage implements AppStorage {
  static const _metaStore = 'meta';
  static const _blobStore = 'blobs';
  static const _metaKey = 'events';

  late Database _db;

  @override
  Future<void> init() async {
    _db = await idbFactoryBrowser.open(
      'photo_album',
      version: 1,
      onUpgradeNeeded: (VersionChangeEvent e) {
        final db = e.database;
        if (!db.objectStoreNames.contains(_metaStore)) db.createObjectStore(_metaStore);
        if (!db.objectStoreNames.contains(_blobStore)) db.createObjectStore(_blobStore);
      },
    );
  }

  Future<T> _run<T>(String store, String mode, Future<T> Function(ObjectStore s) op) async {
    final txn = _db.transaction(store, mode);
    final result = await op(txn.objectStore(store));
    await txn.completed;
    return result;
  }

  @override
  Future<String?> readMeta() =>
      _run(_metaStore, idbModeReadOnly, (s) async => await s.getObject(_metaKey) as String?);

  @override
  Future<void> writeMeta(String json) =>
      _run(_metaStore, idbModeReadWrite, (s) => s.put(json, _metaKey));

  @override
  Future<void> putBlob(String key, Uint8List bytes) =>
      _run(_blobStore, idbModeReadWrite, (s) => s.put(bytes, key));

  @override
  Future<Uint8List?> getBlob(String key) => _run(_blobStore, idbModeReadOnly, (s) async {
        final v = await s.getObject(key);
        if (v == null) return null;
        if (v is Uint8List) return v;
        return Uint8List.fromList((v as List).cast<int>());
      });

  @override
  Future<void> deleteBlob(String key) =>
      _run(_blobStore, idbModeReadWrite, (s) => s.delete(key));
}
