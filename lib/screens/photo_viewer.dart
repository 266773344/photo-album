import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../models/grouping.dart';
import '../models/models.dart';
import 'event_screen.dart' show openAlbumMap;
import '../theme/event_theme.dart';
import '../widgets/common.dart';
import 'photo_actions.dart';

/// Fullscreen, swipeable, zoomable photo viewer.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.eventId, required this.initialPhotoId});
  final String eventId;
  final String initialPhotoId;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  PageController? _pages;
  int _index = 0;
  bool _chrome = true;
  bool _zoomed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pages == null) {
      final e = AlbumScope.read(context).byId(widget.eventId)!;
      _index = math.max(0, e.photos.indexWhere((p) => p.id == widget.initialPhotoId));
      _pages = PageController(initialPage: _index);
    }
  }

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.of(context);
    final e = repo.byId(widget.eventId);
    if (e == null || e.photos.isEmpty) return const SizedBox.shrink();
    _index = _index.clamp(0, e.photos.length - 1);
    final style = EventStyle.of(e);
    // A very dark backdrop, faintly tinted with the album's colour.
    final backdrop = Color.lerp(Colors.black, style.seed, 0.12)!;
    final photo = e.photos[_index];
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fullWidth = math.min(3200, (math.max(size.width, size.height) * dpr).round());

    return Theme(
      data: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: style.seed, brightness: Brightness.dark)),
      child: Scaffold(
        backgroundColor: backdrop,
        extendBodyBehindAppBar: true,
        appBar: _chrome
            ? AppBar(
                backgroundColor: Colors.black26,
                foregroundColor: Colors.white,
                title: Text('${_index + 1} / ${e.photos.length}'),
                actions: [
                  if (photo.hasLocation)
                    IconButton(
                      tooltip: 'Show on map',
                      icon: const Icon(Icons.map_outlined),
                      onPressed: () => openAlbumMap(context, e, focus: LatLng(photo.lat!, photo.lng!)),
                    ),
                  IconButton(
                    tooltip: 'Photo options',
                    icon: const Icon(Icons.more_vert),
                    onPressed: () async {
                      final deleted = await showPhotoActions(context, e, photo);
                      if (deleted && context.mounted && e.photos.isEmpty) Navigator.pop(context);
                    },
                  ),
                ],
              )
            : null,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pages,
              physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
              itemCount: e.photos.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => _ZoomablePhoto(
                photo: e.photos[i],
                fullWidth: fullWidth,
                onTap: () => setState(() => _chrome = !_chrome),
                onZoomChanged: (z) {
                  if (z != _zoomed) setState(() => _zoomed = z);
                },
              ),
            ),
            if (_chrome)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xCC000000), Color(0x00000000)],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 40, 20, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (photo.caption.isNotEmpty)
                              Text(photo.caption, style: const TextStyle(color: Colors.white, fontSize: 17, height: 1.35)),
                            const SizedBox(height: 4),
                            Text(
                              [
                                DateFormat('EEEE, d MMMM y · HH:mm').format(photo.takenAt),
                                ?(e.momentOf(photo.id)?.place?.name ?? e.dayPlaces[dayKey(photo.takenAt)]),
                              ].join('  ·  '),
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({required this.photo, required this.fullWidth, required this.onTap, required this.onZoomChanged});
  final Photo photo;
  final int fullWidth;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> {
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom(TapDownDetails d) {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      widget.onZoomChanged(false);
    } else {
      const s = 2.5;
      final p = d.localPosition;
      _transform.value = Matrix4.identity()
        ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
      widget.onZoomChanged(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.read(context);
    final p = widget.photo;
    TapDownDetails? lastDown;
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => lastDown = d,
      onDoubleTap: () {
        if (lastDown != null) _toggleZoom(lastDown!);
      },
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 5,
        onInteractionEnd: (_) => widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.01),
        child: Center(
          child: Hero(
            tag: 'photo_${p.id}',
            child: AspectRatio(
              aspectRatio: p.aspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Thumbnail shows instantly; the full-resolution original fades in on top.
                  PhotoThumb(photo: p, radius: 0, fit: BoxFit.contain),
                  Image(
                    image: ResizeImage(
                      // Referenced photos load from the device gallery, copied ones from storage.
                      p.assetId != null && repo.gallery != null
                          ? GalleryImage(
                              repo.gallery!,
                              p.assetId!,
                              (widget.fullWidth * math.min(p.width, p.height) / math.max(p.width, p.height)).round(),
                            )
                          : StoredImage(repo, p.fullKey),
                      width: widget.fullWidth,
                      height: widget.fullWidth,
                      policy: ResizeImagePolicy.fit,
                    ),
                    fit: BoxFit.contain,
                    frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                      opacity: frame == null && !sync ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      child: child,
                    ),
                    errorBuilder: (_, _, _) => p.assetId == null
                        ? const SizedBox.shrink()
                        : const Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: EdgeInsets.all(8),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.all(Radius.circular(12)),
                                ),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: Text(
                                    'Original no longer on this device',
                                    style: TextStyle(color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
