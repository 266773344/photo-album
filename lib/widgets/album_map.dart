import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../models/grouping.dart';
import '../models/models.dart';
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

/// A point of interest on an album map.
class MapPin {
  MapPin.photo(AlbumItem this.item)
      : point = LatLng(item.cover.lat!, item.cover.lng!),
        moment = null;
  MapPin.moment(Moment this.moment)
      : point = LatLng(moment.place!.lat, moment.place!.lng),
        item = null;

  final LatLng point;
  final AlbumItem? item;
  final Moment? moment;
}

/// Everything in an album that has a position, plus the route in time order.
class AlbumGeo {
  AlbumGeo(AlbumEvent e) {
    for (final day in buildAlbumStructure(e)) {
      for (final block in day.blocks) {
        for (final item in block.items) {
          if (item.cover.hasLocation) pins.add(MapPin.photo(item));
        }
        if (block is MomentBlock && block.moment.place != null) pins.add(MapPin.moment(block.moment));
      }
    }
    final photoRoute = [
      for (final p in e.photos)
        if (p.hasLocation) LatLng(p.lat!, p.lng!),
    ];
    route = photoRoute.isNotEmpty ? photoRoute : [for (final p in pins) p.point];
  }

  final List<MapPin> pins = [];
  late final List<LatLng> route;

  bool get isEmpty => pins.isEmpty;
  List<LatLng> get allPoints => [...route, for (final p in pins) p.point];
}

/// Small, non-interactive route map shown on the album page. Tap opens [onOpen].
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
                  if (geo.route.length > 1)
                    PolylineLayer(polylines: [
                      Polyline(points: geo.route, color: s.primary.withValues(alpha: 0.8), strokeWidth: 3),
                    ]),
                  MarkerLayer(markers: [
                    for (final p in geo.pins)
                      Marker(
                        point: p.point,
                        width: p.moment != null ? 16 : 10,
                        height: p.moment != null ? 16 : 10,
                        child: Container(
                          decoration: BoxDecoration(
                            color: p.moment != null ? s.tertiary : s.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ]),
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
                  decoration: BoxDecoration(color: s.surface.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(14)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.map_outlined, size: 16, color: s.primary),
                    const SizedBox(width: 6),
                    Text('Open map', style: TextStyle(color: s.onSurface, fontSize: 12.5)),
                  ]),
                ),
              ),
            ),
            Positioned(
              left: 8,
              bottom: 6,
              child: IgnorePointer(
                child: Text('© OpenStreetMap', style: TextStyle(fontSize: 10, color: s.onSurface.withValues(alpha: 0.7))),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen map of an album: photo thumbnails, moment pins and the route.
class AlbumMapScreen extends StatelessWidget {
  const AlbumMapScreen({super.key, required this.eventId, this.focus, required this.onOpenPhoto});

  final String eventId;

  /// Centre on this point initially (e.g. one photo).
  final LatLng? focus;
  final void Function(BuildContext context, Photo photo) onOpenPhoto;

  @override
  Widget build(BuildContext context) {
    final e = AlbumScope.of(context).byId(eventId);
    if (e == null) return const Scaffold();
    final geo = AlbumGeo(e);
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(e.title)),
      body: geo.isEmpty
          ? const Center(child: Text('No photo in this album has a location yet.'))
          : FlutterMap(
              options: MapOptions(
                initialCenter: focus ?? geo.allPoints.first,
                initialZoom: 16,
                initialCameraFit: focus == null
                    ? CameraFit.coordinates(coordinates: geo.allPoints, padding: const EdgeInsets.all(48), maxZoom: 16)
                    : null,
              ),
              children: [
                ...baseMapLayers(context),
                if (geo.route.length > 1)
                  PolylineLayer(polylines: [
                    Polyline(points: geo.route, color: s.primary.withValues(alpha: 0.75), strokeWidth: 3.5),
                  ]),
                MarkerLayer(markers: [
                  for (final p in geo.pins.where((p) => p.item != null))
                    Marker(
                      point: p.point,
                      width: 46,
                      height: 46,
                      child: GestureDetector(
                        onTap: () => onOpenPhoto(context, p.item!.cover),
                        child: Container(
                          padding: const EdgeInsets.all(2.5),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(blurRadius: 4, color: Colors.black38)],
                          ),
                          child: ClipOval(child: PhotoThumb(photo: p.item!.cover, radius: 0)),
                        ),
                      ),
                    ),
                  for (final p in geo.pins.where((p) => p.moment != null))
                    Marker(
                      point: p.point,
                      width: 180,
                      height: 64,
                      alignment: Alignment.topCenter,
                      child: _MomentPin(moment: p.moment!),
                    ),
                ]),
                osmAttribution(),
              ],
            ),
    );
  }
}

class _MomentPin extends StatelessWidget {
  const _MomentPin({required this.moment});
  final Moment moment;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: s.tertiaryContainer,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
          ),
          child: Text(
            moment.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: s.onTertiaryContainer, fontWeight: FontWeight.w600, fontSize: 12.5),
          ),
        ),
        Icon(Icons.place, color: s.tertiary, size: 28),
      ],
    );
  }
}
