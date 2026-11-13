import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';

/// Place search and reverse geocoding via OpenStreetMap's Nominatim.
///
/// Nominatim's usage policy allows at most one request per second and asks
/// for caching, so requests are serialised and results memoised.
class Geocoder {
  Geocoder({http.Client? client}) : _client = client ?? http.Client();

  static final instance = Geocoder();

  final http.Client _client;

  /// Language for place names ('en', 'de'); see [L10n].
  String language = 'en';
  final _cache = <String, Object?>{};
  Future<void> _queue = Future.value();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static const _host = 'nominatim.openstreetmap.org';

  Map<String, String> get _headers => {
    // Browsers don't allow setting User-Agent; they send a Referer instead.
    if (!kIsWeb) 'User-Agent': 'PhotoAlbumApp/1.0 (Flutter personal photo album)',
  };

  Future<Object?> _get(String path, Map<String, String> params) {
    // The language is part of the URL (not a header) so cached answers stay
    // per language, and browsers can't override it.
    final uri = Uri.https(_host, path, {...params, 'format': 'jsonv2', 'accept-language': language});
    final key = uri.toString();
    if (_cache.containsKey(key)) return Future.value(_cache[key]);
    final completer = Completer<Object?>();
    _queue = _queue.then((_) async {
      final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      try {
        final res = await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) throw GeocodingException('Place lookup failed (${res.statusCode})');
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        _cache[key] = body;
        completer.complete(body);
      } catch (e) {
        completer.completeError(e is GeocodingException ? e : GeocodingException('Place lookup failed: $e'));
      }
    });
    return completer.future;
  }

  /// Free-text search ("Café Lua Lisbon").
  Future<List<GeoPlace>> search(String query, {double? nearLat, double? nearLng}) async {
    final params = {'q': query, 'limit': '8', 'addressdetails': '1'};
    if (nearLat != null && nearLng != null) {
      // Prefer (but don't restrict to) results around the album's photos.
      params['viewbox'] = '${nearLng - 0.5},${nearLat + 0.5},${nearLng + 0.5},${nearLat - 0.5}';
    }
    final body = await _get('/search', params);
    return [for (final r in (body as List).cast<Map<String, dynamic>>()) placeFromNominatim(r)];
  }

  /// Name of the place at a position. [zoom] 18 = building/POI, 10 = city.
  Future<GeoPlace?> reverse(double lat, double lng, {int zoom = 18}) async {
    final body = await _get('/reverse', {
      'lat': lat.toStringAsFixed(6),
      'lon': lng.toStringAsFixed(6),
      'zoom': '$zoom',
      'addressdetails': '1',
    });
    if (body is! Map<String, dynamic> || body.containsKey('error')) return null;
    return placeFromNominatim(body, cityLevel: zoom <= 12);
  }
}

class GeocodingException implements Exception {
  GeocodingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Converts a Nominatim result into a [GeoPlace] with a short, friendly name.
@visibleForTesting
GeoPlace placeFromNominatim(Map<String, dynamic> r, {bool cityLevel = false}) {
  final addr = (r['address'] as Map?)?.cast<String, dynamic>() ?? const {};
  String? pick(List<String> keys) {
    for (final k in keys) {
      final v = addr[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  final town = pick(['city', 'town', 'village', 'municipality', 'hamlet', 'county', 'state']);
  final display = r['display_name'] as String? ?? '';
  String name;
  if (cityLevel) {
    name = town ?? display.split(',').first;
  } else {
    final n = r['name'] as String?;
    name = (n != null && n.isNotEmpty)
        ? n
        : [
            pick(['road', 'pedestrian', 'square']),
            pick(['house_number']),
          ].nonNulls.join(' ');
    if (name.isEmpty) name = display.split(',').first;
  }
  // A compact address: road + town + country, skipping what's already in the name.
  final parts = <String>[
    if (!cityLevel) ?pick(['road', 'pedestrian', 'square']),
    if (!cityLevel) ?pick(['suburb', 'neighbourhood', 'quarter']),
    ?town,
    ?pick(['country']),
  ].where((p) => p != name).toSet().toList();
  return GeoPlace(
    name: name.trim(),
    address: parts.join(', '),
    lat: double.parse('${r['lat']}'),
    lng: double.parse('${r['lon']}'),
  );
}

/// What could be extracted from a pasted maps link.
class MapsLink {
  const MapsLink({this.name, this.lat, this.lng, this.isShortLink = false});
  final String? name;
  final double? lat;
  final double? lng;

  /// maps.app.goo.gl / goo.gl links must be resolved (followed) first.
  final bool isShortLink;

  bool get hasPosition => lat != null && lng != null;
}

/// Parses Google Maps (and generic geo:/OSM) links.
MapsLink? parseMapsLink(String input) {
  final text = input.trim();
  if (text.startsWith('geo:')) {
    final m = RegExp(r'^geo:(-?\d+\.?\d*),(-?\d+\.?\d*)').firstMatch(text);
    return m == null ? null : MapsLink(lat: double.parse(m.group(1)!), lng: double.parse(m.group(2)!));
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final host = uri.host.toLowerCase();
  if (host == 'maps.app.goo.gl' || (host == 'goo.gl' && uri.path.startsWith('/maps'))) {
    return const MapsLink(isShortLink: true);
  }
  if (!host.contains('google.') && !host.contains('openstreetmap.org')) return null;

  // Pasted links may contain raw non-ASCII characters, which decodeFull rejects.
  String decoded;
  try {
    decoded = Uri.decodeFull(text);
  } on ArgumentError {
    decoded = text;
  }
  double? lat, lng;
  // !3d<lat>!4d<lng> is the exact position of a selected place.
  final exact = RegExp(r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)').allMatches(decoded).lastOrNull;
  final at = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(decoded);
  final hit = exact ?? at;
  if (hit != null) {
    lat = double.parse(hit.group(1)!);
    lng = double.parse(hit.group(2)!);
  }
  // OSM: #map=zoom/lat/lng or ?mlat=..&mlon=..
  final osm = RegExp(r'map=\d+/(-?\d+\.\d+)/(-?\d+\.\d+)').firstMatch(decoded);
  if (lat == null && osm != null) {
    lat = double.parse(osm.group(1)!);
    lng = double.parse(osm.group(2)!);
  }
  if (lat == null && uri.queryParameters['mlat'] != null) {
    lat = double.tryParse(uri.queryParameters['mlat']!);
    lng = double.tryParse(uri.queryParameters['mlon'] ?? '');
  }

  String? name;
  final place = RegExp(r'/place/([^/@]+)').firstMatch(uri.path);
  if (place != null) {
    final raw = place.group(1)!.replaceAll('+', ' ');
    try {
      name = Uri.decodeComponent(raw);
    } on ArgumentError {
      name = raw;
    }
  }
  final q = uri.queryParameters['q'] ?? uri.queryParameters['query'];
  if (q != null && q.isNotEmpty) {
    final coords = RegExp(r'^\s*(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)\s*$').firstMatch(q);
    if (coords != null) {
      lat ??= double.parse(coords.group(1)!);
      lng ??= double.parse(coords.group(2)!);
    } else {
      name ??= q.replaceAll('+', ' ');
    }
  }
  if (name == null && lat == null) return null;
  return MapsLink(name: name, lat: lat, lng: lng);
}

/// Follows a short maps link to its full URL. Not possible in the browser
/// (cross-origin redirects are hidden), so returns null there.
Future<String?> resolveShortLink(String url) async {
  if (kIsWeb) return null;
  final client = http.Client();
  try {
    var current = Uri.parse(url.trim());
    for (var i = 0; i < 5; i++) {
      final req = http.Request('GET', current)..followRedirects = false;
      final res = await client.send(req).timeout(const Duration(seconds: 10));
      final location = res.headers['location'];
      await res.stream.drain<void>();
      if (location == null) return current.toString();
      current = current.resolve(location);
    }
    return current.toString();
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}
