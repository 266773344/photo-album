import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/screens/gallery_picker.dart';
import 'package:photo_album/screens/photo_viewer.dart';
import 'package:photo_album/services/gallery.dart';
import 'package:photo_album/services/geocoding.dart';
import 'package:photo_album/widgets/common.dart';

/// In-memory stand-in for the device gallery.
class FakeGallery implements Gallery {
  FakeGallery(this.folderAssetsById, {this.gps = const {}, this.addedOrder = false});

  /// List "All photos" folder by folder (like Android's order by date added)
  /// instead of by capture time.
  final bool addedOrder;

  final Map<String, List<GalleryAsset>> folderAssetsById;
  final Map<String, (double, double)> gps;
  GalleryAccess access = GalleryAccess.full;
  final List<String> imageRequests = [];

  static final Uint8List _jpeg = Uint8List.fromList(img.encodeJpg(
    img.Image(width: 64, height: 48)..clear(img.ColorRgb8(70, 120, 200)),
  ));

  @override
  Future<GalleryAccess> requestAccess() async => access;

  @override
  Future<List<GalleryFolder>> folders() async => [
        GalleryFolder(id: 'all', name: 'All photos', count: _all.length, isAll: true),
        for (final MapEntry(:key, :value) in folderAssetsById.entries)
          GalleryFolder(id: key, name: 'Folder $key', count: value.length),
      ];

  List<GalleryAsset> get _all {
    final list = [for (final v in folderAssetsById.values) ...v];
    if (!addedOrder) list.sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return list;
  }

  @override
  Future<List<GalleryAsset>> assets(String folderId, {int start = 0, int end = 1 << 30}) async {
    final list = folderId == 'all' ? _all : folderAssetsById[folderId] ?? const <GalleryAsset>[];
    if (start >= list.length) return const [];
    return list.sublist(start, end > list.length ? list.length : end);
  }

  @override
  Future<List<GalleryAsset>?> folderAssets(String folderId) async =>
      folderAssetsById.containsKey(folderId) ? assets(folderId) : null;

  @override
  Future<Uint8List?> image(String id, int edge, {int quality = 90}) async {
    imageRequests.add(id);
    return _all.any((a) => a.id == id) ? _jpeg : null;
  }

  @override
  Future<(double, double)?> location(String id) async => gps[id];

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> selectMore() async {}
}

GalleryAsset asset(String id, DateTime t, {String? name}) =>
    GalleryAsset(id: id, takenAt: t, width: 4000, height: 3000, name: name ?? '$id.jpg');

AlbumRepository repoWith(Gallery gallery) => AlbumRepository(
      MemoryStorage(),
      gallery: gallery,
      geocoder: Geocoder(client: MockClient((req) async => http.Response(
            jsonEncode({'name': 'Lisboa', 'display_name': 'Lisboa', 'lat': '38.7', 'lon': '-9.1', 'address': {'city': 'Lisboa'}}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ))),
    );

void main() {
  final t0 = DateTime(2024, 8, 1, 9);

  testWidgets('gallery photos are referenced: only the preview is stored', (tester) async {
    await tester.runAsync(() async {
      final g = FakeGallery({
        'cam': [asset('a1', t0), asset('a2', t0.add(const Duration(hours: 2)))],
      }, gps: {'a1': (38.71, -9.14)});
      final repo = repoWith(g);
      await repo.load();
      final e = await repo.createEvent(title: 'Lisbon');

      final failed = await repo.importAssets(e, [asset('a1', t0), asset('a2', t0.add(const Duration(hours: 2)))]);
      expect(failed, 0);
      expect(e.photos.map((p) => p.assetId), ['a1', 'a2']);
      final p = e.photos.first;
      expect(p.takenAt, t0);
      expect((p.lat, p.lng), (38.71, -9.14));
      expect(p.folderId, isNull);
      final blobs = (repo.storage as MemoryStorage).blobs;
      expect(blobs.keys.toSet(), {for (final p in e.photos) p.thumbKey});

      // Picking the same photos again adds nothing.
      await repo.importAssets(e, [asset('a1', t0)]);
      expect(e.photos, hasLength(2));

      // Removing never touches the gallery, and hand-picked photos aren't excluded.
      await repo.deletePhotos(e, [p.id]);
      expect(blobs.containsKey(p.thumbKey), isFalse);
      expect(e.excludedAssets, isEmpty);
    });
  });

  testWidgets('linked folders stay in sync', (tester) async {
    await tester.runAsync(() async {
      final folder = [asset('f1', t0), asset('f2', t0.add(const Duration(hours: 1))), asset('f3', t0.add(const Duration(hours: 2)))];
      final g = FakeGallery({'trip': folder, 'other': [asset('h1', t0.add(const Duration(minutes: 30)))]});
      final repo = repoWith(g);
      await repo.load();
      final e = await repo.createEvent(title: 'Lisbon');
      await repo.importAssets(e, [asset('h1', t0.add(const Duration(minutes: 30)))]); // picked by hand

      final linked = await repo.linkFolder(e, const GalleryFolder(id: 'trip', name: 'Trip', count: 3));
      expect(linked!.added, 3);
      expect(e.photos.where((p) => p.folderId == 'trip'), hasLength(3));

      // A photo is added to the folder, another one deleted from it.
      folder
        ..removeWhere((a) => a.id == 'f2')
        ..add(asset('f4', t0.add(const Duration(hours: 3))));
      // The hand-picked photo disappears from the gallery too, but stays in the album.
      g.folderAssetsById['other'] = [];
      final r = await repo.syncFolders(e, force: true);
      expect((r!.added, r.removed), (1, 1));
      expect(e.photos.map((p) => p.assetId).toSet(), {'h1', 'f1', 'f3', 'f4'});

      // Removed by hand: not brought back by the next sync.
      final f3 = e.photos.firstWhere((p) => p.assetId == 'f3');
      await repo.deletePhotos(e, [f3.id]);
      expect(e.excludedAssets, {'f3'});
      expect((await repo.syncFolders(e, force: true))!.isEmpty, isTrue);
      expect(e.photos.any((p) => p.assetId == 'f3'), isFalse);

      // Limited access: invisible photos are not treated as deleted.
      g.access = GalleryAccess.limited;
      folder.removeWhere((a) => a.id == 'f4');
      expect((await repo.syncFolders(e, force: true))!.removed, 0);
      expect(e.photos.any((p) => p.assetId == 'f4'), isTrue);

      // Folder gone (renamed or deleted): leave everything alone.
      g.access = GalleryAccess.full;
      g.folderAssetsById.remove('trip');
      expect((await repo.syncFolders(e, force: true))!.removed, 0);

      // Unlinking keeps the photos as if they were picked by hand.
      await repo.unlinkFolder(e, 'trip');
      expect(e.linkedFolders, isEmpty);
      expect(e.photos.where((p) => p.folderId != null), isEmpty);
      expect(e.photos, hasLength(3));

      // Without a recent check, automatic syncs are throttled.
      e.linkedFolders.add(FolderLink(id: 'other', name: 'Other'));
      expect(await repo.syncFolders(e, force: true), isNotNull);
      expect(await repo.syncFolders(e), isNull);
    });
  });

  test('references, links and exclusions survive JSON', () {
    final e = AlbumEvent(id: 'e', title: 'T', createdAt: DateTime(2024), photos: [
      Photo(id: 'p', width: 4, height: 3, takenAt: t0, palette: const [], assetId: 'a1', folderId: 'trip'),
    ]);
    e.linkedFolders.add(FolderLink(id: 'trip', name: 'Trip', lastSync: DateTime(2024, 9)));
    e.excludedAssets.add('a9');
    final copy = AlbumEvent.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
    expect(copy.photos.single.assetId, 'a1');
    expect(copy.photos.single.folderId, 'trip');
    expect(copy.linkedFolders.single.name, 'Trip');
    expect(copy.linkedFolders.single.lastSync, DateTime(2024, 9));
    expect(copy.excludedAssets, {'a9'});
  });

  testWidgets('picker: album dates first, day selection, already added photos', (tester) async {
    final g = FakeGallery({
      'cam': [
        asset('new2', DateTime(2024, 9, 10, 12)),
        asset('d2b', DateTime(2024, 8, 2, 15)),
        asset('d2a', DateTime(2024, 8, 2, 10)),
        asset('in', DateTime(2024, 8, 1, 9)),
        asset('old', DateTime(2023, 5, 1, 9)),
      ],
    });
    final repo = repoWith(g);
    await tester.runAsync(repo.load);
    final e = AlbumEvent(id: 'e', title: 'Lisbon', createdAt: DateTime(2024), photos: [
      Photo(id: 'p', width: 4, height: 3, takenAt: DateTime(2024, 8, 1, 9), palette: const [], assetId: 'in'),
    ]);

    GalleryPick? result;
    await tester.pumpWidget(AlbumScope(
      repo: repo,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await pickFromGallery(context, e, g),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Only the album's days (plus one either side) are shown at first.
    expect(find.textContaining('Photos from'), findsOneWidget);
    expect(find.text('Friday, 2 August 2024'), findsOneWidget);
    expect(find.text('Thursday, 1 August 2024'), findsOneWidget);
    expect(find.text('Tuesday, 10 September 2024'), findsNothing);
    expect(find.bySemanticsLabel('Already in this album'), findsOneWidget);

    await tester.tap(find.textContaining('Photos from'));
    await tester.pumpAndSettle();
    expect(find.text('Tuesday, 10 September 2024'), findsOneWidget);

    // Tapping a day heading selects the whole day.
    await tester.tap(find.text('Friday, 2 August 2024'));
    await tester.pumpAndSettle();
    expect(find.text('Add 2 photos'), findsOneWidget);
    // The day of the already-added photo has nothing left to select.
    await tester.tap(find.text('Thursday, 1 August 2024'));
    await tester.pumpAndSettle();
    expect(find.text('Add 2 photos'), findsOneWidget);

    await tester.tap(find.text('Add 2 photos'));
    await tester.pumpAndSettle();
    expect((result! as PickedPhotos).assets.map((a) => a.id), ['d2a', 'd2b']);
  });

  testWidgets('picker: each day once, copies in other folders shown once', (tester) async {
    final g = FakeGallery(addedOrder: true, {
      'cam': [
        asset('d2', DateTime(2024, 8, 2, 15)),
        asset('in', DateTime(2024, 8, 1, 9)),
        asset('d1', DateTime(2024, 8, 1, 10)),
      ],
      // Saved later into another folder: the same photos again, plus a new one.
      'backup': [
        asset('d2-copy', DateTime(2024, 8, 2, 15), name: 'd2.jpg'),
        asset('in-copy', DateTime(2024, 8, 1, 9), name: 'in.jpg'),
        asset('d2b', DateTime(2024, 8, 2, 16)),
      ],
    });
    final repo = repoWith(g);
    await tester.runAsync(repo.load);
    final e = AlbumEvent(id: 'e', title: 'Lisbon', createdAt: DateTime(2024), photos: [
      Photo(id: 'p', width: 4, height: 3, takenAt: DateTime(2024, 8, 1, 9), palette: const [], assetId: 'in'),
    ]);
    await tester.pumpWidget(AlbumScope(
      repo: repo,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => pickFromGallery(context, e, g), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Friday, 2 August 2024'), findsOneWidget);
    expect(find.text('Thursday, 1 August 2024'), findsOneWidget);
    expect(find.bySemanticsLabel('Already in this album'), findsOneWidget);
    // d2, d2b, in, d1 - not the two copies.
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tile'), findsNWidgets(4));

    // Importing a photo together with its copy adds it once.
    final before = e.photos.length;
    await tester.runAsync(() => repo.importAssets(e, [
          asset('d2', DateTime(2024, 8, 2, 15)),
          asset('d2-copy', DateTime(2024, 8, 2, 15), name: 'd2.jpg'),
        ]));
    expect(e.photos.length - before, 1);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('picker: link a whole folder', (tester) async {
    final g = FakeGallery({
      'trip': [asset('t1', DateTime(2024, 8, 1, 9))],
    });
    final repo = repoWith(g);
    await tester.runAsync(repo.load);
    final e = AlbumEvent(id: 'e', title: 'Lisbon', createdAt: DateTime(2024));
    GalleryPick? result;
    await tester.pumpWidget(AlbumScope(
      repo: repo,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await pickFromGallery(context, e, g),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add a whole folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folder trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    expect((result! as PickedFolder).folder.id, 'trip');
  });

  testWidgets('picker: no access shows a way to the settings', (tester) async {
    final g = FakeGallery({})..access = GalleryAccess.denied;
    final repo = repoWith(g);
    await tester.runAsync(repo.load);
    await tester.pumpWidget(AlbumScope(
      repo: repo,
      child: MaterialApp(home: GalleryPickerScreen(event: AlbumEvent(id: 'e', title: 'T', createdAt: DateTime(2024)), gallery: g)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('viewer loads referenced originals from the gallery', (tester) async {
    final g = FakeGallery({'cam': [asset('a1', t0)]});
    final repo = repoWith(g);
    await tester.runAsync(repo.load);
    final e = (await tester.runAsync(() => repo.createEvent(title: 'T')))!;
    e.photos.addAll([
      Photo(id: 'ref', width: 4, height: 3, takenAt: t0, palette: const [], assetId: 'a1'),
      Photo(id: 'copy', width: 4, height: 3, takenAt: t0.add(const Duration(hours: 1)), palette: const []),
    ]);
    Widget viewerFor(Photo p) => AlbumScope(
          repo: repo,
          child: MaterialApp(home: PhotoViewer(key: ValueKey(p.id), eventId: e.id, initialPhotoId: p.id)),
        );
    List<ImageProvider> fullImages() => [
          for (final w in tester.widgetList<Image>(find.byType(Image)))
            if (w.image is ResizeImage) (w.image as ResizeImage).imageProvider,
        ];

    await tester.pumpWidget(viewerFor(e.photos[0]));
    await tester.pump();
    expect(fullImages().whereType<GalleryImage>().map((i) => i.assetId), contains('a1'));

    await tester.pumpWidget(viewerFor(e.photos[1]));
    await tester.pump();
    expect(fullImages().whereType<StoredImage>().map((i) => i.blobKey), contains('full_copy'));
  });
}

