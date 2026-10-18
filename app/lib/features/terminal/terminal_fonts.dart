import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/tokens.dart';
import '../settings/settings_providers.dart';
import 'font_files.dart';

/// The font the terminal draws with.
@immutable
class TerminalFont {
  const TerminalFont({
    this.family = PromptlyTokens.monoFamily,
    this.ligatures = false,
    this.symbols = symbolFamilies,
    this.revision = 0,
  });

  final String family;

  /// Join pairs such as `->` and `!=` into one symbol, where the font has
  /// such ligatures.
  final bool ligatures;

  /// Fonts of Nerd Font symbols, for the icons prompts and editors draw
  /// that the font itself lacks. Ones that are not there are skipped.
  final List<String> symbols;

  /// Goes up when a font has been loaded from its files, so text is
  /// measured again with it.
  final int revision;

  /// The symbols-only Nerd Font, when it is installed.
  static const symbolFamilies = ['Symbols Nerd Font Mono', 'Symbols Nerd Font'];

  static const standard = TerminalFont();

  /// Where characters the font lacks come from: the built-in font, the
  /// symbols, emoji, then a monospaced font the system has.
  List<String> get fallback => [
    if (family != PromptlyTokens.monoFamily) PromptlyTokens.monoFamily,
    ...symbols,
    'Noto Color Emoji',
    'DejaVu Sans Mono',
    'Noto Sans Mono',
    'monospace',
  ];

  @override
  bool operator ==(Object other) =>
      other is TerminalFont &&
      other.family == family &&
      other.ligatures == ligatures &&
      other.revision == revision &&
      listEquals(other.symbols, symbols);

  @override
  int get hashCode => Object.hash(family, ligatures, revision, Object.hashAll(symbols));
}

/// The fonts the terminal can use besides the built-in one: font files the
/// person added, kept in the app's data folder, and the monospaced fonts
/// installed on the device. Swapped for a fake in tests.
abstract class FontLibrary {
  /// Fonts the person added.
  Future<List<FontFamilyFiles>> added();

  /// Monospaced fonts installed on this device. Empty where apps cannot
  /// see them (iPhone and iPad).
  Future<List<FontFamilyFiles>> installed();

  /// Whether an installed font can be used by its name alone, as on
  /// computers. Where it cannot (Android), its files are loaded.
  bool get installedByName;

  /// Keep a copy of a font file and return its family. Throws a
  /// [FormatException] for a file that is not a font.
  Future<String> add(String name, Uint8List bytes);

  /// Delete the copies of an added family's files.
  Future<void> remove(FontFamilyFiles font);

  /// Make a family usable by name. True when its files had to be loaded,
  /// so text should be measured again.
  Future<bool> load(FontFamilyFiles font);
}

class DeviceFontLibrary implements FontLibrary {
  /// Families loaded this run. The text engine keeps them until the app
  /// quits, so each is loaded once.
  static final Set<String> _loaded = {};

  /// The installed fonts, looked for once per run.
  static Future<List<FontFamilyFiles>>? _installed;

  Future<Directory> _folder() async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}fonts');

  Future<List<String>> _files() async {
    final dir = await _folder();
    if (!await dir.exists()) return const [];
    return [
      await for (final entry in dir.list())
        if (entry is File && isFontFileName(entry.path)) entry.path,
    ];
  }

  @override
  Future<List<FontFamilyFiles>> added() async {
    try {
      return groupFamilies((await _files()).map(parseFontFile).nonNulls, added: true);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<FontFamilyFiles>> installed() {
    if (kIsWeb || Platform.isIOS) return Future.value(const []);
    return _installed ??= () async {
      final folders = systemFontFolders();
      try {
        final found = await Isolate.run(() => scanMonospacedFonts(folders));
        return [for (final f in found) if (f.family != PromptlyTokens.monoFamily) f];
      } catch (_) {
        return const <FontFamilyFiles>[];
      }
    }();
  }

  @override
  bool get installedByName => !Platform.isAndroid;

  @override
  Future<String> add(String name, Uint8List bytes) async {
    final face = parseFontBytes(bytes, name);
    if (face == null) throw const FormatException('not a font');
    final dir = await _folder();
    await dir.create(recursive: true);
    // Only the file's own name, so it lands in the folder whatever it says.
    final base = name.split(RegExp(r'[/\\]')).last;
    var file = File('${dir.path}${Platform.pathSeparator}$base');
    for (var n = 2; await file.exists(); n++) {
      file = File('${dir.path}${Platform.pathSeparator}$n-$base');
    }
    await file.writeAsBytes(bytes, flush: true);
    return face.family;
  }

  @override
  Future<void> remove(FontFamilyFiles font) async {
    for (final path in await _files()) {
      if (parseFontFile(path)?.family == font.family) await File(path).delete();
    }
  }

  @override
  Future<bool> load(FontFamilyFiles font) async {
    // By family and files, so a face added to a family already loaded,
    // such as its bold, is loaded too.
    final key = [font.family, ...font.paths].join('\n');
    if (_loaded.contains(key) || (!font.added && installedByName)) return false;
    _loaded.add(key);
    try {
      final loader = FontLoader(font.family);
      for (final path in font.paths) {
        loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
      }
      await loader.load();
      return true;
    } catch (_) {
      _loaded.remove(key);
      return false;
    }
  }
}

final fontLibraryProvider = Provider<FontLibrary>((ref) => DeviceFontLibrary());

/// Fonts the person added; invalidated when one is added or removed.
final addedFontsProvider = FutureProvider<List<FontFamilyFiles>>((ref) => ref.watch(fontLibraryProvider).added());

/// Monospaced fonts installed on the device.
final installedFontsProvider = FutureProvider<List<FontFamilyFiles>>(
  (ref) => ref.watch(fontLibraryProvider).installed(),
);

/// The terminal font as Settings has it. Known at once, so sessions never
/// wait for it; a font that has to be loaded from its files first (one the
/// person added, or any on Android) follows a moment later, as do the
/// symbols of any Nerd Font the person added.
class TerminalFontNotifier extends Notifier<TerminalFont> {
  @override
  TerminalFont build() {
    final family = ref.watch(fontFamilyProvider);
    final ligatures = ref.watch(ligaturesProvider);
    final added = ref.watch(addedFontsProvider).value ?? const <FontFamilyFiles>[];
    final symbols = [for (final f in added) if (f.hasSymbols && f.family != family) f];
    unawaited(_load(family, added, symbols));
    return TerminalFont(
      family: family.isEmpty ? PromptlyTokens.monoFamily : family,
      ligatures: ligatures,
      symbols: [for (final f in symbols) f.family, ...TerminalFont.symbolFamilies],
    );
  }

  Future<void> _load(String family, List<FontFamilyFiles> added, List<FontFamilyFiles> symbols) async {
    try {
      final library = ref.read(fontLibraryProvider);
      var loaded = false;
      for (final f in symbols) {
        loaded |= await library.load(f);
      }
      if (family.isNotEmpty) {
        var chosen = added.where((f) => f.family == family).firstOrNull;
        if (chosen == null && !library.installedByName && ref.mounted) {
          chosen = (await ref.read(installedFontsProvider.future)).where((f) => f.family == family).firstOrNull;
        }
        if (chosen != null) loaded |= await library.load(chosen);
      }
      if (loaded && ref.mounted) {
        final s = state;
        state = TerminalFont(family: s.family, ligatures: s.ligatures, symbols: s.symbols, revision: s.revision + 1);
      }
    } catch (_) {
      // The font stays as named; text falls back to the built-in font.
    }
  }
}

final terminalFontProvider = NotifierProvider<TerminalFontNotifier, TerminalFont>(TerminalFontNotifier.new);
