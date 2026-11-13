import 'dart:math' as math;

import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../layout/collage_layout.dart';
import '../models/models.dart';
import '../theme/event_theme.dart';
import '../widgets/collage_view.dart';
import '../widgets/common.dart';
import 'event_editor.dart';
import 'photo_actions.dart';
import 'photo_viewer.dart';
import 'theme_picker.dart';

void openEvent(BuildContext context, AlbumEvent e, {bool pickPhotos = false}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => EventScreen(eventId: e.id, pickPhotosOnOpen: pickPhotos),
  ));
}

const _maxContentWidth = 1000.0;
const _sidePadding = 12.0;

class EventScreen extends StatefulWidget {
  const EventScreen({super.key, required this.eventId, this.pickPhotosOnOpen = false});
  final String eventId;
  final bool pickPhotosOnOpen;

  @override
  State<EventScreen> createState() => _EventScreenState();
}

class _EventScreenState extends State<EventScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.pickPhotosOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _addPhotos());
    }
  }

  AlbumEvent? get _event => AlbumScope.read(context).byId(widget.eventId);

  Future<void> _addPhotos() async {
    final e = _event;
    if (e == null) return;
    final files = await ImagePicker().pickMultiImage(requestFullMetadata: true);
    if (files.isEmpty || !mounted) return;
    final repo = AlbumScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final failed = await repo.importPhotos(e, files);
    messenger.showSnackBar(SnackBar(
      content: Text(failed == 0
          ? 'Added ${files.length} photo${files.length == 1 ? '' : 's'}'
          : 'Added ${files.length - failed}, $failed could not be read'),
    ));
  }

  Future<void> _editDetails(AlbumEvent e) async {
    final d = await showEventEditor(context, existing: e);
    if (d == null || !mounted) return;
    e
      ..title = d.title
      ..location = d.location
      ..description = d.description;
    await AlbumScope.read(context).changed(e);
  }

  Future<void> _editDayNote(AlbumEvent e, DaySection day) async {
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
    await AlbumScope.read(context).changed(e);
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

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.of(context);
    final e = repo.byId(widget.eventId);
    if (e == null) return const Scaffold();
    final style = EventStyle.of(e);
    final s = style.scheme;
    final days = groupByDay(e.photos);
    final progress = repo.importProgress[e.id];
    final firstDay = days.isEmpty ? null : days.first.date;

    // Background colours flow from one day's tint into the next.
    final tints = [for (final d in days) style.dayTints[d.key] ?? s.surface];

    return Theme(
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
                    day: days[i],
                    dayNumber: days[i].date.difference(firstDay!).inDays + 1,
                    onTap: (p) => _openViewer(e, p),
                    onLongPress: (p) => showPhotoActions(context, e, p),
                    onEditNote: () => _editDayNote(e, days[i]),
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
          bottomNavigationBar: progress == null
              ? null
              : Material(
                  color: s.surfaceContainerHigh,
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
                ),
        );
      }),
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
          switch (v) {
            case 'edit':
              await _editDetails(e);
            case 'shuffle':
              e.layoutSeed = math.Random().nextInt(1 << 30);
              await AlbumScope.read(context).changed(e);
            case 'delete':
              await _delete(e);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit details'))),
          PopupMenuItem(value: 'shuffle', child: ListTile(leading: Icon(Icons.shuffle), title: Text('Shuffle layout'))),
          PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete album'))),
        ],
      ),
      const SizedBox(width: 8),
    ];

    if (cover == null) {
      return SliverAppBar.large(
        title: Text(e.title),
        backgroundColor: s.surface,
        actions: actions,
      );
    }

    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: height,
      backgroundColor: s.surface,
      surfaceTintColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.all(4),
        child: IconButton.filledTonal(
          onPressed: () => Navigator.maybePop(context),
          icon: const BackButtonIcon(),
        ),
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
        ],
      ),
    );
  }
}

class _DaySliver extends StatelessWidget {
  const _DaySliver({
    required this.event,
    required this.day,
    required this.dayNumber,
    required this.onTap,
    required this.onLongPress,
    required this.onEditNote,
  });

  final AlbumEvent event;
  final DaySection day;
  final int dayNumber;
  final ValueChanged<Photo> onTap;
  final ValueChanged<Photo> onLongPress;
  final VoidCallback onEditNote;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(builder: (context, constraints) {
      final width = math.min(constraints.crossAxisExtent, _maxContentWidth) - 2 * _sidePadding + 6;
      final blocks = buildCollage(
        [for (final p in day.photos) p.aspect],
        width,
        // String.hashCode isn't guaranteed stable across runs/platforms.
        seed: event.layoutSeed ^ day.key.codeUnits.fold(17, (h, c) => (h * 31 + c) & 0x7fffffff),
      );
      return SliverList.builder(
        itemCount: blocks.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) return _Constrained(child: _DayHeader(event: event, day: day, dayNumber: dayNumber, onEditNote: onEditNote));
          return Center(
            child: CollageBlockView(
              block: blocks[i - 1],
              photos: day.photos,
              onTap: onTap,
              onLongPress: onLongPress,
            ),
          );
        },
      );
    });
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.event, required this.day, required this.dayNumber, required this.onEditNote});
  final AlbumEvent event;
  final DaySection day;
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
