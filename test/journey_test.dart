import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/screens/event_screen.dart';
import 'package:photo_album/services/geocoding.dart';
import 'package:photo_album/services/routing.dart';
import 'package:photo_album/theme/palette.dart';
import 'package:photo_album/widgets/album_map.dart';
import 'package:photo_album/widgets/common.dart';

Photo photo(String id, DateTime t, {double? lat, double? lng, int color = 0xFF4477AA}) => Photo(
      id: id,
      width: 4,
      height: 3,
      takenAt: t,
      palette: [PaletteColor(color, 1)],
      lat: lat,
      lng: lng,
    );

Geocoder namedGeocoder(String Function(Uri) name) => Geocoder(client: MockClient((req) async {
      final n = name(req.url);
      return http.Response(
        jsonEncode({'name': n, 'display_name': n, 'lat': '0', 'lon': '0', 'address': {'town': n}}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }));

void main() {
  group('album colours', () {
    test('a vivid accent beats sky, stone and foliage', () {
      const palette = [
        PaletteColor(0xFF7FA6CF, 0.35), // sky blue
        PaletteColor(0xFF8A8A88, 0.25), // grey stone
        PaletteColor(0xFF5E7A45, 0.2), // foliage
        PaletteColor(0xFFB89B72, 0.12), // sand
        PaletteColor(0xFFD7262E, 0.08), // a red tram
      ];
      final sig = signatureColors(palette);
      expect(sig.first.argb, 0xFFD7262E);
      expect(sig, hasLength(5));
    });

    test('colours common in the other albums rank lower', () {
      const palette = [PaletteColor(0xFFE0A21B, 0.5), PaletteColor(0xFFD6338A, 0.5)]; // yellow, pink
      expect(signatureColors(palette).first.argb, isNot(0)); // both vivid
      final yellowEverywhere = signatureColors(palette, baseline: const [PaletteColor(0xFFE0A21B, 0.6)]);
      expect(yellowEverywhere.first.argb, 0xFFD6338A);
    });

    test('swatches prefer different hues', () {
      const palette = [
        PaletteColor(0xFFD7262E, 0.3),
        PaletteColor(0xFFDA2A35, 0.3), // almost the same red
        PaletteColor(0xFF1BA3B5, 0.2),
        PaletteColor(0xFFE0A21B, 0.2),
      ];
      final sig = signatureColors(palette, count: 3);
      expect(sig.map((c) => c.argb), [0xFFD7262E, 0xFF1BA3B5, 0xFFE0A21B]..sort((a, b) => sig.indexWhere((c) => c.argb == a) - sig.indexWhere((c) => c.argb == b)));
      expect(sig.map((c) => c.argb), isNot(contains(0xFFDA2A35)));
    });
  });

  group('album place', () {
    test('town names are joined in visiting order', () {
      expect(joinPlaceNames([]), '');
      expect(joinPlaceNames(['Lisboa']), 'Lisboa');
      expect(joinPlaceNames(['Lisboa', 'Sintra']), 'Lisboa & Sintra');
      expect(joinPlaceNames(['Lisboa', 'Sintra', 'Cascais']), 'Lisboa, Sintra & Cascais');
    });

    test('filled in automatically from the photos, unless set by hand', () async {
      final repo = AlbumRepository(
        MemoryStorage(),
        useDeviceGallery: false,
        geocoder: namedGeocoder((u) => u.queryParameters['lat']!.startsWith('38.71') ? 'Lisboa' : 'Sintra'),
      );
      await repo.load();
      repo.settings = const AppSettings(realRoutes: false);
      final e = await repo.createEvent(title: 'Portugal');
      e.photos.addAll([
        photo('a', DateTime(2024, 8, 1, 9), lat: 38.71, lng: -9.14),
        photo('b', DateTime(2024, 8, 2, 9), lat: 38.79, lng: -9.39),
      ]);
      await repo.refreshDayPlaces(e);
      expect(e.location, 'Lisboa & Sintra');

      e
        ..location = 'Portugal'
        ..locationManual = true;
      e.dayPlaces.clear();
      await repo.refreshDayPlaces(e);
      expect(e.location, 'Portugal');

      final copy = AlbumEvent.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(copy.locationManual, isTrue);
    });
  });

  group('routes', () {
    const lisbon = LatLng(38.7139, -9.1394), belem = LatLng(38.6916, -9.2056);

    test('travel mode guess', () {
      expect(guessTravelMode(lisbon, const LatLng(38.7150, -9.1400), const Duration(minutes: 20)), TravelMode.foot);
      expect(guessTravelMode(lisbon, belem, const Duration(hours: 1)), TravelMode.car);
      expect(guessTravelMode(lisbon, const LatLng(52.52, 13.40), const Duration(hours: 5)), TravelMode.flight);
    });

    test('polyline encoding round-trips', () {
      final pts = [lisbon, const LatLng(38.70, -9.17), belem];
      final back = decodePolyline(encodePolyline(pts));
      expect(back, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(back[i].latitude, closeTo(pts[i].latitude, 1e-5));
        expect(back[i].longitude, closeTo(pts[i].longitude, 1e-5));
      }
      expect(decodePolyline('kihkFj~wv@eBt@'), hasLength(2)); // real OSRM output
    });

    test('flight legs are arcs, unknown legs straight', () {
      expect(legPoints(lisbon, belem, null), [lisbon, belem]);
      final arc = legPoints(lisbon, const LatLng(52.52, 13.40), const LegRoute(mode: TravelMode.flight));
      expect(arc.length, greaterThan(10));
      expect(arc.first, lisbon);
    });

    test('routes are looked up once, cached, and implausible ones dropped', () async {
      final requests = <Uri>[];
      final viaRoad = encodePolyline([lisbon, const LatLng(38.705, -9.17), belem]);
      final detour = encodePolyline([belem, const LatLng(40.5, -8.0), const LatLng(38.75, -9.0)]);
      final finder = RouteFinder(client: MockClient((req) async {
        requests.add(req.url);
        final geometry = req.url.path.contains('-9.2056,38.6916;') ? detour : viaRoad;
        return http.Response(jsonEncode({'code': 'Ok', 'routes': [{'geometry': geometry}]}), 200);
      }));
      final repo = AlbumRepository(
        MemoryStorage(),
        useDeviceGallery: false,
        routeFinder: finder,
        geocoder: namedGeocoder((_) => 'X'),
      );
      await repo.load();
      final e = await repo.createEvent(title: 'T');
      final t = DateTime(2024, 8, 1, 9);
      e.photos.addAll([
        photo('a', t, lat: lisbon.latitude, lng: lisbon.longitude),
        photo('b', t.add(const Duration(hours: 2)), lat: belem.latitude, lng: belem.longitude),
        photo('c', t.add(const Duration(hours: 4)), lat: 38.75, lng: -9.0),
      ]);
      await repo.refreshRoutes(e);
      expect(requests, hasLength(2));
      expect(requests.first.host, 'routing.openstreetmap.de');
      expect(requests.first.path, startsWith('/routed-car/'));
      final geo = AlbumGeo(e);
      expect(geo.legs.first.route!.polyline, viaRoad);
      expect(geo.legs.first.dashed, isFalse);
      expect(geo.legs.last.route!.mode, TravelMode.straight); // the detour was dropped
      expect(geo.legs.last.dashed, isTrue);

      await repo.refreshRoutes(e);
      expect(requests, hasLength(2)); // cached

      // The user says the second leg was a train: no lookup, kept as theirs.
      final leg = geo.legs.last;
      await repo.setLegMode(e, leg.key, leg.from.center, leg.to.center, TravelMode.train);
      expect(e.routes[leg.key]!.mode, TravelMode.train);
      expect(e.routes[leg.key]!.manual, isTrue);
      expect(requests, hasLength(2));
      final copy = AlbumEvent.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(copy.routes[leg.key]!.mode, TravelMode.train);
    });

    test('no road connection = straight line, not an error', () async {
      final finder = RouteFinder(client: MockClient((_) async => http.Response('{"code":"NoRoute"}', 400)));
      expect(await finder.route(lisbon, belem, TravelMode.car), isNull);
    });
  });

  group('journey map in the album', () {
    Future<(AlbumRepository, AlbumEvent)> setUpAlbum(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final repo = AlbumRepository(MemoryStorage(), useDeviceGallery: false, geocoder: namedGeocoder((_) => 'X'));
      await tester.runAsync(repo.load);
      repo.settings = const AppSettings(onlineLookups: false);
      final e = (await tester.runAsync(() => repo.createEvent(title: 'Portugal')))!;
      // Two far-apart stops on two days, several photos each.
      for (var i = 0; i < 8; i++) {
        e.photos.add(photo('l$i', DateTime(2024, 8, 1, 9, i * 5), lat: 38.71, lng: -9.14));
      }
      for (var i = 0; i < 8; i++) {
        e.photos.add(photo('p$i', DateTime(2024, 8, 3, 9, i * 5), lat: 41.15, lng: -8.61));
      }
      e.layoutSeed = 1;
      await tester.pumpWidget(PhotoAlbumApp(repo: repo));
      openEvent(tester.element(find.text('Portugal')), e);
      await tester.pumpAndSettle();
      return (repo, e);
    }

    Finder cellOf(String photoId) =>
        find.byWidgetPredicate((w) => w is PhotoThumb && w.photo.id == photoId && w.heroTag != null);

    testWidgets('the header shows the journey map and can be hidden', (tester) async {
      final (_, e) = await setUpAlbum(tester);
      expect(find.byType(JourneyHeaderMap), findsOneWidget);
      await tester.tap(find.byTooltip('Hide map'));
      await tester.pumpAndSettle();
      expect(find.byType(JourneyHeaderMap), findsNothing);
      expect(e.showJourneyMap, isFalse);
      expect(find.byType(AlbumMapCard), findsOneWidget); // the small map moves into the info section
      await tester.tap(find.byTooltip('Show map'));
      await tester.pumpAndSettle();
      expect(find.byType(JourneyHeaderMap), findsOneWidget);
    });

    testWidgets('scrolling moves the current pin along the journey', (tester) async {
      await setUpAlbum(tester);
      JourneyHeaderMap header() => tester.widget<JourneyHeaderMap>(find.byType(JourneyHeaderMap));
      expect(header().current, isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(header().current, 0);
      // Scroll on in steps: the pin moves to Porto once its photos reach the top.
      final seen = <int?>[];
      for (var i = 0; i < 40 && header().current != 1; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpAndSettle();
        seen.add(header().current);
      }
      expect(header().current, 1);
      expect(seen.toSet(), {0, 1}); // never jumps back or skips
      expect(tester.getRect(cellOf('p0')).top, lessThan(300));
    });

    testWidgets('tapping a stop on the full map jumps to its photos', (tester) async {
      await setUpAlbum(tester);
      expect(cellOf('p0').hitTestable(), findsNothing); // off screen at first
      await tester.tap(find.byTooltip('Hide map'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AlbumMapCard));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumMapScreen), findsOneWidget);
      // Two stops far apart: two pins. Tap the one in Porto (the later one).
      final pins = tester.widgetList<VisitPin>(find.byType(VisitPin)).toList();
      expect(pins, hasLength(2));
      final porto = find.byWidgetPredicate((w) => w is VisitPin && w.photo.id.startsWith('p'));
      await tester.tap(porto);
      await tester.pumpAndSettle();
      expect(find.byType(AlbumMapScreen), findsNothing);
      await tester.pump(const Duration(seconds: 2)); // highlight fades
      await tester.pumpAndSettle();
      expect(cellOf('p0').hitTestable(), findsOneWidget);
    });
  });
}
