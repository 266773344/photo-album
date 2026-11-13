import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../layout/collage_layout.dart';
import '../models/grouping.dart';
import '../models/models.dart';
import '../services/place_story.dart';
import '../theme/event_theme.dart';
import '../widgets/album_map.dart';
import '../widgets/collage_view.dart';
import '../widgets/common.dart';
import 'event_editor.dart';
import 'gallery_picker.dart';
import 'moment_sheet.dart';
import 'photo_viewer.dart';
import 'place_picker.dart';
import 'theme_picker.dart';

/// Opens the album's map, optionally centred on [focus].
String _albumRouteName(String eventId) => 'album/$eventId';

void openAlbumMap(BuildContext context, AlbumEvent e, {LatLng? focus}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => Theme(
      data: EventStyle.of(e).themeData,
      child: AlbumMapScreen(
        eventId: e.id,
        focus: focus,
        // Tapping a stop goes back to the album, scrolled to its photos.
        onTapVisit: (ctx, visit) {
          AlbumScope.read(ctx).requestFocus(e, [for (final p in visit.photos) p.id]);
          Navigator.of(ctx).popUntil((r) => r.settings.name == _albumRouteName(e.id) || r.isFirst);
        },
      ),
    ),
  ));
}

void openPhotoViewer(BuildContext context, AlbumEvent e, Photo p) {
  Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => PhotoViewer(eventId: e.id, initialPhotoId: p.id),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
  ));
}

void openEvent(BuildContext context, AlbumEvent e, {bool pickPhotos = false}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    settings: RouteSettings(name: _albumRouteName(e.id)),
    builder: (_) => EventScreen(eventId: e.id, pickPhotosOnOpen: pickPhotos),
  ));
}

const _maxContentWidth = 1000.0;
const _sidePadding = 12.0;
const _gap = 6.0;

int _stableHash(String s) => s.codeUnits.fold(17, (h, c) => (h * 31 + c) & 0x7fffffff);

class EventScreen extends StatefulWidget {
  const EventScreen({super.key, required this.eventId, this.pickPhotosOnOpen = false});
  final String eventId;
  final bool pickPhotosOnOpen;

  @override
  State<EventScreen> createState() => _EventScreenState();
}

class _EventScreenState extends State<EventScreen> {
  /// Selected photo ids. Non-empty = selection mode.
  final Set<String> _selected = {};

  final _scroll = ScrollController();
  final _cells = CellRegistry();

  /// The journey stop of the photos at the top of the screen (null = top of
  /// the album, the map shows the whole trip).
  int? _currentVisit;
  Set<String> _highlight = {};
  AlbumGeo? _geo;
  Timer? _scrollCheck;
  ValueNotifier<(String, List<String>)?>? _focusRequests;

  static const _journeyExpanded = 300.0;
  static const _journeyCollapsed = 150.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_focusRequests == null) {
      _focusRequests = AlbumScope.read(context).focusRequest..addListener(_onFocusRequest);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusRequest());
    }
  }

  @override
  void dispose() {
    _focusRequests?.removeListener(_onFocusRequest);
    _scrollCheck?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocusRequest() {
    final req = _focusRequests?.value;
    if (req == null || req.$1 != widget.eventId || !mounted) return;
    _focusRequests!.value = null;
    // Wait until routes above this one are gone.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPhotos(req.$2));
  }

  /// Scrolls the album to the first of [ids] and outlines them briefly.
  Future<void> _scrollToPhotos(List<String> ids) async {
    final e = _event;
    if (e == null || ids.isEmpty || !_scroll.hasClients) return;
    // Position of every photo in page order (days → blocks → cells).
    final order = <String, int>{};
    for (final day in buildAlbumStructure(e)) {
      for (final block in day.blocks) {
        for (final item in block.items) {
          for (final id in item.ids) {
            order[id] = order.length;
          }
        }
      }
    }
    final targets = ids.where(order.containsKey).toList()..sort((a, b) => order[a]!.compareTo(order[b]!));
    if (targets.isEmpty) return;
    final target = targets.first;

    // The page is built lazily: step towards the target until its cell exists.
    for (var i = 0; i < 80 && mounted; i++) {
      final ctx = _cells[target];
      if (ctx != null && ctx.mounted) {
        setState(() => _highlight = ids.toSet());
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 550),
          curve: Curves.easeInOutCubic,
        );
        break;
      }
      final visible = [for (final entry in _cells.entries) order[entry.key] ?? 0];
      if (visible.isEmpty) break;
      final down = visible.reduce(math.max) < order[target]!;
      final pos = _scroll.position;
      final next = (pos.pixels + pos.viewportDimension * 0.8 * (down ? 1 : -1)).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (next == pos.pixels) break;
      pos.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    if (mounted) setState(() => _highlight = {});
  }

  // Scroll notifications arrive before the frame is laid out, so cell
  // positions are only read a moment later (at most every 100 ms).
  void _onScroll() {
    _scrollCheck ??= Timer(const Duration(milliseconds: 100), () {
      _scrollCheck = null;
      if (mounted) _updateCurrentVisit();
    });
  }

  /// Finds the journey stop of the photos just below the header.
  void _updateCurrentVisit() {
    final geo = _geo;
    if (geo == null || geo.isEmpty || !_scroll.hasClients) return;
    int? visit;
    if (_scroll.offset > _journeyExpanded - _journeyCollapsed) {
      final headerBottom = MediaQuery.paddingOf(context).top + _journeyCollapsed;
      String? topId;
      var topY = double.infinity;
      for (final entry in _cells.entries) {
        final box = entry.value.mounted ? entry.value.findRenderObject() as RenderBox? : null;
        if (box == null || !box.attached || !box.hasSize) continue;
        final y = box.localToGlobal(Offset.zero).dy;
        // The first cell whose lower half is below the header.
        if (y + box.size.height / 2 > headerBottom && y < topY) {
          topY = y;
          topId = entry.key;
        }
      }
      visit = topId == null ? _currentVisit : geo.visitOfPhoto(topId);
    }
    if (visit != _currentVisit) setState(() => _currentVisit = visit);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.pickPhotosOnOpen) {
        _addPhotos();
      } else {
        _syncFolders();
        final e = _event;
        if (e != null) unawaited(AlbumScope.read(context).refreshRoutes(e));
      }
    });
  }

  AlbumEvent? get _event => AlbumScope.read(context).byId(widget.eventId);

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  // ---- selection ----------------------------------------------------------

  void _toggle(AlbumItem item) {
    setState(() {
      if (item.ids.every(_selected.contains)) {
        _selected.removeAll(item.ids);
      } else {
        _selected.addAll(item.ids);
      }
    });
  }

  void _startSelection(AlbumItem item) {
    HapticFeedback.selectionClick();
    _toggle(item);
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _persist(AlbumEvent e) => AlbumScope.read(context).changed(e);

  Future<void> _groupAsCarousel(AlbumEvent e) async {
    final n = _selected.length;
    e.createStack(_selected);
    _clearSelection();
    await _persist(e);
    _snack('Grouped $n photos into a carousel');
  }

  Future<void> _addToMoment(AlbumEvent e) async {
    final choice = await showMomentSheet(context, event: e, photos: _selectedPhotos(e));
    if (choice == null || !mounted) return;
    final repo = AlbumScope.read(context);
    Moment? created;
    switch (choice) {
      case NewMoment(:final title, :final note):
        created = e.createMoment(title, note, _selected);
      case ExistingMoment(:final moment):
        e.addToMoment(moment, _selected);
    }
    _clearSelection();
    await _persist(e);
    if (created != null && choice is NewMoment && choice.place != null) {
      await _guardStory(() => repo.setMomentPlace(e, created!, choice.place));
    }
  }

  /// Runs a place-description action and reports failures as a snackbar.
  Future<void> _guardStory(Future<void> Function() action) async {
    try {
      await action();
    } on StoryException catch (err) {
      if (mounted) _snack(err.message);
    }
  }

  Future<void> _setLocationForSelected(AlbumEvent e) async {
    final photos = _selectedPhotos(e);
    final initial = photos.where((p) => p.hasLocation).firstOrNull;
    final place = await pickPlace(
      context,
      title: 'Where were ${photos.length == 1 ? 'this photo' : 'these photos'} taken?',
      initial: initial == null ? null : GeoPlace(name: 'Current location', lat: initial.lat!, lng: initial.lng!),
      near: photosCenter(e.photos),
    );
    if (place == null || !mounted) return;
    _clearSelection();
    await AlbumScope.read(context).setPhotoLocation(e, photos.map((p) => p.id), place);
  }

  Future<void> _momentActions(AlbumEvent e, Moment m) async {
    final repo = AlbumScope.read(context);
    final canWrite = repo.settings.canWriteStories;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit title, note & place'),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
          if (m.place != null)
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text(m.story == null ? 'Write “About this place”' : 'Rewrite “About this place”'),
              subtitle: canWrite ? null : const Text('Needs an Anthropic API key (Settings)'),
              enabled: canWrite,
              onTap: () => Navigator.pop(context, 'story'),
            ),
          if (m.story != null)
            ListTile(
              leading: const Icon(Icons.notes),
              title: const Text('Remove place description'),
              onTap: () => Navigator.pop(context, 'nostory'),
            ),
          if (m.place != null)
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Show on map'),
              onTap: () => Navigator.pop(context, 'map'),
            ),
          ListTile(
            leading: const Icon(Icons.bookmark_remove_outlined),
            title: const Text('Dissolve moment (keep photos)'),
            onTap: () => Navigator.pop(context, 'dissolve'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'edit':
        await _editMoment(e, m);
      case 'story':
        await _guardStory(() => repo.writeStory(e, m));
      case 'nostory':
        m.story = null;
        await _persist(e);
      case 'map':
        openAlbumMap(context, e, focus: LatLng(m.place!.lat, m.place!.lng));
      case 'dissolve':
        await _dissolveMoment(e, m);
    }
  }

  Future<void> _removeSelected(AlbumEvent e) async {
    final n = _selected.length;
    final ok = await confirmDialog(
      context,
      title: 'Remove $n photo${n == 1 ? '' : 's'}?',
      message: 'They will be removed from this album. Originals in your gallery are not affected.',
      action: 'Remove',
    );
    if (!ok || !mounted) return;
    final ids = {..._selected};
    _clearSelection();
    await AlbumScope.read(context).deletePhotos(e, ids);
  }

  Future<void> _selectionMenu(AlbumEvent e, String action) async {
    switch (action) {
      case 'ungroup':
        e.ungroup(_selected);
      case 'unmoment':
        e.removeFromMoment(_selected);
      case 'location':
        return _setLocationForSelected(e);
      case 'cover':
        e.coverPhotoId = _selectedPhotos(e).first.id;
      case 'caption':
        final p = _selectedPhotos(e).first;
        final text = await editTextDialog(context, title: 'Caption', initial: p.caption, hint: 'Say something about this photo');
        if (text == null || !mounted) return;
        p.caption = text;
    }
    _clearSelection();
    await _persist(e);
  }

  List<Photo> _selectedPhotos(AlbumEvent e) => e.photos.where((p) => _selected.contains(p.id)).toList();

  // ---- other actions ------------------------------------------------------

  Future<void> _addPhotos() async {
    final e = _event;
    if (e == null) return;
    final repo = AlbumScope.read(context);
    final gallery = repo.gallery;
    final stacksBefore = e.stacks.length;
    int count, failed;
    if (gallery != null) {
      // Android: reference photos in the device gallery instead of copying them.
      final pick = await pickFromGallery(context, e, gallery);
      if (pick == null || !mounted) return;
      switch (pick) {
        case PickedPhotos(:final assets):
          count = assets.length;
          failed = await repo.importAssets(e, assets);
        case PickedFolder(:final folder):
          final result = await repo.linkFolder(e, folder);
          if (!mounted) return;
          _snack(result == null || result.isEmpty
              ? 'Linked “${folder.name}”'
              : 'Linked “${folder.name}” · $result');
          return;
      }
    } else {
      final files = await ImagePicker().pickMultiImage(requestFullMetadata: true);
      if (files.isEmpty || !mounted) return;
      count = files.length;
      failed = await repo.importPhotos(e, files);
    }
    if (!mounted) return;
    final newStacks = e.stacks.length - stacksBefore;
    _snack([
      failed == 0 ? 'Added $count photo${count == 1 ? '' : 's'}' : 'Added ${count - failed}, $failed could not be read',
      if (newStacks > 0) 'grouped similar shots into $newStacks carousel${newStacks == 1 ? '' : 's'}',
    ].join(' · '));
  }

  /// Brings the album up to date with its linked gallery folders.
  Future<void> _syncFolders({bool force = false}) async {
    final e = _event;
    if (e == null || e.linkedFolders.isEmpty) return;
    final result = await AlbumScope.read(context).syncFolders(e, force: force);
    if (!mounted || result == null) return;
    if (!result.isEmpty) {
      _snack('Synced ${e.linkedFolders.map((l) => '“${l.name}”').join(', ')}: $result');
    } else if (force) {
      _snack('Up to date');
    }
  }

  Future<void> _manageFolders(AlbumEvent e) async {
    final repo = AlbumScope.read(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('Linked folders', style: Theme.of(context).textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'New photos in these folders are added when you open the album; '
                  'photos deleted from them are removed. Unlinking keeps the photos.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              for (final l in e.linkedFolders)
                ListTile(
                  leading: const Icon(Icons.folder_special_outlined),
                  title: Text(l.name),
                  subtitle: Text('${e.photos.where((p) => p.folderId == l.id).length} photos in this album'),
                  trailing: TextButton(
                    onPressed: () async {
                      await repo.unlinkFolder(e, l.id);
                      setSheet(() {});
                      if (e.linkedFolders.isEmpty && context.mounted) Navigator.pop(context);
                    },
                    child: const Text('Unlink'),
                  ),
                ),
              if (e.linkedFolders.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Sync now'),
                  onTap: () {
                    Navigator.pop(context);
                    _syncFolders(force: true);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editDetails(AlbumEvent e) async {
    final d = await showEventEditor(context, existing: e);
    if (d == null || !mounted) return;
    final wasManual = e.locationManual;
    e
      ..title = d.title
      ..location = d.location
      ..locationManual = d.locationManual
      ..description = d.description;
    await _persist(e);
    // Switched back to automatic: work the place out from the photos again.
    if (wasManual && !d.locationManual && mounted) unawaited(AlbumScope.read(context).refreshDayPlaces(e));
  }

  Future<void> _editDayNote(AlbumEvent e, DayView day) async {
    final text = await editTextDialog(
      context,
      title: 'Note for ${DateFormat('EEEE, d MMMM').format(day.date)}',
      initial: e.dayNotes[day.key] ?? '',
      hint: 'What happened that day?',
    );
    if (text == null || !mounted) return;
    if (text.isEmpty) {
      e.dayNotes.remove(day.key);
    } else {
      e.dayNotes[day.key] = text;
    }
    await _persist(e);
  }

  Future<void> _editMoment(AlbumEvent e, Moment m) async {
    final choice = await showMomentSheet(context, event: e, existing: m);
    if (choice is! NewMoment || !mounted) return;
    m
      ..title = choice.title
      ..note = choice.note;
    final repo = AlbumScope.read(context);
    await _persist(e);
    await _guardStory(() => repo.setMomentPlace(e, m, choice.place));
  }

  Future<void> _dissolveMoment(AlbumEvent e, Moment m) async {
    e.dissolveMoment(m);
    await _persist(e);
    _snack('Moment “${m.title}” removed — its photos stay in the album');
  }

  Future<void> _delete(AlbumEvent e) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete "${e.title}"?',
      message: 'The album and its ${e.photos.length} photos will be removed from this app. '
          'Originals in your gallery are not affected.',
    );
    if (!ok || !mounted) return;
    Navigator.pop(context);
    await AlbumScope.read(context).deleteEvent(e);
  }

  void _openViewer(AlbumEvent e, Photo p) => openPhotoViewer(context, e, p);

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.of(context);
    final e = repo.byId(widget.eventId);
    if (e == null) return const Scaffold();
    _selected.retainWhere((id) => e.photos.any((p) => p.id == id));
    final style = EventStyle.of(e);
    final s = style.scheme;
    final days = buildAlbumStructure(e);
    final progress = repo.importProgress[e.id];
    final firstDay = days.isEmpty ? null : days.first.date;
    final airy = e.layout == LayoutStyle.airy;
    final interaction = CollageInteraction(
      selected: _selected,
      onOpen: (p) => _openViewer(e, p),
      onToggle: _toggle,
      onStartSelection: _startSelection,
      flat: airy,
      highlighted: _highlight,
      registry: _cells,
    );
    final geo = _geo = AlbumGeo(e);
    final journeyMap = !geo.isEmpty && e.showJourneyMap;

    // Background colours flow from one day's tint into the next.
    final tints = [for (final d in days) style.dayTints[d.key] ?? s.surface];

    return PopScope(
      canPop: _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Theme(
        data: style.themeData,
        child: Builder(builder: (context) {
          return Scaffold(
            backgroundColor: s.surface,
            body: NotificationListener<ScrollUpdateNotification>(
              onNotification: (n) {
                if (journeyMap && n.depth == 0) _onScroll();
                return false;
              },
              child: CustomScrollView(
              controller: _scroll,
              slivers: [
                _header(context, e, style, geo, journeyMap),
                DecoratedSliver(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [s.surface, tints.firstOrNull ?? s.surface],
                    ),
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _Constrained(
                      child: _InfoSection(
                        event: e,
                        style: style,
                        geo: journeyMap ? null : geo,
                        onOpenMap: () => openAlbumMap(context, e),
                      ),
                    ),
                  ),
                ),
                if (e.photos.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyAlbum(onAdd: progress == null ? _addPhotos : null),
                  ),
                for (var i = 0; i < days.length; i++)
                  DecoratedSliver(
                    key: ValueKey(days[i].key),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [tints[i], i + 1 < tints.length ? tints[i + 1] : s.surface],
                      ),
                    ),
                    sliver: _DaySliver(
                      event: e,
                      style: style,
                      day: days[i],
                      dayNumber: days[i].date.difference(firstDay!).inDays + 1,
                      interaction: interaction,
                      airy: airy,
                      onEditNote: () => _editDayNote(e, days[i]),
                      onMomentActions: (m) => _momentActions(e, m),
                      onWriteStory: (m) => _guardStory(() => AlbumScope.read(context).writeStory(e, m)),
                    ),
                  ),
                if (e.photos.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
                      child: Center(
                        child: FilledButton.tonalIcon(
                          onPressed: progress == null ? _addPhotos : null,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Add more photos'),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            ),
            bottomNavigationBar: _selected.isNotEmpty
                ? _SelectionBar(
                    event: e,
                    selected: _selected,
                    onClose: _clearSelection,
                    onCarousel: () => _groupAsCarousel(e),
                    onMoment: () => _addToMoment(e),
                    onRemove: () => _removeSelected(e),
                    onMenu: (a) => _selectionMenu(e, a),
                  )
                : progress == null
                    ? null
                    : _ProgressBar(progress: progress),
          );
        }),
      ),
    );
  }

  Widget _header(BuildContext context, AlbumEvent e, EventStyle style, AlbumGeo geo, bool journeyMap) {
    final s = style.scheme;
    final cover = e.cover;
    final height = math.min(440.0, MediaQuery.sizeOf(context).height * 0.52);
    final busy = AlbumScope.of(context).importProgress.containsKey(e.id);

    final actions = <Widget>[
      if (!geo.isEmpty)
        IconButton.filledTonal(
          tooltip: journeyMap ? 'Hide map' : 'Show map',
          isSelected: journeyMap,
          onPressed: () {
            e.showJourneyMap = !e.showJourneyMap;
            _currentVisit = null;
            AlbumScope.read(context).changed(e);
          },
          icon: const Icon(Icons.map_outlined),
          selectedIcon: const Icon(Icons.map),
        ),
      IconButton.filledTonal(
        tooltip: 'Add photos',
        onPressed: busy ? null : _addPhotos,
        icon: const Icon(Icons.add_photo_alternate_outlined),
      ),
      IconButton.filledTonal(
        tooltip: 'Theme & colours',
        onPressed: () => showThemePicker(context, e),
        icon: const Icon(Icons.palette_outlined),
      ),
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        style: IconButton.styleFrom(backgroundColor: s.secondaryContainer),
        onSelected: (v) async {
          final repo = AlbumScope.read(context);
          switch (v) {
            case 'edit':
              await _editDetails(e);
            case 'select':
              setState(() => _selected.addAll(e.photos.map((p) => p.id)));
            case 'autostack':
              await repo.setAutoStack(e, !e.autoStack);
            case 'shuffle':
              e.layoutSeed = math.Random().nextInt(1 << 30);
              await repo.changed(e);
            case 'folders':
              await _manageFolders(e);
            case 'delete':
              await _delete(e);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit details'))),
          if (e.photos.isNotEmpty)
            const PopupMenuItem(value: 'select', child: ListTile(leading: Icon(Icons.checklist), title: Text('Select photos'))),
          CheckedPopupMenuItem(
            value: 'autostack',
            checked: e.autoStack,
            child: const Text('Group similar photos'),
          ),
          const PopupMenuItem(value: 'shuffle', child: ListTile(leading: Icon(Icons.shuffle), title: Text('Shuffle layout'))),
          if (e.linkedFolders.isNotEmpty)
            const PopupMenuItem(
              value: 'folders',
              child: ListTile(leading: Icon(Icons.folder_special_outlined), title: Text('Linked folders')),
            ),
          const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete album'))),
        ],
      ),
      const SizedBox(width: 8),
    ];

    if (journeyMap) {
      // The journey map, pinned as a strip while scrolling; its pin follows
      // the photos on screen.
      return SliverAppBar(
        pinned: true,
        expandedHeight: _journeyExpanded,
        collapsedHeight: _journeyCollapsed,
        backgroundColor: s.surface,
        surfaceTintColor: Colors.transparent,
        leading: Padding(
          padding: const EdgeInsets.all(4),
          child: IconButton.filledTonal(onPressed: () => Navigator.maybePop(context), icon: const BackButtonIcon()),
        ),
        actions: actions,
        flexibleSpace: Stack(
          fit: StackFit.expand,
          children: [
            JourneyHeaderMap(
              geo: geo,
              current: _currentVisit,
              onTapVisit: (v) => _scrollToPhotos([for (final p in v.photos) p.id]),
              onOpen: () => openAlbumMap(
                context,
                e,
                focus: _currentVisit == null ? null : geo.visits[_currentVisit!].center,
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: s.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: s.onSurface, fontWeight: FontWeight.w700, fontSize: 18),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 4,
              child: IgnorePointer(
                child: Text('© OpenStreetMap', style: TextStyle(fontSize: 9.5, color: s.onSurface.withValues(alpha: 0.7))),
              ),
            ),
          ],
        ),
      );
    }

    if (cover == null) {
      return SliverAppBar.large(title: Text(e.title), backgroundColor: s.surface, actions: actions);
    }

    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: height,
      backgroundColor: s.surface,
      surfaceTintColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.all(4),
        child: IconButton.filledTonal(onPressed: () => Navigator.maybePop(context), icon: const BackButtonIcon()),
      ),
      actions: actions,
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        titlePadding: const EdgeInsetsDirectional.only(start: 60, bottom: 14, end: 16),
        title: Text(
          e.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: s.onSurface, fontWeight: FontWeight.w700),
        ),
        background: Stack(
          fit: StackFit.expand,
          children: [
            PhotoThumb(photo: cover, radius: 0),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.55, 1],
                  colors: [s.surface.withValues(alpha: 0), s.surface.withValues(alpha: 0.1), s.surface],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centres content and limits its width on tablets / desktop browsers.
class _Constrained extends StatelessWidget {
  const _Constrained({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: _sidePadding), child: child),
        ),
      );
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.event, required this.style, required this.geo, required this.onOpenMap});
  final AlbumEvent event;
  final EventStyle style;
  final AlbumGeo? geo;
  final VoidCallback onOpenMap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = style.scheme;
    final facts = [
      if (event.location.isNotEmpty) event.location,
      if (event.photos.isNotEmpty) formatDateRange(event.start, event.end),
      if (event.photos.isNotEmpty) '${event.photos.length} photos',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (facts.isNotEmpty)
            Text(facts.join('  ·  '), style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant, letterSpacing: 0.2)),
          if (event.description.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(event.description, style: t.textTheme.bodyLarge?.copyWith(height: 1.55, color: s.onSurface)),
          ],
          if (geo case final geo? when !geo.isEmpty) ...[
            const SizedBox(height: 16),
            AlbumMapCard(geo: geo, onOpen: onOpenMap),
          ],
          if (event.photos.length >= 4 && event.moments.isEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Tip: long-press photos to group them into a moment or carousel. Tap a day\'s title to add a note.',
              style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _DaySliver extends StatelessWidget {
  const _DaySliver({
    required this.event,
    required this.style,
    required this.day,
    required this.dayNumber,
    required this.interaction,
    required this.airy,
    required this.onEditNote,
    required this.onMomentActions,
    required this.onWriteStory,
  });

  final AlbumEvent event;
  final EventStyle style;
  final DayView day;
  final int dayNumber;
  final CollageInteraction interaction;
  final bool airy;
  final VoidCallback onEditNote;
  final ValueChanged<Moment> onMomentActions;
  final ValueChanged<Moment> onWriteStory;

  @override
  Widget build(BuildContext context) {
    final gap = airy ? 10.0 : _gap;
    // Extra breathing room between collage bands in the airy layout.
    final bandSpacing = airy ? 8.0 : 0.0;
    return SliverLayoutBuilder(builder: (context, constraints) {
      final cross = constraints.crossAxisExtent;
      final outer = math.max(0.0, (cross - _maxContentWidth) / 2);
      // Collage cells are inset by half a gap, so let the collage overhang
      // the text column by that much to keep photo edges aligned with text.
      final loosePad = outer + _sidePadding - gap / 2;
      final cardMargin = outer + _sidePadding - 4;
      final cardInner = 10 - gap / 2;
      final daySeed = event.layoutSeed ^ _stableHash(day.key);

      SliverList collageRows(List<AlbumItem> items, double width, int seed) {
        final blocks = buildCollage([for (final i in items) i.aspect], width, seed: seed, airy: airy);
        return SliverList.builder(
          itemCount: blocks.length,
          itemBuilder: (context, i) => Padding(
            padding: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : bandSpacing),
            child: CollageBlockView(block: blocks[i], items: items, interaction: interaction, gap: gap),
          ),
        );
      }

      return SliverMainAxisGroup(slivers: [
        SliverToBoxAdapter(
          child: _Constrained(child: _DayHeader(event: event, day: day, dayNumber: dayNumber, onEditNote: onEditNote)),
        ),
        for (final (index, block) in day.blocks.indexed)
          switch (block) {
            LooseRun() => SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: loosePad, vertical: airy ? 6 : 4),
                sliver: collageRows(block.items, cross - 2 * loosePad, daySeed ^ (index * 7919)),
              ),
            MomentBlock() => SliverPadding(
                padding: EdgeInsets.fromLTRB(cardMargin, airy ? 18 : 10, cardMargin, airy ? 18 : 10),
                sliver: DecoratedSliver(
                  decoration: BoxDecoration(
                    color: style.momentTint(block.photos),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  sliver: SliverPadding(
                    padding: EdgeInsets.fromLTRB(cardInner, 0, cardInner, cardInner + 2),
                    sliver: SliverMainAxisGroup(slivers: [
                      SliverToBoxAdapter(
                        child: _MomentHeader(
                          block: block,
                          onTap: () => onMomentActions(block.moment),
                          onWriteStory: () => onWriteStory(block.moment),
                        ),
                      ),
                      collageRows(block.items, cross - 2 * (cardMargin + cardInner), _stableHash(block.moment.id)),
                    ]),
                  ),
                ),
              ),
          },
      ]);
    });
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.event, required this.day, required this.dayNumber, required this.onEditNote});
  final AlbumEvent event;
  final DayView day;
  final int dayNumber;
  final VoidCallback onEditNote;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final note = event.dayNotes[day.key];
    final place = event.dayPlaces[day.key];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 30, 0, 8),
      child: InkWell(
        onTap: onEditNote,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Day $dayNumber',
                style: t.textTheme.headlineMedium?.copyWith(color: s.primary, fontWeight: FontWeight.w800, letterSpacing: -0.5),
              ),
              Text(
                [DateFormat('EEEE, d MMMM').format(day.date), ?place].join('  ·  '),
                style: t.textTheme.titleSmall?.copyWith(color: s.onSurfaceVariant),
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10, right: 12),
                  child: Text(note, style: t.textTheme.bodyLarge?.copyWith(fontStyle: FontStyle.italic, height: 1.5)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MomentHeader extends StatelessWidget {
  const _MomentHeader({required this.block, required this.onTap, required this.onWriteStory});
  final MomentBlock block;
  final VoidCallback onTap;
  final VoidCallback onWriteStory;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final repo = AlbumScope.of(context);
    final photos = block.photos;
    final m = block.moment;
    final hm = DateFormat('HH:mm');
    final first = photos.first.takenAt, last = photos.last.takenAt;
    final multiDay = dayKey(first) != dayKey(last);
    final time = [
      (multiDay ? DateFormat('d MMM, HH:mm') : hm).format(first),
      if (last.difference(first).inMinutes >= 1) (multiDay ? DateFormat('d MMM, HH:mm') : hm).format(last),
    ].join(' – ');
    final loading = repo.storyLoading.contains(m.id);
    final offerStory = m.place != null && m.story == null && !loading && repo.settings.canWriteStories;

    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15)),
            const SizedBox(height: 2),
            Text(
              [time, if (m.place != null) m.place!.name].join('  ·  '),
              style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
            ),
            if (m.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(m.note, style: t.textTheme.bodyMedium?.copyWith(height: 1.5)),
              ),
            if (loading)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(children: [
                  const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Looking into ${m.place!.name}…', style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
                ]),
              )
            else if (m.story != null)
              _StoryText(story: m.story!)
            else if (offerStory)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: onWriteStory,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: Text('About ${m.place!.name}'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The AI-written place description: set apart as quiet "flavour text".
class _StoryText extends StatelessWidget {
  const _StoryText({required this.story});
  final PlaceStory story;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final domains = story.sources
        .map((u) => Uri.tryParse(u)?.host.replaceFirst(RegExp(r'^www\.'), ''))
        .nonNulls
        .toSet()
        .take(2)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: s.primary.withValues(alpha: 0.5), width: 2))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              story.text,
              style: t.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, height: 1.5, color: s.onSurface.withValues(alpha: 0.85)),
            ),
            const SizedBox(height: 4),
            Text(
              ['AI-written', if (domains.isNotEmpty) 'from ${domains.join(', ')}'].join(' '),
              style: t.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.event,
    required this.selected,
    required this.onClose,
    required this.onCarousel,
    required this.onMoment,
    required this.onRemove,
    required this.onMenu,
  });

  final AlbumEvent event;
  final Set<String> selected;
  final VoidCallback onClose;
  final VoidCallback onCarousel;
  final VoidCallback onMoment;
  final VoidCallback onRemove;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final n = selected.length;
    final anyStacked = selected.any((id) => event.stackOf(id) != null);
    final anyInMoment = selected.any((id) => event.momentOf(id) != null);
    // "One thing" = a single photo or exactly one whole carousel.
    final single = n == 1 || (event.stackOf(selected.first)?.photoIds.toSet().containsAll(selected) ?? false);

    return Material(
      color: s.surfaceContainerHigh,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                IconButton(tooltip: 'Cancel', onPressed: onClose, icon: const Icon(Icons.close)),
                Text('$n selected', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: onMenu,
                  itemBuilder: (_) => [
                    if (n == 1)
                      const PopupMenuItem(value: 'caption', child: ListTile(leading: Icon(Icons.short_text), title: Text('Caption'))),
                    if (single)
                      const PopupMenuItem(value: 'cover', child: ListTile(leading: Icon(Icons.star_outline), title: Text('Use as album cover'))),
                    const PopupMenuItem(
                      value: 'location',
                      child: ListTile(leading: Icon(Icons.add_location_alt_outlined), title: Text('Set location')),
                    ),
                    if (anyStacked)
                      const PopupMenuItem(value: 'ungroup', child: ListTile(leading: Icon(Icons.burst_mode_outlined), title: Text('Ungroup carousel'))),
                    if (anyInMoment)
                      const PopupMenuItem(
                        value: 'unmoment',
                        child: ListTile(leading: Icon(Icons.bookmark_remove_outlined), title: Text('Take out of moment')),
                      ),
                  ],
                ),
              ]),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _BarAction(icon: Icons.bookmark_add_outlined, label: 'Moment', onTap: onMoment),
                  _BarAction(icon: Icons.burst_mode_outlined, label: 'Carousel', onTap: n >= 2 ? onCarousel : null),
                  _BarAction(icon: Icons.delete_outline, label: 'Remove', onTap: onRemove),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final color = onTap == null ? s.onSurface.withValues(alpha: 0.38) : s.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: color, fontSize: 12.5)),
        ]),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});
  final (int, int) progress;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Arranging photos… ${progress.$1} of ${progress.$2}'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress.$2 == 0 ? null : progress.$1 / progress.$2),
              ],
            ),
          ),
        ),
      );
}

class _EmptyAlbum extends StatelessWidget {
  const _EmptyAlbum({required this.onAdd});
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.collections_outlined, size: 72, color: t.colorScheme.primary),
            const SizedBox(height: 16),
            Text('No photos yet', style: t.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Add photos and they will be grouped by day and arranged into collages automatically.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Add photos')),
          ],
        ),
      ),
    );
  }
}
