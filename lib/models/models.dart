/// Plain data classes for albums ("events") and their photos.
///
/// Everything is serialised to JSON and stored via [AppStorage]; image bytes
/// are stored separately as blobs keyed by [Photo.thumbKey] / [Photo.fullKey].
library;

/// One weighted colour of a palette extracted from a photo.
class PaletteColor {
  const PaletteColor(this.argb, this.weight);

  /// Colour as 0xAARRGGBB.
  final int argb;

  /// Share of the sampled pixels this colour represents (0..1).
  final double weight;

  Map<String, dynamic> toJson() => {'c': argb, 'w': weight};

  factory PaletteColor.fromJson(Map<String, dynamic> j) =>
      PaletteColor(j['c'] as int, (j['w'] as num).toDouble());
}

class Photo {
  Photo({
    required this.id,
    required this.width,
    required this.height,
    required this.takenAt,
    required this.palette,
    this.caption = '',
  });

  final String id;

  /// Pixel size of the stored thumbnail (orientation already applied).
  /// Only the ratio matters for layout.
  final int width;
  final int height;

  /// Capture time from EXIF, falling back to the file's modification time.
  DateTime takenAt;
  final List<PaletteColor> palette;
  String caption;

  double get aspect => width / height;

  String get thumbKey => 'thumb_$id';
  String get fullKey => 'full_$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'w': width,
        'h': height,
        'takenAt': takenAt.toIso8601String(),
        'palette': palette.map((p) => p.toJson()).toList(),
        'caption': caption,
      };

  factory Photo.fromJson(Map<String, dynamic> j) => Photo(
        id: j['id'] as String,
        width: j['w'] as int,
        height: j['h'] as int,
        takenAt: DateTime.parse(j['takenAt'] as String),
        palette: (j['palette'] as List)
            .map((e) => PaletteColor.fromJson(e as Map<String, dynamic>))
            .toList(),
        caption: j['caption'] as String? ?? '',
      );
}

/// Where an event's colours come from.
enum ThemeSource { auto, preset, custom }

class EventThemeSettings {
  const EventThemeSettings({
    this.source = ThemeSource.auto,
    this.presetId,
    this.customSeed,
    this.dark,
  });

  final ThemeSource source;
  final String? presetId;
  final int? customSeed;

  /// null = decide automatically (from the photos or the preset).
  final bool? dark;

  EventThemeSettings copyWith({
    ThemeSource? source,
    String? presetId,
    int? customSeed,
    bool? Function()? dark,
  }) =>
      EventThemeSettings(
        source: source ?? this.source,
        presetId: presetId ?? this.presetId,
        customSeed: customSeed ?? this.customSeed,
        dark: dark != null ? dark() : this.dark,
      );

  Map<String, dynamic> toJson() => {
        'source': source.name,
        'presetId': presetId,
        'customSeed': customSeed,
        'dark': dark,
      };

  factory EventThemeSettings.fromJson(Map<String, dynamic> j) =>
      EventThemeSettings(
        source: ThemeSource.values.asNameMap()[j['source']] ?? ThemeSource.auto,
        presetId: j['presetId'] as String?,
        customSeed: j['customSeed'] as int?,
        dark: j['dark'] as bool?,
      );
}

class AlbumEvent {
  AlbumEvent({
    required this.id,
    required this.title,
    required this.createdAt,
    this.location = '',
    this.description = '',
    this.coverPhotoId,
    List<Photo>? photos,
    Map<String, String>? dayNotes,
    this.theme = const EventThemeSettings(),
    int? layoutSeed,
  })  : photos = photos ?? [],
        dayNotes = dayNotes ?? {},
        layoutSeed = layoutSeed ?? createdAt.microsecondsSinceEpoch & 0x7fffffff;

  final String id;
  String title;
  String location;
  String description;
  final DateTime createdAt;
  String? coverPhotoId;

  /// Kept sorted by [Photo.takenAt].
  final List<Photo> photos;

  /// Free text per day, keyed by [dayKey].
  final Map<String, String> dayNotes;
  EventThemeSettings theme;

  /// Seed for the collage layout so it stays stable between app starts;
  /// "shuffle layout" simply changes it.
  int layoutSeed;

  Photo? get cover {
    if (photos.isEmpty) return null;
    return photos.where((p) => p.id == coverPhotoId).firstOrNull ?? photos.first;
  }

  DateTime? get start => photos.isEmpty ? null : photos.first.takenAt;
  DateTime? get end => photos.isEmpty ? null : photos.last.takenAt;

  void sortPhotos() => photos.sort((a, b) => a.takenAt.compareTo(b.takenAt));

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'location': location,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
        'coverPhotoId': coverPhotoId,
        'photos': photos.map((p) => p.toJson()).toList(),
        'dayNotes': dayNotes,
        'theme': theme.toJson(),
        'layoutSeed': layoutSeed,
      };

  factory AlbumEvent.fromJson(Map<String, dynamic> j) => AlbumEvent(
        id: j['id'] as String,
        title: j['title'] as String,
        location: j['location'] as String? ?? '',
        description: j['description'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        coverPhotoId: j['coverPhotoId'] as String?,
        photos: (j['photos'] as List)
            .map((e) => Photo.fromJson(e as Map<String, dynamic>))
            .toList(),
        dayNotes: (j['dayNotes'] as Map?)?.cast<String, String>(),
        theme: j['theme'] == null
            ? const EventThemeSettings()
            : EventThemeSettings.fromJson(j['theme'] as Map<String, dynamic>),
        layoutSeed: j['layoutSeed'] as int?,
      );
}

/// Calendar-day key used for grouping photos and for [AlbumEvent.dayNotes].
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A group of photos taken on the same calendar day.
class DaySection {
  DaySection(this.key, this.date, this.photos);
  final String key;
  final DateTime date;
  final List<Photo> photos;
}

List<DaySection> groupByDay(List<Photo> photos) {
  final sections = <DaySection>[];
  for (final p in photos) {
    final k = dayKey(p.takenAt);
    if (sections.isEmpty || sections.last.key != k) {
      sections.add(DaySection(k, DateTime(p.takenAt.year, p.takenAt.month, p.takenAt.day), []));
    }
    sections.last.photos.add(p);
  }
  return sections;
}
