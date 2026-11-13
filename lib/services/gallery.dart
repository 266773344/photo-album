import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart' as pm;

/// How much of the device gallery the app may read.
enum GalleryAccess { full, limited, denied }

/// A photo in the device gallery (metadata only).
class GalleryAsset {
  const GalleryAsset({required this.id, required this.takenAt, required this.width, required this.height});
  final String id;
  final DateTime takenAt;
  final int width;
  final int height;
}

/// A gallery folder ("Camera", "WhatsApp Images", a folder you made, …).
class GalleryFolder {
  const GalleryFolder({required this.id, required this.name, required this.count, this.isAll = false});
  final String id;
  final String name;
  final int count;

  /// The virtual "all photos" folder.
  final bool isAll;
}

/// Read access to the photos on the device. Albums reference these photos by
/// [GalleryAsset.id] instead of storing a copy of the original.
///
/// Only available on Android ([Gallery.create] returns null elsewhere); the
/// browser keeps copying picked files.
abstract class Gallery {
  static Gallery? create() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? PhotoManagerGallery() : null;

  Future<GalleryAccess> requestAccess();

  /// Folders that contain photos; the "all photos" folder first.
  Future<List<GalleryFolder>> folders();

  /// Photos of a folder, newest first, in the range [start, end).
  Future<List<GalleryAsset>> assets(String folderId, {int start = 0, int end = 1 << 30});

  /// All photos of a folder, or null if the folder no longer exists.
  Future<List<GalleryAsset>?> folderAssets(String folderId);

  /// The photo, decoded and scaled by the system so that its shorter side is
  /// at least [edge] pixels (keeps the aspect ratio, applies rotation, handles
  /// HEIC). JPEG bytes, or null if the photo no longer exists.
  Future<Uint8List?> image(String id, int edge, {int quality = 90});

  /// GPS position, if the photo has one (needs the media-location permission).
  Future<(double, double)?> location(String id);

  Future<void> openSettings();

  /// Lets the user widen a limited ("selected photos only") permission.
  Future<void> selectMore();
}

class PhotoManagerGallery implements Gallery {
  static const _permission = pm.PermissionRequestOption(
    androidPermission: pm.AndroidPermission(type: pm.RequestType.image, mediaLocation: true),
  );

  final Map<String, pm.AssetEntity> _entities = {};
  final Map<String, pm.AssetPathEntity> _paths = {};

  pm.FilterOptionGroup get _filter => pm.FilterOptionGroup(
        orders: const [pm.OrderOption(type: pm.OrderOptionType.createDate, asc: false)],
      );

  @override
  Future<GalleryAccess> requestAccess() async {
    final state = await pm.PhotoManager.requestPermissionExtend(requestOption: _permission);
    return switch (state) {
      pm.PermissionState.authorized => GalleryAccess.full,
      pm.PermissionState.limited => GalleryAccess.limited,
      _ => GalleryAccess.denied,
    };
  }

  @override
  Future<List<GalleryFolder>> folders() async {
    final paths = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image, filterOption: _filter);
    final out = <GalleryFolder>[];
    for (final p in paths) {
      _paths[p.id] = p;
      final count = await p.assetCountAsync;
      if (count == 0) continue;
      out.add(GalleryFolder(id: p.id, name: p.isAll ? 'All photos' : p.name, count: count, isAll: p.isAll));
    }
    out.sort((a, b) => a.isAll != b.isAll ? (a.isAll ? -1 : 1) : b.count.compareTo(a.count));
    return out;
  }

  Future<pm.AssetPathEntity?> _path(String id) async {
    final known = _paths[id];
    if (known != null) return known;
    try {
      return _paths[id] = await pm.AssetPathEntity.fromId(id, type: pm.RequestType.image, filterOption: _filter);
    } catch (_) {
      return null; // folder no longer exists
    }
  }

  @override
  Future<List<GalleryAsset>> assets(String folderId, {int start = 0, int end = 1 << 30}) async {
    final path = await _path(folderId);
    if (path == null) return const [];
    final count = await path.assetCountAsync;
    if (start >= count) return const [];
    final list = await path.getAssetListRange(start: start, end: end > count ? count : end);
    return [
      for (final a in list)
        if (a.type == pm.AssetType.image) _remember(a),
    ];
  }

  @override
  Future<List<GalleryAsset>?> folderAssets(String folderId) async {
    if (await _path(folderId) == null) return null;
    return assets(folderId);
  }

  GalleryAsset _remember(pm.AssetEntity a) {
    _entities[a.id] = a;
    return GalleryAsset(id: a.id, takenAt: a.createDateTime, width: a.orientatedWidth, height: a.orientatedHeight);
  }

  Future<pm.AssetEntity?> _entity(String id) async {
    final known = _entities[id];
    if (known != null) return known;
    final found = await pm.AssetEntity.fromId(id);
    if (found != null) _entities[id] = found;
    return found;
  }

  @override
  Future<Uint8List?> image(String id, int edge, {int quality = 90}) async {
    final a = await _entity(id);
    if (a == null) return null;
    return a.thumbnailDataWithSize(pm.ThumbnailSize.square(edge), quality: quality);
  }

  @override
  Future<(double, double)?> location(String id) async {
    final a = await _entity(id);
    if (a == null) return null;
    final ll = await a.latlngAsync();
    if (ll == null || (ll.latitude == 0 && ll.longitude == 0)) return null;
    return (ll.latitude, ll.longitude);
  }

  @override
  Future<void> openSettings() => pm.PhotoManager.openSetting();

  @override
  Future<void> selectMore() => pm.PhotoManager.presentLimited(type: pm.RequestType.image);
}
