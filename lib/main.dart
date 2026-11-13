import 'package:material_ui/material_ui.dart';

import 'data/album_repository.dart';
import 'data/storage/storage.dart';
import 'screens/home_screen.dart';
import 'widgets/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = AlbumRepository(AppStorage.create());
  repo.load();
  runApp(PhotoAlbumApp(repo: repo));
}

class PhotoAlbumApp extends StatelessWidget {
  const PhotoAlbumApp({super.key, required this.repo});
  final AlbumRepository repo;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF8A6F5A); // warm neutral for the home screen
    return AlbumScope(
      repo: repo,
      child: MaterialApp(
        title: 'Photo Album',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
        darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)),
        home: const HomeScreen(),
      ),
    );
  }
}
