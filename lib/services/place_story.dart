import 'dart:convert';

import '../l10n/strings.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../models/models.dart';

/// Models offered in settings. The first is the default.
const storyModels = <(String id, String label, String hint)>[
  ('claude-opus-5-5', 'Claude Opus 5.5', 'Best writing and fact-finding'),
  ('claude-sonnet-5-5', 'Claude Sonnet 5.5', 'Faster, about half the price'),
  ('claude-haiku-5-5', 'Claude Haiku 5.5', 'Fastest and cheapest'),
];

class StoryException implements Exception {
  StoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Writes a short, web-grounded flavour text about a place using the Claude
/// API and the user's own API key.
///
/// Claude searches the web (server-side web search tool) and only uses what
/// it finds, so the text is based on real sources rather than invented.
class PlaceStoryWriter {
  PlaceStoryWriter({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  static const _system = '''
You write short flavour texts for a personal travel photo album. Given a place the
traveller visited, search the web for genuinely interesting, verifiable facts about
it: for example the history of the building, who founded it, what it is famous for,
or its signature dish or speciality.

Rules:
- 2 to 3 sentences, at most about 70 words, warm but not gushing.
- Only state facts supported by what you found. If you find nothing reliable about
  this specific place, write about its street or neighbourhood instead, and never
  invent details.
- Plain text only: no markdown, headings, lists, quotation marks around the whole
  text, or source mentions. No preamble - output only the flavour text.''';

  Future<PlaceStory> write({
    required AppSettings settings,
    required GeoPlace place,
    String? momentTitle,
    DateTime? visitedOn,
    String? albumTitle,
  }) async {
    if (!settings.canWriteStories) throw StoryException(tr('Add your Anthropic API key in Settings first.'));
    final model = settings.model;
    final prompt = [
      'Place: ${place.name}',
      if (place.address.isNotEmpty) 'Address: ${place.address}',
      'Coordinates: ${place.lat.toStringAsFixed(5)}, ${place.lng.toStringAsFixed(5)}',
      if (momentTitle != null && momentTitle.isNotEmpty) 'The traveller titled this moment: "$momentTitle"',
      if (albumTitle != null && albumTitle.isNotEmpty) 'Album: "$albumTitle"',
      if (visitedOn != null) 'Visited on: ${DateFormat('d MMMM y', 'en_US').format(visitedOn)}',
      '',
      // The app's language decides the description's language.
      L10n.german ? 'Write the flavour text in German.' : 'Write the flavour text in English.',
    ].join('\n');

    // Haiku uses the basic web search tool; the newer variant with dynamic
    // filtering is supported on Opus/Sonnet.
    final isHaiku = model.startsWith('claude-haiku');
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': 16000,
      'system': _system,
      'output_config': {'effort': 'low'},
      'tools': [
        {'type': isHaiku ? 'web_search_20250305' : 'web_search_20260209', 'name': 'web_search', 'max_uses': 3},
      ],
      // If a safety classifier declines, let the API retry on a suitable model.
      if (!isHaiku) 'fallbacks': 'default',
    };
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': prompt},
    ];

    Map<String, dynamic> response;
    var continuations = 0;
    while (true) {
      response = await _send({...body, 'messages': messages}, settings.apiKey.trim(), fallback: !isHaiku);
      final stop = response['stop_reason'];
      if (stop == 'pause_turn' && continuations < 3) {
        // The server-side search loop paused; resend so it can resume.
        continuations++;
        if (messages.length == 2) messages.removeLast();
        messages.add({'role': 'assistant', 'content': response['content']});
        continue;
      }
      if (stop == 'refusal') throw StoryException(tr('Claude declined to write about this place.'));
      break;
    }
    final story = parseStoryResponse(response);
    if (story.text.isEmpty) throw StoryException(tr('No description came back. Try again later.'));
    return story;
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> body, String apiKey, {required bool fallback}) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            _endpoint,
            headers: {
              'content-type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2026-10-21',
              if (fallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
              // Required for calls straight from a browser (the key is the user's own).
              if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 2));
    } catch (e) {
      throw StoryException(tr('Could not reach the Claude API. Check your connection.'));
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return json;
    final apiMessage = (json['error'] as Map?)?['message'] as String?;
    throw StoryException(switch (res.statusCode) {
      401 => tr('The API key was rejected. Check it in Settings.'),
      403 => tr('This API key is not allowed to use this model or web search.'),
      429 => tr('Rate limit reached. Try again in a minute.'),
      529 || 503 => tr('Claude is busy right now. Try again shortly.'),
      _ => apiMessage ?? tr('Claude API error {code}.', {'code': res.statusCode}),
    });
  }
}

/// Extracts the final text and cited sources from a Messages API response.
///
/// With web search, the response interleaves `server_tool_use`,
/// `web_search_tool_result` and `text` blocks; any text before the last
/// search result is the model talking to itself ("Let me search…"), so only
/// text after it is kept. Cited text blocks carry `citations` with URLs.
@visibleForTesting
PlaceStory parseStoryResponse(Map<String, dynamic> response) {
  final blocks = (response['content'] as List).cast<Map<String, dynamic>>();
  final lastResult = blocks.lastIndexWhere((b) => b['type'] == 'web_search_tool_result');
  final buffer = StringBuffer();
  final sources = <String>[];
  for (final b in blocks.skip(lastResult + 1)) {
    if (b['type'] != 'text') continue;
    buffer.write(b['text'] as String? ?? '');
    for (final c in (b['citations'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final url = c['url'] as String?;
      if (url != null && !sources.contains(url)) sources.add(url);
    }
  }
  final text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return PlaceStory(text: text, sources: sources.take(4).toList(), createdAt: DateTime.now());
}
