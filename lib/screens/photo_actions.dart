import 'package:material_ui/material_ui.dart';

import '../models/grouping.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'moment_sheet.dart' show photosCenter;
import 'place_picker.dart';

/// Per-photo actions (used by the fullscreen viewer).
/// Returns true if the photo was deleted.
Future<bool> showPhotoActions(BuildContext context, AlbumEvent e, Photo p) async {
  final stack = e.stackOf(p.id);
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.short_text),
            title: Text(p.caption.isEmpty ? 'Add caption' : 'Edit caption'),
            onTap: () => Navigator.pop(context, 'caption'),
          ),
          ListTile(
            leading: Icon(e.cover?.id == p.id ? Icons.star : Icons.star_outline),
            title: const Text('Use as album cover'),
            enabled: e.cover?.id != p.id,
            onTap: () => Navigator.pop(context, 'cover'),
          ),
          ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: Text(p.hasLocation ? 'Change location' : 'Set location'),
            onTap: () => Navigator.pop(context, 'location'),
          ),
          if (stack != null) ...[
            ListTile(
              leading: const Icon(Icons.first_page),
              title: const Text('Show first in carousel'),
              onTap: () => Navigator.pop(context, 'stackcover'),
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Take out of carousel'),
              onTap: () => Navigator.pop(context, 'unstack'),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove from album'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;
  final repo = AlbumScope.read(context);
  switch (action) {
    case 'caption':
      final text = await editTextDialog(context, title: 'Caption', initial: p.caption, hint: 'Say something about this photo');
      if (text == null) return false;
      p.caption = text;
    case 'cover':
      e.coverPhotoId = p.id;
    case 'location':
      final place = await pickPlace(
        context,
        title: 'Where was this photo taken?',
        initial: p.hasLocation ? GeoPlace(name: 'Current location', lat: p.lat!, lng: p.lng!) : null,
        near: photosCenter(e.photos),
      );
      if (place == null) return false;
      await repo.setPhotoLocation(e, [p.id], place);
      return false;
    case 'stackcover':
      stack!.coverId = p.id;
    case 'unstack':
      e.removeFromStack(p.id);
    case 'delete':
      final ok = await confirmDialog(context, title: 'Remove photo?', message: 'The photo will be removed from this album.', action: 'Remove');
      if (!ok) return false;
      await repo.deletePhoto(e, p);
      return true;
  }
  await repo.changed(e);
  return false;
}
