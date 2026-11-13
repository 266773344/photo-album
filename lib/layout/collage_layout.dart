import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Dynamic collage layout.
///
/// A collage block is a small tree of rows and columns whose leaves are
/// photos. Because a row's aspect ratio is the *sum* of its children's
/// aspects, and a column's is the inverse of the sum of inverse aspects, such
/// a tree fits its photos with (almost) no cropping. The engine walks through
/// the photos, tries several templates for the next few photos and picks the
/// one whose overall shape and cell sizes look best, with a seeded random
/// component so each album gets its own varied — but stable — layout.

sealed class LayoutNode {
  double get aspect;

  /// Assigns a rectangle to every leaf, writing results into [out].
  void place(Rect r, List<PlacedPhoto> out);
}

class Leaf extends LayoutNode {
  Leaf(this.index, this.aspect);
  final int index;
  @override
  final double aspect;

  @override
  void place(Rect r, List<PlacedPhoto> out) => out.add(PlacedPhoto(index, r));
}

class RowNode extends LayoutNode {
  RowNode(this.children);
  final List<LayoutNode> children;
  @override
  late final double aspect = children.fold(0.0, (s, c) => s + c.aspect);

  @override
  void place(Rect r, List<PlacedPhoto> out) {
    var x = r.left;
    for (final c in children) {
      final w = r.width * c.aspect / aspect;
      c.place(Rect.fromLTWH(x, r.top, w, r.height), out);
      x += w;
    }
  }
}

class ColumnNode extends LayoutNode {
  ColumnNode(this.children);
  final List<LayoutNode> children;
  @override
  late final double aspect = 1 / children.fold(0.0, (s, c) => s + 1 / c.aspect);

  @override
  void place(Rect r, List<PlacedPhoto> out) {
    var y = r.top;
    for (final c in children) {
      final h = r.height * (1 / c.aspect) * aspect;
      c.place(Rect.fromLTWH(r.left, y, r.width, h), out);
      y += h;
    }
  }
}

class PlacedPhoto {
  const PlacedPhoto(this.index, this.rect);

  /// Index into the list of photos passed to [buildCollage].
  final int index;
  final Rect rect;
}

/// One horizontal band of the collage, spanning the full width.
class CollageBlock {
  CollageBlock(this.node, this.template, this.width)
      : height = width / node.aspect {
    node.place(Rect.fromLTWH(0, 0, width, height), cells);
  }

  final LayoutNode node;
  final String template;
  final double width;
  final double height;
  final List<PlacedPhoto> cells = [];
}

typedef _Template = LayoutNode Function(List<Leaf> l);

// Templates by number of photos they consume. Names are used to avoid
// repeating the same arrangement twice in a row.
final Map<int, Map<String, _Template>> _templates = {
  1: {'single': (l) => l[0]},
  2: {
    'row2': (l) => RowNode([l[0], l[1]]),
    'col2': (l) => ColumnNode([l[0], l[1]]),
  },
  3: {
    'row3': (l) => RowNode([l[0], l[1], l[2]]),
    'bigLeft': (l) => RowNode([l[0], ColumnNode([l[1], l[2]])]),
    'bigRight': (l) => RowNode([ColumnNode([l[0], l[1]]), l[2]]),
    'bigTop': (l) => ColumnNode([l[0], RowNode([l[1], l[2]])]),
    'bigBottom': (l) => ColumnNode([RowNode([l[0], l[1]]), l[2]]),
  },
  4: {
    'row4': (l) => RowNode([l[0], l[1], l[2], l[3]]),
    'bigLeft3': (l) => RowNode([l[0], ColumnNode([l[1], l[2], l[3]])]),
    'bigRight3': (l) => RowNode([ColumnNode([l[0], l[1], l[2]]), l[3]]),
    'bigTop3': (l) => ColumnNode([l[0], RowNode([l[1], l[2], l[3]])]),
    'grid': (l) => ColumnNode([RowNode([l[0], l[1]]), RowNode([l[2], l[3]])]),
    'cols2x2': (l) => RowNode([ColumnNode([l[0], l[1]]), ColumnNode([l[2], l[3]])]),
    'mosaic': (l) => RowNode([l[0], ColumnNode([l[1], RowNode([l[2], l[3]])])]),
  },
  5: {
    'twoThree': (l) => ColumnNode([RowNode([l[0], l[1]]), RowNode([l[2], l[3], l[4]])]),
    'threeTwo': (l) => ColumnNode([RowNode([l[0], l[1], l[2]]), RowNode([l[3], l[4]])]),
  },
};

/// Lays out [aspects] (width / height of each photo, in order) into blocks
/// for a container of [width] logical pixels.
List<CollageBlock> buildCollage(List<double> aspects, double width, {int seed = 0}) {
  final rnd = math.Random(seed);
  // Ideal block height: roughly 70% of the width on phones, capped on large
  // screens so blocks don't become huge.
  final idealHeight = (width * 0.72).clamp(220.0, 560.0);
  final idealAspect = width / idealHeight;
  final minCell = math.min(110.0, width * 0.24);

  final blocks = <CollageBlock>[];
  var i = 0;
  String? lastTemplate;
  while (i < aspects.length) {
    final remaining = aspects.length - i;
    // Seeded preference for how many photos this block should hold.
    final roll = rnd.nextDouble();
    final desired = roll < 0.14 ? 1 : roll < 0.42 ? 2 : roll < 0.78 ? 3 : roll < 0.95 ? 4 : 5;

    _Candidate? best;
    for (final entry in _templates.entries) {
      final n = entry.key;
      if (n > remaining) continue;
      final leaves = [for (var k = 0; k < n; k++) Leaf(i + k, aspects[i + k].clamp(0.3, 4.0))];
      for (final t in entry.value.entries) {
        final node = t.value(leaves);
        final block = CollageBlock(node, t.key, width);
        var score = (math.log(node.aspect / idealAspect)).abs() * 2.2;
        // Cells must stay big enough to see.
        for (final c in block.cells) {
          final shortSide = math.min(c.rect.width, c.rect.height);
          if (shortSide < minCell) score += (minCell - shortSide) / minCell * 3;
        }
        // Very tall blocks are hard to take in on a phone.
        if (block.height > width * 1.35) score += (block.height / width - 1.35) * 3;
        score += (n - desired).abs() * 0.45;
        if (t.key == lastTemplate) score += 0.6;
        // Avoid leaving a lonely single photo at the very end.
        if (remaining - n == 1) score += 0.5;
        score += rnd.nextDouble() * 0.35;
        if (best == null || score < best.score) best = _Candidate(block, score, n);
      }
    }
    blocks.add(best!.block);
    lastTemplate = best.block.template;
    i += best.count;
  }
  return blocks;
}

class _Candidate {
  _Candidate(this.block, this.score, this.count);
  final CollageBlock block;
  final double score;
  final int count;
}
