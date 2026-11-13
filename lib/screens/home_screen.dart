import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../theme/event_theme.dart';
import '../widgets/common.dart';
import 'event_editor.dart';
import 'event_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final details = await showEventEditor(context);
    if (details == null || !context.mounted) return;
    final repo = AlbumScope.read(context);
    final e = await repo.createEvent(
      title: details.title,
      location: details.location,
      description: details.description,
    );
    if (context.mounted) openEvent(context, e, pickPhotos: true);
  }

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.of(context);
    final events = repo.events;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('My Albums', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
            backgroundColor: scheme.surface,
          ),
          if (!repo.loaded)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else if (events.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: _EmptyState(onCreate: () => _create(context)))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 440,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.86,
                ),
                itemCount: events.length,
                itemBuilder: (context, i) => _EventCard(event: events[i]),
              ),
            ),
        ],
      ),
      floatingActionButton: events.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _create(context),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('New album'),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_album_outlined, size: 88, color: t.colorScheme.primary),
            const SizedBox(height: 20),
            Text('Your memories, beautifully arranged', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              'Create an album for a trip or event, add your photos, and get automatic collages in colours that match them.',
              style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Create your first album'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});
  final AlbumEvent event;

  @override
  Widget build(BuildContext context) {
    final style = EventStyle.of(event);
    final s = style.scheme;
    final cover = event.cover;
    final progress = AlbumScope.of(context).importProgress[event.id];

    return Material(
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(22),
      elevation: 2,
      shadowColor: style.seed.withValues(alpha: 0.4),
      color: s.surfaceContainer,
      child: InkWell(
        onTap: () => openEvent(context, event),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: cover == null
                  ? DecoratedBox(
                      decoration: BoxDecoration(gradient: eventGradient(style)),
                      child: Center(child: Icon(Icons.photo_library_outlined, size: 48, color: s.onPrimaryContainer)),
                    )
                  : _CoverMosaic(event: event),
            ),
            if (progress != null) LinearProgressIndicator(value: progress.$1 / progress.$2),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [s.primaryContainer, Color.lerp(s.primaryContainer, s.tertiaryContainer, 0.7)!]),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: s.onPrimaryContainer),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (event.location.isNotEmpty) event.location,
                      formatDateRange(event.start, event.end),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: s.onPrimaryContainer.withValues(alpha: 0.8)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final c in style.palette.take(6))
                        Container(
                          width: 14,
                          height: 14,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: s.onPrimaryContainer.withValues(alpha: 0.25)),
                          ),
                        ),
                      const Spacer(),
                      Icon(Icons.photo_outlined, size: 16, color: s.onPrimaryContainer),
                      const SizedBox(width: 4),
                      Text('${event.photos.length}', style: TextStyle(color: s.onPrimaryContainer)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cover photo plus up to two small accent photos, like a stack of prints.
class _CoverMosaic extends StatelessWidget {
  const _CoverMosaic({required this.event});
  final AlbumEvent event;

  @override
  Widget build(BuildContext context) {
    final cover = event.cover!;
    final others = event.photos.where((p) => p.id != cover.id).toList();
    // Pick two spread-out photos so the preview shows variety.
    final extras = others.length < 3 ? <Photo>[] : [others[others.length ~/ 3], others[others.length * 2 ~/ 3]];
    if (extras.isEmpty) return PhotoThumb(photo: cover, radius: 0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 2, child: PhotoThumb(photo: cover, radius: 0)),
        const SizedBox(width: 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: PhotoThumb(photo: extras[0], radius: 0)),
              const SizedBox(height: 2),
              Expanded(child: PhotoThumb(photo: extras[1], radius: 0)),
            ],
          ),
        ),
      ],
    );
  }
}
