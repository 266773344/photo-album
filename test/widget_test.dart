import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/photo_processor.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/layout/collage_layout.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/theme/event_theme.dart';
import 'package:photo_album/theme/palette.dart';

void main() {
  group('collage layout', () {
    final aspects = [1.5, 0.75, 1.33, 1.0, 0.66, 1.78, 1.5, 0.75, 0.75, 1.33, 2.5, 1.0, 0.56];

    test('places every photo exactly once, in order', () {
      for (final width in [360.0, 412.0, 800.0, 1000.0]) {
        for (var seed = 0; seed < 20; seed++) {
          final blocks = buildCollage(aspects, width, seed: seed);
          final indices = [for (final b in blocks) ...b.cells.map((c) => c.index)]..sort();
          expect(indices, List.generate(aspects.length, (i) => i));
        }
      }
    });

    test('cells tile each block without overflow and keep their aspect', () {
      final blocks = buildCollage(aspects, 400, seed: 3);
      for (final b in blocks) {
        var area = 0.0;
        for (final c in b.cells) {
          expect(c.rect.left, greaterThanOrEqualTo(-0.01));
          expect(c.rect.right, lessThanOrEqualTo(b.width + 0.01));
          expect(c.rect.bottom, lessThanOrEqualTo(b.height + 0.01));
          area += c.rect.width * c.rect.height;
          // No cropping: each cell has the photo's own aspect ratio.
          expect(c.rect.width / c.rect.height, closeTo(aspects[c.index].clamp(0.3, 4.0), 0.001));
        }
        expect(area, closeTo(b.width * b.height, 0.5));
      }
    });

    test('is deterministic for a seed and varies between seeds', () {
      String sig(int seed) => buildCollage(aspects, 400, seed: seed).map((b) => b.template).join(',');
      expect(sig(7), sig(7));
      expect({for (var s = 0; s < 10; s++) sig(s)}.length, greaterThan(1));
    });
  });

  group('palette', () {
    Uint8List solid(List<int> rgb, int n) =>
        Uint8List.fromList([for (var i = 0; i < n; i++) ...[...rgb, 255]]);

    test('finds dominant colours with weights', () {
      final pixels = Uint8List.fromList([...solid([20, 120, 200], 700), ...solid([240, 200, 60], 300)]);
      final p = extractPalette(pixels, 100, 10);
      expect(p.length, 2);
      expect(p.first.weight, closeTo(0.7, 0.02));
      expect((p.first.argb >> 16) & 0xFF, closeTo(20, 8));
      expect(chooseSeed(p), isNotNull);
    });

    test('seed prefers colourful over grey', () {
      final grey = PaletteColor(0xFF808080, 0.6);
      final teal = PaletteColor(0xFF1FA9B8, 0.4);
      expect(chooseSeed([grey, teal]), teal.argb);
    });
  });

  test('parses EXIF dates', () {
    expect(parseExifDate('2024:08:12 14:33:10'), DateTime(2024, 8, 12, 14, 33, 10));
    expect(parseExifDate('0000:00:00 00:00:00'), isNull);
    expect(parseExifDate(null), isNull);
  });

  test('groups photos by day and round-trips through JSON', () {
    Photo ph(String id, DateTime t) => Photo(id: id, width: 3, height: 2, takenAt: t, palette: const [PaletteColor(0xFF336699, 1)]);
    final e = AlbumEvent(id: 'e', title: 'Trip', createdAt: DateTime(2024), photos: [
      ph('a', DateTime(2024, 8, 1, 9)),
      ph('b', DateTime(2024, 8, 1, 18)),
      ph('c', DateTime(2024, 8, 3, 10)),
    ]);
    e.dayNotes['2024-08-01'] = 'Arrival';
    final days = groupByDay(e.photos);
    expect(days.map((d) => d.photos.length), [2, 1]);

    final copy = AlbumEvent.fromJson(e.toJson());
    expect(copy.photos.map((p) => p.id), ['a', 'b', 'c']);
    expect(copy.dayNotes['2024-08-01'], 'Arrival');
    expect(copy.layoutSeed, e.layoutSeed);
    expect(EventStyle.of(copy).dayTints.length, 2);
  });

  testWidgets('home screen shows empty state, then created album', (tester) async {
    final repo = AlbumRepository(MemoryStorage());
    await repo.load();
    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    expect(find.text('Create your first album'), findsOneWidget);

    await repo.createEvent(title: 'Lisbon', location: 'Portugal');
    await tester.pumpAndSettle();
    expect(find.text('Lisbon'), findsOneWidget);
    expect(find.text('New album'), findsOneWidget);
  });
}
