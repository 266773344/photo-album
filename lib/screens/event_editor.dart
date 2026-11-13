import 'package:material_ui/material_ui.dart';

import '../models/models.dart';

class EventDetails {
  EventDetails(this.title, this.location, this.description);
  final String title;
  final String location;
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
  late final _location = TextEditingController(text: widget.existing?.location);
  late final _description = TextEditingController(text: widget.existing?.description);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, EventDetails(_title.text.trim(), _location.text.trim(), _description.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
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
              TextFormField(
                controller: _location,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Location (optional)',
                  prefixIcon: Icon(Icons.place_outlined),
                  border: OutlineInputBorder(),
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
