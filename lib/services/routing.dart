import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/models.dart';

const _distance = Distance();

/// Finds road and footpath routes on OpenStreetMap data using the public
/// FOSSGIS OSRM servers (routing.openstreetmap.de). Requests are rate limited
/// to one per 1.1 s and only send coordinates.
class RouteFinder {
  RouteFinder({http.Client? client}) : _client = client ?? http.Client();

  static final instance = RouteFinder();

  final http.Client _client;
  Future<void> _queue = Future.value();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static const _userAgent = 'PhotoAlbumApp/1.0 (Flutter personal photo album)';

  /// Road/path route from [a] to [b] as an encoded polyline, or null if there
  /// is none (e.g. across open sea).
  Future<String?> route(LatLng a, LatLng b, TravelMode mode) {
    assert(mode.routed);
    final profile = mode == TravelMode.foot ? 'routed-foot' : 'routed-car';
    final url = Uri.https(
      'routing.openstreetmap.de',
      '/$profile/route/v1/driving/${a.longitude},${a.latitude};${b.longitude},${b.latitude}',
      {'overview': 'simplified', 'geometries': 'polyline'},
    );
    final result = _queue.then((_) async {
      final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _last = DateTime.now();
      final res = await _client.get(url, headers: kIsWeb ? null : {'User-Agent': _userAgent});
      if (res.statusCode != 200) {
        // 400 "NoRoute"/"NoSegment" just means there is no road connection.
        if (res.statusCode == 400) return null;
        throw http.ClientException('Routing failed (${res.statusCode})', url);
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (body['code'] != 'Ok') return null;
      final routes = body['routes'] as List;
      return routes.isEmpty ? null : (routes.first as Map<String, dynamic>)['geometry'] as String?;
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// Guesses how the stretch between two stops was travelled from its length
/// and the time between them.
TravelMode guessTravelMode(LatLng from, LatLng to, Duration between) {
  final km = _distance.as(LengthUnit.Meter, from, to) / 1000;
  final hours = math.max(between.inMinutes / 60, 0.05);
  final speed = km / hours;
  if (km > 800 || (km > 150 && speed > 250)) return TravelMode.flight;
  if (km < 1.5) return TravelMode.foot;
  return TravelMode.car;
}

/// Whether a found route is plausible: not wildly longer than the straight
/// line (which would suggest a train, ferry or flight instead).
bool isPlausibleRoute(LatLng from, LatLng to, List<LatLng> route) {
  final straight = _distance.as(LengthUnit.Meter, from, to);
  if (straight < 300) return true;
  var length = 0.0;
  for (var i = 1; i < route.length; i++) {
    length += _distance.as(LengthUnit.Meter, route[i - 1], route[i]);
  }
  return length <= straight * 3;
}

/// The points to draw for a leg: the real route if known, a gentle arc for
/// flights, otherwise a straight line.
List<LatLng> legPoints(LatLng from, LatLng to, LegRoute? route) {
  if (route?.polyline != null) {
    final pts = decodePolyline(route!.polyline!);
    if (pts.length >= 2) return [from, ...pts, to];
  }
  if (route?.mode == TravelMode.flight) return flightArc(from, to);
  return [from, to];
}

/// A curved line between two points, bulging sideways by 15 % of the distance.
List<LatLng> flightArc(LatLng a, LatLng b, {int segments = 24}) {
  final mx = (a.longitude + b.longitude) / 2, my = (a.latitude + b.latitude) / 2;
  final dx = b.longitude - a.longitude, dy = b.latitude - a.latitude;
  // Control point: midpoint shifted perpendicular to the line.
  final cx = mx - dy * 0.3, cy = my + dx * 0.3;
  return [
    for (var i = 0; i <= segments; i++)
      () {
        final t = i / segments, u = 1 - t;
        return LatLng(
          u * u * a.latitude + 2 * u * t * cy + t * t * b.latitude,
          u * u * a.longitude + 2 * u * t * cx + t * t * b.longitude,
        );
      }(),
  ];
}

/// Decodes a Google/OSRM encoded polyline (precision 5).
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0, lat = 0, lng = 0;
  int next() {
    var result = 0, shift = 0, b = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && index < encoded.length);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  try {
    while (index < encoded.length) {
      lat += next();
      lng += next();
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
  } catch (_) {
    // Malformed: return what was decoded.
  }
  return points;
}

/// Encodes points as a polyline (precision 5); used by tests.
String encodePolyline(List<LatLng> points) {
  final out = StringBuffer();
  var pLat = 0, pLng = 0;
  void put(int v) {
    var s = v < 0 ? ~(v << 1) : v << 1;
    while (s >= 0x20) {
      out.writeCharCode((0x20 | (s & 0x1f)) + 63);
      s >>= 5;
    }
    out.writeCharCode(s + 63);
  }

  for (final p in points) {
    final lat = (p.latitude * 1e5).round(), lng = (p.longitude * 1e5).round();
    put(lat - pLat);
    put(lng - pLng);
    pLat = lat;
    pLng = lng;
  }
  return out.toString();
}
