import 'dart:math' as math;

import 'models.dart';

/// One cell of a collage: a single photo or a carousel of similar photos.
class AlbumItem {
  AlbumItem(this.photos, this.stack);

  /// In time order.
  final List<Photo> photos;
  final PhotoStack? stack;

  bool get isStack => stack != null;

  Photo get cover {
    if (stack == null) return photos.first;
    final chosen = photos.where((p) => p.id == stack!.coverId).firstOrNull;
    if (chosen != null) return chosen;
    return photos.reduce((a, b) => (b.sharpness ?? 0) > (a.sharpness ?? 0) ? b : a);
  }

  double get aspect => cover.aspect;

  /// Room in the collage: the largest size chosen for any of its photos,
  /// otherwise large for carousels and normal for single photos.
  PhotoSize get size {
    PhotoSize? chosen;
    for (final p in photos) {
      final s = p.size;
      if (s != null && (chosen == null || s.index > chosen.index)) chosen = s;
    }
    return chosen ?? (isStack ? PhotoSize.large : PhotoSize.normal);
  }
  Iterable<String> get ids => photos.map((p) => p.id);
}

sealed class DayBlock {
  DayBlock(this.items);
  final List<AlbumItem> items;
}

/// Photos that aren't part of any moment.
class LooseRun extends DayBlock {
  LooseRun(super.items);
}

class MomentBlock extends DayBlock {
  MomentBlock(this.moment, super.items);
  final Moment moment;

  List<Photo> get photos => [for (final i in items) ...i.photos];
}

class DayView {
  DayView(this.key, this.date);
  final String key;
  final DateTime date;
  final List<DayBlock> blocks = [];
}

/// Turns an album into what is drawn: days, each a sequence of loose photo
/// runs and moments, each a list of items (photos or carousels).
///
/// A moment appears where its earliest photo falls in the timeline and pulls
/// all its photos together there; loose photos keep their chronological place.
List<DayView> buildAlbumStructure(AlbumEvent e) {
  final byId = {for (final p in e.photos) p.id: p};
  final stackOf = <String, PhotoStack>{
    for (final s in e.stacks)
      for (final id in s.photoIds) id: s,
  };
  final momentOf = <String, Moment>{
    for (final m in e.moments)
      for (final id in m.photoIds) id: m,
  };
  final consumed = <String>{};

  AlbumItem itemFor(Photo p) {
    final s = stackOf[p.id];
    if (s == null) return AlbumItem([p], null);
    final photos = s.photoIds.map((id) => byId[id]).nonNulls.toList()..sort((a, b) => a.takenAt.compareTo(b.takenAt));
    return AlbumItem(photos, s);
  }

  final days = <DayView>[];
  for (final p in e.photos) {
    if (consumed.contains(p.id)) continue;
    final k = dayKey(p.takenAt);
    if (days.isEmpty || days.last.key != k) {
      days.add(DayView(k, DateTime(p.takenAt.year, p.takenAt.month, p.takenAt.day)));
    }
    final day = days.last;
    final m = momentOf[p.id];
    if (m != null) {
      final items = <AlbumItem>[];
      for (final q in e.photos) {
        if (momentOf[q.id] != m || consumed.contains(q.id)) continue;
        final item = itemFor(q);
        consumed.addAll(item.ids);
        items.add(item);
      }
      day.blocks.add(MomentBlock(m, items));
    } else {
      final item = itemFor(p);
      consumed.addAll(item.ids);
      final last = day.blocks.lastOrNull;
      if (last is LooseRun) {
        last.items.add(item);
      } else {
        day.blocks.add(LooseRun([item]));
      }
    }
  }
  return days;
}

final _rnd = math.Random();
String _id() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';

/// Editing operations. All of them leave the album in a consistent state:
/// each photo is in at most one carousel and one moment, carousels have 2+
/// photos and all their photos share one moment (or none).
extension AlbumGrouping on AlbumEvent {
  PhotoStack? stackOf(String photoId) => stacks.where((s) => s.photoIds.contains(photoId)).firstOrNull;
  Moment? momentOf(String photoId) => moments.where((m) => m.photoIds.contains(photoId)).firstOrNull;

  /// Adds the carousel-mates of [ids], so carousels are never split.
  Set<String> withStackMates(Iterable<String> ids) => {
        for (final id in ids) ...(stackOf(id)?.photoIds ?? [id]),
      };

  List<Photo> _sorted(Iterable<String> ids) {
    final set = ids.toSet();
    return photos.where((p) => set.contains(p.id)).toList();
  }

  /// Groups [ids] into one carousel (pulling them out of any other carousel).
  PhotoStack? createStack(Iterable<String> ids, {bool auto = false, String? coverId}) {
    final members = _sorted(ids);
    if (members.length < 2) return null;
    final memberIds = members.map((p) => p.id).toSet();
    for (final s in stacks) {
      s.photoIds.removeWhere(memberIds.contains);
    }
    final stack = PhotoStack(id: _id(), photoIds: members.map((p) => p.id).toList(), auto: auto, coverId: coverId);
    stacks.add(stack);
    normalize();
    return stack;
  }

  /// Dissolves every carousel that contains one of [ids].
  void ungroup(Iterable<String> ids) {
    final set = ids.toSet();
    for (final s in stacks.where((s) => s.photoIds.any(set.contains)).toList()) {
      noAutoStack.addAll(s.photoIds);
      stacks.remove(s);
    }
  }

  void removeFromStack(String photoId) {
    stackOf(photoId)?.photoIds.remove(photoId);
    noAutoStack.add(photoId);
    normalize();
  }

  Moment createMoment(String title, String note, Iterable<String> ids) {
    final m = Moment(id: _id(), title: title, note: note, photoIds: []);
    moments.add(m);
    addToMoment(m, ids);
    return m;
  }

  void addToMoment(Moment m, Iterable<String> ids) {
    final all = withStackMates(ids);
    for (final other in moments) {
      if (other != m) other.photoIds.removeWhere(all.contains);
    }
    m.photoIds.addAll(all.where((id) => !m.photoIds.contains(id)));
    normalize();
  }

  void removeFromMoment(Iterable<String> ids) {
    final all = withStackMates(ids);
    for (final m in moments) {
      m.photoIds.removeWhere(all.contains);
    }
    normalize();
  }

  void dissolveMoment(Moment m) => moments.remove(m);

  /// Removes photos from the album and returns them (so their files can be deleted).
  List<Photo> removePhotos(Iterable<String> ids) {
    final set = ids.toSet();
    final removed = photos.where((p) => set.contains(p.id)).toList();
    photos.removeWhere((p) => set.contains(p.id));
    if (set.contains(coverPhotoId)) coverPhotoId = null;
    normalize();
    return removed;
  }

  /// Repairs invariants after any change.
  void normalize() {
    final valid = photos.map((p) => p.id).toSet();
    final order = {for (var i = 0; i < photos.length; i++) photos[i].id: i};

    final seen = <String>{};
    for (final s in stacks) {
      s.photoIds.retainWhere((id) => valid.contains(id) && seen.add(id));
      s.photoIds.sort((a, b) => order[a]!.compareTo(order[b]!));
      if (s.coverId != null && !s.photoIds.contains(s.coverId)) s.coverId = null;
    }
    stacks.removeWhere((s) => s.photoIds.length < 2);

    seen.clear();
    for (final m in moments) {
      m.photoIds.retainWhere((id) => valid.contains(id) && seen.add(id));
    }
    // A carousel lives entirely in the moment of its earliest photo.
    for (final s in stacks) {
      final home = momentOf(s.photoIds.first);
      for (final m in moments) {
        if (m == home) {
          m.photoIds.addAll(s.photoIds.where((id) => !m.photoIds.contains(id)));
        } else {
          m.photoIds.removeWhere(s.photoIds.contains);
        }
      }
    }
    for (final m in moments) {
      m.photoIds.sort((a, b) => order[a]!.compareTo(order[b]!));
    }
    moments.removeWhere((m) => m.photoIds.isEmpty);
    noAutoStack.retainWhere(valid.contains);
  }
}
