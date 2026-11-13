import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../services/gallery.dart';
import '../theme/event_theme.dart';
import '../widgets/common.dart';

/// What the user chose in the gallery picker.
sealed class GalleryPick {
  const GalleryPick();
}

/// Individual photos.
class PickedPhotos extends GalleryPick {
  const PickedPhotos(this.assets);
  final List<GalleryAsset> assets;
}

/// A whole folder, to link to the album.
class PickedFolder extends GalleryPick {
  const PickedFolder(this.folder);
  final GalleryFolder folder;
}

/// Opens the in-app gallery picker for adding photos to [event].
Future<GalleryPick?> pickFromGallery(BuildContext context, AlbumEvent event, Gallery gallery) {
  return Navigator.of(context).push<GalleryPick>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => Theme(
      data: EventStyle.of(event).themeData,
      child: GalleryPickerScreen(event: event, gallery: gallery),
    ),
  ));
}

class GalleryPickerScreen extends StatefulWidget {
  const GalleryPickerScreen({super.key, required this.event, required this.gallery});
  final AlbumEvent event;
  final Gallery gallery;

  @override
  State<GalleryPickerScreen> createState() => _GalleryPickerScreenState();
}

class _GalleryPickerScreenState extends State<GalleryPickerScreen> {
  static const _chunk = 500;

  GalleryAccess? _access;
  List<GalleryFolder> _folders = [];
  GalleryFolder? _folder;
  final List<GalleryAsset> _assets = [];
  bool _loading = false;
  int _generation = 0;

  /// Only show photos from the album's dates (when it already has photos).
  late bool _onlyAlbumDates = widget.event.photos.isNotEmpty;
  final Map<String, GalleryAsset> _selected = {};
  late final Set<String> _inAlbum = {
    for (final p in widget.event.photos)
      if (p.assetId != null) p.assetId!,
  };

  Gallery get _g => widget.gallery;

  /// The album's date range, padded by a day on both sides.
  (DateTime, DateTime)? get _albumRange {
    final e = widget.event;
    if (e.start == null) return null;
    final s = e.start!, end = e.end!;
    return (DateTime(s.year, s.month, s.day - 1), DateTime(end.year, end.month, end.day + 2));
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final access = await _g.requestAccess();
    if (!mounted) return;
    setState(() => _access = access);
    if (access == GalleryAccess.denied) return;
    final folders = await _g.folders();
    if (!mounted) return;
    setState(() => _folders = folders);
    if (folders.isNotEmpty) _open(folders.first);
  }

  /// Loads all photos of [f] in chunks, so the grid fills up progressively.
  Future<void> _open(GalleryFolder f) async {
    final gen = ++_generation;
    setState(() {
      _folder = f;
      _assets.clear();
      _loading = true;
    });
    for (var start = 0;; start += _chunk) {
      final chunk = await _g.assets(f.id, start: start, end: start + _chunk);
      if (!mounted || gen != _generation) return;
      setState(() => _assets.addAll(chunk));
      if (chunk.length < _chunk) break;
    }
    if (mounted && gen == _generation) setState(() => _loading = false);
  }

  List<GalleryAsset> get _visible {
    final range = _albumRange;
    if (!_onlyAlbumDates || range == null) return _assets;
    return [
      for (final a in _assets)
        if (!a.takenAt.isBefore(range.$1) && a.takenAt.isBefore(range.$2)) a,
    ];
  }

  void _toggle(GalleryAsset a) => setState(() {
        if (_selected.remove(a.id) == null) _selected[a.id] = a;
      });

  void _toggleDay(List<GalleryAsset> day) {
    final pickable = day.where((a) => !_inAlbum.contains(a.id)).toList();
    final all = pickable.every((a) => _selected.containsKey(a.id));
    setState(() {
      for (final a in pickable) {
        if (all) {
          _selected.remove(a.id);
        } else {
          _selected[a.id] = a;
        }
      }
    });
  }

  Future<void> _retryAccess() async {
    setState(() => _access = null);
    await _init();
  }

  Future<void> _selectMore() async {
    await _g.selectMore();
    if (!mounted) return;
    await _init();
  }

  Future<void> _pickFolder() async {
    final linked = {for (final l in widget.event.linkedFolders) l.id};
    final folder = await showModalBottomSheet<GalleryFolder>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Add a whole folder', style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                'The album stays in sync: photos you add to the folder later appear in the album, '
                'photos you delete from it disappear.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            for (final f in _folders.where((f) => !f.isAll))
              ListTile(
                leading: Icon(linked.contains(f.id) ? Icons.folder_special : Icons.folder_outlined),
                title: Text(f.name),
                subtitle: Text(linked.contains(f.id) ? 'Already linked · ${_count(f.count)}' : _count(f.count)),
                enabled: !linked.contains(f.id),
                onTap: () => Navigator.pop(context, f),
              ),
          ],
        ),
      ),
    );
    if (folder == null || !mounted) return;
    final ok = await confirmDialog(
      context,
      title: 'Add “${folder.name}”?',
      message: 'All ${_count(folder.count)} will be added, and the album will keep following the folder.'
          '${folder.count > 500 ? '\n\nThat\'s a lot of photos. Importing them takes a while and the album may get long.' : ''}',
      action: 'Add folder',
    );
    if (ok && mounted) Navigator.pop(context, PickedFolder(folder));
  }

  static String _count(int n) => '$n photo${n == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: s.surface,
      appBar: AppBar(
        title: _folders.isEmpty
            ? const Text('Add photos')
            : DropdownButtonHideUnderline(
                child: DropdownButton<GalleryFolder>(
                  value: _folder,
                  isExpanded: true,
                  items: [
                    for (final f in _folders)
                      DropdownMenuItem(value: f, child: Text('${f.name} (${f.count})', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (f) {
                    if (f != null && f != _folder) _open(f);
                  },
                ),
              ),
        actions: [
          if (_folders.any((f) => !f.isAll))
            IconButton(
              tooltip: 'Add a whole folder',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _pickFolder,
            ),
        ],
      ),
      body: switch (_access) {
        null => const Center(child: CircularProgressIndicator()),
        GalleryAccess.denied => _NoAccess(onSettings: _g.openSettings, onRetry: _retryAccess),
        _ => Column(
            children: [
              if (_access == GalleryAccess.limited)
                Material(
                  color: s.secondaryContainer,
                  child: ListTile(
                    leading: Icon(Icons.info_outline, color: s.onSecondaryContainer),
                    title: Text('Only photos you selected are visible', style: TextStyle(color: s.onSecondaryContainer)),
                    trailing: TextButton(onPressed: _selectMore, child: const Text('Select more')),
                  ),
                ),
              if (_albumRange != null) _dateChip(context),
              Expanded(child: _grid(context)),
            ],
          ),
      },
      bottomNavigationBar: _selected.isEmpty
          ? null
          : Material(
              color: s.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      TextButton(onPressed: () => setState(_selected.clear), child: const Text('Clear')),
                      const Spacer(),
                      FilledButton.icon(
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text('Add ${_count(_selected.length)}'),
                        onPressed: () {
                          final picked = _selected.values.toList()..sort((a, b) => a.takenAt.compareTo(b.takenAt));
                          Navigator.pop(context, PickedPhotos(picked));
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _dateChip(BuildContext context) {
    final e = widget.event;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilterChip(
          label: Text('Photos from ${formatDateRange(e.start!, e.end!)}'),
          selected: _onlyAlbumDates,
          onSelected: (v) => setState(() => _onlyAlbumDates = v),
        ),
      ),
    );
  }

  Widget _grid(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_loading) ...[const CircularProgressIndicator(), const SizedBox(height: 16)],
            Text(
              _loading
                  ? 'Looking for photos…'
                  : _onlyAlbumDates
                      ? 'No photos from these days in this folder.'
                      : 'No photos here.',
              textAlign: TextAlign.center,
            ),
            if (!_loading && _onlyAlbumDates && _assets.isNotEmpty)
              TextButton(onPressed: () => setState(() => _onlyAlbumDates = false), child: const Text('Show all photos')),
          ]),
        ),
      );
    }

    // Group by day (assets are newest first).
    final days = <List<GalleryAsset>>[];
    for (final a in visible) {
      if (days.isEmpty || dayKey(days.last.first.takenAt) != dayKey(a.takenAt)) days.add([]);
      days.last.add(a);
    }
    final now = DateTime.now();
    return CustomScrollView(
      slivers: [
        for (final day in days) ...[
          SliverToBoxAdapter(
            child: _DayHeading(
              date: day.first.takenAt,
              showYear: day.first.takenAt.year != now.year,
              count: day.length,
              allSelected: day.where((a) => !_inAlbum.contains(a.id)).every((a) => _selected.containsKey(a.id)) &&
                  day.any((a) => !_inAlbum.contains(a.id)),
              onTap: () => _toggleDay(day),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: day.length,
                (context, i) {
                  final a = day[i];
                  return _Tile(
                    gallery: _g,
                    asset: a,
                    inAlbum: _inAlbum.contains(a.id),
                    selected: _selected.containsKey(a.id),
                    accent: s.primary,
                    onTap: () => _toggle(a),
                  );
                },
              ),
            ),
          ),
        ],
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _DayHeading extends StatelessWidget {
  const _DayHeading({
    required this.date,
    required this.showYear,
    required this.count,
    required this.allSelected,
    required this.onTap,
  });
  final DateTime date;
  final bool showYear;
  final int count;
  final bool allSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 10, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                DateFormat(showYear ? 'EEEE, d MMMM y' : 'EEEE, d MMMM').format(date),
                style: t.textTheme.titleSmall,
              ),
            ),
            Icon(
              allSelected ? Icons.check_circle : Icons.check_circle_outline,
              size: 22,
              color: allSelected ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
              semanticLabel: allSelected ? 'Deselect day' : 'Select day',
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.gallery,
    required this.asset,
    required this.inAlbum,
    required this.selected,
    required this.accent,
    required this.onTap,
  });
  final Gallery gallery;
  final GalleryAsset asset;
  final bool inAlbum;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: inAlbum ? null : onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black12,
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 120),
              padding: EdgeInsets.all(selected ? 8 : 0),
              child: Image(
                image: GalleryImage(gallery, asset.id, 220),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          if (inAlbum)
            const ColoredBox(
              color: Colors.black45,
              child: Center(child: Icon(Icons.check, color: Colors.white, semanticLabel: 'Already in this album')),
            ),
          if (!inAlbum)
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? accent : Colors.white,
                shadows: const [Shadow(blurRadius: 3, color: Colors.black54)],
              ),
            ),
        ],
      ),
    );
  }
}

class _NoAccess extends StatelessWidget {
  const _NoAccess({required this.onSettings, required this.onRetry});
  final VoidCallback onSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              'To add photos without copying them, the app needs access to your photos. '
              'Allow it in the app settings, including access to photo locations for the album map.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onSettings, child: const Text('Open settings')),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
