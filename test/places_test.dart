import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/photo_processor.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/layout/collage_layout.dart';
import 'package:photo_album/models/grouping.dart';
import 'package:latlong2/latlong.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/models/visits.dart';
import 'package:photo_album/services/geocoding.dart';
import 'package:photo_album/services/place_story.dart';
import 'package:photo_album/widgets/album_map.dart';

Photo photo(String id, DateTime t, {double? lat, double? lng}) => Photo(
      id: id,
      width: 4,
      height: 3,
      takenAt: t,
      palette: const [PaletteColor(0xFF4477AA, 1)],
      lat: lat,
      lng: lng,
    );

void main() {
  test('EXIF GPS degrees/minutes/seconds to decimal', () {
    expect(gpsToDecimal([38, 42, 36], 'N'), closeTo(38.71, 0.001));
    expect(gpsToDecimal([9, 8, 24], 'W'), closeTo(-9.14, 0.001));
    expect(gpsToDecimal([33, 51, 0], 'S'), closeTo(-33.85, 0.001));
  });

  group('maps links', () {
    test('Google Maps place URL with exact position', () {
      final l = parseMapsLink(
        'https://www.google.com/maps/place/Caf%C3%A9+Lua/@38.7139,-9.1394,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d38.71402!4d-9.13951',
      )!;
      expect(l.name, 'Café Lua');
      expect(l.lat, 38.71402);
      expect(l.lng, -9.13951);
    });

    test('search-style link and plain coordinates', () {
      expect(parseMapsLink('https://maps.google.com/?q=Pastéis+de+Belém')!.name, 'Pastéis de Belém');
      final c = parseMapsLink('https://www.google.com/maps?q=38.6975,-9.2032')!;
      expect((c.lat, c.lng), (38.6975, -9.2032));
      expect(parseMapsLink('geo:48.8584,2.2945')!.lat, 48.8584);
    });

    test('short links are recognised, unrelated text is not a link', () {
      expect(parseMapsLink('https://maps.app.goo.gl/AbC123')!.isShortLink, isTrue);
      expect(parseMapsLink('Café Lua Lisbon'), isNull);
      expect(parseMapsLink('https://example.com/x'), isNull);
    });
  });

  test('Nominatim results become friendly names', () {
    final poi = placeFromNominatim({
      'name': 'Café Lua',
      'display_name': 'Café Lua, 12, Rua da Rosa, Bairro Alto, Lisboa, Portugal',
      'lat': '38.7140',
      'lon': '-9.1395',
      'address': {'road': 'Rua da Rosa', 'suburb': 'Bairro Alto', 'city': 'Lisboa', 'country': 'Portugal'},
    });
    expect(poi.name, 'Café Lua');
    expect(poi.address, 'Rua da Rosa, Bairro Alto, Lisboa, Portugal');

    final city = placeFromNominatim({
      'name': 'Sintra',
      'display_name': 'Sintra, Lisboa, Portugal',
      'lat': '38.79',
      'lon': '-9.39',
      'address': {'town': 'Sintra', 'country': 'Portugal'},
    }, cityLevel: true);
    expect(city.name, 'Sintra');
  });

  test('geocoder sends an identifying user agent and caches answers', () async {
    var calls = 0;
    final geo = Geocoder(client: MockClient((req) async {
      calls++;
      expect(req.url.host, 'nominatim.openstreetmap.org');
      expect(req.headers['User-Agent'], contains('PhotoAlbumApp'));
      return http.Response(
        jsonEncode({'name': 'Belém Tower', 'display_name': 'Belém Tower, Lisboa', 'lat': '38.69', 'lon': '-9.21', 'address': {'city': 'Lisboa'}}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }));
    final a = await geo.reverse(38.69, -9.21);
    final b = await geo.reverse(38.69, -9.21);
    expect(a!.name, 'Belém Tower');
    expect(b!.name, 'Belém Tower');
    expect(calls, 1);
  });

  group('place descriptions', () {
    const place = GeoPlace(name: 'Café Lua', address: 'Rua da Rosa, Lisboa', lat: 38.714, lng: -9.1395);

    Map<String, dynamic> answer({String stop = 'end_turn'}) => {
          'stop_reason': stop,
          'content': [
            {'type': 'text', 'text': 'Let me look this up.'},
            {'type': 'server_tool_use', 'id': 'srv_1', 'name': 'web_search', 'input': {'query': 'Café Lua Lisbon'}},
            {'type': 'web_search_tool_result', 'tool_use_id': 'srv_1', 'content': []},
            {
              'type': 'text',
              'text': 'Café Lua opened in 1932 ',
              'citations': [
                {'type': 'web_search_result_location', 'url': 'https://www.example.pt/lua', 'title': 'History'},
              ],
            },
            {'type': 'text', 'text': 'and is known for its custard tarts.'},
          ],
        };

    test('keeps only the text after the last search and collects sources', () {
      final story = parseStoryResponse(answer());
      expect(story.text, 'Café Lua opened in 1932 and is known for its custard tarts.');
      expect(story.sources, ['https://www.example.pt/lua']);
    });

    test('sends the right request and resumes a paused turn', () async {
      final bodies = <Map<String, dynamic>>[];
      final writer = PlaceStoryWriter(client: MockClient((req) async {
        expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
        expect(req.headers['x-api-key'], 'sk-test');
        expect(req.headers['anthropic-version'], '2026-10-21');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        bodies.add(body);
        return http.Response(jsonEncode(bodies.length == 1 ? answer(stop: 'pause_turn') : answer()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));
      final story = await writer.write(
        settings: const AppSettings(apiKey: 'sk-test'),
        place: place,
        momentTitle: 'Breakfast',
      );
      expect(story.text, startsWith('Café Lua opened'));
      expect(bodies.first['model'], 'claude-opus-5-5');
      expect((bodies.first['tools'] as List).single['type'], 'web_search_20260209');
      expect(bodies.first['messages'], hasLength(1));
      // Continuation: original question + the paused assistant turn, no extra user message.
      expect(bodies.last['messages'], hasLength(2));
      expect((bodies.last['messages'] as List).last['role'], 'assistant');
    });

    test('friendly errors and refusals', () async {
      Future<Object?> run(http.Response r, {String model = 'claude-opus-5-5'}) async {
        try {
          await PlaceStoryWriter(client: MockClient((_) async => r))
              .write(settings: AppSettings(apiKey: 'k', model: model), place: place);
          return null;
        } on StoryException catch (e) {
          return e.message;
        }
      }

      expect(await run(http.Response('{"error":{"message":"bad key"}}', 401)), contains('API key was rejected'));
      expect(await run(http.Response(jsonEncode({'stop_reason': 'refusal', 'content': []}), 200)), contains('declined'));
      await expectLater(
        PlaceStoryWriter().write(settings: const AppSettings(), place: place),
        throwsA(isA<StoryException>().having((e) => e.message, 'message', contains('API key'))),
      );
    });
  });

  test('hand-placed moments join the route between the stops before and after them', () {
    final t = DateTime(2024, 8, 1, 9);
    final e = AlbumEvent(id: 'e', title: 'T', createdAt: t, photos: [
      photo('a', t, lat: 38.71, lng: -9.14),
      photo('b', t.add(const Duration(hours: 1))),
      photo('c', t.add(const Duration(hours: 2)), lat: 38.70, lng: -9.20),
      photo('d', t.add(const Duration(hours: 3))), // no position, no moment
    ]);
    final m = e.createMoment('Lunch', '', ['b']);
    m.place = const GeoPlace(name: 'Tasca', lat: 38.705, lng: -9.17);
    final geo = AlbumGeo(e);
    expect(geo.visits.map((v) => v.photos.single.id), ['a', 'b', 'c']);
    expect(geo.visits[1].label, 'Lunch');
    expect(geo.visits[1].center, const LatLng(38.705, -9.17));
    expect(geo.legs, hasLength(2));
    expect(geo.legs.first.to.index, 1);
    // A photo without a position belongs to the stop before it.
    expect(geo.visitOfPhoto('d'), 2);
  });

  group('visits', () {
    final t = DateTime(2024, 8, 1, 9);

    test('close in place and time = one stop; same place hours later = new stop', () {
      final e = AlbumEvent(id: 'e', title: 'T', createdAt: t, photos: [
        photo('a', t, lat: 38.7100, lng: -9.1400),
        photo('b', t.add(const Duration(minutes: 20)), lat: 38.7105, lng: -9.1405), // ~70 m away
        photo('c', t.add(const Duration(minutes: 50)), lat: 38.7300, lng: -9.1400), // ~2 km away
        photo('d', t.add(const Duration(hours: 6)), lat: 38.7300, lng: -9.1400), // same place, much later
      ]);
      final visits = buildVisits(e);
      expect(visits.map((v) => v.photos.map((p) => p.id).join()), ['ab', 'c', 'd']);
    });

    test('representative is the sharpest photo; label only when the stop is one moment', () {
      final e = AlbumEvent(id: 'e', title: 'T', createdAt: t, photos: [
        photo('a', t, lat: 38.71, lng: -9.14)..sharpness = 1,
        photo('b', t.add(const Duration(minutes: 5)), lat: 38.71, lng: -9.14)..sharpness = 9,
      ]);
      expect(buildVisits(e).single.representative.id, 'b');
      expect(buildVisits(e).single.label, isNull);
      e.createMoment('Breakfast', '', ['a', 'b']);
      expect(buildVisits(e).single.label, 'Breakfast');
    });
  });

  test('setting a location manually updates photos and re-names the day', () async {
    final repo = AlbumRepository(
      MemoryStorage(),
      geocoder: Geocoder(client: MockClient((req) async => http.Response(
            jsonEncode({'name': 'Sintra', 'display_name': 'Sintra', 'lat': '38.79', 'lon': '-9.39', 'address': {'town': 'Sintra'}}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ))),
    );
    await repo.load();
    final e = await repo.createEvent(title: 'T');
    e.photos.add(photo('a', DateTime(2024, 8, 2, 10)));
    await repo.setPhotoLocation(e, ['a'], const GeoPlace(name: 'Pena Palace', lat: 38.7876, lng: -9.3906));
    expect(e.photos.single.lat, 38.7876);
    expect(e.photos.single.locationManual, isTrue);
    await repo.refreshDayPlaces(e);
    expect(e.dayPlaces['2024-08-02'], 'Sintra');
  });

  test('new fields survive JSON', () {
    final e = AlbumEvent(id: 'e', title: 'T', createdAt: DateTime(2024), layout: LayoutStyle.compact, photos: [
      photo('a', DateTime(2024, 8, 1), lat: 1.5, lng: 2.5)..locationManual = true,
    ]);
    e.dayPlaces['2024-08-01'] = 'Lisboa';
    final m = e.createMoment('M', '', ['a']);
    m.place = const GeoPlace(name: 'P', address: 'A', lat: 1, lng: 2);
    m.story = PlaceStory(text: 'Nice.', sources: const ['https://x.org'], createdAt: DateTime(2024));
    final copy = AlbumEvent.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
    expect(copy.layout, LayoutStyle.compact);
    expect(copy.dayPlaces['2024-08-01'], 'Lisboa');
    expect(copy.photos.single.lat, 1.5);
    expect(copy.photos.single.locationManual, isTrue);
    expect(copy.moments.single.place!.address, 'A');
    expect(copy.moments.single.story!.sources.single, 'https://x.org');

    final s = AppSettings.fromJson(const AppSettings(apiKey: 'k', autoStories: true).toJson());
    expect((s.apiKey, s.autoStories, s.model), ('k', true, 'claude-opus-5-5'));
  });

  test('airy layout uses fewer photos per band', () {
    final aspects = List.generate(60, (i) => [1.5, 0.75, 1.33, 1.0][i % 4]);
    double perBand(bool airy) {
      var bands = 0;
      for (var seed = 0; seed < 10; seed++) {
        bands += buildCollage(aspects, 400, seed: seed, airy: airy).length;
      }
      return aspects.length * 10 / bands;
    }

    expect(perBand(true), lessThan(perBand(false)));
  });
}
