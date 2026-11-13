import 'dart:convert';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/screens/event_screen.dart';
import 'package:photo_album/screens/place_picker.dart';
import 'package:photo_album/services/geocoding.dart';

Photo photoAt(String id, DateTime t) =>
    Photo(id: id, width: 4, height: 3, takenAt: t, palette: const [PaletteColor(0xFF4477AA, 1)]);

void main() {
  testWidgets('set location via selection → tap map → use this place → back in album', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);

    final repo = AlbumRepository(
      MemoryStorage(),
      geocoder: Geocoder(client: MockClient((req) async => http.Response(
            jsonEncode({'name': 'Café Lua', 'display_name': 'Café Lua, Lisboa', 'lat': '38.7', 'lon': '-9.1', 'address': {'city': 'Lisboa'}}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ))),
    );
    await repo.load();
    final e = await repo.createEvent(title: 'Lisbon');
    e.photos.addAll([photoAt('p0', DateTime(2024, 8, 1, 9)), photoAt('p1', DateTime(2024, 8, 1, 12))]);
    await repo.changed(e);

    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    openEvent(tester.element(find.text('Lisbon')), e);
    await tester.pumpAndSettle();

    final cell = find.byType(GestureDetector).evaluate().firstWhere((el) {
      final w = el.widget as GestureDetector;
      return w.onLongPress != null && w.behavior == HitTestBehavior.translucent;
    });
    await tester.longPress(find.byWidget(cell.widget));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set location'));
    await tester.pumpAndSettle();
    expect(find.byType(PlacePickerScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(PlacePickerScreen, skipOffstage: false), findsOneWidget);
    expect(find.text('Use this place'), findsOneWidget);

    await tester.tap(find.text('Use this place'));
    await tester.pumpAndSettle();
    expect(find.byType(PlacePickerScreen, skipOffstage: false), findsNothing);
    expect(e.photos.first.hasLocation, isTrue);
    expect(find.text('Lisbon'), findsWidgets);
    await tester.pump(const Duration(seconds: 3)); // let the rate-limited day-name lookup finish
    expect(tester.takeException(), isNull);
  });

  testWidgets('set location from the photo viewer and close the viewer again', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);

    final repo = AlbumRepository(
      MemoryStorage(),
      geocoder: Geocoder(client: MockClient((req) async => http.Response(
            jsonEncode({'name': 'Café Lua', 'display_name': 'Café Lua, Lisboa', 'lat': '38.7', 'lon': '-9.1', 'address': {'city': 'Lisboa'}}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ))),
    );
    await repo.load();
    final e = await repo.createEvent(title: 'Lisbon');
    e.photos.addAll([photoAt('p0', DateTime(2024, 8, 1, 9)), photoAt('p1', DateTime(2024, 8, 1, 12))]);
    await repo.changed(e);

    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    openEvent(tester.element(find.text('Lisbon')), e);
    await tester.pumpAndSettle();
    openPhotoViewer(tester.element(find.byType(EventScreen)), e, e.photos.first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Photo options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set location'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this place'));
    await tester.pumpAndSettle();
    expect(find.byType(PlacePickerScreen, skipOffstage: false), findsNothing);
    expect(e.photos.first.hasLocation, isTrue);

    // Back to the album.
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
