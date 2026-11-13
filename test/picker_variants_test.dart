import 'dart:convert';

import 'package:flutter/gestures.dart';
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
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('variant $kind: many taps, confirm while loading', (tester) async {
      tester.view.physicalSize = const Size(1600, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = AlbumRepository(
        MemoryStorage(),
        geocoder: Geocoder(client: MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return http.Response(
            jsonEncode({'name': 'Café Lua', 'display_name': 'Café Lua, Lisboa', 'lat': '38.7', 'lon': '-9.1', 'address': {'city': 'Lisboa'}}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        })),
      );
      await repo.load();
      final e = await repo.createEvent(title: 'Lisbon');
      e.photos.addAll([photoAt('p0', DateTime(2024, 8, 1, 9))..lat = 38.71..lng = -9.14, photoAt('p1', DateTime(2024, 8, 1, 12))..lat = 38.70..lng = -9.20]);
      e.layoutSeed = 1; // fixed layout, so the long-pressed cell is on screen
      await repo.changed(e);
      await tester.pumpWidget(PhotoAlbumApp(repo: repo));
      openEvent(tester.element(find.text('Lisbon')), e);
      await tester.pumpAndSettle();
      final cell = find.byType(GestureDetector).evaluate().firstWhere((el) {
        final w = el.widget as GestureDetector;
        return w.onLongPress != null && w.behavior == HitTestBehavior.translucent;
      });
      await tester.longPress(find.byWidget(cell.widget), kind: kind);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'), kind: kind);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set location'), kind: kind);
      await tester.pumpAndSettle();
      final c = tester.getCenter(find.byType(FlutterMap));
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(c + Offset(i * 30.0, 0), kind: kind);
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tester.tap(find.text('Use this place'), kind: kind);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(PlacePickerScreen, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('moment sheet: add place via map, create moment', (tester) async {
    tester.view.physicalSize = const Size(1600, 4000);
    tester.view.devicePixelRatio = 1;
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
    e.layoutSeed = 1; // fixed layout, so the long-pressed cell is on screen
    await repo.changed(e);
    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    openEvent(tester.element(find.text('Lisbon')), e);
    await tester.pumpAndSettle();
    final cell = find.byType(GestureDetector).evaluate().firstWhere((el) {
      final w = el.widget as GestureDetector;
      return w.onLongPress != null && w.behavior == HitTestBehavior.translucent;
    });
    await tester.longPress(find.byWidget(cell.widget), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Title'), 'Breakfast');
    await tester.tap(find.text('Add a place (optional)'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this place'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Café Lua'), findsOneWidget);
    await tester.tap(find.text('Create moment'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(e.moments.single.place?.name, 'Café Lua');
    expect(tester.takeException(), isNull);
  });
}
