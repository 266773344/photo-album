import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../layout/collage_layout.dart';
import '../models/grouping.dart';
import '../models/models.dart';
import '../theme/event_theme.dart';
import '../widgets/collage_view.dart';
import '../widgets/common.dart';
import 'event_editor.dart';
import 'moment_sheet.dart';
import 'photo_viewer.dart';
import 'theme_picker.dart';

void openEvent(BuildContext context, AlbumEvent e, {bool pickPhotos = false}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
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

  @override
  void initState() {
    super.initState();
    if (widget.pickPhotosOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addPhotos());
    }
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
    final choice = await showMomentSheet(context, event: e, photoCount: _selected.length);
    if (choice == null || !mounted) return;
    switch (choice) {
      case NewMoment(:final title, :final note):
        e.createMoment(title, note, _selected);
      case ExistingMoment(:final moment):
        e.addToMoment(moment, _selected);
    }
    _clearSelection();
    await _persist(e);
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
    final files = await ImagePicker().pickMultiImage(requestFullMetadata: true);
    if (files.isEmpty || !mounted) return;
    final repo = AlbumScope.read(context);
    final stacksBefore = e.stacks.length;
    final failed = await repo.importPhotos(e, files);
    if (!mounted) return;
    final newStacks = e.stacks.length - stacksBefore;
    _snack([
      failed == 0 ? 'Added ${files.length} photo${files.length == 1 ? '' : 's'}' : 'Added ${files.length - failed}, $failed could not be read',
      if (newStacks > 0) 'grouped similar shots into $newStacks carousel${newStacks == 1 ? '' : 's'}',
    ].join(' · '));
  }

  Future<void> _editDetails(AlbumEvent e) async {
    final d = await showEventEditor(context, existing: e);
    if (d == null || !mounted) return;
    e
      ..title = d.title
      ..location = d.location
      ..description = d.description;
    await _persist(e);
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
    await _persist(e);
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

  void _openViewer(AlbumEvent e, Photo p) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => PhotoViewer(eventId: e.id, initialPhotoId: p.id),
      transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
    ));
  }

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
    final interaction = CollageInteraction(
      selected: _selected,
      onOpen: (p) => _openViewer(e, p),
      onToggle: _toggle,
      onStartSelection: _startSelection,
    );

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
            body: CustomScrollView(
              slivers: [
                _header(context, e, style),
                DecoratedSliver(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [s.surface, tints.firstOrNull ?? s.surface],
                    ),
                  ),
                  sliver: SliverToBoxAdapter(child: _Constrained(child: _InfoSection(event: e, style: style))),
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
                      onEditNote: () => _editDayNote(e, days[i]),
                      onEditMoment: (m) => _editMoment(e, m),
                      onDissolveMoment: (m) => _dissolveMoment(e, m),
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

  Widget _header(BuildContext context, AlbumEvent e, EventStyle style) {
    final s = style.scheme;
    final cover = e.cover;
    final height = math.min(440.0, MediaQuery.sizeOf(context).height * 0.52);
    final busy = AlbumScope.of(context).importProgress.containsKey(e.id);

    final actions = <Widget>[
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
          const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete album'))),
        ],
      ),
      const SizedBox(width: 8),
    ];

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
  const _InfoSection({required this.event, required this.style});
  final AlbumEvent event;
  final EventStyle style;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = style.scheme;
    final chips = <(IconData, String)>[
      if (event.location.isNotEmpty) (Icons.place_outlined, event.location),
      if (event.photos.isNotEmpty) (Icons.calendar_today_outlined, formatDateRange(event.start, event.end)),
      if (event.photos.isNotEmpty) (Icons.photo_outlined, '${event.photos.length} photos'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chips.isNotEmpty)
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                for (final (icon, label) in chips)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 18, color: s.primary),
                    const SizedBox(width: 6),
                    Text(label, style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
                  ]),
              ],
            ),
          if (event.description.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(event.description, style: t.textTheme.bodyLarge?.copyWith(height: 1.5, color: s.onSurface)),
          ],
          if (style.palette.isNotEmpty) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Row(children: [for (final c in style.palette) Expanded(child: ColoredBox(color: c))]),
              ),
            ),
          ],
          if (event.photos.length >= 4 && event.moments.isEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.touch_app_outlined, size: 16, color: s.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Tip: long-press photos to select them, then group them into a moment or a carousel.',
                  style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
                ),
              ),
            ]),
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
    required this.onEditNote,
    required this.onEditMoment,
    required this.onDissolveMoment,
  });

  final AlbumEvent event;
  final EventStyle style;
  final DayView day;
  final int dayNumber;
  final CollageInteraction interaction;
  final VoidCallback onEditNote;
  final ValueChanged<Moment> onEditMoment;
  final ValueChanged<Moment> onDissolveMoment;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(builder: (context, constraints) {
      final cross = constraints.crossAxisExtent;
      final outer = math.max(0.0, (cross - _maxContentWidth) / 2);
      // Collage cells are inset by half a gap, so let the collage overhang
      // the text column by that much to keep photo edges aligned with text.
      final loosePad = outer + _sidePadding - _gap / 2;
      final cardMargin = outer + _sidePadding - 4;
      const cardInner = 8 - _gap / 2;
      final daySeed = event.layoutSeed ^ _stableHash(day.key);

      SliverList collageRows(List<AlbumItem> items, double width, int seed) {
        final blocks = buildCollage([for (final i in items) i.aspect], width, seed: seed);
        return SliverList.builder(
          itemCount: blocks.length,
          itemBuilder: (context, i) => CollageBlockView(block: blocks[i], items: items, interaction: interaction),
        );
      }

      return SliverMainAxisGroup(slivers: [
        SliverToBoxAdapter(
          child: _Constrained(child: _DayHeader(event: event, day: day, dayNumber: dayNumber, onEditNote: onEditNote)),
        ),
        for (final (index, block) in day.blocks.indexed)
          switch (block) {
            LooseRun() => SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: loosePad, vertical: 4),
                sliver: collageRows(block.items, cross - 2 * loosePad, daySeed ^ (index * 7919)),
              ),
            MomentBlock() => SliverPadding(
                padding: EdgeInsets.fromLTRB(cardMargin, 10, cardMargin, 10),
                sliver: DecoratedSliver(
                  decoration: BoxDecoration(
                    color: style.momentTint(block.photos),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: style.scheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  sliver: SliverPadding(
                    padding: const EdgeInsets.fromLTRB(cardInner, 0, cardInner, cardInner + 2),
                    sliver: SliverMainAxisGroup(slivers: [
                      SliverToBoxAdapter(
                        child: _MomentHeader(
                          block: block,
                          onEdit: () => onEditMoment(block.moment),
                          onDissolve: () => onDissolveMoment(block.moment),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 28, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Day $dayNumber',
                style: t.textTheme.headlineMedium?.copyWith(color: s.primary, fontWeight: FontWeight.w800, letterSpacing: -0.5),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    DateFormat('EEEE, d MMMM y').format(day.date),
                    style: t.textTheme.titleSmall?.copyWith(color: s.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                tooltip: note == null ? 'Add a note' : 'Edit note',
                onPressed: onEditNote,
                icon: Icon(note == null ? Icons.edit_note : Icons.edit_outlined, color: s.onSurfaceVariant),
              ),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 12),
              child: InkWell(
                onTap: onEditNote,
                child: Container(
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: s.primary, width: 3))),
                  child: Text(note, style: t.textTheme.bodyLarge?.copyWith(fontStyle: FontStyle.italic, height: 1.45)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MomentHeader extends StatelessWidget {
  const _MomentHeader({required this.block, required this.onEdit, required this.onDissolve});
  final MomentBlock block;
  final VoidCallback onEdit;
  final VoidCallback onDissolve;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final photos = block.photos;
    final hm = DateFormat('HH:mm');
    final first = photos.first.takenAt, last = photos.last.takenAt;
    final time = [
      if (dayKey(first) != dayKey(last)) DateFormat('d MMM, HH:mm').format(first) else hm.format(first),
      if (last.difference(first).inMinutes >= 1) (dayKey(first) != dayKey(last) ? DateFormat('d MMM, HH:mm') : hm).format(last),
    ].join(' – ');
    final m = block.moment;

    return InkWell(
      onTap: onEdit,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 0, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bookmark, size: 20, color: s.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15)),
                      Text(
                        '$time · ${photos.length} photo${photos.length == 1 ? '' : 's'}',
                        style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: s.onSurfaceVariant),
                  onSelected: (v) => v == 'edit' ? onEdit() : onDissolve(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit moment'))),
                    PopupMenuItem(
                      value: 'dissolve',
                      child: ListTile(leading: Icon(Icons.bookmark_remove_outlined), title: Text('Dissolve (keep photos)')),
                    ),
                  ],
                ),
              ],
            ),
            if (m.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 6, 12, 0),
                child: Text(m.note, style: t.textTheme.bodyMedium?.copyWith(height: 1.45)),
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
