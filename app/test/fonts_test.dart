import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/file_picker.dart';
import 'package:promptly/core/platform.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/settings/fonts_screen.dart';
import 'package:promptly/features/settings/settings_screen.dart' show TerminalChoices, TextChoices;
import 'package:promptly/features/terminal/font_files.dart';
import 'package:promptly/features/terminal/terminal_fonts.dart';

import 'widget_test.dart' show FakeEngine, FakeFontLibrary;

/// A font file with only the tables Promptly reads: its name, whether it
/// is fixed-pitch, and its weight and slant. `base` is where the font
/// starts in the file, for one inside a collection.
Uint8List fontBytes(String family, {int weight = 400, bool italic = false, bool fixedPitch = true, int base = 0}) {
  final name = [for (final c in family.codeUnits) ...[c >> 8, c & 0xFF]];
  final nameTable = ByteData(6 + 12 + name.length)
    ..setUint16(2, 1) // one record
    ..setUint16(4, 18) // strings start after it
    ..setUint16(6, 3) // Windows
    ..setUint16(8, 1) // Unicode
    ..setUint16(10, 0x409) // US English
    ..setUint16(12, 1) // the family name
    ..setUint16(14, name.length);
  final nameBytes = nameTable.buffer.asUint8List()..setRange(18, 18 + name.length, name);
  final post = ByteData(32)..setUint32(12, fixedPitch ? 1 : 0);
  final os2 = ByteData(78)
    ..setUint16(4, weight)
    ..setUint16(62, italic ? 1 : 0);
  final tables = {'OS/2': os2.buffer.asUint8List(), 'name': nameBytes, 'post': post.buffer.asUint8List()};

  final header = ByteData(12 + 16 * tables.length)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, tables.length);
  final body = BytesBuilder();
  var offset = base + header.lengthInBytes;
  for (final (i, MapEntry(key: tag, value: data)) in tables.entries.indexed) {
    final at = 12 + i * 16;
    for (var j = 0; j < 4; j++) {
      header.setUint8(at + j, tag.codeUnitAt(j));
    }
    header
      ..setUint32(at + 8, offset)
      ..setUint32(at + 12, data.length);
    body.add(data);
    offset += data.length;
  }
  return Uint8List.fromList([...header.buffer.asUint8List(), ...body.toBytes()]);
}

/// A font collection holding one font.
Uint8List collectionBytes(String family) {
  final header = ByteData(16)
    ..setUint32(0, 0x74746366) // 'ttcf'
    ..setUint32(4, 0x00010000)
    ..setUint32(8, 1)
    ..setUint32(12, 16);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...fontBytes(family, base: 16)]);
}

void main() {
  group('font files', () {
    test('a font says its family, weight, slant and whether it is monospaced', () {
      final face = parseFontBytes(fontBytes('Iosevka Term', weight: 700, italic: true), 'iosevka.ttf')!;
      expect(face.family, 'Iosevka Term');
      expect(face.weight, 700);
      expect(face.italic, isTrue);
      expect(face.monospaced, isTrue);
      expect(parseFontBytes(fontBytes('Inter', fixedPitch: false), 'inter.ttf')!.monospaced, isFalse);
      expect(parseFontBytes(collectionBytes('Menlo'), 'Menlo.ttc')!.family, 'Menlo', reason: 'the first in a collection');
    });

    test('anything else is not a font', () {
      expect(parseFontBytes(Uint8List.fromList('hello, world'.codeUnits), 'notes.ttf'), isNull);
      expect(parseFontBytes(Uint8List(0), 'empty.ttf'), isNull);
      final cut = fontBytes('Cut Short');
      expect(parseFontBytes(Uint8List.sublistView(cut, 0, 40), 'cut.ttf'), isNull);
    });

    test('a family keeps the faces the terminal draws with', () {
      FontFace face(String path, int weight, {bool italic = false}) =>
          FontFace(family: 'Code', path: path, weight: weight, italic: italic, monospaced: true);
      final families = groupFamilies([
        face('Light', 300),
        face('Regular', 400),
        face('SemiBold', 600),
        face('Bold', 700),
        face('Italic', 400, italic: true),
        const FontFace(family: 'another', path: 'Other', monospaced: true),
      ]);
      expect(families.map((f) => f.family), ['another', 'Code'], reason: 'by name, whatever the case');
      expect(families.last.paths, ['Regular', 'Bold', 'Italic']);
      expect(const FontFamilyFiles(family: 'Hack Nerd Font Mono', paths: []).hasSymbols, isTrue);
      expect(const FontFamilyFiles(family: 'Symbols Nerd Font', paths: []).hasSymbols, isTrue);
      expect(const FontFamilyFiles(family: 'Fira Code', paths: []).hasSymbols, isFalse);
    });

    test('characters a font lacks come from the built-in font, then the Nerd Font symbols', () {
      expect(TerminalFont.standard.fallback.first, 'Symbols Nerd Font Mono');
      expect(TerminalFont.standard.fallback, isNot(contains('JetBrains Mono')));
      const chosen = TerminalFont(family: 'Fira Code', symbols: ['Hack Nerd Font', ...TerminalFont.symbolFamilies]);
      expect(chosen.fallback.take(3), ['JetBrains Mono', 'Hack Nerd Font', 'Symbols Nerd Font Mono']);
    });
    testWidgets('a face added to a family already loaded is loaded too', (tester) async {
      await tester.runAsync(() async {
        final library = DeviceFontLibrary();
        const regular = FontFamilyFiles(
          family: 'Load Test Mono',
          paths: ['assets/fonts/JetBrainsMono-Regular.ttf'],
          added: true,
        );
        const withBold = FontFamilyFiles(
          family: 'Load Test Mono',
          paths: ['assets/fonts/JetBrainsMono-Regular.ttf', 'assets/fonts/JetBrainsMono-Bold.ttf'],
          added: true,
        );
        expect(await library.load(regular), isTrue);
        expect(await library.load(regular), isFalse, reason: 'already loaded');
        expect(await library.load(withBold), isTrue, reason: 'the bold face is new');
        expect(await library.load(withBold), isFalse);
      });
    });

    test('the picker on iOS offers files in a way iOS accepts', () {
      // file_selector_ios goes through the groups in order and, before the
      // picker opens, refuses one that neither allows every file nor names
      // type identifiers.
      bool iosAccepts(List<XTypeGroup> groups) {
        for (final g in groups) {
          if (g.allowsAny) return true;
          if (g.uniformTypeIdentifiers?.isEmpty ?? true) return false;
        }
        return true;
      }

      expect(iosAccepts(pickerTypeGroups('Font files', const ['ttf', 'otf'], ios: true)), isTrue);
      expect(iosAccepts(pickerTypeGroups('Font files', const ['ttf', 'otf'], ios: false)), isFalse);
      expect(pickerTypeGroups('Font files', const ['ttf', 'otf'], ios: false).first.extensions, ['ttf', 'otf']);
    });
  });

  group('font settings', () {
    late FakeEngine engine;
    late FakeFontLibrary fonts;
    late ProviderContainer container;
    PickedBinaryFile? picked;
    Object? pickError;

    Future<void> show(WidgetTester tester, Widget child) async {
      engine = FakeEngine();
      pickError = null;
      fonts = FakeFontLibrary();
      // A fresh start, with nothing kept from a screen shown before.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            engineProvider.overrideWithValue(engine),
            fontLibraryProvider.overrideWithValue(fonts),
            binaryFilePickerProvider.overrideWithValue(
              ({required String label, required List<String> extensions}) async {
                if (pickError != null) throw pickError!;
                return picked;
              },
            ),
          ],
          child: MaterialApp(
            theme: buildPromptlyTheme(Brightness.dark),
            home: Scaffold(body: child),
          ),
        ),
      );
      await tester.pumpAndSettle();
      container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    testWidgets('picking a font from the device changes the terminal font', (tester) async {
      await show(tester, const FontsScreen());
      expect(find.text('JetBrains Mono'), findsOneWidget);
      expect(find.text('Ubuntu Mono'), findsOneWidget);
      expect(container.read(terminalFontProvider).family, 'JetBrains Mono');

      await tester.tap(find.text('Fira Code'));
      await tester.pumpAndSettle();
      expect(engine.settings['terminal_font'], '"Fira Code"');
      expect(container.read(terminalFontProvider).family, 'Fira Code');
      final selected = tester.widget<ListTile>(find.byKey(const Key('font-Fira Code')));
      expect(selected.selected, isTrue);
      expect(fonts.loaded, isEmpty, reason: 'an installed font is used by its name');

      await tester.tap(find.text('JetBrains Mono'));
      await tester.pumpAndSettle();
      expect(engine.settings['terminal_font'], '""');
      expect(container.read(terminalFontProvider), TerminalFont.standard);
    });

    testWidgets('a picker that fails to open says so', (tester) async {
      await show(tester, const FontsScreen());
      pickError = ArgumentError('no type identifiers');
      await tester.tap(find.byKey(const Key('font-add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not open the file picker'), findsOneWidget);
      expect(fonts.mine, isEmpty);
    });

    testWidgets('a font file is added, used, and lends its symbols to other fonts', (tester) async {
      await show(tester, const FontsScreen());

      picked = PickedBinaryFile(name: 'notes.txt', bytes: Uint8List.fromList('not a font'.codeUnits));
      await tester.tap(find.byKey(const Key('font-add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('isn\'t a font Promptly can read'), findsOneWidget);
      expect(fonts.mine, isEmpty);

      picked = PickedBinaryFile(name: 'HackNerdFontMono-Regular.ttf', bytes: fontBytes('Hack Nerd Font Mono'));
      await tester.tap(find.byKey(const Key('font-add')));
      await tester.pumpAndSettle();
      expect(find.text('Added Hack Nerd Font Mono. The terminal uses it now.'), findsOneWidget);
      expect(engine.settings['terminal_font'], '"Hack Nerd Font Mono"');
      expect(find.text('YOUR FONTS'), findsOneWidget);
      expect(fonts.loaded, ['Hack Nerd Font Mono'], reason: 'loaded from its file');
      final font = container.read(terminalFontProvider);
      expect(font.family, 'Hack Nerd Font Mono');
      expect(font.revision, 1, reason: 'measured again once loaded');

      // Another font in use draws the Nerd Font's symbols from it.
      await tester.tap(find.text('Fira Code'));
      await tester.pumpAndSettle();
      expect(container.read(terminalFontProvider).symbols.first, 'Hack Nerd Font Mono');

      await tester.tap(find.byTooltip('Remove Hack Nerd Font Mono'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('font-remove-ok')));
      await tester.pumpAndSettle();
      expect(fonts.mine, isEmpty);
      expect(find.text('YOUR FONTS'), findsNothing);
      expect(container.read(terminalFontProvider).symbols, TerminalFont.symbolFamilies);
      expect(engine.settings['terminal_font'], '"Fira Code"', reason: 'the font in use stays');
    });

    testWidgets('ligatures and keyboard suggestions are switched in Settings', (tester) async {
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      await show(tester, const SingleChildScrollView(child: Card(child: Column(children: [TextChoices(), TerminalChoices()]))));
      expect(find.text('JetBrains Mono, built in'), findsOneWidget);
      final ligatures = tester.widget<SwitchListTile>(find.byKey(const Key('ligatures')));
      expect(ligatures.value, isFalse);
      await tester.tap(find.byKey(const Key('ligatures')));
      await tester.pumpAndSettle();
      expect(engine.settings['terminal_ligatures'], 'true');
      expect(container.read(terminalFontProvider).ligatures, isTrue);

      expect(tester.widget<SwitchListTile>(find.byKey(const Key('autocorrect'))).value, isFalse);
      await tester.tap(find.byKey(const Key('autocorrect')));
      await tester.pumpAndSettle();
      expect(engine.settings['terminal_autocorrect'], 'true');

      // A computer has no keyboard to suggest words.
      touchPlatformOverride = false;
      await show(tester, const SingleChildScrollView(child: Card(child: Column(children: [TextChoices(), TerminalChoices()]))));
      expect(find.byKey(const Key('autocorrect')), findsNothing);
    });

    testWidgets('the font screen and the new settings fit a 360-wide phone at double text size', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);

      await show(tester, const FontsScreen());
      picked = PickedBinaryFile(name: 'a.ttf', bytes: fontBytes('A Font With Rather A Long Name', fixedPitch: false));
      await tester.tap(find.byKey(const Key('font-add')));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await tester.pumpAndSettle();

      await show(tester, const SingleChildScrollView(child: Card(child: Column(children: [TextChoices(), TerminalChoices()]))));
      expect(find.byKey(const Key('autocorrect')), findsOneWidget);
      // An overflow anywhere above would have failed the test.
    });
  });
}
