import 'package:latlong2/latlong.dart';

import '../data/similarity.dart' show pickCover;
import 'grouping.dart';
import 'models.dart';

/// Photos join the current visit while they are this close to its centre…
const visitRadiusMeters = 200.0;

/// …and taken less than this long after its previous photo.
const visitMaxGap = Duration(hours: 3);

const _distance = Distance();

/// Where a photo appears on the map: its own GPS position, otherwise the
/// place of the moment it belongs to (set by hand). Null if neither exists.
LatLng? effectivePosition(AlbumEvent e, Photo p) {
  if (p.hasLocation) return LatLng(p.lat!, p.lng!);
  final place = e.momentOf(p.id)?.place;
  return place == null ? null : LatLng(place.lat, place.lng);
}

/// A stop on the journey: photos taken close together in place and time.
class Visit {
  Visit(this.index, this.photos, this.center, this.moment);

  /// Position in the journey (0 = first stop).
  final int index;

  /// In time order.
  final List<Photo> photos;
  final LatLng center;

  /// The moment, if every photo of this visit belongs to the same one.
  final Moment? moment;

  DateTime get start => photos.first.takenAt;
  DateTime get end => photos.last.takenAt;

  /// The photo that represents the visit on the map: the moment's cover if
  /// the visit is one moment, otherwise the sharpest shot.
  Photo get representative => _representative ??= pickCover(photos);
  Photo? _representative;

  /// A short label: the moment's title or its place name.
  String? get label => moment?.title ?? moment?.place?.name;
}

/// Groups the album's positioned photos into [Visit]s, in time order.
List<Visit> buildVisits(
  AlbumEvent e, {
  double radiusMeters = visitRadiusMeters,
  Duration maxGap = visitMaxGap,
}) {
  final groups = <(List<Photo>, List<LatLng>)>[];
  for (final p in e.photos) {
    final pos = effectivePosition(e, p);
    if (pos == null) continue;
    if (groups.isNotEmpty) {
      final (photos, points) = groups.last;
      final center = _centroid(points);
      final close = _distance.as(LengthUnit.Meter, center, pos) <= radiusMeters;
      final soon = p.takenAt.difference(photos.last.takenAt) < maxGap;
      if (close && soon) {
        photos.add(p);
        points.add(pos);
        continue;
      }
    }
    groups.add(([p], [pos]));
  }

  return [
    for (final (i, (photos, points)) in groups.indexed)
      Visit(i, photos, _centroid(points), _commonMoment(e, photos)),
  ];
}

Moment? _commonMoment(AlbumEvent e, List<Photo> photos) {
  final m = e.momentOf(photos.first.id);
  if (m == null) return null;
  return photos.every((p) => e.momentOf(p.id) == m) ? m : null;
}

LatLng _centroid(List<LatLng> points) {
  var lat = 0.0, lng = 0.0;
  for (final p in points) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / points.length, lng / points.length);
}
