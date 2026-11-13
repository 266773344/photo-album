import 'dart:math' as math;
import 'dart:typed_data';

import '../models/models.dart';

/// Extracts up to [maxColors] dominant colours from raw RGBA pixels.
///
/// Pixels are sampled, bucketed into a 4-bit-per-channel histogram and then
/// greedily merged so that visually similar buckets count as one colour.
/// Pure Dart so it can run in an isolate and be unit-tested.
List<PaletteColor> extractPalette(Uint8List rgba, int width, int height, {int maxColors = 6}) {
  final pixelCount = width * height;
  if (pixelCount == 0) return const [];
  final step = math.max(1, (pixelCount / 6000).floor());

  final count = <int, int>{};
  final sumR = <int, int>{}, sumG = <int, int>{}, sumB = <int, int>{};
  var total = 0;
  for (var i = 0; i < pixelCount; i += step) {
    final o = i * 4;
    if (rgba[o + 3] < 128) continue;
    final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
    final key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
    count[key] = (count[key] ?? 0) + 1;
    sumR[key] = (sumR[key] ?? 0) + r;
    sumG[key] = (sumG[key] ?? 0) + g;
    sumB[key] = (sumB[key] ?? 0) + b;
    total++;
  }
  if (total == 0) return const [];

  final buckets = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
  final clusters = <_Cluster>[];
  for (final k in buckets) {
    final n = count[k]!;
    final c = _Cluster(sumR[k]! / n, sumG[k]! / n, sumB[k]! / n, n.toDouble());
    _addToClusters(clusters, c, maxColors);
  }
  return _toPalette(clusters, total.toDouble());
}

/// Combines the palettes of several photos (each photo weighted equally).
List<PaletteColor> mergePalettes(Iterable<List<PaletteColor>> palettes, {int maxColors = 8}) {
  final all = <_Cluster>[];
  for (final p in palettes) {
    for (final c in p) {
      all.add(_Cluster(_r(c.argb).toDouble(), _g(c.argb).toDouble(), _b(c.argb).toDouble(), c.weight));
    }
  }
  all.sort((a, b) => b.n.compareTo(a.n));
  final clusters = <_Cluster>[];
  for (final c in all) {
    _addToClusters(clusters, c, maxColors);
  }
  final total = clusters.fold<double>(0, (s, c) => s + c.n);
  return total == 0 ? const [] : _toPalette(clusters, total);
}

/// Picks the colour that best characterises a palette: common, but also
/// reasonably saturated and neither near-black nor near-white.
int? chooseSeed(List<PaletteColor> palette) {
  int? best;
  var bestScore = -1.0;
  for (final c in palette) {
    final hsl = _hsl(c.argb);
    final lightnessFit = (1 - (hsl.l - 0.5).abs() * 1.6).clamp(0.05, 1.0);
    final score = math.pow(c.weight, 0.6) * (0.12 + hsl.s) * lightnessFit;
    if (score > bestScore) {
      bestScore = score.toDouble();
      best = c.argb;
    }
  }
  return best;
}

/// How typical a colour is for the generic backgrounds of travel photos:
/// sky blue, grey buildings/roads, foliage green, earth/sand, near-white and
/// near-black. 0 = distinctive, up to ~0.9 = very generic.
double backgroundCommonness(int argb) {
  final c = _hsl(argb);
  if (c.l > 0.9 || c.l < 0.1) return 0.9;
  if (c.s < 0.15) return 0.85; // greys
  final h = c.h;
  if (h >= 185 && h <= 235 && c.s < 0.75) return 0.75; // sky
  if (h >= 65 && h <= 165 && c.s < 0.6) return 0.7; // foliage, grass
  if (h >= 15 && h <= 50 && c.s < 0.55 && c.l < 0.75) return 0.6; // earth, sand, stone
  return 0;
}

/// How well a colour characterises an album: present in its photos, vivid,
/// not a generic background colour, and (when [baseline] - the user's other
/// albums - is given) more common here than elsewhere.
double vibeScore(PaletteColor c, {List<PaletteColor> baseline = const []}) {
  final hsl = _hsl(c.argb);
  final chroma = hsl.s * (1 - (2 * hsl.l - 1).abs());
  var elsewhere = 0.0;
  for (final b in baseline) {
    if (_dist2(b.argb, c.argb) < _mergeThreshold2) elsewhere += b.weight;
  }
  return math.pow(c.weight, 0.5) *
      (0.04 + chroma) *
      (1 - backgroundCommonness(c.argb)) /
      (1 + 3 * elsewhere);
}

/// The [count] colours that best capture an album's "vibe" (see
/// [vibeScore]), with different hues so the row isn't five blues.
/// [palette] should be a fine-grained merge (e.g. 24 colours).
List<PaletteColor> signatureColors(
  List<PaletteColor> palette, {
  List<PaletteColor> baseline = const [],
  int count = 5,
  double minHueDistance = 28,
}) {
  final ranked = [...palette]..sort((a, b) => vibeScore(b, baseline: baseline).compareTo(vibeScore(a, baseline: baseline)));
  final out = <PaletteColor>[];
  bool distinct(PaletteColor c) {
    final h = _hsl(c.argb);
    return out.every((o) {
      final oh = _hsl(o.argb);
      // Greys have no meaningful hue: compare lightness instead.
      if (h.s < 0.15 || oh.s < 0.15) return (h.l - oh.l).abs() > 0.15 || (h.s - oh.s).abs() > 0.2;
      final d = (h.h - oh.h).abs();
      return math.min(d, 360 - d) >= minHueDistance;
    });
  }

  for (final c in ranked) {
    if (out.length == count) break;
    if (distinct(c)) out.add(c);
  }
  // Not enough different hues: fill up with the next best.
  for (final c in ranked) {
    if (out.length == count) break;
    if (!out.contains(c)) out.add(c);
  }
  return out;
}

double _dist2(int a, int b) {
  final dr = (_r(a) - _r(b)).toDouble(), dg = (_g(a) - _g(b)).toDouble(), db = (_b(a) - _b(b)).toDouble();
  return 2 * dr * dr + 4 * dg * dg + 3 * db * db;
}

/// Weighted mean lightness (0..1) of a palette.
double averageLightness(List<PaletteColor> palette) {
  var sum = 0.0, w = 0.0;
  for (final c in palette) {
    sum += _hsl(c.argb).l * c.weight;
    w += c.weight;
  }
  return w == 0 ? 0.5 : sum / w;
}

// ---------------------------------------------------------------------------

class _Cluster {
  _Cluster(this.r, this.g, this.b, this.n);
  double r, g, b, n;

  double dist2(_Cluster o) {
    // Weighted RGB distance (approximates perceived difference).
    final dr = r - o.r, dg = g - o.g, db = b - o.b;
    return 2 * dr * dr + 4 * dg * dg + 3 * db * db;
  }

  void absorb(_Cluster o) {
    final t = n + o.n;
    r = (r * n + o.r * o.n) / t;
    g = (g * n + o.g * o.n) / t;
    b = (b * n + o.b * o.n) / t;
    n = t;
  }
}

const _mergeThreshold2 = 9.0 * 28 * 28;

void _addToClusters(List<_Cluster> clusters, _Cluster c, int maxColors) {
  _Cluster? nearest;
  var nearestD = double.infinity;
  for (final e in clusters) {
    final d = e.dist2(c);
    if (d < nearestD) {
      nearestD = d;
      nearest = e;
    }
  }
  if (nearest != null && (nearestD < _mergeThreshold2 || clusters.length >= maxColors)) {
    nearest.absorb(c);
  } else {
    clusters.add(c);
  }
}

List<PaletteColor> _toPalette(List<_Cluster> clusters, double total) {
  final sorted = [...clusters]..sort((a, b) => b.n.compareTo(a.n));
  return [
    for (final c in sorted)
      PaletteColor(
        0xFF000000 | c.r.round().clamp(0, 255) << 16 | c.g.round().clamp(0, 255) << 8 | c.b.round().clamp(0, 255),
        c.n / total,
      ),
  ];
}

int _r(int argb) => (argb >> 16) & 0xFF;
int _g(int argb) => (argb >> 8) & 0xFF;
int _b(int argb) => argb & 0xFF;

({double h, double s, double l}) _hsl(int argb) {
  final r = _r(argb) / 255, g = _g(argb) / 255, b = _b(argb) / 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  if (mx == mn) return (h: 0, s: 0, l: l);
  final d = mx - mn;
  final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  double h;
  if (mx == r) {
    h = (g - b) / d + (g < b ? 6 : 0);
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  return (h: h * 60, s: s, l: l);
}
