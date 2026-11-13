import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../theme/event_theme.dart';
import '../widgets/common.dart';

/// Lets the user choose between automatic colours (from the photos),
/// a preset mood, or a custom colour. Changes apply live.
Future<void> showThemePicker(BuildContext context, AlbumEvent e) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: 0.92,
      builder: (context, scroll) => _ThemePicker(event: e, scroll: scroll),
    ),
  );
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.event, required this.scroll});
  final AlbumEvent event;
  final ScrollController scroll;

  Future<void> _set(BuildContext context, EventThemeSettings t) async {
    event.theme = t;
    await AlbumScope.read(context).changed(event, styleChanged: true);
  }

  @override
  Widget build(BuildContext context) {
    AlbumScope.of(context); // rebuild on changes
    final style = EventStyle.of(event);
    final t = event.theme;
    final text = Theme.of(context).textTheme;

    return Theme(
      data: style.themeData,
      child: Builder(builder: (context) {
        final s = Theme.of(context).colorScheme;
        return Material(
          color: s.surfaceContainerLow,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              Text('Theme & colours', style: text.headlineSmall),
              const SizedBox(height: 16),
              _OptionCard(
                selected: t.source == ThemeSource.auto,
                onTap: () => _set(context, t.copyWith(source: ThemeSource.auto)),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, color: s.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('From your photos', style: text.titleMedium),
                          Text(
                            'Colours are picked from the album, and each day gets its own tint.',
                            style: text.bodySmall?.copyWith(color: s.onSurfaceVariant),
                          ),
                          if (style.palette.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(spacing: 4, children: [for (final c in style.palette) _Dot(color: c, size: 18)]),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text('Mood presets', style: text.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in themePresets)
                    ChoiceChip(
                      selected: t.source == ThemeSource.preset && t.presetId == p.id,
                      avatar: CircleAvatar(backgroundColor: p.seed, child: Icon(p.icon, size: 14, color: Colors.white)),
                      label: Text(p.name),
                      onSelected: (_) => _set(
                        context,
                        EventThemeSettings(source: ThemeSource.preset, presetId: p.id, customSeed: t.customSeed, dark: null),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Custom colour', style: text.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in customSeeds)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _set(
                        context,
                        EventThemeSettings(source: ThemeSource.custom, presetId: t.presetId, customSeed: c.toARGB32(), dark: t.dark),
                      ),
                      child: _Dot(
                        color: c,
                        size: 36,
                        selected: t.source == ThemeSource.custom && t.customSeed == c.toARGB32(),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text('Appearance', style: text.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<bool?>(
                segments: const [
                  ButtonSegment(value: null, label: Text('Auto'), icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: false, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: true, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {t.dark},
                onSelectionChanged: (v) => _set(context, t.copyWith(dark: () => v.first)),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.selected, required this.onTap, required this.child});
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Material(
      color: selected ? s.secondaryContainer : s.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? s.primary : Colors.transparent, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size, this.selected = false});
  final Color color;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: selected ? s.onSurface : s.outlineVariant, width: selected ? 3 : 1),
      ),
      child: selected ? Icon(Icons.check, size: size * 0.5, color: Colors.white) : null,
    );
  }
}
