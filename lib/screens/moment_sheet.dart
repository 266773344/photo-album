import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../models/models.dart';

/// What the user chose in the moment sheet.
sealed class MomentChoice {}

class NewMoment extends MomentChoice {
  NewMoment(this.title, this.note);
  final String title;
  final String note;
}

class ExistingMoment extends MomentChoice {
  ExistingMoment(this.moment);
  final Moment moment;
}

/// Asks for a title and note for a new moment, or (if [existing] is given)
/// edits that moment. When creating, existing moments of the album are
/// offered as targets too, so photos can be added to them.
Future<MomentChoice?> showMomentSheet(
  BuildContext context, {
  required AlbumEvent event,
  Moment? existing,
  int photoCount = 0,
}) {
  return showModalBottomSheet<MomentChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _MomentSheet(event: event, existing: existing, photoCount: photoCount),
  );
}

class _MomentSheet extends StatefulWidget {
  const _MomentSheet({required this.event, this.existing, required this.photoCount});
  final AlbumEvent event;
  final Moment? existing;
  final int photoCount;

  @override
  State<_MomentSheet> createState() => _MomentSheetState();
}

class _MomentSheetState extends State<_MomentSheet> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _note = TextEditingController(text: widget.existing?.note);
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, NewMoment(_title.text.trim(), _note.text.trim()));
  }

  String _describe(Moment m) {
    final photos = widget.event.photos.where((p) => m.photoIds.contains(p.id)).toList();
    if (photos.isEmpty) return '';
    return '${DateFormat('EEE d MMM, HH:mm').format(photos.first.takenAt)} · ${photos.length} photos';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final editing = widget.existing != null;
    final others = editing ? const <Moment>[] : widget.event.moments;
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
                  'Give ${widget.photoCount == 1 ? 'this photo' : 'these ${widget.photoCount} photos'} their own '
                  'little chapter within the day, like “Breakfast at Café Lua”.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
                autofocus: true,
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
