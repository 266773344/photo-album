import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/similarity.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/grouping.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/screens/event_screen.dart';

/// Synthetic "photo": a smooth scene described by [f] (0..1 brightness).
Uint8List scene(int w, int h, double Function(double x, double y) f, {double shift = 0, int seed = 0}) {
  final rnd = math.Random(seed);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = ((f(x / w, y / h) + shift) * 255 + rnd.nextDouble() * 6 - 3).clamp(0, 255).round();
      final o = (y * w + x) * 4;
      out[o] = v;
      out[o + 1] = (v * 0.8).round();
      out[o + 2] = (255 - v * 0.5).round();
      out[o + 3] = 255;
    }
  }
  return out;
}

double hills(double x, double y) => 0.5 + 0.35 * math.sin(x * 7) * math.cos(y * 5);
double stripes(double x, double y) => 0.5 + 0.4 * math.sin(y * 19 + x * 3);

Photo photoAt(String id, DateTime t, {String? hash, bool exact = true}) => Photo(
      id: id,
      width: 4,
      height: 3,
      takenAt: t,
      palette: const [PaletteColor(0xFF4477AA, 1)],
      dhash: hash,
      sharpness: id.codeUnitAt(0).toDouble(),
      exactTime: exact,
    );

void main() {
  group('similarity features', () {
    test('near-duplicates have close hashes, different scenes do not', () {
      final a = computeFeatures(scene(320, 240, hills, seed: 1), 320, 240);
      final b = computeFeatures(scene(320, 240, hills, shift: 0.04, seed: 2), 320, 240);
      final c = computeFeatures(scene(320, 240, stripes, seed: 3), 320, 240);
      expect(a.dhash.length, 16);
      expect(hammingDistance(a.dhash, b.dhash), lessThanOrEqualTo(6));
      expect(hammingDistance(a.dhash, c.dhash), greaterThan(16));
      expect(hammingDistance(a.dhash, a.dhash), 0);
    });

    test('hash is resolution independent enough for thumbnails vs. backfill', () {
      final big = computeFeatures(scene(640, 480, hills), 640, 480);
      final small = computeFeatures(scene(160, 120, hills), 160, 120);
      expect(hammingDistance(big.dhash, small.dhash), lessThanOrEqualTo(6));
    });

    test('sharpness is higher for detailed images', () {
      final smooth = computeFeatures(scene(200, 150, (x, y) => 0.5), 200, 150);
      final detailed = computeFeatures(scene(200, 150, (x, y) => 0.5 + 0.4 * math.sin(x * 120)), 200, 150);
      expect(detailed.sharpness, greaterThan(smooth.sharpness));
    });
  });

  group('detectSimilarGroups', () {
    final t0 = DateTime(2024, 8, 1, 9);
    const h1 = '0f0f0f0f33333333';
    const h1b = '0f0f0f0f33333337'; // 1 bit away
    const h2 = 'f0f0f0f0cccccccc'; // far away

    test('groups a burst and leaves distinct photos alone', () {
      final photos = [
        photoAt('a', t0, hash: h1),
        photoAt('b', t0.add(const Duration(seconds: 3)), hash: h1b),
        photoAt('c', t0.add(const Duration(seconds: 5)), hash: h1),
        photoAt('d', t0.add(const Duration(seconds: 20)), hash: h2),
      ];
      final groups = detectSimilarGroups(photos);
      expect(groups.map((g) => g.map((p) => p.id).toList()), [
        ['a', 'b', 'c'],
      ]);
    });

    test('identical-looking photos hours apart are not grouped', () {
      final photos = [photoAt('a', t0, hash: h1), photoAt('b', t0.add(const Duration(hours: 3)), hash: h1)];
      expect(detectSimilarGroups(photos), isEmpty);
    });

    test('never groups across moments', () {
      final photos = [photoAt('a', t0, hash: h1), photoAt('b', t0.add(const Duration(seconds: 2)), hash: h1)];
      expect(detectSimilarGroups(photos, groupKey: (p) => p.id), isEmpty);
    });
  });

  group('structure and grouping ops', () {
    late AlbumEvent e;
    setUp(() {
      final t = DateTime(2024, 8, 1, 8);
      e = AlbumEvent(id: 'e', title: 'Trip', createdAt: DateTime(2024), photos: [
        for (var i = 0; i < 6; i++) photoAt('p$i', t.add(Duration(hours: i))),
        photoAt('q0', DateTime(2024, 8, 2, 10)),
      ]);
    });

    List<String> describe() => [
          for (final d in buildAlbumStructure(e))
            '${d.key}: ${d.blocks.map((b) => switch (b) {
                  LooseRun() => 'loose(${b.items.map((i) => i.ids.join('+')).join(',')})',
                  MomentBlock() => '${b.moment.title}(${b.items.map((i) => i.ids.join('+')).join(',')})',
                }).join(' ')}',
        ];

    test('moments sit at their first photo, loose photos keep their order', () {
      e.createMoment('Breakfast', '', ['p1', 'p2']);
      e.createStack(['p4', 'p5']);
      expect(describe(), [
        '2024-08-01: loose(p0) Breakfast(p1,p2) loose(p3,p4+p5)',
        '2024-08-02: loose(q0)',
      ]);
    });

    test('a carousel moves into a moment as a whole', () {
      e.createStack(['p1', 'p2']);
      e.createMoment('City', 'Old town', ['p2', 'p3']);
      expect(e.moments.single.photoIds, ['p1', 'p2', 'p3']);
      expect(describe().first, '2024-08-01: loose(p0) City(p1+p2,p3) loose(p4,p5)');
    });

    test('a photo is in one moment at most; empty moments disappear', () {
      final a = e.createMoment('A', '', ['p0', 'p1']);
      final b = e.createMoment('B', '', ['p1', 'p2']);
      expect(a.photoIds, ['p0']);
      expect(b.photoIds, ['p1', 'p2']);
      e.removeFromMoment(['p0']);
      expect(e.moments, [b]);
    });

    test('removing photos dissolves carousels that get too small', () {
      e.createStack(['p0', 'p1']);
      e.coverPhotoId = 'p0';
      final removed = e.removePhotos(['p0']);
      expect(removed.single.id, 'p0');
      expect(e.stacks, isEmpty);
      expect(e.coverPhotoId, isNull);
    });

    test('ungrouping remembers the photos so auto-detection leaves them alone', () {
      e.createStack(['p0', 'p1'], auto: true);
      e.ungroup(['p1']);
      expect(e.stacks, isEmpty);
      expect(e.noAutoStack, {'p0', 'p1'});
    });

    test('stack cover defaults to the sharpest photo', () {
      e.createStack(['p0', 'p1', 'q0']);
      final item = buildAlbumStructure(e).first.blocks.first.items.first;
      expect(item.isStack, isTrue);
      expect(item.cover.id, 'q0'); // 'q' has the highest test sharpness
    });

    test('stacks and moments survive JSON', () {
      e.createStack(['p0', 'p1']);
      e.createMoment('Lunch', 'Fish!', ['p3']);
      e.noAutoStack.add('p5');
      e.autoStack = false;
      final copy = AlbumEvent.fromJson(e.toJson());
      expect(copy.stacks.single.photoIds, ['p0', 'p1']);
      expect(copy.moments.single.note, 'Fish!');
      expect(copy.noAutoStack, {'p5'});
      expect(copy.autoStack, isFalse);
      expect(copy.photos.first.dhash, e.photos.first.dhash);
    });
  });

  testWidgets('long-press selects; carousel and moment actions work', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);

    final repo = AlbumRepository(MemoryStorage());
    await repo.load();
    final e = await repo.createEvent(title: 'Lisbon');
    final t = DateTime(2024, 8, 1, 8);
    e.photos.addAll([for (var i = 0; i < 4; i++) photoAt('p$i', t.add(Duration(hours: i)))]);
    await repo.changed(e);

    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    openEvent(tester.element(find.text('Lisbon')), e);
    await tester.pumpAndSettle();

    // Long-press the first photo cell to start selecting, tap a second one.
    final cells = find.byType(GestureDetector).evaluate().where((el) {
      final w = el.widget as GestureDetector;
      return w.onLongPress != null && w.behavior == HitTestBehavior.translucent;
    }).toList();
    expect(cells.length, 4);
    await tester.longPress(find.byWidget(cells[0].widget));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byWidget(cells[1].widget));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Carousel'));
    await tester.pumpAndSettle();
    expect(e.stacks.single.photoIds.toSet(), {'p0', 'p1'});
    expect(find.text('2 selected'), findsNothing);
    expect(find.text('2'), findsOneWidget); // carousel badge

    // Select the carousel (whole) and put it into a new moment.
    final cells2 = find.byType(GestureDetector).evaluate().where((el) {
      final w = el.widget as GestureDetector;
      return w.onLongPress != null && w.behavior == HitTestBehavior.translucent;
    }).toList();
    expect(cells2.length, 3);
    await tester.longPress(find.byWidget(cells2[0].widget));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Moment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Breakfast at Café Lua');
    await tester.tap(find.text('Create moment'));
    await tester.pumpAndSettle();
    expect(e.moments.single.photoIds, ['p0', 'p1']);
    expect(find.text('Breakfast at Café Lua'), findsOneWidget);
  });
}
