import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'moment_sheet.dart' show photosCenter;
import 'place_picker.dart';

class EventDetails {
  EventDetails(this.title, this.location, this.description, {this.locationManual = false});
  final String title;

  /// The album's place; empty with [locationManual] false = automatic.
  final String location;
  final bool locationManual;
  final String description;
}

/// Bottom sheet for creating or editing an album's title, place and story.
Future<EventDetails?> showEventEditor(BuildContext context, {AlbumEvent? existing}) {
  return showModalBottomSheet<EventDetails>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => _EventEditor(existing: existing),
  );
}

class _EventEditor extends StatefulWidget {
  const _EventEditor({this.existing});
  final AlbumEvent? existing;

  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _description = TextEditingController(text: widget.existing?.description);
  final _formKey = GlobalKey<FormState>();

  /// Manually chosen place, or null = automatic from the photos.
  late String? _manualPlace = widget.existing?.locationManual ?? false ? widget.existing!.location : null;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final manual = _manualPlace;
    Navigator.pop(
      context,
      EventDetails(
        _title.text.trim(),
        manual ?? (widget.existing?.locationManual == false ? widget.existing!.location : ''),
        _description.text.trim(),
        locationManual: manual != null,
      ),
    );
  }

  Future<void> _choosePlace() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Automatic'),
              subtitle: const Text('The towns where the photos were taken'),
              trailing: _manualPlace == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, 'auto'),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Choose on the map'),
              onTap: () => Navigator.pop(context, 'map'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Type a name'),
              onTap: () => Navigator.pop(context, 'type'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'auto':
        setState(() => _manualPlace = null);
      case 'map':
        final e = widget.existing;
        final place = await pickPlace(
          context,
          title: 'Where was this album?',
          near: e == null ? null : photosCenter(e.photos),
        );
        if (place != null && mounted) setState(() => _manualPlace = place.name);
      case 'type':
        final text = await editTextDialog(
          context,
          title: 'Album place',
          initial: _manualPlace ?? widget.existing?.location ?? '',
          hint: 'e.g. Portugal',
          multiline: false,
        );
        if (text != null && text.isNotEmpty && mounted) setState(() => _manualPlace = text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final s = Theme.of(context).colorScheme;
    final auto = widget.existing?.locationManual == false ? widget.existing!.location : '';
    final String placeText;
    final String placeHint;
    if (_manualPlace != null) {
      placeText = _manualPlace!;
      placeHint = 'Chosen by you · tap to change';
    } else if (auto.isNotEmpty) {
      placeText = auto;
      placeHint = 'Automatic from the photos · tap to change';
    } else {
      placeText = 'Place';
      placeHint = 'Filled in automatically from the photos · tap to choose';
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(isNew ? 'New album' : 'Edit album', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
                autofocus: isNew,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'e.g. Summer in Portugal',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a title' : null,
              ),
              const SizedBox(height: 12),
              Material(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                  side: BorderSide(color: s.outline),
                ),
                child: ListTile(
                  leading: Icon(_manualPlace == null ? Icons.auto_awesome_outlined : Icons.place_outlined),
                  title: Text(placeText),
                  subtitle: Text(placeHint),
                  onTap: _choosePlace,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 3,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Story (optional)',
                  hintText: 'What made this trip special?',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _submit, child: Text(isNew ? 'Create album' : 'Save')),
            ],
          ),
        ),
      ),
    );
  }
}
