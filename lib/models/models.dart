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
    this.dhash,
    this.sharpness,
    this.exactTime = true,
    this.lat,
    this.lng,
    this.locationManual = false,
    this.assetId,
    this.folderId,
  });

  /// GPS position (from EXIF or set by the user).
  double? lat;
  double? lng;
  bool locationManual;

  bool get hasLocation => lat != null && lng != null;

  /// Id of the original in the device gallery (Android). When set, the app
  /// stores only the preview and loads the original from the gallery.
  final String? assetId;

  /// The linked gallery folder this photo came from ([FolderLink.id]); null
  /// for photos picked by hand.
  String? folderId;

  final String id;

  /// Pixel size of the stored thumbnail (orientation already applied).
  /// Only the ratio matters for layout.
  final int width;
  final int height;

  /// Capture time from EXIF, falling back to the file's modification time.
  DateTime takenAt;
  final List<PaletteColor> palette;
  String caption;

  /// 64-bit perceptual difference hash as 16 hex chars (see similarity.dart).
  /// Null for photos imported before hashing existed, until backfilled.
  String? dhash;

  /// Relative sharpness (variance of the Laplacian); used to pick the best
  /// shot of a carousel.
  double? sharpness;

  /// Whether [takenAt] came from EXIF (reliable) rather than a file date.
  bool exactTime;

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
        if (dhash != null) 'dh': dhash,
        if (sharpness != null) 'sh': sharpness,
        if (!exactTime) 'et': false,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (locationManual) 'lm': true,
        if (assetId != null) 'aid': assetId,
        if (folderId != null) 'fid': folderId,
      };

  factory Photo.fromJson(Map<String, dynamic> j) => Photo(
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        locationManual: j['lm'] as bool? ?? false,
        assetId: j['aid'] as String?,
        folderId: j['fid'] as String?,
        dhash: j['dh'] as String?,
        sharpness: (j['sh'] as num?)?.toDouble(),
        exactTime: j['et'] as bool? ?? true,
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

/// Several very similar photos shown as one swipeable carousel in a collage.
class PhotoStack {
  PhotoStack({required this.id, required this.photoIds, this.coverId, this.auto = false});

  final String id;
  final List<String> photoIds;

  /// Photo shown first; null = the sharpest one.
  String? coverId;

  /// Created by similarity detection (vs. grouped by the user).
  final bool auto;

  Map<String, dynamic> toJson() => {'id': id, 'photos': photoIds, 'cover': coverId, 'auto': auto};

  factory PhotoStack.fromJson(Map<String, dynamic> j) => PhotoStack(
        id: j['id'] as String,
        photoIds: (j['photos'] as List).cast<String>().toList(),
        coverId: j['cover'] as String?,
        auto: j['auto'] as bool? ?? false,
      );
}

/// A named point on the map (a café, a viewpoint, a town).
class GeoPlace {
  const GeoPlace({required this.name, this.address = '', required this.lat, required this.lng});

  final String name;

  /// Human-readable address / context ("Rua da Rosa 12, Lisbon, Portugal").
  final String address;
  final double lat;
  final double lng;

  Map<String, dynamic> toJson() => {'name': name, 'address': address, 'lat': lat, 'lng': lng};

  factory GeoPlace.fromJson(Map<String, dynamic> j) => GeoPlace(
        name: j['name'] as String,
        address: j['address'] as String? ?? '',
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
      );
}

/// A short AI-written flavour text about a place, with the web sources it
/// was based on.
class PlaceStory {
  const PlaceStory({required this.text, this.sources = const [], required this.createdAt});

  final String text;

  /// Source URLs the text is grounded in.
  final List<String> sources;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {'text': text, 'sources': sources, 'at': createdAt.toIso8601String()};

  factory PlaceStory.fromJson(Map<String, dynamic> j) => PlaceStory(
        text: j['text'] as String,
        sources: (j['sources'] as List?)?.cast<String>() ?? const [],
        createdAt: DateTime.parse(j['at'] as String),
      );
}

/// A titled sub-section of a day ("Breakfast at Café Lua"), holding any
/// subset of photos. Shown where its earliest photo falls in the timeline.
class Moment {
  Moment({required this.id, required this.title, this.note = '', required this.photoIds, this.place, this.story});

  final String id;
  String title;
  String note;
  final List<String> photoIds;
  GeoPlace? place;
  PlaceStory? story;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'photos': photoIds,
        if (place != null) 'place': place!.toJson(),
        if (story != null) 'story': story!.toJson(),
      };

  factory Moment.fromJson(Map<String, dynamic> j) => Moment(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        note: j['note'] as String? ?? '',
        photoIds: (j['photos'] as List).cast<String>().toList(),
        place: j['place'] == null ? null : GeoPlace.fromJson(j['place'] as Map<String, dynamic>),
        story: j['story'] == null ? null : PlaceStory.fromJson(j['story'] as Map<String, dynamic>),
      );
}

/// How densely the collages are packed.
enum LayoutStyle { airy, compact }

/// App-wide settings (stored with the albums, on this device only).
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.model = 'claude-opus-5-5',
    this.onlineLookups = true,
    this.autoStories = false,
  });

  /// The user's own Anthropic API key, used for place descriptions.
  final String apiKey;
  final String model;

  /// Look up place names / search places via OpenStreetMap.
  final bool onlineLookups;

  /// Write a place description automatically when a moment gets a place.
  final bool autoStories;

  bool get canWriteStories => apiKey.trim().isNotEmpty;

  AppSettings copyWith({String? apiKey, String? model, bool? onlineLookups, bool? autoStories}) => AppSettings(
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        onlineLookups: onlineLookups ?? this.onlineLookups,
        autoStories: autoStories ?? this.autoStories,
      );

  Map<String, dynamic> toJson() =>
      {'apiKey': apiKey, 'model': model, 'onlineLookups': onlineLookups, 'autoStories': autoStories};

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        apiKey: j['apiKey'] as String? ?? '',
        model: j['model'] as String? ?? 'claude-opus-5-5',
        onlineLookups: j['onlineLookups'] as bool? ?? true,
        autoStories: j['autoStories'] as bool? ?? false,
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
    List<PhotoStack>? stacks,
    List<Moment>? moments,
    Set<String>? noAutoStack,
    this.autoStack = true,
    Map<String, String>? dayPlaces,
    this.layout = LayoutStyle.airy,
    List<FolderLink>? linkedFolders,
    Set<String>? excludedAssets,
  })  : photos = photos ?? [],
        linkedFolders = linkedFolders ?? [],
        excludedAssets = excludedAssets ?? {},
        dayPlaces = dayPlaces ?? {},
        dayNotes = dayNotes ?? {},
        stacks = stacks ?? [],
        moments = moments ?? [],
        noAutoStack = noAutoStack ?? {},
        layoutSeed = layoutSeed ?? createdAt.microsecondsSinceEpoch & 0x7fffffff;

  final List<PhotoStack> stacks;
  final List<Moment> moments;

  /// Photos the user pulled out of a carousel; auto-detection leaves them alone.
  final Set<String> noAutoStack;

  /// Whether similar photos are grouped into carousels automatically.
  bool autoStack;

  /// Town / area name per day (keyed by [dayKey]), looked up from GPS.
  final Map<String, String> dayPlaces;

  LayoutStyle layout;

  /// Gallery folders this album stays in sync with.
  final List<FolderLink> linkedFolders;

  /// Gallery photos the user removed from the album; folder sync skips them.
  final Set<String> excludedAssets;

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
        'stacks': stacks.map((s) => s.toJson()).toList(),
        'moments': moments.map((m) => m.toJson()).toList(),
        'noAutoStack': noAutoStack.toList(),
        'autoStack': autoStack,
        'dayPlaces': dayPlaces,
        'layout': layout.name,
        if (linkedFolders.isNotEmpty) 'lf': linkedFolders.map((l) => l.toJson()).toList(),
        if (excludedAssets.isNotEmpty) 'xa': excludedAssets.toList(),
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
        stacks: (j['stacks'] as List?)?.map((e) => PhotoStack.fromJson(e as Map<String, dynamic>)).toList(),
        moments: (j['moments'] as List?)?.map((e) => Moment.fromJson(e as Map<String, dynamic>)).toList(),
        noAutoStack: (j['noAutoStack'] as List?)?.cast<String>().toSet(),
        autoStack: j['autoStack'] as bool? ?? true,
        dayPlaces: (j['dayPlaces'] as Map?)?.cast<String, String>(),
        layout: LayoutStyle.values.asNameMap()[j['layout']] ?? LayoutStyle.airy,
        linkedFolders: (j['lf'] as List?)?.map((e) => FolderLink.fromJson(e as Map<String, dynamic>)).toList(),
        excludedAssets: (j['xa'] as List?)?.cast<String>().toSet(),
      );
}

/// A device gallery folder whose photos an album mirrors.
class FolderLink {
  FolderLink({required this.id, required this.name, this.lastSync});
  final String id;
  String name;
  DateTime? lastSync;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (lastSync != null) 'sync': lastSync!.toIso8601String(),
      };

  factory FolderLink.fromJson(Map<String, dynamic> j) => FolderLink(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        lastSync: j['sync'] == null ? null : DateTime.parse(j['sync'] as String),
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
