import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/album_repository.dart';
import '../models/models.dart';
import '../services/gallery.dart';

/// Makes the [AlbumRepository] available to the widget tree and rebuilds
/// dependents when it changes.
class AlbumScope extends InheritedNotifier<AlbumRepository> {
  const AlbumScope({super.key, required AlbumRepository repo, required super.child}) : super(notifier: repo);

  /// Subscribes to changes.
  static AlbumRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AlbumScope>()!.notifier!;

  /// Access without subscribing (for callbacks).
  static AlbumRepository read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AlbumScope>()!.notifier!;
}

/// Image provider that loads bytes from the album's blob storage.
@immutable
class StoredImage extends ImageProvider<StoredImage> {
  const StoredImage(this.repo, this.blobKey);
  final AlbumRepository repo;
  final String blobKey;

  @override
  Future<StoredImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(StoredImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: blobKey);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await repo.blob(blobKey);
    if (bytes == null) throw StateError('Missing image $blobKey');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is StoredImage && other.blobKey == blobKey;

  @override
  int get hashCode => blobKey.hashCode;
}

/// Image provider that loads a photo straight from the device gallery, scaled
/// by the system so its shorter side is at least [edge] pixels.
@immutable
class GalleryImage extends ImageProvider<GalleryImage> {
  const GalleryImage(this.gallery, this.assetId, this.edge);
  final Gallery gallery;
  final String assetId;
  final int edge;

  @override
  Future<GalleryImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(GalleryImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: 'gallery $assetId');

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await gallery.image(assetId, edge, quality: 92);
    if (bytes == null) throw StateError('Photo $assetId is no longer on this device');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is GalleryImage && other.assetId == assetId && other.edge == edge;

  @override
  int get hashCode => Object.hash(assetId, edge);
}

/// A photo thumbnail that fills its box, with the photo's dominant colour as
/// placeholder while loading and a soft fade-in.
class PhotoThumb extends StatelessWidget {
  const PhotoThumb({
    super.key,
    required this.photo,
    this.radius = 8,
    this.fit = BoxFit.cover,
    this.heroTag,
    this.transparent = false,
  });

  final Photo photo;
  final double radius;
  final BoxFit fit;
  final Object? heroTag;

  /// No coloured placeholder behind the image (for letterboxed photos).
  final bool transparent;

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.read(context);
    final placeholder = transparent
        ? Colors.transparent
        : photo.palette.isEmpty
            ? Colors.grey.shade400
            : Color(photo.palette.first.argb);
    Widget child = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: placeholder,
        child: Image(
          image: StoredImage(repo, photo.thumbKey),
          fit: fit,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSync) => wasSync
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOut,
                  child: child,
                ),
          errorBuilder: (context, error, stack) => const Center(child: Icon(Icons.broken_image_outlined)),
        ),
      ),
    );
    if (heroTag != null) child = Hero(tag: heroTag!, child: child);
    return child;
  }
}

String formatDateRange(DateTime? start, DateTime? end) {
  if (start == null || end == null) return 'No photos yet';
  final d = DateFormat('d MMM y');
  if (dayKey(start) == dayKey(end)) return d.format(start);
  if (start.year == end.year && start.month == end.month) {
    return '${start.day}–${DateFormat('d MMM y').format(end)}';
  }
  if (start.year == end.year) {
    return '${DateFormat('d MMM').format(start)} – ${d.format(end)}';
  }
  return '${d.format(start)} – ${d.format(end)}';
}

/// Simple text-entry dialog. Returns null when cancelled.
Future<String?> editTextDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  bool multiline = true,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: multiline ? 3 : 1,
        maxLines: multiline ? 8 : 1,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}

Future<bool> confirmDialog(BuildContext context, {required String title, required String message, String action = 'Delete'}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}
