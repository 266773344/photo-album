import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';

import 'data/album_repository.dart';
import 'data/storage/storage.dart';
import 'l10n/strings.dart';
import 'screens/home_screen.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting(); // German month and weekday names
  final repo = AlbumRepository(AppStorage.create());
  repo.load();
  runApp(PhotoAlbumApp(repo: repo));
}

class PhotoAlbumApp extends StatefulWidget {
  const PhotoAlbumApp({super.key, required this.repo});
  final AlbumRepository repo;

  @override
  State<PhotoAlbumApp> createState() => _PhotoAlbumAppState();
}

class _PhotoAlbumAppState extends State<PhotoAlbumApp> {
  late String _language = L10n.code;

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_onRepo);
  }

  @override
  void dispose() {
    widget.repo.removeListener(_onRepo);
    super.dispose();
  }

  void _onRepo() {
    if (L10n.code == _language) return;
    setState(() => _language = L10n.code);
    // Texts are looked up while building, so rebuild every screen (keeping
    // their state and the open pages) to show the new language.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void rebuild(Element e) {
        e.markNeedsBuild();
        e.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    });
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF8A6F5A); // warm neutral for the home screen
    return AlbumScope(
      repo: widget.repo,
      child: MaterialApp(
        title: 'Photo Album',
        debugShowCheckedModeBanner: false,
        locale: Locale(_language),
        supportedLocales: [for (final c in L10n.supported) Locale(c)],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
