import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:photo_album/data/album_repository.dart';
import 'package:photo_album/data/storage/storage.dart';
import 'package:photo_album/main.dart';
import 'package:photo_album/models/models.dart';
import 'package:photo_album/screens/event_screen.dart';
import 'package:photo_album/screens/photo_viewer.dart';

void main() {
  testWidgets('tapping beside the photo closes the viewer; on the photo it toggles the details', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final repo = AlbumRepository(MemoryStorage(), useDeviceGallery: false);
    await tester.runAsync(repo.load);
    repo.settings = repo.settings.copyWith(onlineLookups: false);
    final e = (await tester.runAsync(() => repo.createEvent(title: 'Lisbon')))!;
    final p = Photo(
      id: 'a',
      width: 4,
      height: 3,
      takenAt: DateTime(2024, 8, 1, 9),
      palette: const [],
      caption: 'Tram 28',
    );
    e.photos.add(p);
    await tester.pumpWidget(PhotoAlbumApp(repo: repo));
    await tester.pumpAndSettle();

    openPhotoViewer(tester.element(find.text('Lisbon')), e, p);
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(find.text('Tram 28'), findsOneWidget);

    // On the photo (centre of a landscape photo): details hide, viewer stays.
    final screen = tester.getSize(find.byType(PhotoViewer));
    await tester.tapAt(screen.center(Offset.zero));
    await tester.pump(const Duration(milliseconds: 400)); // past the double-tap window
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(find.text('Tram 28'), findsNothing);

    // Below the photo, on the black background: closes.
    await tester.tapAt(Offset(screen.width / 2, screen.height * 0.8));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
  });
}
