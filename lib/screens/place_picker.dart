import 'dart:async';

import '../l10n/strings.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../services/geocoding.dart';
import '../widgets/album_map.dart';
import '../widgets/common.dart';

/// Lets the user choose a place: search by name, tap the map, or paste a
/// Google Maps link. Returns the chosen [GeoPlace], or null when cancelled.
Future<GeoPlace?> pickPlace(BuildContext context, {String? title, GeoPlace? initial, LatLng? near}) {
  return Navigator.of(context).push<GeoPlace>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PlacePickerScreen(title: title ?? tr('Choose a place'), initial: initial, near: near),
    ),
  );
}

class PlacePickerScreen extends StatefulWidget {
  const PlacePickerScreen({super.key, required this.title, this.initial, this.near});
  final String title;
  final GeoPlace? initial;
  final LatLng? near;

  @override
  State<PlacePickerScreen> createState() => _PlacePickerScreenState();
}

class _PlacePickerScreenState extends State<PlacePickerScreen> {
  final _map = MapController();
  final _query = TextEditingController();
  Timer? _debounce;
  List<GeoPlace> _results = [];
  bool _searching = false;
  String? _message;
  GeoPlace? _selected;
  bool _resolvingPin = false;

  bool get _online => AlbumScope.read(context).settings.onlineLookups;
  Geocoder get _geo => AlbumScope.read(context).geocoder;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () => _search(text));
  }

  Future<void> _search(String text) async {
    final q = text.trim();
    if (q.isEmpty) {
      setState(() => _results = []);
      return;
    }
    // A pasted maps link?
    var link = parseMapsLink(q);
    if (link != null && link.isShortLink) {
      setState(() => _searching = true);
      final full = await resolveShortLink(q);
      link = full == null ? null : parseMapsLink(full);
      if (!mounted) return;
      if (link == null) {
        setState(() {
          _searching = false;
          _message = tr(
            'Short links can\'t be opened here. Open the link in Google Maps and copy the full address from the browser bar.',
          );
        });
        return;
      }
    }
    if (link != null) {
      if (link.hasPosition) {
        var place = GeoPlace(name: link.name ?? tr('Pinned location'), lat: link.lat!, lng: link.lng!);
        if (link.name == null && _online) {
          place = await _geo.reverse(link.lat!, link.lng!).catchError((_) => null) ?? place;
        }
        if (!mounted) return;
        _choose(place);
        setState(() => _searching = false);
        return;
      }
      if (link.name != null) return _search(link.name!);
    }

    if (!_online) {
      setState(
        () => _message = tr('Online place search is turned off in Settings. Tap the map to drop a pin instead.'),
      );
      return;
    }
    setState(() {
      _searching = true;
      _message = null;
    });
    try {
      final near = widget.near ?? (widget.initial == null ? null : LatLng(widget.initial!.lat, widget.initial!.lng));
      final results = await _geo.search(q, nearLat: near?.latitude, nearLng: near?.longitude);
      if (!mounted || _query.text.trim() != text.trim()) return;
      setState(() {
        _results = results;
        _message = results.isEmpty ? tr('Nothing found. Try adding the town, or tap the map.') : null;
      });
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _choose(GeoPlace p) {
    setState(() {
      _selected = p;
      _results = [];
      _message = null;
    });
    FocusScope.of(context).unfocus();
    _map.move(LatLng(p.lat, p.lng), 17);
  }

  Future<void> _dropPin(LatLng point) async {
    setState(() {
      _selected = GeoPlace(name: tr('Pinned location'), lat: point.latitude, lng: point.longitude);
      _results = [];
      _resolvingPin = _online;
    });
    if (!_online) return;
    try {
      final named = await _geo.reverse(point.latitude, point.longitude);
      if (!mounted || _selected?.lat != point.latitude) return;
      if (named != null) {
        setState(
          () =>
              _selected = GeoPlace(name: named.name, address: named.address, lat: point.latitude, lng: point.longitude),
        );
      }
    } catch (_) {
      // Keep the unnamed pin.
    } finally {
      if (mounted) setState(() => _resolvingPin = false);
    }
  }

  Future<void> _rename() async {
    final p = _selected!;
    final name = await editTextDialog(context, title: tr('Name this place'), initial: p.name, multiline: false);
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _selected = GeoPlace(name: name, address: p.address, lat: p.lat, lng: p.lng));
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final start = _selected != null ? LatLng(_selected!.lat, _selected!.lng) : widget.near;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _query,
              onChanged: _onChanged,
              onSubmitted: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: tr('Search a place, or paste a Google Maps link'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _query.clear();
                          _results = [];
                          _message = null;
                        }),
                      ),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: start ?? const LatLng(30, 10),
                    initialZoom: start == null ? 2.5 : 16,
                    onTap: (_, point) => _dropPin(point),
                    // Don't take keyboard focus away from the search field.
                    interactionOptions: const InteractionOptions(keyboardOptions: KeyboardOptions(autofocus: false)),
                  ),
                  children: [
                    ...baseMapLayers(context),
                    if (_selected != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(_selected!.lat, _selected!.lng),
                            width: 44,
                            height: 44,
                            alignment: Alignment.topCenter,
                            child: Icon(Icons.place, size: 44, color: s.primary),
                          ),
                        ],
                      ),
                    osmAttribution(),
                  ],
                ),
                if (_results.isNotEmpty || _message != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 0,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(16),
                      color: s.surfaceContainerHigh,
                      clipBehavior: Clip.antiAlias,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: _message != null
                            ? Padding(padding: const EdgeInsets.all(16), child: Text(_message!))
                            : ListView(
                                shrinkWrap: true,
                                children: [
                                  for (final r in _results)
                                    ListTile(
                                      leading: const Icon(Icons.place_outlined),
                                      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      subtitle: Text(r.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                                      onTap: () => _choose(r),
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Material(
            color: s.surfaceContainer,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: _selected == null
                    ? Text(
                        tr('Search above, or tap the map to drop a pin.'),
                        style: TextStyle(color: s.onSurfaceVariant),
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: _rename,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _selected!.name,
                                          style: Theme.of(context).textTheme.titleMedium,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Icon(Icons.edit_outlined, size: 16, color: s.onSurfaceVariant),
                                    ],
                                  ),
                                  if (_resolvingPin)
                                    const LinearProgressIndicator()
                                  else if (_selected!.address.isNotEmpty)
                                    Text(
                                      _selected!.address,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: s.onSurfaceVariant),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, _selected),
                            child: Text(tr('Use this place')),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
