import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/layout/collage_layout.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/grouping.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/screens/event_screen.dart';
import 'package:photo_album/widgets/album_map.dart';
import 'package:photo_album/widgets/common.dart';

Photo photoAt(String id, DateTime t, {int w = 4, int h = 3}) =>
    Photo(id: id, width: w, height: h, takenAt: t, palette: const [PaletteColor(0xFF4477AA, 1)]);

List<double> randomAspects(int seed, int n) {
  final r = math.Random(seed);
  return [for (var i = 0; i < n; i++) r.nextBool() ? 1.5 : (r.nextBool() ? 0.75 : 1.0)];
}

CollageBlock blockOf(List<CollageBlock> blocks, int index) =>
    blocks.firstWhere((b) => b.cells.any((c) => c.index == index));

void main() {
  group('collage sizes', () {
    const width = 400.0;

    test('without sizes the layout is unchanged', () {
      for (var seed = 0; seed < 20; seed++) {
        final aspects = randomAspects(seed, 14);
        final a = buildCollage(aspects, width, seed: seed);
        final b = buildCollage(aspects, width, seed: seed, sizes: List.filled(14, PhotoSize.normal));
        expect(b.map((x) => x.template), a.map((x) => x.template));
      }
    });

    test('a full-width photo always gets a band of its own', () {
      for (var seed = 0; seed < 50; seed++) {
        final sizes = List.filled(14, PhotoSize.normal)..[6] = PhotoSize.full;
        final blocks = buildCollage(randomAspects(seed, 14), width, seed: seed, sizes: sizes);
        expect(blockOf(blocks, 6).cells, hasLength(1), reason: 'seed $seed');
      }
    });

    test('a large photo usually gets a big cell', () {
      var big = 0;
      for (var seed = 0; seed < 50; seed++) {
        final sizes = List.filled(14, PhotoSize.normal)..[6] = PhotoSize.large;
        final blocks = buildCollage(randomAspects(seed, 14), width, seed: seed, sizes: sizes);
        final cell = blockOf(blocks, 6).cells.firstWhere((c) => c.index == 6);
        // At least ~60% of the width in both directions of a typical band.
        if (cell.rect.width * cell.rect.height >= 0.35 * width * width * 0.72) big++;
      }
      expect(big, greaterThanOrEqualTo(45));
    });

    test('small photos go into busier bands', () {
      double perBand(PhotoSize s) {
        var bands = 0, photos = 0;
        for (var seed = 0; seed < 30; seed++) {
          final blocks = buildCollage(randomAspects(seed, 14), width, seed: seed, sizes: List.filled(14, s));
          bands += blocks.length;
          photos += 14;
        }
        return photos / bands;
      }

      expect(perBand(PhotoSize.small), greaterThan(perBand(PhotoSize.normal) + 0.3));
    });

    test('carousels are large by default; a chosen size wins and survives JSON', () {
      final t = DateTime(2024, 8, 1, 9);
      final e = AlbumEvent(
        id: 'e',
        title: 'T',
        createdAt: t,
        photos: [
          photoAt('a', t),
          photoAt('b', t.add(const Duration(seconds: 2))),
          photoAt('c', t.add(const Duration(hours: 1))),
        ],
      );
      e.createStack(['a', 'b']);
      List<AlbumItem> items() => [
        for (final d in buildAlbumStructure(e))
          for (final b in d.blocks) ...b.items,
      ];
      expect(items().map((i) => i.size), [PhotoSize.large, PhotoSize.normal]);
      e.photos[0].size = PhotoSize.normal; // the user says: normal
      e.photos[2].size = PhotoSize.full;
      expect(items().map((i) => i.size), [PhotoSize.normal, PhotoSize.full]);
      final copy = Photo.fromJson(jsonDecode(jsonEncode(e.photos[2].toJson())) as Map<String, dynamic>);
      expect(copy.size, PhotoSize.full);
      expect(Photo.fromJson(jsonDecode(jsonEncode(e.photos[1].toJson())) as Map<String, dynamic>).size, isNull);
    });
  });

  group('header map zoom', () {
    const viewport = Size(411, 150);
    final lisbon = [const LatLng(38.711, -9.140), const LatLng(38.697, -9.206), const LatLng(38.716, -9.130)];
    final berlin = [const LatLng(52.516, 13.378), const LatLng(52.520, 13.405), const LatLng(52.507, 13.391)];

    test('far-apart cities: following a stop zooms into its city', () {
      final stops = [...lisbon, ...berlin];
      for (var i = 0; i < stops.length; i++) {
        final z = followZoom(stops, i, overviewZoom: 3.2, viewport: viewport);
        expect(z, greaterThanOrEqualTo(10), reason: 'stop $i');
        // Its pin is apart from the nearest stop: at zoom z, 256·2^z px span
        // the world, so the nearest stop is ≥ 1.3 pin sizes away.
        final worldPx = 256 * math.pow(2, z);
        final nearest = [
          for (var k = 0; k < stops.length; k++)
            if (k != i) const Distance().as(LengthUnit.Meter, stops[i], stops[k]),
        ].reduce(math.min);
        final metersPerPx = 40075016 * math.cos(stops[i].latitude * math.pi / 180) / worldPx;
        expect(nearest / metersPerPx, greaterThan(1.25 * 34), reason: 'stop $i');
      }
    });

    test('never zooms out beyond the overview, never closer than street level', () {
      final z = followZoom([lisbon[0]], 0, overviewZoom: 14, viewport: viewport);
      expect(z, 14);
      final close = followZoom(
        [const LatLng(38.7110, -9.1400), const LatLng(38.7111, -9.1401)],
        0,
        overviewZoom: 10,
        viewport: viewport,
      );
      expect(close, 16.5);
    });
  });

  testWidgets('selection → Size → Full width gives the photo a band of its own', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final repo = AlbumRepository(MemoryStorage(), useDeviceGallery: false);
    await tester.runAsync(repo.load);
    repo.settings = const AppSettings(onlineLookups: false);
    final e = (await tester.runAsync(() => repo.createEvent(title: 'Sizes')))!;
    for (var i = 0; i < 6; i++) {
      e.photos.add(photoAt('p$i', DateTime(2024, 8, 1, 9 + i), w: i.isEven ? 4 : 3, h: i.isEven ? 3 : 4));
    }
    e.layoutSeed = 1;
    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    openEvent(tester.element(find.text('Sizes')), e);
    await tester.pumpAndSettle();

    final p2 = find.byWidgetPredicate((w) => w is PhotoThumb && w.photo.id == 'p2' && w.heroTag != null);
    await tester.scrollUntilVisible(p2, 200, scrollable: find.byType(Scrollable).first);
    final screenWidth = tester.getSize(find.byType(CustomScrollView)).width;
    expect(tester.getSize(p2).width, lessThan(screenWidth * 0.8)); // shares its band at first

    await tester.longPress(p2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Size'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full width'));
    await tester.pumpAndSettle();

    expect(e.photos.firstWhere((p) => p.id == 'p2').size, PhotoSize.full);
    await tester.scrollUntilVisible(p2, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.getSize(p2).width, greaterThan(screenWidth * 0.85));
  });
}
