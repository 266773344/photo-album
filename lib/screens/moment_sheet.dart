import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'place_picker.dart';

/// What the user chose in the moment sheet.
sealed class MomentChoice {}

class NewMoment extends MomentChoice {
  NewMoment(this.title, this.note, this.place);
  final String title;
  final String note;
  final GeoPlace? place;
}

class ExistingMoment extends MomentChoice {
  ExistingMoment(this.moment);
  final Moment moment;
}

/// Asks for a title, note and place for a new moment, or (if [existing] is
/// given) edits that moment. When creating, existing moments of the album are
/// offered as targets too, so photos can be added to them.
Future<MomentChoice?> showMomentSheet(
  BuildContext context, {
  required AlbumEvent event,
  Moment? existing,
  List<Photo> photos = const [],
}) {
  return showModalBottomSheet<MomentChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _MomentSheet(event: event, existing: existing, photos: photos),
  );
}

/// Median position of the photos that have one.
LatLng? photosCenter(Iterable<Photo> photos) {
  final located = photos.where((p) => p.hasLocation).toList();
  if (located.isEmpty) return null;
  final lats = located.map((p) => p.lat!).toList()..sort();
  final lngs = located.map((p) => p.lng!).toList()..sort();
  return LatLng(lats[lats.length ~/ 2], lngs[lngs.length ~/ 2]);
}

class _MomentSheet extends StatefulWidget {
  const _MomentSheet({required this.event, this.existing, required this.photos});
  final AlbumEvent event;
  final Moment? existing;
  final List<Photo> photos;

  @override
  State<_MomentSheet> createState() => _MomentSheetState();
}

class _MomentSheetState extends State<_MomentSheet> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _note = TextEditingController(text: widget.existing?.note);
  final _form = GlobalKey<FormState>();
  late GeoPlace? _place = widget.existing?.place;
  bool _suggested = false;
  bool _looking = false;

  List<Photo> get _photos => widget.existing == null
      ? widget.photos
      : widget.event.photos.where((p) => widget.existing!.photoIds.contains(p.id)).toList();

  @override
  void initState() {
    super.initState();
    if (_place == null) WidgetsBinding.instance.addPostFrameCallback((_) => _suggest());
  }

  /// Proposes the place where the photos were taken (café, museum, …).
  Future<void> _suggest() async {
    final center = photosCenter(_photos);
    if (!mounted) return;
    final repo = AlbumScope.read(context);
    if (center == null || !repo.settings.onlineLookups) return;
    setState(() => _looking = true);
    try {
      final place = await repo.geocoder.reverse(center.latitude, center.longitude);
      if (mounted && place != null && _place == null) {
        setState(() {
          _place = place;
          _suggested = true;
        });
      }
    } catch (_) {
      // Offline: no suggestion.
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Future<void> _choosePlace() async {
    final center = photosCenter(_photos) ?? photosCenter(widget.event.photos);
    final picked = await pickPlace(context, title: 'Place of this moment', initial: _place, near: center);
    if (picked != null && mounted) {
      setState(() {
        _place = picked;
        _suggested = false;
      });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, NewMoment(_title.text.trim(), _note.text.trim(), _place));
  }

  String _describe(Moment m) {
    final photos = widget.event.photos.where((p) => m.photoIds.contains(p.id)).toList();
    if (photos.isEmpty) return '';
    return '${DateFormat('EEE d MMM, HH:mm').format(photos.first.takenAt)} · ${photos.length} photos';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final editing = widget.existing != null;
    final others = editing ? const <Moment>[] : widget.event.moments;
    final n = widget.photos.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(editing ? 'Edit moment' : 'New moment', style: t.textTheme.headlineSmall),
              if (!editing) ...[
                const SizedBox(height: 4),
                Text(
                  'Give ${n == 1 ? 'this photo' : 'these $n photos'} their own little chapter within the day, '
                  'like “Breakfast at Café Lua”.',
                  style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
                autofocus: !editing,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a title' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Material(
                color: s.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  leading: Icon(_place == null ? Icons.add_location_alt_outlined : Icons.place, color: s.primary),
                  title: Text(_place?.name ?? (_looking ? 'Finding the place…' : 'Add a place (optional)')),
                  subtitle: _place == null
                      ? null
                      : Text(
                          [if (_suggested) 'Suggested from photo location', if (_place!.address.isNotEmpty) _place!.address].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: _place == null
                      ? null
                      : IconButton(
                          tooltip: 'Remove place',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _place = null;
                            _suggested = false;
                          }),
                        ),
                  onTap: _choosePlace,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _submit, child: Text(editing ? 'Save' : 'Create moment')),
              if (others.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Or add to an existing moment', style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final m in others)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bookmark_add_outlined),
                    title: Text(m.title),
                    subtitle: Text(_describe(m)),
                    onTap: () => Navigator.pop(context, ExistingMoment(m)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
