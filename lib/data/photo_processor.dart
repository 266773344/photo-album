import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/models.dart';
import '../theme/palette.dart';

/// Result of preparing one picked image for the album.
class ProcessedPhoto {
  ProcessedPhoto(this.thumbJpeg, this.width, this.height, this.palette, this.takenAt);
  final Uint8List thumbJpeg;
  final int width;
  final int height;
  final List<PaletteColor> palette;
  final DateTime? takenAt;
}

/// Longest edge of stored thumbnails used in the collages.
const thumbMaxEdge = 1280;

/// Decodes [bytes] (using the platform's native decoder, which also applies
/// EXIF rotation), creates a JPEG thumbnail, extracts its colour palette and
/// reads the capture date.
Future<ProcessedPhoto> processPhoto(Uint8List bytes) async {
  final takenAt = await _readExifDate(bytes);

  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
    final scale = math.min(1.0, thumbMaxEdge / math.max(w, h));
    return ui.TargetImageSize(width: (w * scale).round(), height: (h * scale).round());
  });
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final w = image.width, h = image.height;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  codec.dispose();
  if (data == null) throw StateError('Could not decode image');

  // JPEG encoding and colour analysis are CPU heavy: run them off the UI
  // isolate on Android (on the web `compute` runs inline).
  final result = await compute(_encodeAndAnalyse, (data.buffer.asUint8List(), w, h));
  return ProcessedPhoto(result.$1, w, h, result.$2, takenAt);
}

(Uint8List, List<PaletteColor>) _encodeAndAnalyse((Uint8List, int, int) args) {
  final (rgba, w, h) = args;
  final palette = extractPalette(rgba, w, h);
  final image = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return (img.encodeJpg(image, quality: 86), palette);
}

Future<DateTime?> _readExifDate(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(bytes);
    for (final name in const ['EXIF DateTimeOriginal', 'EXIF DateTimeDigitized', 'Image DateTime']) {
      final parsed = parseExifDate(tags[name]?.printable);
      if (parsed != null) return parsed;
    }
  } catch (_) {
    // Not every format carries EXIF; fall back to file dates.
  }
  return null;
}

/// Parses EXIF's "YYYY:MM:DD HH:MM:SS" format.
DateTime? parseExifDate(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(s.trim());
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (p[0] < 1900) return null;
  return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
}
