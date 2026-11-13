import 'package:material_ui/material_ui.dart';

import '../services/place_story.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _key = TextEditingController(text: AlbumScope.read(context).settings.apiKey);
  bool _showKey = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = AlbumScope.of(context);
    final s = repo.settings;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('Places & maps', style: t.textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Look up place names online'),
            subtitle: const Text(
              'Uses OpenStreetMap to name the places in your photos and to search for places. '
              'Only coordinates or your search text are sent — never photos. Map tiles always load from OpenStreetMap.',
            ),
            value: s.onlineLookups,
            onChanged: (v) => repo.updateSettings(s.copyWith(onlineLookups: v)),
          ),
          const Divider(height: 32),
          Text('Place descriptions (AI)', style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Moments with a place can get a short description — e.g. the history of the building or what the café is '
            'known for. Claude searches the web and writes it from what it finds. This uses your own Anthropic API key '
            '(console.anthropic.com); each description costs a few cents. Only the place name, address, the moment\'s '
            'title and date are sent.',
            style: muted,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: !_showKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Anthropic API key',
              hintText: 'sk-ant-…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
            onChanged: (v) => repo.updateSettings(s.copyWith(apiKey: v.trim())),
          ),
          const SizedBox(height: 6),
          Text('Stored only on this device, together with your albums.', style: muted),
          const SizedBox(height: 16),
          DropdownMenu<String>(
            initialSelection: s.model,
            label: const Text('Model'),
            expandedInsets: EdgeInsets.zero,
            dropdownMenuEntries: [
              for (final (id, label, hint) in storyModels) DropdownMenuEntry(value: id, label: label, trailingIcon: Text(hint, style: muted)),
            ],
            onSelected: (v) {
              if (v != null) repo.updateSettings(s.copyWith(model: v));
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Write descriptions automatically'),
            subtitle: const Text('As soon as a moment gets a place. Otherwise, tap “About this place” on a moment.'),
            value: s.autoStories,
            onChanged: s.canWriteStories ? (v) => repo.updateSettings(s.copyWith(autoStories: v)) : null,
          ),
        ],
      ),
    );
  }
}
