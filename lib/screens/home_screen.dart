import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';

import '../models/models.dart';
import '../theme/event_theme.dart';
import '../widgets/common.dart';
import 'event_editor.dart';
import 'event_screen.dart';
import 'settings_screen.dart';

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
    if (details.locationManual) {
      e.locationManual = true;
      await repo.changed(e);
    }
    if (context.mounted) openEvent(context, e, pickPhotos: true);
  }

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.of(context);
    final events = repo.events;
    final scheme = Theme.of(context).colorScheme;
    // A faint tint from all albums' colours together.
    final tint = EventStyle.libraryTint();
    final background = tint == null ? scheme.surface : Color.lerp(scheme.surface, tint, 0.08)!;

    return Scaffold(
      backgroundColor: background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 210,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            flexibleSpace: _AuroraHeader(
              colors: [
                for (final e in events.take(7))
                  if (e.photos.isNotEmpty) haloColor(EventStyle.of(e), grey: 0.15),
              ],
              seeds: [
                for (final e in events.take(7))
                  if (e.photos.isNotEmpty) e.id.hashCode,
              ],
              background: background,
              subtitle: _librarySummary(events),
            ),
            actions: [
              IconButton(
                tooltip: tr('Settings'),
                icon: const Icon(Icons.settings_outlined),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
              ),
              const SizedBox(width: 4),
            ],
          ),
          if (!repo.loaded)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else if (events.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: _EmptyState(onCreate: () => _create(context)))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 440,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 20,
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
              label: Text(tr('New album')),
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
            Text(
              tr('Your memories, beautifully arranged'),
              style: t.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              tr(
                'Create an album for a trip or event, add your photos, and get automatic collages in colours that match them.',
              ),
              style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: Text(tr('Create your first album')),
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

    final dark = Theme.of(context).brightness == Brightness.dark;
    // A soft halo in the album's colour; neighbouring halos blend together.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(color: haloColor(style).withValues(alpha: dark ? 0.3 : 0.22), blurRadius: 36, spreadRadius: 2),
        ],
      ),
      child: Material(
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(22),
        elevation: 1,
        shadowColor: Colors.black26,
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
                    : PhotoThumb(photo: cover, radius: 0),
              ),
              if (progress != null) LinearProgressIndicator(value: progress.$1 / progress.$2),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [s.primaryContainer, Color.lerp(s.primaryContainer, s.tertiaryContainer, 0.7)!],
                  ),
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
      ),
    );
  }
}

/// "5 albums · 843 photos · since 2023".
String _librarySummary(List<AlbumEvent> events) {
  if (events.isEmpty) return tr('Your trips and events, beautifully arranged');
  final photos = events.fold(0, (n, e) => n + e.photos.length);
  final starts = [for (final e in events) ?e.start];
  final first = starts.isEmpty ? null : starts.reduce((a, b) => a.isBefore(b) ? a : b);
  return [
    trn('{n} album', '{n} albums', events.length),
    trn('{n} photo', '{n} photos', photos),
    if (first != null && first.year < DateTime.now().year) tr('since {year}', {'year': first.year}),
  ].join('  ·  ');
}

/// The home header: the albums' colours as soft drifting light behind the
/// title, fading into the page so the cards' glow continues upwards. As the
/// header collapses on scroll the lights drift together into the bar.
class _AuroraHeader extends StatelessWidget {
  const _AuroraHeader({required this.colors, required this.seeds, required this.background, required this.subtitle});

  final List<Color> colors;
  final List<int> seeds;
  final Color background;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final top = MediaQuery.paddingOf(context).top;
    final lights = colors.isEmpty ? [s.primary, s.tertiary, s.secondary] : colors;
    return LayoutBuilder(
      builder: (context, c) {
        final minH = top + kToolbarHeight;
        // 1 = fully expanded, 0 = collapsed into the bar.
        final t = ((c.maxHeight - minH) / (210 + top - minH)).clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _AuroraPainter(
                lights,
                colors.isEmpty ? const [1, 2, 3] : seeds,
                t,
                background,
                dark ? 0.5 : 0.42,
              ),
            ),
            Positioned(
              left: 20,
              right: 72,
              bottom: 10 + 14 * t,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('My Albums'),
                    style: TextStyle(
                      fontSize: 22 + 14 * t,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                      color: s.onSurface,
                    ),
                  ),
                  if (t > 0.05)
                    Opacity(
                      opacity: t,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: s.onSurfaceVariant, fontSize: 14),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.colors, this.seeds, this.t, this.background, this.strength);

  final List<Color> colors;
  final List<int> seeds;
  final double t;
  final Color background;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final n = colors.length;
    for (var i = 0; i < n; i++) {
      // A stable spot per album, spread across the width.
      final h = seeds[i] & 0x7fffffff;
      final fx = (i + 0.5) / n + ((h % 100) / 100 - 0.5) * 0.5 / n;
      final fy = 0.25 + ((h ~/ 100) % 100) / 100 * 0.5;
      final dir = (h ~/ 10000).isEven ? 1 : -1;
      // Drift sideways and up as the header collapses.
      final center = Offset(size.width * (fx + dir * (1 - t) * 0.08), size.height * (fy * (0.6 + 0.4 * t)));
      final radius = size.width * (0.26 + 0.12 * ((h ~/ 7) % 10) / 10) * (0.75 + 0.25 * t);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colors[i].withValues(alpha: strength),
              colors[i].withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    // Dissolve into the page at the bottom, so there's no edge.
    final fade = Rect.fromLTWH(0, size.height * 0.55, size.width, size.height * 0.45);
    canvas.drawRect(
      fade,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [background.withValues(alpha: 0), background],
        ).createShader(fade),
    );
    // While expanded, the bottom edge turns see-through so the glow of the
    // cards below isn't cut off (collapsed, the bar stays solid).
    final edge = Rect.fromLTWH(0, size.height * 0.7, size.width, size.height * 0.3);
    canvas.drawRect(
      edge,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black,
            Colors.black.withValues(alpha: 1 - t),
          ],
        ).createShader(edge),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.t != t ||
      old.background != background ||
      old.strength != strength ||
      old.colors.length != colors.length ||
      !_same(old.colors, colors);

  static bool _same(List<Color> a, List<Color> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
