import 'dart:math' as math;
import 'dart:typed_data';

import '../models/models.dart';

/// Cheap image fingerprints for spotting near-duplicate photos.
///
/// * dHash: the image is reduced to 9×8 average-luminance blocks and each bit
///   records whether a block is darker than its right neighbour. Very similar
///   photos differ in only a few of the 64 bits. Costs well under 1 ms.
/// * Sharpness: variance of the Laplacian on a small greyscale copy; the
///   sharpest shot of a group becomes the carousel's cover.
class PhotoFeatures {
  const PhotoFeatures(this.dhash, this.sharpness);
  final String dhash;
  final double sharpness;
}

PhotoFeatures computeFeatures(Uint8List rgba, int w, int h) =>
    PhotoFeatures(_dHash(rgba, w, h), _sharpness(rgba, w, h));

double _lum(Uint8List p, int i) => p[i] * 0.299 + p[i + 1] * 0.587 + p[i + 2] * 0.114;

String _dHash(Uint8List rgba, int w, int h) {
  const cols = 9, rows = 8;
  final grid = List<double>.filled(cols * rows, 0);
  for (var by = 0; by < rows; by++) {
    final y0 = by * h ~/ rows, y1 = math.max(y0 + 1, (by + 1) * h ~/ rows);
    final sy = math.max(1, (y1 - y0) ~/ 12);
    for (var bx = 0; bx < cols; bx++) {
      final x0 = bx * w ~/ cols, x1 = math.max(x0 + 1, (bx + 1) * w ~/ cols);
      final sx = math.max(1, (x1 - x0) ~/ 12);
      var sum = 0.0, n = 0;
      for (var y = y0; y < y1 && y < h; y += sy) {
        for (var x = x0; x < x1 && x < w; x += sx) {
          sum += _lum(rgba, (y * w + x) * 4);
          n++;
        }
      }
      grid[by * cols + bx] = n == 0 ? 0 : sum / n;
    }
  }
  // Two 32-bit halves so this works identically on the web (no 64-bit ints).
  var hi = 0, lo = 0;
  for (var by = 0; by < rows; by++) {
    for (var bx = 0; bx < 8; bx++) {
      final bit = grid[by * cols + bx] < grid[by * cols + bx + 1] ? 1 : 0;
      if (by < 4) {
        hi = (hi << 1 | bit) & 0xFFFFFFFF;
      } else {
        lo = (lo << 1 | bit) & 0xFFFFFFFF;
      }
    }
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}

double _sharpness(Uint8List rgba, int w, int h) {
  final step = math.max(1, math.max(w, h) ~/ 256);
  final gw = w ~/ step, gh = h ~/ step;
  if (gw < 3 || gh < 3) return 0;
  final g = Float64List(gw * gh);
  for (var y = 0; y < gh; y++) {
    for (var x = 0; x < gw; x++) {
      g[y * gw + x] = _lum(rgba, ((y * step) * w + x * step) * 4);
    }
  }
  var sum = 0.0, sum2 = 0.0, n = 0;
  for (var y = 1; y < gh - 1; y++) {
    for (var x = 1; x < gw - 1; x++) {
      final i = y * gw + x;
      final l = 4 * g[i] - g[i - 1] - g[i + 1] - g[i - gw] - g[i + gw];
      sum += l;
      sum2 += l * l;
      n++;
    }
  }
  final mean = sum / n;
  return sum2 / n - mean * mean;
}

/// Number of differing bits between two dHashes (0 = identical, 64 = opposite).
int hammingDistance(String a, String b) {
  var d = 0;
  for (var half = 0; half < 2; half++) {
    var x = int.parse(a.substring(half * 8, half * 8 + 8), radix: 16) ^
        int.parse(b.substring(half * 8, half * 8 + 8), radix: 16);
    for (var i = 0; i < 32; i++) {
      d += (x >> i) & 1;
    }
  }
  return d;
}

/// Average distance (0..~440) between two palettes: for every colour of one,
/// the weighted distance to the nearest colour of the other, both ways.
double paletteDistance(List<PaletteColor> a, List<PaletteColor> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  double oneWay(List<PaletteColor> x, List<PaletteColor> y) {
    var total = 0.0, wsum = 0.0;
    for (final c in x) {
      var best = double.infinity;
      for (final o in y) {
        final dr = ((c.argb >> 16) & 0xFF) - ((o.argb >> 16) & 0xFF);
        final dg = ((c.argb >> 8) & 0xFF) - ((o.argb >> 8) & 0xFF);
        final db = (c.argb & 0xFF) - (o.argb & 0xFF);
        best = math.min(best, math.sqrt((dr * dr + dg * dg + db * db).toDouble()));
      }
      total += best * c.weight;
      wsum += c.weight;
    }
    return wsum == 0 ? 0 : total / wsum;
  }

  return (oneWay(a, b) + oneWay(b, a)) / 2;
}

/// Tunables for [detectSimilarGroups].
const similarMaxBits = 10; // with reliable capture times
const similarMaxBitsNoTime = 6; // when times are just file dates
const similarMaxBitsToFirst = 14; // keeps slow pans from chaining forever
const similarMaxPalette = 48.0;
const similarMaxGap = Duration(seconds: 120);
const similarMaxIndexGap = 4;

bool _similar(Photo a, Photo b, {required bool timed}) {
  if (a.dhash == null || b.dhash == null) return false;
  final bits = hammingDistance(a.dhash!, b.dhash!);
  if (bits > (timed ? similarMaxBits : similarMaxBitsNoTime)) return false;
  return paletteDistance(a.palette, b.palette) <= similarMaxPalette;
}

/// Finds groups of near-duplicate photos.
///
/// [photos] must be sorted by time. Only photos taken close together are
/// compared, so this is effectively linear in the number of photos.
/// [groupKey] returns e.g. the moment a photo belongs to; photos with
/// different keys are never grouped.
List<List<Photo>> detectSimilarGroups(List<Photo> photos, {String? Function(Photo)? groupKey}) {
  final groups = <_Group>[];
  final open = <_Group>[];
  for (var i = 0; i < photos.length; i++) {
    final p = photos[i];
    if (p.dhash == null) continue;
    final key = groupKey?.call(p);

    open.removeWhere((g) {
      final last = g.members.last;
      final timed = last.exactTime && p.exactTime;
      return timed ? p.takenAt.difference(last.takenAt).abs() > similarMaxGap : i - g.lastIndex > similarMaxIndexGap;
    });

    _Group? target;
    for (final g in open.reversed) {
      if (g.key != key) continue;
      if (hammingDistance(p.dhash!, g.members.first.dhash!) > similarMaxBitsToFirst) continue;
      final recent = g.members.length <= 4 ? g.members : g.members.sublist(g.members.length - 4);
      if (recent.any((m) => _similar(m, p, timed: m.exactTime && p.exactTime))) {
        target = g;
        break;
      }
    }
    if (target == null) {
      target = _Group(key);
      open.add(target);
      groups.add(target);
    }
    target.members.add(p);
    target.lastIndex = i;
  }
  return [for (final g in groups) if (g.members.length > 1) g.members];
}

class _Group {
  _Group(this.key);
  final String? key;
  final members = <Photo>[];
  int lastIndex = 0;
}

/// The best photo to represent a group: the sharpest one.
Photo pickCover(List<Photo> photos) =>
    photos.reduce((a, b) => (b.sharpness ?? 0) > (a.sharpness ?? 0) ? b : a);
