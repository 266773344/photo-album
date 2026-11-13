import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import '../l10n/strings.dart';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../models/grouping.dart';
import '../models/models.dart';
import '../services/gallery.dart';
import '../services/geocoding.dart';
import '../services/place_story.dart';
import '../services/routing.dart';
import '../models/visits.dart';
import 'package:latlong2/latlong.dart';
import '../theme/event_theme.dart';
import 'photo_processor.dart';
import 'similarity.dart';
import 'storage/storage.dart';

/// Holds all albums in memory and persists every change.
class AlbumRepository extends ChangeNotifier {
  AlbumRepository(
    this.storage, {
    Geocoder? geocoder,
    PlaceStoryWriter? storyWriter,
    Gallery? gallery,
    bool useDeviceGallery = true,
    RouteFinder? routeFinder,
  })  : geocoder = geocoder ?? Geocoder.instance,
        storyWriter = storyWriter ?? PlaceStoryWriter(),
        routeFinder = routeFinder ?? RouteFinder.instance,
        gallery = gallery ?? (useDeviceGallery ? Gallery.create() : null);

  final RouteFinder routeFinder;

  /// Lets album colours be compared across the library.
  void _linkStyles() => EventStyle.library = () => _events;

  /// Asks an open album page to scroll to these photos (e.g. after tapping a
  /// pin on the map): (album id, photo ids).
  final ValueNotifier<(String, List<String>)?> focusRequest = ValueNotifier(null);

  void requestFocus(AlbumEvent e, List<String> photoIds) => focusRequest.value = (e.id, photoIds);

  final AppStorage storage;

  /// Device gallery (Android). Null in the browser, where picked photos are
  /// copied into the app instead of referenced.
  final Gallery? gallery;
  final Geocoder geocoder;
  final PlaceStoryWriter storyWriter;
  final List<AlbumEvent> _events = [];
  bool loaded = false;
  AppSettings settings = const AppSettings();

  /// Moment ids whose place description is being written right now.
  final Set<String> storyLoading = {};

  Future<void> updateSettings(AppSettings s) async {
    final routesTurnedOn = s.realRoutes && s.onlineLookups && !(settings.realRoutes && settings.onlineLookups);
    settings = s;
    final languageChanged = _applyLanguage();
    notifyListeners();
    await _save();
    if (languageChanged) {
      // Day and album place names in the new language.
      for (final e in [..._events]) {
        unawaited(refreshDayPlaces(e));
      }
    }
    if (routesTurnedOn) {
      for (final e in [..._events]) {
        unawaited(refreshRoutes(e));
      }
    }
  }

  /// Switches the app and place-name language to the setting; returns
  /// whether it changed.
  bool _applyLanguage() {
    final changed = L10n.apply(settings.language);
    geocoder.language = L10n.code;
    return changed;
  }

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
    _linkStyles();
    await storage.init();
    final raw = await storage.readMeta();
    if (raw != null) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _events.addAll((decoded['events'] as List).map((e) => AlbumEvent.fromJson(e as Map<String, dynamic>)));
      if (decoded['settings'] != null) settings = AppSettings.fromJson(decoded['settings'] as Map<String, dynamic>);
    }
    _applyLanguage();
    loaded = true;
    notifyListeners();
    unawaited(() async {
      await _backfillFeatures();
      for (final e in [..._events]) {
        await refreshDayPlaces(e);
      }
      for (final e in [..._events]) {
        await refreshRoutes(e);
      }
    }());
  }

  // ---- locations ------------------------------------------------------------

  /// Looks up a town/area name for every day that has GPS photos but no name yet.
  Future<void> refreshDayPlaces(AlbumEvent e) async {
    if (!settings.onlineLookups) return;
    var changedAny = false;
    // Place names follow the app language: look them up again after a switch.
    if (e.placesLanguage != geocoder.language) {
      if (e.dayPlaces.isNotEmpty) changedAny = true;
      e.dayPlaces.clear();
      e.placesLanguage = geocoder.language;
    }
    for (final day in groupByDay(e.photos)) {
      if (e.dayPlaces.containsKey(day.key)) continue;
      final located = day.photos.where((p) => p.hasLocation).toList();
      if (located.isEmpty) continue;
      // The median position is robust against a single stray GPS fix.
      final lats = located.map((p) => p.lat!).toList()..sort();
      final lngs = located.map((p) => p.lng!).toList()..sort();
      try {
        final place = await geocoder.reverse(lats[lats.length ~/ 2], lngs[lngs.length ~/ 2], zoom: 10);
        if (place != null && place.name.isNotEmpty) {
          e.dayPlaces[day.key] = place.name;
          changedAny = true;
        }
      } catch (err) {
        debugPrint('Day place lookup failed: $err');
        return; // offline or rate limited: try again next time
      }
    }
    if (await _updateAutoLocation(e)) changedAny = true;
    if (changedAny) await changed(e);
  }

  /// Keeps an album's place in sync with its photos' towns unless the user
  /// set it: "Lisboa", "Lisboa, Sintra & Cascais", or the region for longer
  /// trips. Returns whether it changed.
  Future<bool> _updateAutoLocation(AlbumEvent e) async {
    if (e.locationManual) return false;
    final towns = autoLocationTowns(e);
    String text;
    if (towns.length <= 3) {
      text = joinPlaceNames(towns);
    } else {
      final located = e.photos.where((p) => p.hasLocation).toList();
      final lats = located.map((p) => p.lat!).toList()..sort();
      final lngs = located.map((p) => p.lng!).toList()..sort();
      try {
        final region = await geocoder.reverse(lats[lats.length ~/ 2], lngs[lngs.length ~/ 2], zoom: 5);
        text = region?.name ?? joinPlaceNames(towns.take(3).toList());
      } catch (_) {
        return false; // offline: keep what we have
      }
    }
    if (text == e.location) return false;
    e.location = text;
    return true;
  }

  // ---- routes ------------------------------------------------------------------

  final Set<String> _routing = {};

  /// Looks up real travel routes between the album's consecutive stops that
  /// aren't cached yet (at most [maxLegs] per call).
  Future<void> refreshRoutes(AlbumEvent e, {int maxLegs = 50}) async {
    if (!settings.onlineLookups || !settings.realRoutes || _routing.contains(e.id)) return;
    _routing.add(e.id);
    try {
      final visits = buildVisits(e);
      var done = 0;
      for (var i = 1; i < visits.length && done < maxLegs; i++) {
        final a = visits[i - 1], b = visits[i];
        final key = legKey(a.center.latitude, a.center.longitude, b.center.latitude, b.center.longitude);
        if (e.routes.containsKey(key) || a.center == b.center) continue;
        final mode = guessTravelMode(a.center, b.center, b.start.difference(a.end));
        try {
          e.routes[key] = await _findRoute(a.center, b.center, mode);
        } catch (err) {
          debugPrint('Route lookup failed: $err');
          return; // offline or server trouble: try again next time
        }
        done++;
        notifyListeners();
        if (done % 5 == 0) await _save();
      }
      if (done > 0) await changed(e);
    } finally {
      _routing.remove(e.id);
    }
  }

  Future<LegRoute> _findRoute(LatLng a, LatLng b, TravelMode mode, {bool manual = false}) async {
    if (!mode.routed) return LegRoute(mode: mode, manual: manual);
    final polyline = await routeFinder.route(a, b, mode);
    if (polyline == null || !isPlausibleRoute(a, b, decodePolyline(polyline))) {
      // No road connection or a huge detour: probably a ferry or train.
      return LegRoute(mode: manual ? mode : TravelMode.straight, manual: manual);
    }
    return LegRoute(mode: mode, polyline: polyline, manual: manual);
  }

  /// The user says how a leg was travelled.
  Future<void> setLegMode(AlbumEvent e, String key, LatLng a, LatLng b, TravelMode mode) async {
    e.routes[key] = LegRoute(mode: mode, manual: true);
    await changed(e);
    if (!mode.routed || !settings.onlineLookups) return;
    try {
      e.routes[key] = await _findRoute(a, b, mode, manual: true);
      await changed(e);
    } catch (err) {
      debugPrint('Route lookup failed: $err');
    }
  }

  Future<void> setPhotoLocation(AlbumEvent e, Iterable<String> ids, GeoPlace place) async {
    final set = ids.toSet();
    for (final p in e.photos.where((p) => set.contains(p.id))) {
      p
        ..lat = place.lat
        ..lng = place.lng
        ..locationManual = true;
      e.dayPlaces.remove(dayKey(p.takenAt));
    }
    await changed(e);
    unawaited(refreshDayPlaces(e).then((_) => refreshRoutes(e)));
  }

  /// Sets a moment's place; writes a description automatically if enabled.
  Future<void> setMomentPlace(AlbumEvent e, Moment m, GeoPlace? place) async {
    final placeChanged = m.place?.name != place?.name || m.place?.lat != place?.lat;
    m.place = place;
    if (placeChanged) m.story = null;
    await changed(e);
    if (placeChanged) unawaited(refreshRoutes(e));
    if (place != null && placeChanged && settings.autoStories && settings.canWriteStories) {
      try {
        await writeStory(e, m);
      } catch (err) {
        debugPrint('Automatic place description failed: $err');
      }
    }
  }

  /// Asks Claude for a short description of the moment's place.
  /// Throws [StoryException] with a user-facing message on failure.
  Future<void> writeStory(AlbumEvent e, Moment m) async {
    final place = m.place;
    if (place == null || storyLoading.contains(m.id)) return;
    storyLoading.add(m.id);
    notifyListeners();
    try {
      final first = e.photos.where((p) => m.photoIds.contains(p.id)).firstOrNull;
      m.story = await storyWriter.write(
        settings: settings,
        place: place,
        momentTitle: m.title,
        visitedOn: first?.takenAt,
        albumTitle: e.title,
      );
    } finally {
      storyLoading.remove(m.id);
      await changed(e);
    }
  }

  /// Photos imported before similarity detection existed get their
  /// fingerprints computed from the stored thumbnails (~a few ms each).
  Future<void> _backfillFeatures() async {
    for (final e in [..._events]) {
      final missing = e.photos.where((p) => p.dhash == null).toList();
      if (missing.isEmpty) continue;
      for (final p in missing) {
        try {
          final thumb = await storage.getBlob(p.thumbKey);
          if (thumb == null) continue;
          final f = await featuresFromThumb(thumb);
          p
            ..dhash = f.dhash
            ..sharpness = f.sharpness;
        } catch (err) {
          debugPrint('Could not fingerprint ${p.id}: $err');
        }
      }
      if (e.autoStack) _detect(e);
      await changed(e);
    }
  }

  /// Groups near-duplicates among photos that aren't in a carousel yet and
  /// that the user hasn't pulled out of one.
  void _detect(AlbumEvent e) {
    final candidates = e.photos.where((p) => e.stackOf(p.id) == null && !e.noAutoStack.contains(p.id)).toList();
    for (final group in detectSimilarGroups(candidates, groupKey: (p) => e.momentOf(p.id)?.id)) {
      e.createStack(group.map((p) => p.id), auto: true, coverId: pickCover(group).id);
    }
  }

  Future<void> setAutoStack(AlbumEvent e, bool enabled) async {
    e.autoStack = enabled;
    if (enabled) {
      e.noAutoStack.clear();
      _detect(e);
    } else {
      e.stacks.removeWhere((s) => s.auto);
    }
    await changed(e);
  }

  Future<void> _save() => storage.writeMeta(jsonEncode({
        'version': 1,
        'settings': settings.toJson(),
        'events': _events.map((e) => e.toJson()).toList(),
      }));

  /// Persist after the caller mutated an event (title, notes, captions, ...).
  Future<void> changed(AlbumEvent e, {bool styleChanged = false}) async {
    if (styleChanged) {
      EventStyle.invalidate(e.id);
      // Other albums compare their colours with this one.
      EventStyle.invalidateComparisons();
    }
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
    await _deleteBlobs(e.photos);
  }

  /// Imports picked files into [e] by copying them (browser).
  /// Returns how many could not be read.
  Future<int> importPhotos(AlbumEvent e, List<XFile> files) => _importEach(e, files.length, (i) async {
        final f = files[i];
        final bytes = await f.readAsBytes();
        final processed = await processPhoto(bytes);
        DateTime? fileDate;
        if (processed.takenAt == null) {
          try {
            fileDate = await f.lastModified();
          } catch (_) {}
        }
        final photo = _photoFrom(
          processed,
          takenAt: processed.takenAt ?? fileDate ?? DateTime.now(),
          exactTime: processed.takenAt != null,
          lat: processed.exif.lat,
          lng: processed.exif.lng,
        );
        await storage.putBlob(photo.thumbKey, processed.thumbJpeg);
        await storage.putBlob(photo.fullKey, bytes);
        return photo;
      }, describe: (i) => files[i].name);

  /// Imports photos from the device gallery by reference: only the preview is
  /// stored, the original stays in the gallery. Photos already in the album
  /// are skipped. Returns how many could not be read.
  Future<int> importAssets(AlbumEvent e, List<GalleryAsset> assets, {String? folderId}) {
    final g = gallery;
    if (g == null) throw StateError('No device gallery on this platform');
    final have = {for (final p in e.photos) p.assetId};
    // The same photo can sit in several folders: import one copy.
    final keys = <String>{};
    final todo = assets.where((a) => !have.contains(a.id) && keys.add(a.copyKey)).toList();
    // Picking a photo by hand again overrides an earlier removal.
    if (folderId == null) e.excludedAssets.removeAll(todo.map((a) => a.id));
    return _importEach(e, todo.length, (i) async {
      final a = todo[i];
      final preview = await g.image(a.id, thumbMaxEdge, quality: 92);
      if (preview == null) throw StateError('Photo no longer in the gallery');
      final processed = await processPhoto(preview);
      final gps = processed.exif.lat != null ? (processed.exif.lat!, processed.exif.lng!) : await g.location(a.id);
      final photo = _photoFrom(
        processed,
        // The gallery's "date taken" comes from the original's EXIF data.
        takenAt: processed.takenAt ?? a.takenAt,
        exactTime: true,
        lat: gps?.$1,
        lng: gps?.$2,
        assetId: a.id,
        folderId: folderId,
      );
      await storage.putBlob(photo.thumbKey, processed.thumbJpeg);
      return photo;
    }, describe: (i) => 'gallery photo ${todo[i].id}');
  }

  Photo _photoFrom(
    ProcessedPhoto processed, {
    required DateTime takenAt,
    required bool exactTime,
    double? lat,
    double? lng,
    String? assetId,
    String? folderId,
  }) =>
      Photo(
        id: newId(),
        width: processed.width,
        height: processed.height,
        takenAt: takenAt,
        palette: processed.palette,
        dhash: processed.features.dhash,
        sharpness: processed.features.sharpness,
        exactTime: exactTime,
        lat: lat,
        lng: lng,
        assetId: assetId,
        folderId: folderId,
      );

  /// Shared import loop: progress, periodic saving, then grouping and names.
  Future<int> _importEach(
    AlbumEvent e,
    int count,
    Future<Photo> Function(int i) importOne, {
    required String Function(int i) describe,
  }) async {
    if (count == 0) return 0;
    var failed = 0;
    importProgress[e.id] = (0, count);
    notifyListeners();
    for (var i = 0; i < count; i++) {
      try {
        e.photos.add(await importOne(i));
        e.sortPhotos();
        EventStyle.invalidate(e.id);
      } catch (err) {
        debugPrint('Import failed for ${describe(i)}: $err');
        failed++;
      }
      importProgress[e.id] = (i + 1, count);
      notifyListeners();
      // Save periodically so a long import isn't lost if the app is closed.
      if (i % 10 == 9) await _save();
    }
    importProgress.remove(e.id);
    e.normalize();
    if (e.autoStack) _detect(e);
    await changed(e, styleChanged: true);
    unawaited(refreshDayPlaces(e).then((_) => refreshRoutes(e)));
    return failed;
  }

  /// Removes photos from the album (never from the device gallery).
  Future<void> deletePhotos(AlbumEvent e, Iterable<String> ids) async {
    final removed = e.removePhotos(ids);
    // Keep folder sync from bringing them back.
    e.excludedAssets.addAll([
      for (final p in removed)
        if (p.folderId != null && p.assetId != null) p.assetId!,
    ]);
    await changed(e, styleChanged: true);
    await _deleteBlobs(removed);
  }

  Future<void> _deleteBlobs(Iterable<Photo> photos) async {
    for (final p in photos) {
      await storage.deleteBlob(p.thumbKey);
      if (p.assetId == null) await storage.deleteBlob(p.fullKey);
    }
  }

  // ---- linked gallery folders -------------------------------------------------

  /// Album ids whose folders are being synced right now.
  final Set<String> syncing = {};
  final Map<String, DateTime> _lastSync = {};

  /// Links [folder] to [e] and imports its photos.
  Future<FolderSyncResult?> linkFolder(AlbumEvent e, GalleryFolder folder) async {
    if (!e.linkedFolders.any((l) => l.id == folder.id)) {
      e.linkedFolders.add(FolderLink(id: folder.id, name: folder.name));
      await changed(e);
    }
    return syncFolders(e, force: true);
  }

  /// Stops syncing; the folder's photos stay as if picked by hand.
  Future<void> unlinkFolder(AlbumEvent e, String folderId) async {
    e.linkedFolders.removeWhere((l) => l.id == folderId);
    for (final p in e.photos.where((p) => p.folderId == folderId)) {
      p.folderId = null;
    }
    await changed(e);
  }

  /// Adds new photos from the album's linked folders and removes those that
  /// were deleted from them. Returns null if nothing was checked (no folders,
  /// no gallery, no permission, already running, or checked < 1 min ago).
  Future<FolderSyncResult?> syncFolders(AlbumEvent e, {bool force = false}) async {
    final g = gallery;
    if (g == null || e.linkedFolders.isEmpty || syncing.contains(e.id)) return null;
    final last = _lastSync[e.id];
    if (!force && last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) return null;
    _lastSync[e.id] = DateTime.now();

    final access = await g.requestAccess();
    if (access == GalleryAccess.denied) return null;
    syncing.add(e.id);
    notifyListeners();
    var added = 0, removed = 0, failed = 0;
    try {
      for (final link in [...e.linkedFolders]) {
        final assets = await g.folderAssets(link.id);
        if (assets == null) continue; // folder gone (renamed/deleted): leave the photos alone
        final ids = {for (final a in assets) a.id};
        // With "selected photos only" access, unselected photos are merely
        // invisible, not deleted, so nothing is removed then.
        if (access == GalleryAccess.full) {
          final gone = [
            for (final p in e.photos)
              if (p.folderId == link.id && !ids.contains(p.assetId)) p,
          ];
          if (gone.isNotEmpty) {
            e.removePhotos(gone.map((p) => p.id));
            await _deleteBlobs(gone);
            removed += gone.length;
          }
        }
        final have = {for (final p in e.photos) p.assetId};
        final fresh = [
          for (final a in assets)
            if (!have.contains(a.id) && !e.excludedAssets.contains(a.id)) a,
        ];
        failed += await importAssets(e, fresh, folderId: link.id);
        added += fresh.length;
        link.lastSync = DateTime.now();
      }
      await changed(e, styleChanged: removed > 0);
      return FolderSyncResult(added: added - failed, removed: removed, failed: failed);
    } finally {
      syncing.remove(e.id);
      notifyListeners();
    }
  }

  Future<void> deletePhoto(AlbumEvent e, Photo p) => deletePhotos(e, [p.id]);

  Future<Uint8List?> blob(String key) => storage.getBlob(key);

  static final _rnd = math.Random();
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';
}

/// Outcome of [AlbumRepository.syncFolders].
class FolderSyncResult {
  const FolderSyncResult({required this.added, required this.removed, required this.failed});
  final int added;
  final int removed;
  final int failed;

  bool get isEmpty => added == 0 && removed == 0 && failed == 0;

  @override
  String toString() => [
        if (added > 0) tr('+{n} new', {'n': added}),
        if (removed > 0) tr('{n} removed', {'n': removed}),
        if (failed > 0) tr('{n} could not be read', {'n': failed}),
      ].join(', ');
}

/// Distinct town names of an album's days, in visiting order.
List<String> autoLocationTowns(AlbumEvent e) {
  final towns = <String>[];
  for (final day in groupByDay(e.photos)) {
    final name = e.dayPlaces[day.key];
    if (name != null && name.isNotEmpty && !towns.contains(name)) towns.add(name);
  }
  return towns;
}

/// "A", "A & B", "A, B & C".
String joinPlaceNames(List<String> names) => joinNames(names);
