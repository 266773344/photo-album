# Photo Album

A Flutter app (Android + web) that turns the photos of a trip or event into a
beautiful album: photos are grouped by day, arranged into dynamic collages, and
each album gets background colours derived from its own photos.

## Features

- **Home screen** with one card per album (cover mosaic, dates, colour swatches).
- **Automatic collages** — `lib/layout/collage_layout.dart` builds each band of
  the collage as a row/column tree, so photos fit with no cropping. Layouts are
  seeded per album (stable between launches); *Shuffle layout* re-rolls them.
- **Photo-matched theming** — dominant colours are extracted on import
  (`lib/theme/palette.dart`); the album's Material 3 colour scheme is seeded from
  them, and every day section gets its own tint so the background shifts as you
  scroll. You can override this with mood presets (Beach, Mountains, City, …),
  a custom colour, and light/dark mode.
- **Grouped by day** using the EXIF capture date (falls back to file date).
- **Similar-photo carousels** — bursts and near-duplicates (perceptual dHash +
  palette check, only among photos taken within ~2 minutes) are combined into one
  swipeable collage cell showing the sharpest shot first
  (`lib/data/similarity.dart`). Toggle per album via *Group similar photos*.
- **Selection mode** — long-press a photo, tap more, then: *Moment*, *Carousel*,
  *Remove*, or (⋯) caption / cover / ungroup / take out of moment.
- **Moments** — optional titled chapters within a day ("Breakfast at Café Lua")
  with a note, shown as a tinted card where their first photo falls in the
  timeline. Photos don't have to belong to one (`lib/models/grouping.dart`).
- **Maps** — GPS from EXIF (or set by hand via selection → ⋯ → *Set location*)
  feeds a route map on the album page, a full-screen map with photo markers,
  and town names next to each day (OpenStreetMap / Nominatim, `lib/services/geocoding.dart`).
- **Places & AI descriptions** — moments can have a place (suggested from the
  photos' GPS, searched by name, tapped on the map, or pasted as a Google Maps
  link). With an Anthropic API key in Settings, Claude searches the web and writes
  a 2–3 sentence description of the place (`lib/services/place_story.dart`).
- **Airy / Compact layout** per album (theme sheet). Carousels turn automatically
  and show differently shaped photos whole on a blurred fill.
- **Captions & notes** — album title/location/story, a note per day, and a
  caption per photo (long-press a photo).
- **Fullscreen viewer** — swipe between photos, pinch or double-tap to zoom.
- **Photos stay where they are (Android)** — an in-app gallery picker
  (`lib/screens/gallery_picker.dart`, grouped by day, opens on the album's dates)
  adds photos *by reference*: the app stores only a small preview (~250 KB) plus
  its own data, and loads originals from the gallery (`lib/services/gallery.dart`).
  Reading the gallery directly also keeps the photos' GPS data.
- **Linked folders** — "Add a whole folder" links a gallery folder to an album;
  new photos in it are added when the album opens, deleted ones removed
  (album menu → *Linked folders* to sync or unlink).
- **Local storage** — album data and previews in the app directory on Android,
  IndexedDB in the browser (where picked photos are copied, since a web page
  can't keep references to files).

Android permissions: `READ_MEDIA_IMAGES` (or "selected photos only" on
Android 14+) and `ACCESS_MEDIA_LOCATION` for GPS. Removing photos from an album
never deletes them from the phone.

## Running

The Flutter SDK is at `D:\Programmierung\flutter` (add `D:\Programmierung\flutter\bin` to `PATH`).

```sh
flutter run -d chrome          # in the browser
flutter run -d <android-device> # needs Android Studio / Android SDK installed
flutter build apk --release     # Android APK
flutter build web --release     # static site in build/web
flutter test
```

### Installing on your own phone

1. Install [Android Studio](https://developer.android.com/studio) once (it brings
   the Android SDK and Java), open it and finish the setup wizard.
2. `flutter doctor --android-licenses` (accept all), then `flutter doctor` should
   show the Android toolchain as ✓.
3. `flutter build apk --release --split-per-abi` →
   `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk` (modern phones).
4. Either connect the phone by USB (Developer options → USB debugging) and run
   `flutter install`, or copy the APK to the phone, open it and allow
   "Install unknown apps" for your file manager.

The release build is signed with this PC's debug key
(`%USERPROFILE%\.android\debug.keystore`). Updates must use the same key, so
keep that file. Uninstalling the app deletes its albums.

## Structure

```
lib/
  main.dart                  app entry, home theme
  models/models.dart         AlbumEvent, Photo, theme settings, day grouping
  data/album_repository.dart state + persistence + photo import
  data/photo_processor.dart  decode, thumbnail, palette, EXIF date
  data/storage/              file storage (Android) / IndexedDB (web)
  layout/collage_layout.dart collage engine
  theme/                     palette extraction, presets, EventStyle
  screens/                   home, album, viewer, theme picker, editors
  widgets/                   collage rendering, image provider, dialogs
```
