import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import 'palette.dart';

class ThemePreset {
  const ThemePreset(this.id, this.name, this.icon, this.seed, {this.dark = false});
  final String id;
  final String name;
  final IconData icon;
  final Color seed;
  final bool dark;
}

const themePresets = <ThemePreset>[
  ThemePreset('beach', 'Beach', Icons.beach_access, Color(0xFF1FA9B8)),
  ThemePreset('mountains', 'Mountains', Icons.landscape, Color(0xFF4E7D5B)),
  ThemePreset('forest', 'Forest', Icons.forest, Color(0xFF2F6B3A), dark: true),
  ThemePreset('city', 'City', Icons.location_city, Color(0xFF5C6B8A), dark: true),
  ThemePreset('winter', 'Winter', Icons.ac_unit, Color(0xFF7FAEDB)),
  ThemePreset('autumn', 'Autumn', Icons.eco, Color(0xFFC8662B)),
  ThemePreset('desert', 'Desert', Icons.wb_sunny, Color(0xFFD39A55)),
  ThemePreset('party', 'Party', Icons.celebration, Color(0xFFD6338A), dark: true),
  ThemePreset('romance', 'Wedding', Icons.favorite, Color(0xFFE38FA6)),
  ThemePreset('night', 'Night', Icons.nightlight_round, Color(0xFF3B3F8F), dark: true),
];

/// Swatches offered for a fully custom theme.
const customSeeds = <Color>[
  Color(0xFFE53935), Color(0xFFFF7043), Color(0xFFFFB300), Color(0xFFC0CA33),
  Color(0xFF43A047), Color(0xFF00897B), Color(0xFF00ACC1), Color(0xFF1E88E5),
  Color(0xFF3949AB), Color(0xFF8E24AA), Color(0xFFD81B60), Color(0xFF6D4C41),
  Color(0xFF546E7A), Color(0xFF212121),
];

const _fallbackSeed = Color(0xFF6B7FA3);

/// Everything the UI needs to paint one event in its own colours.
class EventStyle {
  EventStyle._(this.scheme, this.seed, this.palette, this.dayTints, this._photoColors);

  /// Whether colours follow the photos (auto theme) or a fixed choice.
  final bool _photoColors;

  /// Card background for a moment, tinted by its own photos when the album
  /// uses automatic colours.
  Color momentTint(List<Photo> photos) {
    final base = scheme.surfaceContainerLowest;
    final argb = _photoColors ? chooseSeed(mergePalettes(photos.map((p) => p.palette))) : null;
    final tint = argb == null ? scheme.secondaryContainer : Color(argb);
    return Color.lerp(base, tint, isDark ? 0.14 : 0.2)!.withValues(alpha: 0.82);
  }

  final ColorScheme scheme;
  final Color seed;

  /// The merged palette of all photos (for swatches and decoration).
  final List<Color> palette;

  /// Soft background tint per day section, derived from that day's photos.
  final Map<String, Color> dayTints;

  bool get isDark => scheme.brightness == Brightness.dark;

  ThemeData get themeData => ThemeData(colorScheme: scheme, useMaterial3: true);

  static final _cache = <String, EventStyle>{};

  static EventStyle of(AlbumEvent e) => _cache[e.id] ??= _compute(e);

  /// Fine-grained palette per album (24 colours), for comparing albums.
  static final _albumPalettes = <String, List<PaletteColor>>{};

  /// All albums of the library, so an album's colours can be compared with
  /// the others (set by the app; empty in isolation).
  static Iterable<AlbumEvent> Function() library = () => const [];

  /// Must be called whenever an event's photos or theme settings change.
  static void invalidate(String eventId) {
    _cache.remove(eventId);
    _albumPalettes.remove(eventId);
  }

  /// Recompute every album's colours (their comparison baseline changed).
  static void invalidateComparisons() => _cache.clear();

  static List<PaletteColor> _albumPalette(AlbumEvent e) =>
      _albumPalettes[e.id] ??= mergePalettes(e.photos.map((p) => p.palette), maxColors: 24);

  static EventStyle _compute(AlbumEvent e) {
    final merged = mergePalettes(e.photos.map((p) => p.palette));
    // The album's signature colours: vivid, not sky/stone/foliage, and more
    // typical of this trip than of the user's other albums.
    final others = [
      for (final o in library())
        if (o.id != e.id && o.photos.isNotEmpty) _albumPalette(o),
    ];
    final signature = signatureColors(
      _albumPalette(e),
      baseline: others.isEmpty ? const [] : mergePalettes(others, maxColors: 24),
    );
    final autoSeedArgb = signature.isNotEmpty ? signature.first.argb : chooseSeed(merged);
    final autoSeed = autoSeedArgb == null ? _fallbackSeed : Color(autoSeedArgb);

    Color seed;
    bool dark;
    switch (e.theme.source) {
      case ThemeSource.auto:
        seed = autoSeed;
        dark = merged.isNotEmpty && averageLightness(merged) < 0.3;
      case ThemeSource.preset:
        final preset = themePresets.where((p) => p.id == e.theme.presetId).firstOrNull ?? themePresets.first;
        seed = preset.seed;
        dark = preset.dark;
      case ThemeSource.custom:
        seed = e.theme.customSeed == null ? autoSeed : Color(e.theme.customSeed!);
        dark = false;
    }
    dark = e.theme.dark ?? dark;
    final brightness = dark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );

    // Each day gets a background tinted towards its own photos' character,
    // so the page gently shifts colour as you scroll through the trip.
    final tints = <String, Color>{};
    final useDayColors = e.theme.source == ThemeSource.auto;
    for (final day in groupByDay(e.photos)) {
      final daySeedArgb = useDayColors ? chooseSeed(mergePalettes(day.photos.map((p) => p.palette))) : null;
      final daySeed = daySeedArgb == null ? seed : Color(daySeedArgb);
      tints[day.key] = Color.lerp(scheme.surface, daySeed, dark ? 0.16 : 0.22)!;
    }

    return EventStyle._(scheme, seed, signature.map((c) => Color(c.argb)).toList(), tints, useDayColors);
  }
}

/// A background gradient for cards/headers that uses the event's colours.
LinearGradient eventGradient(EventStyle s) {
  final a = s.palette.isNotEmpty ? s.palette.first : s.scheme.primaryContainer;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.lerp(s.scheme.primaryContainer, a, 0.25)!,
      s.scheme.tertiaryContainer,
    ],
  );
}
