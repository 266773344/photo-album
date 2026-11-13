import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/models.dart';
import '../theme/palette.dart';
import 'similarity.dart';

export 'similarity.dart' show PhotoFeatures;

/// Result of preparing one picked image for the album.
class ProcessedPhoto {
  ProcessedPhoto(this.thumbJpeg, this.width, this.height, this.palette, this.exif, this.features);
  final Uint8List thumbJpeg;
  final int width;
  final int height;
  final List<PaletteColor> palette;
  final ExifInfo exif;
  final PhotoFeatures features;

  DateTime? get takenAt => exif.takenAt;
}

class ExifInfo {
  const ExifInfo({this.takenAt, this.lat, this.lng});
  final DateTime? takenAt;
  final double? lat;
  final double? lng;
}

/// Longest edge of stored thumbnails used in the collages.
const thumbMaxEdge = 1280;

/// Decodes [bytes] (using the platform's native decoder, which also applies
/// EXIF rotation), creates a JPEG thumbnail, extracts its colour palette and
/// reads the capture date.
Future<ProcessedPhoto> processPhoto(Uint8List bytes) async {
  final exif = await _readExif(bytes);

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
  return ProcessedPhoto(result.$1, w, h, result.$2, exif, result.$3);
}

/// Computes similarity features from an already stored thumbnail (for photos
/// imported before similarity detection existed).
Future<PhotoFeatures> featuresFromThumb(Uint8List jpeg) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(jpeg);
  final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
    final scale = math.min(1.0, 320 / math.max(w, h));
    return ui.TargetImageSize(width: (w * scale).round(), height: (h * scale).round());
  });
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = image.width, h = image.height;
  image.dispose();
  codec.dispose();
  if (data == null) throw StateError('Could not decode thumbnail');
  return computeFeatures(data.buffer.asUint8List(), w, h);
}

(Uint8List, List<PaletteColor>, PhotoFeatures) _encodeAndAnalyse((Uint8List, int, int) args) {
  final (rgba, w, h) = args;
  final palette = extractPalette(rgba, w, h);
  final features = computeFeatures(rgba, w, h);
  final image = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return (img.encodeJpg(image, quality: 86), palette, features);
}

Future<ExifInfo> _readExif(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(bytes);
    DateTime? takenAt;
    for (final name in const ['EXIF DateTimeOriginal', 'EXIF DateTimeDigitized', 'Image DateTime']) {
      takenAt = parseExifDate(tags[name]?.printable);
      if (takenAt != null) break;
    }
    double? coord(String key) {
      final values = tags['GPS GPS$key']?.values.toList();
      if (values == null || values.length < 3 || values.first is! Ratio) return null;
      final ratios = values.cast<Ratio>();
      return gpsToDecimal(
        [for (final r in ratios) r.denominator == 0 ? 0.0 : r.numerator / r.denominator],
        tags['GPS GPS${key}Ref']?.printable ?? '',
      );
    }

    final lat = coord('Latitude'), lng = coord('Longitude');
    // 0,0 is what some cameras write when they had no fix.
    final valid = lat != null && lng != null && !(lat == 0 && lng == 0) && lat.abs() <= 90 && lng.abs() <= 180;
    return ExifInfo(takenAt: takenAt, lat: valid ? lat : null, lng: valid ? lng : null);
  } catch (_) {
    // Not every format carries EXIF; fall back to file dates.
    return const ExifInfo();
  }
}

/// Converts EXIF degrees/minutes/seconds plus N/S/E/W reference to decimal degrees.
double gpsToDecimal(List<double> dms, String ref) {
  final v = dms[0] + dms[1] / 60 + dms[2] / 3600;
  final r = ref.trim().toUpperCase();
  return (r == 'S' || r == 'W') ? -v : v;
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
