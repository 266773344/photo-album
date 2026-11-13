import 'dart:math' as math;

import '../l10n/strings.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../models/visits.dart';
import '../services/routing.dart';
import 'common.dart';

/// OpenStreetMap base layer + required attribution.
List<Widget> baseMapLayers(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return [
    TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.photoalbum.photo_album',
      tileBuilder: dark ? darkModeTileBuilder : null,
    ),
  ];
}

Widget osmAttribution() => const RichAttributionWidget(
  showFlutterMapAttribution: false,
  attributions: [TextSourceAttribution('OpenStreetMap contributors')],
);

/// One stretch of the journey between two consecutive stops.
class JourneyLeg {
  JourneyLeg(this.from, this.to, this.key, this.route) : points = legPoints(from.center, to.center, route);

  final Visit from;
  final Visit to;
  final String key;
  final LegRoute? route;
  final List<LatLng> points;

  TravelMode get mode => route?.mode ?? TravelMode.straight;

  /// Drawn dashed: everything that isn't a real road/path route.
  bool get dashed => route?.polyline == null;
}

/// Everything the maps need about an album: its stops ([visits]) in time
/// order and the legs between them.
class AlbumGeo {
  AlbumGeo(this.event) : visits = buildVisits(event) {
    for (var i = 1; i < visits.length; i++) {
      final a = visits[i - 1], b = visits[i];
      final key = legKey(a.center.latitude, a.center.longitude, b.center.latitude, b.center.longitude);
      legs.add(JourneyLeg(a, b, key, event.routes[key]));
    }
    // Every photo maps to its stop, or the last stop before it: photos
    // without a position "happen" where the journey was at the time.
    var current = 0;
    final byPhoto = {
      for (final v in visits)
        for (final p in v.photos) p.id: v.index,
    };
    for (final p in event.photos) {
      current = byPhoto[p.id] ?? current;
      _visitOfPhoto[p.id] = current;
    }
  }

  final AlbumEvent event;
  final List<Visit> visits;
  final List<JourneyLeg> legs = [];
  final Map<String, int> _visitOfPhoto = {};

  bool get isEmpty => visits.isEmpty;

  /// The stop a photo belongs to (see constructor); null without stops.
  int? visitOfPhoto(String photoId) => visits.isEmpty ? null : _visitOfPhoto[photoId];

  List<LatLng> get allPoints => [for (final v in visits) v.center];
}

/// Route lines for [geo]. With [current], legs up to that stop are drawn
/// solid and later ones faded.
Widget journeyRouteLayer(
  BuildContext context,
  AlbumGeo geo, {
  int? current,
  LayerHitNotifier<String>? hitNotifier,
  double width = 3.5,
}) {
  final s = Theme.of(context).colorScheme;
  return PolylineLayer<String>(
    hitNotifier: hitNotifier,
    minimumHitbox: 16,
    polylines: [
      for (final leg in geo.legs)
        Polyline<String>(
          points: leg.points,
          hitValue: leg.key,
          strokeWidth: leg.mode == TravelMode.foot ? width * 0.8 : width,
          color: (leg.mode == TravelMode.ferry ? s.tertiary : s.primary).withValues(
            alpha: current == null || leg.to.index <= current ? 0.85 : 0.3,
          ),
          pattern: leg.dashed ? StrokePattern.dashed(segments: [width * 3, width * 2.2]) : const StrokePattern.solid(),
        ),
    ],
  );
}

/// Photo pins for the stops of [geo]. Stops whose pins would overlap at the
/// current zoom are merged into one pin (the earliest stop's photo on top).
class VisitMarkerLayer extends StatelessWidget {
  const VisitMarkerLayer({
    super.key,
    required this.geo,
    required this.onTapVisit,
    this.current,
    this.size = 46,
    this.zoomIntoGroups = true,
  });

  final AlbumGeo geo;
  final ValueChanged<Visit> onTapVisit;
  final int? current;
  final double size;

  /// Tapping a merged pin zooms in on it (full map) instead of opening its
  /// first stop (small, non-interactive maps).
  final bool zoomIntoGroups;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final groups = <(Offset, List<Visit>)>[];
    for (final v in geo.visits) {
      final o = camera.latLngToScreenOffset(v.center);
      final near = groups.where((g) => (g.$1 - o).distance < size * 0.8).firstOrNull;
      if (near != null) {
        near.$2.add(v);
      } else {
        groups.add((o, [v]));
      }
    }
    bool isCurrent((Offset, List<Visit>) g) => g.$2.any((v) => v.index == current);
    // The current stop is drawn last, so it is on top.
    groups.sort((a, b) => (isCurrent(a) ? 1 : 0) - (isCurrent(b) ? 1 : 0));
    return MarkerLayer(
      markers: [
        for (final g in groups)
          Marker(
            point: g.$2.first.center,
            width: size + 14,
            height: size + 14,
            child: VisitPin(
              photo: g.$2.first.representative,
              count: g.$2.fold(0, (n, v) => n + v.photos.length),
              size: size,
              highlighted: isCurrent(g),
              onTap: () {
                final visits = g.$2;
                // Zoom in to separate merged stops, unless they can't be separated.
                if (visits.length > 1 && zoomIntoGroups && camera.zoom < 17.5) {
                  MapController.of(context).fitCamera(
                    CameraFit.coordinates(
                      coordinates: [for (final v in visits) v.center],
                      padding: EdgeInsets.all(size * 1.5),
                      maxZoom: 18,
                    ),
                  );
                } else {
                  onTapVisit(visits.first);
                }
              },
            ),
          ),
      ],
    );
  }
}

/// A round photo pin with an optional photo count.
class VisitPin extends StatelessWidget {
  const VisitPin({
    super.key,
    required this.photo,
    required this.count,
    required this.size,
    required this.onTap,
    this.highlighted = false,
  });

  final Photo photo;
  final int count;
  final double size;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: highlighted ? size + 8 : size,
            height: highlighted ? size + 8 : size,
            padding: EdgeInsets.all(highlighted ? 3.5 : 2.5),
            decoration: BoxDecoration(
              color: highlighted ? s.primary : Colors.white,
              shape: BoxShape.circle,
              boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
            ),
            child: ClipOval(child: PhotoThumb(photo: photo, radius: 0)),
          ),
          if (count > 1)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 18),
                decoration: BoxDecoration(color: s.primary, borderRadius: BorderRadius.circular(9)),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: s.onPrimary, fontSize: 10.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const _pinSize = 34.0;

/// Web-mercator position of [p] on a world 1 unit wide.
(double, double) _mercator(LatLng p) {
  final lat = p.latitude.clamp(-85.0, 85.0) * math.pi / 180;
  return ((p.longitude + 180) / 360, (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2);
}

/// Zoom for showing stop [i] of [stops] (time order) on a map of [viewport]
/// centred on it: close enough to show its neighbourhood (nearby stops
/// shortly before/after, within ~30 km) and for its pin not to merge with
/// the nearest other stop - independent of how big the whole trip is.
double followZoom(
  List<LatLng> stops,
  int i, {
  required double overviewZoom,
  required Size viewport,
  double pinSize = _pinSize,
  double maxZoom = 16.5,
}) {
  const tile = 256.0;
  final here = stops[i];
  final (hx, hy) = _mercator(here);
  const dist = Distance();

  // 1. The neighbourhood: stops just before/after that are close by.
  var dx = 0.0, dy = 0.0;
  for (var k = math.max(0, i - 2); k <= math.min(stops.length - 1, i + 2); k++) {
    if (k == i || dist(here, stops[k]) > 30000) continue;
    final (x, y) = _mercator(stops[k]);
    dx = math.max(dx, (x - hx).abs());
    dy = math.max(dy, (y - hy).abs());
  }
  final halfW = math.max(40.0, viewport.width / 2 - 30), halfH = math.max(30.0, viewport.height / 2 - 34);
  double regionZoom;
  if (dx == 0 && dy == 0) {
    regionZoom = 13; // alone: town level
  } else {
    final fit = math.min(
      dx == 0 ? double.infinity : halfW / (dx * tile),
      dy == 0 ? double.infinity : halfH / (dy * tile),
    );
    regionZoom = math.log(fit) / math.ln2;
  }

  // 2. Keep its pin apart from the nearest stop.
  var nearest = double.infinity;
  for (var k = 0; k < stops.length; k++) {
    if (k == i) continue;
    final (x, y) = _mercator(stops[k]);
    final d = math.sqrt((x - hx) * (x - hx) + (y - hy) * (y - hy));
    if (d > 0) nearest = math.min(nearest, d);
  }
  final separateZoom = nearest.isFinite ? math.log(1.3 * pinSize / (tile * nearest)) / math.ln2 : 0.0;

  return math.max(regionZoom, separateZoom).clamp(math.min(overviewZoom, maxZoom), maxZoom);
}

/// The journey map in the album header. Non-interactive (it must not fight
/// the page scroll); follows [current] with a smooth camera move.
class JourneyHeaderMap extends StatefulWidget {
  const JourneyHeaderMap({
    super.key,
    required this.geo,
    required this.current,
    required this.onTapVisit,
    required this.onOpen,
  });

  final AlbumGeo geo;

  /// The stop the reader is looking at, or null at the top of the album.
  final int? current;
  final ValueChanged<Visit> onTapVisit;
  final VoidCallback onOpen;

  @override
  State<JourneyHeaderMap> createState() => _JourneyHeaderMapState();
}

class _JourneyHeaderMapState extends State<JourneyHeaderMap> with SingleTickerProviderStateMixin {
  final _map = MapController();
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  VoidCallback? _tick;
  bool _ready = false;

  @override
  void didUpdateWidget(JourneyHeaderMap old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current && _ready) _follow();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  CameraFit get _overview => CameraFit.coordinates(
    coordinates: widget.geo.allPoints,
    padding: const EdgeInsets.fromLTRB(36, 72, 36, 28),
    maxZoom: 14,
  );

  void _follow() {
    final camera = _map.camera;
    final overview = _overview.fit(camera);
    final i = widget.current;
    final LatLng center;
    final double zoom;
    if (i == null || i >= widget.geo.visits.length) {
      center = overview.center;
      zoom = overview.zoom;
    } else {
      center = widget.geo.visits[i].center;
      zoom = followZoom(
        widget.geo.allPoints,
        i,
        overviewZoom: overview.zoom,
        viewport: camera.nonRotatedSize,
        pinSize: _pinSize,
      );
    }
    // Big jumps (another city or country) take a little longer.
    _anim.duration = Duration(milliseconds: (zoom - camera.zoom).abs() > 4 ? 950 : 700);
    final lat = Tween(begin: camera.center.latitude, end: center.latitude);
    final lng = Tween(begin: camera.center.longitude, end: center.longitude);
    final z = Tween(begin: camera.zoom, end: zoom);
    final curve = CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic);
    if (_tick != null) _anim.removeListener(_tick!);
    _tick = () {
      if (mounted) _map.move(LatLng(lat.evaluate(curve), lng.evaluate(curve)), z.evaluate(curve));
    };
    _anim
      ..addListener(_tick!)
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCameraFit: _overview,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.none,
          keyboardOptions: KeyboardOptions.disabled(),
        ),
        onMapReady: () {
          _ready = true;
          if (widget.current != null) _follow();
        },
        onTap: (_, _) => widget.onOpen(),
      ),
      children: [
        ...baseMapLayers(context),
        journeyRouteLayer(context, widget.geo, current: widget.current, width: 3),
        VisitMarkerLayer(
          geo: widget.geo,
          current: widget.current,
          size: _pinSize,
          zoomIntoGroups: false,
          onTapVisit: widget.onTapVisit,
        ),
      ],
    );
  }
}

/// Full-screen map of an album: stops, route, and the travel mode per leg.
class AlbumMapScreen extends StatefulWidget {
  const AlbumMapScreen({super.key, required this.eventId, this.focus, required this.onTapVisit});

  final String eventId;

  /// Centre on this point initially (e.g. one photo).
  final LatLng? focus;

  /// A stop was tapped (the album jumps to its photos).
  final void Function(BuildContext context, Visit visit) onTapVisit;

  @override
  State<AlbumMapScreen> createState() => _AlbumMapScreenState();
}

class _AlbumMapScreenState extends State<AlbumMapScreen> {
  final LayerHitNotifier<String> _legHit = ValueNotifier(null);

  Future<void> _legActions(AlbumGeo geo) async {
    final key = _legHit.value?.hitValues.firstOrNull;
    final leg = geo.legs.where((l) => l.key == key).firstOrNull;
    if (leg == null) return;
    final repo = AlbumScope.read(context);
    final mode = await showModalBottomSheet<TravelMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(tr('How did you travel here?'), style: Theme.of(context).textTheme.titleLarge),
              ),
              for (final m in TravelMode.values)
                ListTile(
                  leading: Icon(travelModeIcon(m)),
                  title: Text(m.label),
                  subtitle: m.routed ? Text(tr('Follows roads and paths')) : null,
                  trailing: leg.mode == m ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, m),
                ),
            ],
          ),
        ),
      ),
    );
    if (mode == null || !mounted) return;
    final e = repo.byId(widget.eventId);
    if (e != null) await repo.setLegMode(e, leg.key, leg.from.center, leg.to.center, mode);
  }

  @override
  void dispose() {
    _legHit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = AlbumScope.of(context).byId(widget.eventId);
    if (e == null) return const Scaffold();
    final geo = AlbumGeo(e);
    return Scaffold(
      appBar: AppBar(title: Text(e.title)),
      body: geo.isEmpty
          ? Center(child: Text(tr('No photo in this album has a location yet.')))
          : FlutterMap(
              options: MapOptions(
                initialCenter: widget.focus ?? geo.allPoints.first,
                initialZoom: 16,
                initialCameraFit: widget.focus == null
                    ? CameraFit.coordinates(coordinates: geo.allPoints, padding: const EdgeInsets.all(56), maxZoom: 16)
                    : null,
                interactionOptions: const InteractionOptions(keyboardOptions: KeyboardOptions(autofocus: false)),
              ),
              children: [
                ...baseMapLayers(context),
                GestureDetector(
                  onTap: () => _legActions(geo),
                  child: journeyRouteLayer(context, geo, hitNotifier: _legHit),
                ),
                VisitMarkerLayer(geo: geo, onTapVisit: (v) => widget.onTapVisit(context, v)),
                osmAttribution(),
              ],
            ),
    );
  }
}

IconData travelModeIcon(TravelMode m) => switch (m) {
  TravelMode.car => Icons.directions_car_outlined,
  TravelMode.foot => Icons.directions_walk,
  TravelMode.train => Icons.train_outlined,
  TravelMode.ferry => Icons.directions_boat_outlined,
  TravelMode.flight => Icons.flight,
  TravelMode.straight => Icons.horizontal_rule,
};

/// Small, non-interactive overview map (shown when the header map is hidden).
class AlbumMapCard extends StatelessWidget {
  const AlbumMapCard({super.key, required this.geo, required this.onOpen});
  final AlbumGeo geo;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 150,
        child: Stack(
          children: [
            IgnorePointer(
              child: FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.coordinates(
                    coordinates: geo.allPoints,
                    padding: const EdgeInsets.all(28),
                    maxZoom: 14,
                  ),
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none,
                    keyboardOptions: KeyboardOptions.disabled(),
                  ),
                ),
                children: [
                  ...baseMapLayers(context),
                  journeyRouteLayer(context, geo, width: 2.5),
                  VisitMarkerLayer(geo: geo, size: 26, zoomIntoGroups: false, onTapVisit: (_) {}),
                ],
              ),
            ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: onOpen),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: s.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.map_outlined, size: 16, color: s.primary),
                      const SizedBox(width: 6),
                      Text(tr('Open map'), style: TextStyle(color: s.onSurface, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              bottom: 6,
              child: IgnorePointer(
                child: Text(
                  '© OpenStreetMap',
                  style: TextStyle(fontSize: 10, color: s.onSurface.withValues(alpha: 0.7)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
