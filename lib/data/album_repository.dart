import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/models.dart';
import '../theme/event_theme.dart';
import 'photo_processor.dart';
import 'storage/storage.dart';

/// Holds all albums in memory and persists every change.
class AlbumRepository extends ChangeNotifier {
  AlbumRepository(this.storage);

  final AppStorage storage;
  final List<AlbumEvent> _events = [];
  bool loaded = false;

  /// Import progress per event id: (done, total).
  final Map<String, (int, int)> importProgress = {};

  /// Albums sorted with the most recent trip first.
  List<AlbumEvent> get events {
    final list = [..._events];
    list.sort((a, b) => (b.start ?? b.createdAt).compareTo(a.start ?? a.createdAt));
    return list;
  }

  AlbumEvent? byId(String id) => _events.where((e) => e.id == id).firstOrNull;

  Future<void> load() async {
    await storage.init();
    final raw = await storage.readMeta();
    if (raw != null) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _events.addAll((decoded['events'] as List).map((e) => AlbumEvent.fromJson(e as Map<String, dynamic>)));
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() => storage.writeMeta(jsonEncode({
        'version': 1,
        'events': _events.map((e) => e.toJson()).toList(),
      }));

  /// Persist after the caller mutated an event (title, notes, captions, ...).
  Future<void> changed(AlbumEvent e, {bool styleChanged = false}) async {
    if (styleChanged) EventStyle.invalidate(e.id);
    notifyListeners();
    await _save();
  }

  Future<AlbumEvent> createEvent({required String title, String location = '', String description = ''}) async {
    final e = AlbumEvent(
      id: newId(),
      title: title,
      location: location,
      description: description,
      createdAt: DateTime.now(),
    );
    _events.add(e);
    await changed(e);
    return e;
  }

  Future<void> deleteEvent(AlbumEvent e) async {
    _events.remove(e);
    EventStyle.invalidate(e.id);
    notifyListeners();
    await _save();
    for (final p in e.photos) {
      await storage.deleteBlob(p.thumbKey);
      await storage.deleteBlob(p.fullKey);
    }
  }

  /// Imports picked files into [e]. Returns how many could not be read.
  Future<int> importPhotos(AlbumEvent e, List<XFile> files) async {
    var failed = 0;
    importProgress[e.id] = (0, files.length);
    notifyListeners();
    for (var i = 0; i < files.length; i++) {
      try {
        final f = files[i];
        final bytes = await f.readAsBytes();
        final processed = await processPhoto(bytes);
        DateTime? fileDate;
        if (processed.takenAt == null) {
          try {
            fileDate = await f.lastModified();
          } catch (_) {}
        }
        final photo = Photo(
          id: newId(),
          width: processed.width,
          height: processed.height,
          takenAt: processed.takenAt ?? fileDate ?? DateTime.now(),
          palette: processed.palette,
        );
        await storage.putBlob(photo.thumbKey, processed.thumbJpeg);
        await storage.putBlob(photo.fullKey, bytes);
        e.photos.add(photo);
        e.sortPhotos();
        EventStyle.invalidate(e.id);
      } catch (err) {
        debugPrint('Import failed for ${files[i].name}: $err');
        failed++;
      }
      importProgress[e.id] = (i + 1, files.length);
      notifyListeners();
      // Save periodically so a long import isn't lost if the app is closed.
      if (i % 10 == 9) await _save();
    }
    importProgress.remove(e.id);
    await changed(e, styleChanged: true);
    return failed;
  }

  Future<void> deletePhoto(AlbumEvent e, Photo p) async {
    e.photos.remove(p);
    if (e.coverPhotoId == p.id) e.coverPhotoId = null;
    await changed(e, styleChanged: true);
    await storage.deleteBlob(p.thumbKey);
    await storage.deleteBlob(p.fullKey);
  }

  Future<Uint8List?> blob(String key) => storage.getBlob(key);

  static final _rnd = math.Random();
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';
}
