import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/l10n/de.dart';
import 'package:photo_album/l10n/strings.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/services/geocoding.dart';
import 'package:photo_album/services/place_story.dart';
import 'package:photo_album/theme/event_theme.dart';
import 'package:photo_album/widgets/common.dart';

/// Every text passed to tr()/trn() in lib/, as Dart would see it.
Set<String> sourceTexts() {
  const lit = r"'(?:[^'\\]|\\.)*'";
  final re = RegExp(r'\btrn?\(\s*((?:' + lit + r'\s*)+)(?:,\s*((?:' + lit + r'\s*)+))?');
  String unescape(String s) => s.replaceAllMapped(
    RegExp(r'\\(.)'),
    (m) => switch (m[1]) {
      'n' => '\n',
      _ => m[1]!,
    },
  );
  final texts = <String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart') || f.path.contains('l10n')) continue;
    final src = f.readAsStringSync();
    for (final m in re.allMatches(src)) {
      final isTrn = src.startsWith('trn(', m.start);
      for (final g in [m[1], if (isTrn) m[2]]) {
        if (g == null) continue;
        texts.add(RegExp(lit).allMatches(g).map((x) => unescape(x[0]!.substring(1, x[0]!.length - 1))).join());
      }
    }
  }
  return texts;
}

Set<String> placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m[1]!).toSet();

void main() {
  tearDown(() => L10n.apply('en'));

  test('every text in the app has a German translation with the same placeholders', () {
    L10n.apply('en');
    final texts = {
      ...sourceTexts(),
      // Labels that are passed through tr() from data.
      for (final s in PhotoSize.values) s.label,
      for (final m in TravelMode.values) m.label,
      for (final p in themePresets) p.name,
      for (final (_, _, hint) in storyModels) hint,
    };
    expect(texts.length, greaterThan(200));
    final missing = texts.where((t) => !germanTexts.containsKey(t)).toList();
    expect(missing, isEmpty, reason: 'Add these to lib/l10n/de.dart');
    for (final t in texts) {
      expect(placeholders(germanTexts[t]!), placeholders(t), reason: t);
    }
  });

  test('tr, plurals, place lists and dates follow the language', () async {
    await initializeDateFormatting();
    final aug = DateTime(2024, 8, 2), aug5 = DateTime(2024, 8, 5);
    L10n.apply('en');
    expect(trn('{n} photo', '{n} photos', 1), '1 photo');
    expect(trn('{n} photo', '{n} photos', 3), '3 photos');
    expect(joinNames(['Lisboa', 'Sintra']), 'Lisboa & Sintra');
    expect(formatDateRange(aug, aug5), '2–5 Aug 2024');

    expect(L10n.apply('de'), isTrue);
    expect(trn('{n} photo', '{n} photos', 3), '3 Fotos');
    expect(tr('Linked “{name}”', {'name': 'Kamera'}), '„Kamera“ verknüpft');
    expect(joinNames(['Lisboa', 'Sintra', 'Cascais']), 'Lisboa, Sintra und Cascais');
    expect(formatDateRange(aug, aug5), '2.–5. Aug. 2024');
    expect(TravelMode.train.label, 'Zug');
  });

  testWidgets('switching the language in Settings changes the whole app at once', (tester) async {
    await initializeDateFormatting();
    final repo = AlbumRepository(MemoryStorage(), useDeviceGallery: false);
    await tester.runAsync(repo.load);
    repo.settings = repo.settings.copyWith(onlineLookups: false);
    await tester.runAsync(() => repo.createEvent(title: 'Lisbon'));
    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    await tester.pumpAndSettle();
    expect(find.text('My Albums'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch'));
    await tester.pumpAndSettle();
    expect(repo.settings.language, 'de');
    expect(find.text('Sprache'), findsOneWidget); // the open page switched too
    expect(find.text('Orte & Karten'), findsOneWidget);

    // Material's own texts are German as well: the back button says "Zurück".
    await tester.tap(find.byTooltip('Zurück'));
    await tester.pumpAndSettle();
    expect(find.text('Meine Alben'), findsOneWidget);
    expect(find.text('Neues Album'), findsOneWidget);

    // The choice is saved with the settings.
    final copy = AppSettings.fromJson(repo.settings.toJson());
    expect(copy.language, 'de');
  });
  test('place names are looked up in the app language, and again after a switch', () async {
    final languages = <String?>[];
    final repo = AlbumRepository(
      MemoryStorage(),
      useDeviceGallery: false,
      geocoder: Geocoder(
        client: MockClient((req) async {
          final lang = req.url.queryParameters['accept-language'];
          languages.add(lang);
          final n = lang == 'de' ? 'Lissabon' : 'Lisbon';
          return http.Response(
            jsonEncode({
              'name': n,
              'display_name': n,
              'lat': '0',
              'lon': '0',
              'address': {'city': n},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    await repo.load();
    repo.settings = repo.settings.copyWith(realRoutes: false);
    final e = await repo.createEvent(title: 'Portugal');
    e.photos.add(
      Photo(id: 'a', width: 4, height: 3, takenAt: DateTime(2024, 8, 1), palette: const [], lat: 38.71, lng: -9.14),
    );
    await repo.refreshDayPlaces(e);
    expect(e.dayPlaces.values.single, 'Lisbon');
    expect(e.location, 'Lisbon');

    await repo.updateSettings(repo.settings.copyWith(language: 'de'));
    await repo.refreshDayPlaces(e); // (also started by the switch itself)
    expect(e.dayPlaces.values.single, 'Lissabon');
    expect(e.location, 'Lissabon');
    expect(languages, containsAll(['en', 'de']));
    expect(AlbumEvent.fromJson(e.toJson()).placesLanguage, 'de');
  });
}
