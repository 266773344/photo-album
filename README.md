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
- **Captions & notes** — album title/location/story, a note per day, and a
  caption per photo (long-press a photo).
- **Fullscreen viewer** — swipe between photos, pinch or double-tap to zoom.
- **Local, private storage** — files in the app directory on Android, IndexedDB
  in the browser. Nothing leaves the device.

## Running

The Flutter SDK is at `D:\Programmierung\flutter` (add `D:\Programmierung\flutter\bin` to `PATH`).

```sh
flutter run -d chrome          # in the browser
flutter run -d <android-device> # needs Android Studio / Android SDK installed
flutter build apk --release     # Android APK
flutter build web --release     # static site in build/web
flutter test
```

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
