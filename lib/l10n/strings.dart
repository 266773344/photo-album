import 'dart:ui' show PlatformDispatcher;

import 'package:intl/intl.dart';

import 'de.dart';

/// App language: English (the source texts) and German.
///
/// Texts are looked up by their English wording ([tr]), so the code stays
/// readable and a missing translation shows English instead of failing.
/// `test/l10n_test.dart` checks that every [tr] text has a German version.
class L10n {
  L10n._();

  static const supported = ['en', 'de'];

  /// The language in use ('en' or 'de').
  static String code = 'en';

  static bool get german => code == 'de';

  /// [setting] is the user's choice: 'en', 'de' or 'system' (the phone's
  /// language when supported, otherwise English).
  static String resolve(String setting) {
    if (supported.contains(setting)) return setting;
    final device = PlatformDispatcher.instance.locale.languageCode;
    return supported.contains(device) ? device : 'en';
  }

  /// Switches language; returns whether it changed.
  static bool apply(String setting) {
    final c = resolve(setting);
    Intl.defaultLocale = c == 'de' ? 'de_DE' : 'en_US';
    if (c == code) return false;
    code = c;
    return true;
  }
}

/// The text in the current language. `{name}` placeholders are filled from
/// [args]: `tr('Linked “{name}”', {'name': f.name})`.
String tr(String en, [Map<String, Object?> args = const {}]) {
  var s = L10n.german ? (germanTexts[en] ?? en) : en;
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// Singular/plural: `trn('{n} photo', '{n} photos', count)`.
String trn(String one, String many, int n, [Map<String, Object?> args = const {}]) =>
    tr(n == 1 ? one : many, {'n': n, ...args});

/// "A", "A & B", "A, B & C" (German: "A und B").
String joinNames(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return names.single;
  final and = L10n.german ? ' und ' : ' & ';
  return '${names.sublist(0, names.length - 1).join(', ')}$and${names.last}';
}
